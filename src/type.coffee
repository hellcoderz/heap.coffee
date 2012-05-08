# `type.coffee` contains all the code having to do with analyzing types for
# generating code with a manual heap. Only local variables may be typed and
# types are file-local. To import external typed stuff unsafe casts are
# required.

{Scope} = require './scope'
{Base, Parens, Block, Value, Literal, Op, Assign, Try, If, Switch, Param,
 Code, Index, Access, Call, Return, Obj, While, Comment, Arr, Obj,
 TypeAssign, DeclareType, Cast, TypeArr, TypeObj,
 TypeName, PointerType, ArrowType, StructType} = require './nodes'
{flatten, extend, tystr} = require './helpers'

# Raise a type error.
error = (node, msg) ->
  err = new TypeError msg
  err.lineno = node.lineno
  throw err

#### Constants and Utilities

# The heap module that holds all the views.
HEAP    = new Value new Literal '_HEAP'
# Views.
I8V     = new Literal '_I8'
U8V     = new Literal '_U8'
I16V    = new Literal '_I16'
U16V    = new Literal '_U16'
I32V    = new Literal '_I32'
U32V    = new Literal '_U32'
F32V    = new Literal '_F32'
F64V    = new Literal '_F64'
# The cached stack pointer.
SP      = new Value new Literal '_SP'
# The actual stack pointer.
SPREAL  = new Value U32V, [new Index new Value new Literal 1]
# Memory operations.
MALLOC  = new Value new Literal 'malloc'
FREE    = new Value new Literal 'free'
MEMCPY  = new Value new Literal 'memcpy'

# Functions to get to the views, but also record in the scope that the view
# has been used so we can bring it in.
recorderForView = (view) -> (o) ->
  name = view.value
  # The exported view from the heap module doesn't start with underscores.
  o.scope.assign name, "#{HEAP.base.value}.#{name.substr name.lastIndexOf('_') + 1}"
  view
I8  = recorderForView I8V
U8  = recorderForView U8V
I16 = recorderForView I16V
U16 = recorderForView U16V
I32 = recorderForView I32V
U32 = recorderForView U32V
F32 = recorderForView F32V
F64 = recorderForView F64V

# Since all typed array views are aligned, we record the various views' sizes
# here for use in computing shifts.
I8.BYTES_PER_ELEMENT  = U8.BYTES_PER_ELEMENT  = 1
I16.BYTES_PER_ELEMENT = U16.BYTES_PER_ELEMENT = 2
I32.BYTES_PER_ELEMENT = U32.BYTES_PER_ELEMENT = 4
F32.BYTES_PER_ELEMENT = 4
F64.BYTES_PER_ELEMENT = 8

# Global option for if we should print warnings.
opts = { warn: false, unsafe: false }
printWarn = (line) -> process.stderr.write 'warning: ' + line + '\n' if opts.warn

# Convert a pointer aligned according to `lalign` to one aligned to `ralign`.
normalizePtr = (ptr, lalign, ralign) ->
  # We're done if they're the same size or if the ptr is 0 or null.
  if lalign is ralign or
     ((inner = ptr.unwrapAll()) instanceof Literal and
      inner.value is '0' or inner.value is 'null')
    return ptr
  # Compute the ratio.
  if lalign < ralign
    ratio = ralign / lalign
    op = '<<'
  else
    ratio = lalign / ralign
    op = '>>'
  # Pretty sure this is true all the time, commenting it out for now.
  # if ratio and not ((ratio & (ratio - 1)) is 0)
  #   error this, "ratio between primitive type sizes must be a power of 2"
  new Parens new Op op, ptr, new Value new Literal (Math.log(ratio) / Math.log(2))

# Generate an offset expression from `base`. The `base` is normalized
# according to the type of data (and the view needed) found at `offset`.
offsetExpr = (base, baseTy, offset, offsetTy) ->
  balign = baseTy.view.BYTES_PER_ELEMENT
  oalign = offsetTy.view.BYTES_PER_ELEMENT
  normalized = normalizePtr base, balign, oalign
  if offset isnt 0
    # Offsets are always in bytes, so compute the right offset now.
    new Op '+', normalized, new Value new Literal offset / oalign
  else
    normalized

# Calls `offsetExpr` with the stack pointer.
stackOffsetExpr = (offset, offsetTy) ->
  offsetExpr SP, SP.computedType, offset, offsetTy

# Multiply by a size. If the size is a power of 2, use left shift.
multExpr = (base, size) ->
  # Is size a power of 2?
  if size and ((size & (size - 1)) is 0)
    new Parens new Op '<<', base, new Value new Literal (Math.log(size) / Math.log(2))
  else
    new Op '*', base, new Value new Literal size

# Ensure that a variable is fresh by transforming just-in-time.
freshVariable = (name) ->
  lit = new Literal
  lit.transformNode = (o) ->
    @value = o.scope.freeVariable name
    delete this.transformNode
    return
  lit

# A box used to record a local variable's type and other metadata.
class Binding
  constructor: (@type) ->

# This is like *Scope::type*, but it also looks up the scope chain.
Scope::binding = (name, immediate) ->
  found = @type name
  return found if found or immediate
  @parent?.binding name

# Many of the algorithms we do here are more naturally expressed as folds.
# Also, instead of passing in a function, pass in a prop to be called on each
# child, which pushes the typecase into the VM.
Base::foldChildren = (r, pre, post, o) ->
  r = if typeof @[pre] is 'function' then @[pre](r, o) else r
  return r unless @children

  if o.immediate
    for attr in @children when @[attr]
      for child in flatten [@[attr]]
        r = if typeof child[pre] is 'function' then child[pre](r, o) else r
        r = if post and typeof child[post] is 'function' then child[post](r, o) else r
  else
    for attr in @children when @[attr]
      for child in flatten [@[attr]]
        r = child.foldChildren r, pre, post, o

  if post and typeof @[post] is 'function' then @[post](r, o) else r

Code::foldChildren = (r, pre, post, o) ->
  return r unless o.crossScope
  super(r, pre, post, (extend {}, o))

# Collect type synonyms.
TypeAssign::collectType = (types) ->
  types[@name] = @type
  types

#### Type Linting

# Align an offset according to its size.
alignOffset = (offset, ty) ->
  size = ty.view.BYTES_PER_ELEMENT
  (((offset - 1) / size + 1) | 0) * size

# Number of units in alignment size.
alignmentUnits = (ty) -> ty.size / ty.view.BYTES_PER_ELEMENT

# Sanity check the type and compute the size. Expects synonyms to already have
# been computed.
#
# We have the following restrictions:
#
#  - struct types are nominal
#  - pointers can only be taken on sized types
TypeName::lint = (types) ->
  error this, "circular type synonym: #{@name}" if @linting
  return @linted if @linted
  @linting = true
  error this, "cannot resolve type `#{@name}'" unless @name of types
  linted = types[@name]?.lint types
  delete @linting
  @linted = linted

PointerType::size = 4
PointerType::view = U32
PointerType::baseAlignment = -> @base?.view.BYTES_PER_ELEMENT or 1

PointerType::lint = (types) ->
  return this if @linted
  @linted = true
  @base = base = @base.lint types
  if base and not base.size
    error this, "cannot take pointers of unsized type `#{base}'"
  this

PointerType::coerce = (expr) ->
  ty = expr.unwrapAll().computedType
  return expr unless ty instanceof PointerType and ty isnt this
  normalizePtr expr, this.baseAlignment(), ty.baseAlignment()

TypeArr::lint = (types) ->
  return this if @linted
  @linted = true
  @elements[i] = el.lint types for el, i in @elements
  this

TypeObj::lint = (types) ->
  return this if @linted
  @linted = true
  field.type = field.type.lint types for field in @fields
  this

StructType::lint = (types) ->
  return this if @linted
  @linted = true
  # Have a fake non-0 size for now to deal with recursive linting so pointers
  # don't complain.
  @size = 1
  fields = @fields
  field.type = field.type.lint types for field in fields
  # Make an imaginary first field whose offset and size is 0.
  prev = offset: 0, type: { size: 0 }
  # The size of the struct is the its maximum offset + the size of the largest
  # field with that offset.
  size = 0
  # Start off with the smallest view, `U8`.
  maxView = U8
  # An undefined offset tells the typechecker to fill it in from the
  # previous field. For example,
  #
  #     struct { [4] i :: int, j :: int }
  #
  # is the same as
  #
  #     struct { [4] i :: int, [8] j :: int }
  #
  # The first field's offset is 0 if undefined.
  #
  # The special form [-] means to use the same offset as the previous
  # field. For example,
  #
  #     struct { i :: int, [-] j :: int }
  #
  # is the same as
  #
  #     struct { [0] i :: int, [0] j ::
  #
  # Since there is an imaginary first field with an offset of 0, you can use
  # `[-]` on the first field too to make everything line up.
  #
  # The special form `[+]` means add the size of the previous field to the
  # previous field's offset for the current offset. This is the default
  # behavior when no offset attribute exists.
  #
  # Field offsets must be aligned to the type of the field.
  for field in fields
    ty = field.type
    unless ty.size
      error this, "cannot store unsized type `#{ty}' as a struct field"
    # Record the max view encountered to set as the view of this struct.
    maxView = ty.view if ty.view.BYTES_PER_ELEMENT > maxView.BYTES_PER_ELEMENT
    if (offset = field.offset)?
      error this, "struct field offsets cannot be negative" if offset < 0
      if offset < prev.offset
        printWarn "offset of field `#{field.name}' is smaller offset of previous field"
      if offset isnt alignOffset offset, ty
        error this, "manual offset [#{offset}] cannot be aligned to `#{ty}'"
    else if field.usePreviousOffset
      # If the previous offset isn't aligned to the current field's size, move
      # both up.
      if (field.offset = alignOffset prev.offset, ty) isnt prev.offset
        prev.offset = field.offset
    else
      field.offset = alignOffset prev.offset + prev.type.size, ty
    size = s if (s = field.offset + ty.size) > size
    prev = field
  # Pointers of incompatible types cannot be at the same offset due to
  # alignment.
  for field in fields when (ty = field.type) instanceof PointerType
    for field2 in fields when field2.offset is field.offset and
                              (ty2 = field2.type) instanceof PointerType
      # Print warnings about unioning incompatible pointer types, which is
      # unsafe.
      unify types, ty, ty2, true and unify types, ty2, ty, true
  # Pad the size to a multiple of the alignment.
  align = maxView.BYTES_PER_ELEMENT
  @size = (((size - 1) / align + 1) | 0) * align
  @view = maxView
  this

ArrowType::lint = (types) ->
  return this if @linted
  @linted = true
  ty = @ret.lint types
  @ret = ty
  params = @params
  for ty, i in params
    params[i] = ty.lint types
  this

#### Type Checking

# Unify two types, if possible, into a single type. If `assign` is true, then
# this behaves asymmetrically for pointer types and automatic promotions of
# primitive types.
unify = (types, lty, rty, assigning) ->
  # Unify is reflexive.
  return lty if lty is rty
  # If the left side is dynamic, the entire expression is dynamic.
  return unless lty and rty
  # Two pointer types are unifiable iff their bases are size compatible.
  if lty instanceof PointerType and rty instanceof PointerType
    if assigning
      # Assigning a narrower pointer to a wider one may mess up due to
      # alignment, since all views are aligned.
      if rty.base and rty.baseAlignment() < lty.baseAlignment()
        printWarn "incompatible pointer conversion from `#{rty}' to `#{lty}' may alter its value"
      return lty
    else
      # If we're not assigning, the base types have to be exactly the same.
      return lty if lty.base is rty.base
  # Two function types are unifiable if they are point-wise unifiable.
  if lty instanceof ArrowType and rty instanceof ArrowType
    lptys = lty.params
    rptys = rty.params
    return unless lptys.length is rptys.length
    ptys = []
    for lpty, i in lptys
      ptys.push unify types, lpty, rptys[i], assigning
    return new ArrowType ptys, unify(types, lty.ret, rty.ret, assigning)
  if lty instanceof PointerType and rty in integral
    printWarn "conversion from `#{rty}' to pointer without cast"
    return lty
  if lty in integral and rty instanceof PointerType
    printWarn "conversion from pointer to `#{lty}' without cast"
    return lty
  # Primitive types follow C-like promotion rules.
  if lty in numeric and rty in numeric
    # If we're assigning, return the left type, else return the wider primitive.
    if lty.size isnt rty.size
      printWarn "conversion from `#{rty}' to `#{lty}' may alter its value"
      return if assigning then lty else if lty.size > rty.size then lty else rty
    # Return the sign of the left type if they're the same size. This is just
    # to break the tie arbitrarily and to behave as expected for assignments.
    if lty.signed isnt rty.signed
      printWarn "conversion from `#{rty}' to `#{lty}' may alter its sign"
      return lty
  null

# Is this **Op** a dereference?
Op::isAssignable = Op::isDeref = -> not @second and @operator is '*'

# A block gets the type of its tail expression.
Block::computeType = (r, o) ->
  # A block of only one item will be taken care of by unwrapAll.
  exprs = @expressions
  return unless exprs.length > 1
  return @computedType if @typeCached
  @typeCached = true
  @computedType = exprs[exprs.length - 1].unwrapAll().computedType

# An if gets the unified type of both of its branches.
If::computeType = (r, o) ->
  return @computedType if @typeCached
  @typeCached = true
  thenTy = @body?.unwrapAll().computedType
  elseTy = @elseBody?.unwrapAll().computedType
  @computedType = ty = unify o.types, thenTy, elseTy
  if (thenTy or elseTy) and not ty
    printWarn "branches of if have different types: `#{tystr(thenTy)}' and `#{tystr(elseTy)}'"

# A switch gets the unified type of all its cases.
Switch::computeType = (r, o) ->
  return @computedType if @typeCached
  @typeCached = true
  types = o.types
  caseTys = []
  someCaseJumps = false
  someCaseTyped = false
  for [conds, block], i in @cases
    if block.jumps()
      ty = null
      someCaseJumps = true
    else
      ty = block.unwrapAll().computedType
    caseTys.push ty
    someCaseTyped = true if ty
    if i is 0
      cty = ty
    else
      cty = unify types, ty, cty
  cty = unify types, @otherwise.unwrapAll().computedType, cty if @otherwise
  if someCaseTyped and not cty
    if someCaseJumps
      printWarn "cannot type switch with jumps"
    else
      printWarn "branches of switch have different types: `#{(tystr(ty) for ty in caseTys).join('\', `')}'"
  @computedType = cty

# Casting coerces the expression to a certain type.
Cast::computeType = (r, o) ->
  return @computedType if @typeCached
  @typeCached = true
  @computedType = @type.lint o.types

# Assignments do asymmetric type unification.
assign = (o, lval, rval, context) ->
  if lval instanceof Value
    if lval.isArray()
      rval = if rval.isArray() then rval.base else null
    else if lval.isObject()
      rval = if rval.isObject() then rval.base else null
    else if lval.this
      return
    lval = lval.base
  if lval instanceof Literal and lty = lval.computedType
    # As a convenience if the left-hand side is a pointer and the right-hand
    # side is 0, replace the right-hand side with null, which has the type *any
    # to suppress int-to-pointer warnings.
    if rval?
      value = rval.unwrapAll()
      if lty instanceof PointerType and value instanceof Literal and value.value is '0'
        value.computedType = anyPtrTy
      # `context` can only be passed in from `Assign::computeType'. This is okay
      # since compound assignments only have **SimpleAssignable**s as lvals.
      rty = if context
        op = context.substr 0, context.indexOf '='
        binopType o, op, lty, value.computedType, lval
      else
        value.computedType
    else
      rty = null
    unless unify o.types, lty, rty, true
      msg = "incompatible types: assigning `#{tystr(rty)}' to `#{lty}'"
      if context
        error lval, msg + " using #{context}"
      else
        error lval, msg
  else if lval instanceof Arr
    robjects = rval?.objects
    assign o, lel, robjects?[i] for lel, i in lval.objects
  else if lval instanceof Obj
    # Build property-name mapping.
    props = {}
    if rval?
      for prop in rval.properties
        prop = prop.variable if prop.isComplex()
        if prop?
          propName = prop.unwrapAll().value.toString()
          props[propName] = prop
    for obj in lval.objects
      if obj instanceof Assign
        assign o, obj.value, props[obj.variable.unwrapAll().value]
      else if obj instanceof Value
        assign o, obj.base, props[obj.base.unwrapAll().value]

Assign::computeType = (r, o) ->
  if @context is 'object'
    delete @variable.computedType
    return
  return @computedType if @typeCached
  @typeCached = true
  assign o, (variable = @variable), @value, @context
  # Complex left-hand sides (destructuring assignments) always have dynamic type.
  @computedType = variable.computedType unless variable.isComplex()

# Accesses on struct types may be typed. If we arrived at this case it's
# because `unwrapAll()` didn't manage to unwrap value, i.e. this is a properties
# access.
Value::computeType = (r, o) ->
  return @computedType if @typeCached
  @typeCached = true
  inner = @base.unwrapAll()
  # Only literals that are values should get types. We don't want to transform
  # properties. Simple identifiers and integer literals may be typed.
  if inner instanceof Literal
    val = inner.value
    inner.computedType = if val is 'null'
      anyPtrTy
    else if inner.isAssignable()
      (@computedBinding = o.scope.binding val)?.type
    else if inner.isSimpleNumber()
      i32ty
    else if not isNaN number val
      f64ty
  if baseTy = inner.computedType
    for prop in @properties
      baseTy = baseTy.base if baseTy instanceof PointerType
      return unless baseTy instanceof StructType
      error this, "cannot soak struct field names" if prop.soak
      fieldName = prop.name.unwrapAll().value
      field = prop.computedField = baseTy.names[fieldName]
      error this, "unknown struct field name `#{fieldName}'" unless field
      baseTy = field.type
    @computedType = baseTy

# Functions may be typed if their parameters are typed and all return
# expression types are compatible.
Code::computeType = (r, o) ->
  return @computedType if @typeCached
  @typeCached = true
  # Cache the stack-allocated variables and their offsets.
  @spOffsets = spOffsets o.scope
  @frameSize = o.scope.frameSize
  # Arriving in this function means that all the parameters typechecked, since
  # this is called after the body has been processed. So we just need to
  # collect the return expressions and compatible their types.
  types = o.types
  for rexpr, i in returnExpressions @body
    if i is 0
      rty = rexpr.unwrapAll().computedType
    else
      rty = unify types, rexpr.unwrapAll().computedType, rty
  @computedType = new ArrowType @paramTypes, rty

# Applications may be typed if the function is typed and the parameter types
# unify asymmetrically.
Call::computeType = (r, o) ->
  return @computedType if @typeCached
  @typeCached = true
  return unless fty = @variable?.unwrapAll().computedType
  error this, "calling a non-function type `#{fty}'" unless fty instanceof ArrowType
  paramTys = fty.params
  args = @args
  types = o.types
  for pty, i in fty.params
    # If fewer arguments than there are parameters were passed, this will be
    # `undefined` and interpreted as the type `any`.
    aty = args[i]?.computedType
    if pty and not unify types, pty, aty, true
      error this, "incompatible types: passing arg `#{tystr(aty)}' to param `#{tystr(pty)}'"
  # If all the arguments checked, the call gets the return type.
  @computedType = fty.ret

# Allocations, pointer arithmetic, and foldably constant arithmetic
# expressions may be typed.
ARITH   = [ '+', '-', '*', '/' ]
BITWISE = [ '<<', '>>', '>>>', '~', '&', '|' ]
COMPARE = [ '===', '!==', '<', '>', '<=', '>=' ]

binopType = (o, op, ty1, ty2, node) ->
  if (op is '+' or op is '-') and ty1 instanceof PointerType
    if ty2 in integral
      ty1
    else if op is '-' and ty2 instanceof PointerType
      unless unify o.types, ty1.base, ty2.base
        printWarn "pointer subtraction on incompatible pointer types `#{tystr(ty1)}' and `#{ty2}'"
      i32ty
    else
      error node, "invalid operand type `#{tystr(ty2)}' for pointer arithmetic"
  else if op is '%'
    i32ty
  else if op in COMPARE
    if ty1 instanceof PointerType and ty2 instanceof PointerType and
       not unify o.types, ty1, ty2
      printWarn "comparison between incompatible pointer types `#{tystr(ty1)}' and `#{tystr(ty2)}'"
    i32ty
  else if op in BITWISE
    i32ty
  else if op in ARITH and ty1 in numeric and ty2 in numeric
    f64ty

Op::computeType = (r, o) ->
  return @computedType if @typeCached
  @typeCached = true

  op  = @operator

  if @isUnary()
    first = @first.unwrapAll()
    return @computedType = if op is 'new' and first.value of o.types
      ty1 = o.types[first.value]
      error this, "cannot allocate unsized type `#{ty1}'" unless ty1?.size
      Scope.root.needsMalloc = yes
      new PointerType ty1
    else if op is 'delete' and (ty1 = first.computedType)
      error this, 'cannot free non-pointer type' unless ty1 instanceof PointerType
      Scope.root.needsMalloc = yes
      null
    else if op is 'sizeof'
      ty1 = @first = @first.lint o.types
      error this, "cannot determine size of type `#{ty1}'" unless ty1.size
      i32ty
    else if op is '&'
      ty1 = first.computedType
      error this, "taking reference of an untyped expression `#{@first.compile o}'" unless ty1
      error this, "taking reference of a function type" if ty1 instanceof ArrowType
      error this, "taking reference of non-assignable" unless first.isAssignable()
      # Can't take references of upvars.
      if first instanceof Literal
        name  = first.value
        scope = o.scope
        unless scope.check name, true
          error this, "taking reference of non-local or undefined variable `#{name}'"
        putOnStack scope, name
      new PointerType ty1
    else if op is '*' and (ty1 = first.computedType)
      error this, "dereferencing an untyped expression:\n#{@first}" unless ty1
      error this, "dereferencing a non-pointer type" unless ty1 instanceof PointerType
      ty1.base
    else if (op is '++' or op is '--') and ty1 = first.computedType
      ty1 if ty1 instanceof PointerType or ty1 in integral

  ty1 = @first.unwrapAll().computedType
  ty2 = @second.unwrapAll().computedType

  # Commute.
  if ty2 instanceof PointerType
    tmp = ty1
    ty1 = ty2
    ty2 = tmp

  @computedType = binopType o, op, ty1, ty2, this

# Gather return expressions.
returnExpressions = (body) ->
  exprs = body.expressions
  body.foldChildren [exprs[exprs.length - 1]], 'returnExpression', null, {}

undefExpr = new Value new Literal 'undefined'

Return::returnExpression = (exprs, o) ->
  # @expression could be undefined, which means it's returning null.
  exprs.push @expression or undefExpr
  exprs

# Add parameter and return types to the typed scope.
newTypedScope = (p, e, m) ->
  scope = new Scope p, e, m
  scope.variables.length = 0
  scope.frameSize = 0
  scope

# Find function bindings to match up arrow types.
#
# This is not a full-fledged type system, so this behavior is just to provide
# a convenience. The following
#
#     f :: (int) -> int
#     f =  (x) -> x
#
# is equivalent to
#
#     f :: (int) -> int
#     f =  (x) :: (int) -> x
#
# _only_ when the binding for f is a _syntactic_ function. If not, you would
# have to declare the types of arguments manually.
Assign::primeComputeType = (r, o) ->
  if (fn = @value.unwrapAll()) instanceof Code and
     (name = @variable.unwrapAll()) instanceof Literal and name.isAssignable() and
     (ty = o.scope.binding(name.value)?.type) instanceof ArrowType
    # Remember the parameter and return types on the right-hand side. The
    # return type is only used to propagate the types further, if it is
    # another arrow type.
    fn.paramTypes ?= ty.params
    fn.returnType ?= ty.ret
  return

# Declare parameter types, and propagate the return type to return expressions
# if the return type is an arrow type.
Code::primeComputeType = (r, o) ->
  # If the declared return type is an arrow type, recur on all return
  # positions and propagate.
  rty = @returnType
  if rty instanceof ArrowType
    for rexpr in returnExpressions @body when rexpr instanceof Code
      rexpr = rexpr.unwrapAll()
      rexpr.paramTypes ?= rty.params
      rexpr.returnType ?= rty.ret
  # Make a new scope and declare parameter types.
  o.scope = newTypedScope o.scope, @body, this
  ptys = @paramTypes
  if ptys
    if ptys.length isnt @params.length
      error this, "arrow type has different number of parameters than function"
    types = o.types
    for param, i in @params
      param.type = ptys[i]
      param.declareType r, o
  # Hoist all the **DeclareType**s to the top and process them. We shouldn't cross
  # scope here.
  @body.foldChildren null, 'declareType', null, types: o.types, scope: o.scope
  return

# Declaring a type associates a type with the variable in the current
# scope. Destructuring is allowed, but each destructured variable must get a
# simple type, i.e. not a **TypeArr** or a **TypeObj**.
declare = (scope, v, ty, variables) ->
  if v instanceof Literal
    name = v.value
    error v, "cannot redeclare typed variable `#{name}'" if scope.check name
    return unless ty
    if ty instanceof TypeArr or ty instanceof TypeObj
      error v, "cannot type non-destructuring variable with destructuring type `#{ty}'"
    bind = new Binding ty
    scope.add name, bind
    variables.push { name, type: ty, binding: bind }
    putOnStack scope, name if ty instanceof StructType
    return
  if v instanceof Value
    error v, "cannot type properties" if v.hasProperties()
    v = v.base
  if v instanceof Arr
    els = v.objects
    unless ty instanceof TypeArr
      error v, "cannot type destructuring array with non-destructuring array type `#{ty}'"
    for el, i in els
      if el.this
        error v, "cannot type @-names"
      else
        declare scope, el.base, ty.elements[i], variables
    return
  if v instanceof Obj
    objs = v.objects
    unless ty instanceof TypeObj
      error v, "cannot type destructuring object with non-destructuring object type `#{ty}'"
    for obj in objs
      if obj instanceof Assign
        name = obj.variable.base
        declare scope, obj.value, ty.names[name.value]?.type, variables
      else if obj.this
        error v, "cannot type @-names"
      else
        name = obj.base
        declare scope, name, ty.names[name.value]?.type, variables
    return
  error v, "trying to type non-typeable"

DeclareType::declareType = (r, o) ->
  scope = o.scope
  declare scope, v, @type.lint(o.types), (@variables = []) for v in @typeables
  return

Param::declareType = (r, o) ->
  # Lint just in case the user manually declared the parameter types and
  # thus the types were not linted before this point.
  scope = o.scope
  declare scope, this.name, @type.lint(o.types), (@variables = [])
  return

#### AST Transformation

# Put a variable on the stack and increment the frame size.
putOnStack = (scope, name) ->
  bind = scope.binding name, true
  bind.onStack = true
  bind.spOffset = alignOffset scope.frameSize, bind.type
  scope.frameSize = bind.spOffset + bind.type.size
  return

# Condense a typed scope to a map of variable names to sp offsets.
spOffsets = (scope) ->
  offsets = []
  for { name, type: bind } in scope.variables when bind.onStack
    offsets.push { name, offset: bind.spOffset, ty: bind.type }
  offsets

# Dereference something in a heap view.
makeDeref = (o, base, baseTy, offset, offsetTy) ->
  new Value offsetTy.view(o), [new Index offsetExpr base, baseTy, offset, offsetTy]

# Generate an inline memcpy.
inlineMemcpy = (o, dest, src, ty) ->
  scope = o.scope
  stmts = []
  # Store the pointer to the struct we're copying to.
  destPtr = freshVariable 'dest'
  destPtr.computedType = dest.computedType
  stmts.push new Assign new Value(destPtr), dest
  # Store the pointer to the struct we're copying from.
  srcPtr = freshVariable 'src'
  srcPtr.computedType = src.computedType
  stmts.push new Assign new Value(srcPtr), src
  # Unroll the copy loop over the bytes.
  if ty instanceof StructType
    # We can do better than byte-by-byte if we're memcpying a struct. We need
    # to manually set the computedType so they get transformed properly in
    # `Value::transformNode`.
    for field in ty.fields
      access = new Access new Literal field.name
      access.computedField = field
      fty = field.type
      destProp = new Value destPtr, [access]
      destProp.computedType = fty
      srcProp = new Value srcPtr, [access]
      srcProp.computedType = fty
      asn = new Assign destProp, srcProp
      asn.computedType = fty
      stmts.push asn
  else
    for i in [0...ty.size]
      offset = new Value new Literal i
      stmts.push new Assign new Value(U8(o), [new Index new Op '+', new Value(destPtr), offset]),
                            new Value(U8(o), [new Index new Op '+', new Value(srcPtr), offset])
  stmts.push new Value destPtr
  new Value new Parens new Block stmts

# Reflect a heap-allocated struct as a JavaScript object literal.
structLiteral = (v, ty, o) ->
  ptr = freshVariable 'ptr'
  propList = []
  for field in ty.fields
    fname = field.name
    # Use transform here to get a struct literal out, since we have to compute
    # the offset for the field. We have to manually set the types, kind of
    # gross.
    access = new Access new Literal fname
    access.computedField = field
    propValue = new Value ptr, [access]
    propValue.computedType = field.type
    propList.push new Assign new Value(new Literal fname), propValue.transformNode(), 'object'
  obj = new Value new Obj propList
  new Value new Parens new Block [new Assign(new Value(ptr), v), obj]

# Transform a function to have the right stack pointer computations upon entry
# and exit. The safe way is to wrap the entire body of the function in a
# `try..finally` block to account for possible throws. If the user indicated
# `gotta-go-fast`, we'll only emit stack pointer computations for explicit
# returns.
stackFence = (o, exprs, frameSize, spOffsets, isRoot) ->
  # The stack uses `U32`, so record it manually.
  U32(o)
  # Assign all the on-stack locals to their addresses.
  scope = o.scope
  for { name, offset, ty } in spOffsets
    exprs.unshift new Assign new Value(new Literal name), stackOffsetExpr(offset, ty)
  exprs.unshift new Assign SP, normalizePtr(SPREAL, U32.BYTES_PER_ELEMENT, 1)
  exprs.unshift new Assign SPREAL, new Value(new Literal frameSize), '-='
  restoreStack = new Assign SPREAL, new Value(new Literal frameSize), '+='
  if opts.unsafe
    exprs.push restoreStack if isRoot
  else
    exprs[0] = new Try new Block(exprs.slice()), null, null, new Block [restoreStack]
    exprs.length = 1
  return

# Coerce to a type.
Cast::transformNode = (o) ->
  return @computedType.coerce?(@expr)

# Add `SP` computations and bring in heap views if needed.
Code::transformNode = (o) ->
  o.returnType = @computedType?.ret
  if frameSize = @frameSize
    # All parameters that need to be stack allocated need to not be emitted as
    # stack dereferences in the parameter list and we have to copy over the
    # argument.
    exprs = @body.expressions
    for param in @params
      for arg in param.variables
        if arg.binding.onStack
          arg.save = freshVariable arg.name
          plh = new Value new Literal arg.name
          prh = new Value arg.save
          asn = new Assign plh, prh
          asn.computedType = plh.computedType = prh.computedType = arg.type
          plh.computedBinding = arg.binding
          exprs.unshift asn
    o.frameSize = frameSize
    stackFence o, exprs, frameSize, @spOffsets
    for param in @params
      for { name, save } in param.variables
        exprs.unshift new Assign new Value(save), new Value new Literal name
  return

# Add SP computation and pointer conversions to explicit returns.
Return::transformNode = (o) ->
  # First transform for pointer conversion.
  @expression = ty.coerce?(@expression) if ty = o.returnType
  # Then transform for any stack fencing we need to do.
  return unless (frameSize = o.frameSize) and opts.unsafe
  restoreStack = new Assign SPREAL, new Value(new Literal frameSize), '+='
  if expr = @expression
    body = new Block
    body.transformNode = (o) ->
      tmp = new Value freshVariable 't'
      @expressions = [new Assign(tmp, expr), restoreStack, tmp]
      return
  else
    body = new Block [restoreStack, new Return]
  @expression = new Value new Parens body
  return

# Need to convert pointers when passing them as arguments.
Call::transformNode = (o) ->
  return unless fty = @variable?.unwrapAll().computedType
  paramTys = fty.params
  args = @args
  for pty, i in fty.params
    args[i] = pty.coerce?(args[i])
  return

# Transform this Value into a new Value that does offset index lookups on
# the heap.
Value::transformNode = (o) ->
  return unless ty = @computedType
  base  = @base
  inner = base.unwrapAll()
  props = @properties
  unless props.length
    if inner instanceof Literal
      if @computedBinding?.onStack and
         ty not instanceof StructType and not inner.noStackDeref
        # Treat stack accesses as dereferences, except for structs, which are
        # kept as offsets. FIXME: it's unclear what raw use of a
        # stack-allocated struct means right now.
        return new Value U32(o), [new Index new Value new Literal inner.value]
      if inner.value is 'null' and ty instanceof PointerType
        # This matters for TI: null will cause the typeset of pointers to be
        # dimorphic.
        inner.value = '0'
    return
  # If we're explicitly dereferencing the struct base, treat it like we
  # weren't.
  v = if inner.isDeref?() then inner.first else base
  vty = v.unwrapAll().computedType
  cumulativeOffset = 0
  for prop in props
    field = prop.computedField
    if (fty = field.type) instanceof StructType
      cumulativeOffset += field.offset
    else
      v = makeDeref o, v, vty, field.offset + cumulativeOffset, fty
      vty = fty
      cumulativeOffset = 0
  if fty instanceof StructType and cumulativeOffset isnt 0
    new Op '+', v, new Value new Literal cumulativeOffset
  else
    v

# Do struct copy semantics here since it requires a non-local transformation,
# i.e. it can't be compiled by transforming the lval and rval individually.
Assign::transformNode = (o) ->
  return unless lty = @computedType
  if lty instanceof StructType
    lval = @variable.unwrapAll()
    return inlineMemcpy o, (if lval.isDeref?() then lval.first else @variable), @value, lty
  if lty instanceof PointerType and @context and (au = alignmentUnits lty.base) isnt 1
    @value = new Op('*', @value, new Value new Literal au)
  else if lty.coerce
    @value = lty.coerce @value
  return

# Typed new and delete are transformed to malloc and free, and pointer
# arithmetic also needs to be transformed.
Op::transformNode = (o) ->
  return unless @computedType or @first.computedType
  op = @operator
  if @isUnary()
    if op is 'new' and ty1 = @computedType
      new Call MALLOC, [new Value new Literal ty1.base.size]
    else if op is 'delete'
      new Call FREE, [@first]
    else if op is 'sizeof'
      new Literal @first.size
    else if op is '&'
      if @computedType.base instanceof StructType
        # If we're taking the pointer of a struct, we don't need to do anything
        # since structs are kept as pointers.
        @first
      else
        # Otherwise we must be doing a dereference, so transform it now and
        # get out the index expression, which must be the address.
        @first.unwrapAll().transformNode(o).properties[0].index
    else if op is '*'
      # This is only called when this deref is _not_ the base of a struct
      # access, as in struct accesses, dereferencing is the same as not
      # dereferencing, since . is extended to work like -> in C.
      ty1 = @first.computedType
      makeDeref o, @first, ty1, 0, ty1
    else if (op is '++' or op is '--') and
            (ty1 = @computedType) instanceof PointerType and
            (au = alignmentUnits ty1.base) isnt 1
      # If `p` is type `*T`, p++` desugars to `(p += sizeof T, p - sizeof T)`.
      size = new Value new Literal au
      if op is '++'
        op1 = '+='
        op2 = '-'
      else
        op1 = '-='
        op2 = '-'
      new Value new Parens new Block [new Assign(@first, size, op1),
                                      new Op(op2, @first, size)]
  else
    # Don't return a new Op so we don't have to set transform to null to
    # prevent unbounded recursion.
    ty1 = @first.computedType
    ty2 = @second.computedType
    if (op is '+' or op is '-') and
       ((ty1 instanceof PointerType and ty2 in integral and
         (au = alignmentUnits ty1.base) isnt 1) or
        (ty2 instanceof PointerType and ty1 in integral and
         (au = alignmentUnits ty2.base) isnt 1))
      size = new Value new Literal au
      if ty1 instanceof PointerType
        @second = new Op('*', @second, size)
      else
        @first = new Op('*', @first, size)
    else if op in COMPARE and
         ty1 instanceof PointerType and ty2 instanceof PointerType
      # By convention always normalize the second operand.
      @second = ty1.coerce @second
    return

# Coerce to an integral type.
coerceIntegral = (width, signed) -> (expr) ->
  ty = expr.unwrapAll().computedType
  return expr unless ty isnt this
  # Do we need to truncate? Bitwise operators automatically truncate to 32
  # bits in JavaScript so if the width is 32, we don't need to do manual
  # truncation.
  if width isnt 32 and ty.size << 3 > width
    c = new Op '&', expr, new Value new Literal '0x' + ((1 << width) - 1).toString(16)
    # Do we need to sign extend?
    if signed
      shiftBy = new Value new Literal 32 - width
      c = new Op '>>', new Op('<<', c, shiftBy), shiftBy
    c
  else if ty.signed isnt signed
    new Op (if signed then '|' else '>>>'), expr, new Value new Literal '0'
  else
    expr

#### Driver

# Primitive types as found in C.
class PrimitiveType
  constructor: (@size, @debugName, @view, @signed, @coerce) ->
  lint: (types) -> this
  toString: -> @debugName

# Cache this for typing null values.
anyPtrTy = new PointerType null

# Builtin primitives.
i8ty  = new PrimitiveType 1, 'i8',  I8,  yes, coerceIntegral(8,  yes)
u8ty  = new PrimitiveType 1, 'u8',  U8,  no,  coerceIntegral(8,  no)
i16ty = new PrimitiveType 2, 'i16', I16, yes, coerceIntegral(16, yes)
u16ty = new PrimitiveType 2, 'u16', U16, no,  coerceIntegral(16, no)
i32ty = new PrimitiveType 4, 'i32', I32, yes, coerceIntegral(32, yes)
u32ty = new PrimitiveType 4, 'u32', U32, no,  coerceIntegral(32, no)
f64ty = new PrimitiveType 8, 'double', F64, yes

# Number type sets.
integral = [ i8ty, u8ty, i16ty, u16ty, i32ty, u32ty ]
numeric  = integral.concat [ f64ty ]

# The local stack pointer is a `u32`.
SP.computedType = u32ty
# The actual stack pointer is a `u8`.
SPREAL.computedType = u8ty
SPREAL.transformNode = null

requireExpr = (name) ->
  new Call new Value(new Literal 'require'), [new Value new Literal "'#{name}'"]

exports.analyzeTypes = (root, o) ->
  usesTypes = no
  root.traverseChildren yes, (node) ->
    if (node instanceof DeclareType) or
       (node instanceof Op and node.isUnary() and
        (node.operator is '&' or node.operator is '*')) or
       (node instanceof Code and node.paramTypes)
      usesTypes = yes
      return no
  return unless usesTypes

  # Global options.
  opts.warn   = o.warn
  opts.unsafe = o.unsafe

  initialTypes =
    any:    null
    # Integrals.
    i8:     i8ty
    u8:     u8ty
    i16:    i16ty
    u16:    u16ty
    i32:    i32ty
    u32:    u32ty
    # Aliases.
    byte:   u8ty
    short:  i16ty
    int:    i32ty
    uint:   u32ty
    # Floating point.
    double: f64ty
    num:    f64ty

  types = root.foldChildren initialTypes, 'collectType', null, immediate: true
  types[name] = ty.lint types for name, ty of types when ty

  scope = newTypedScope null, root, null
  options = types: types, scope: scope
  root.foldChildren null, 'declareType', null, options
  options.crossScope = true
  root.foldChildren null, 'primeComputeType', 'computeType', options
  root.spOffsets = spOffsets scope
  root.frameSize = scope.frameSize
  root.transformRoot = (o) ->
    # Require the heap. This has to be done using `o.scope.assign`, to make sure
    # that it comes before the cached views.
    o.scope.assign HEAP.base.value, "require('heap/heap')"
    # Do the stack fence for the module.
    exprs = @expressions
    if frameSize = @frameSize
      o.frameSize = frameSize
      stackFence o, exprs, frameSize, @spOffsets, yes
    # Bring in `malloc` if this module needs it.
    if scope.needsMalloc
      obj = new Value new Obj [MALLOC, FREE]
      exprs.unshift new Assign obj, requireExpr 'heap/malloc'
  types
