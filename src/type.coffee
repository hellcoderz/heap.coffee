# `type.coffee` contains all the code having to do with analyzing types for
# generating code with a manual heap.
#
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# !! THIS IS NOT A GOOD TYPE SYSTEM !!
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#
# Only local variables may be typed and types are file-local. To import
# external typed stuff unsafe casts are required.

{Scope} = require './scope'
{Base, Parens, Block, Value, Literal, Op, Assign, Try,
 Code, Index, Access, Call, Return, Obj, While, Comment,
 TypeAssign, DeclareType, Cast,
 TypeName, PointerType, ArrowType, StructType} = require './nodes'
{flatten, extend, tystr} = require './helpers'

# The heap module that holds all the views.
HEAP    = new Value new Literal '_HEAP'
# Views.
I8V     = new Literal '_I8'
U8V     = new Literal '_U8'
I16V    = new Literal '_I16'
U16V    = new Literal '_U16'
I32V    = new Literal '_I32'
U32V    = new Literal '_U32'
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

# Used to compute shifts.
I8.BYTES_PER_ELEMENT  = U8.BYTES_PER_ELEMENT  = 1
I16.BYTES_PER_ELEMENT = U16.BYTES_PER_ELEMENT = 2
I32.BYTES_PER_ELEMENT = U32.BYTES_PER_ELEMENT = 4

# Global option for if we should print warnings.
opts = { warn: false, unsafe: false }
printWarn = (line) -> process.stderr.write 'warning: ' + line + '\n' if opts.warn

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
  #   throw TypeError "ratio between primitive type sizes must be a power of 2"
  new Parens new Op op, ptr, new Value new Literal (Math.log(ratio) / Math.log(2))

offsetExpr = (base, baseTy, offset, offsetTy) ->
  balign = baseTy.view.BYTES_PER_ELEMENT
  oalign = offsetTy.view.BYTES_PER_ELEMENT
  normalized = normalizePtr base, balign, oalign
  if offset isnt 0
    # Offsets are always in bytes, so compute the right offset now.
    new Op '+', normalized, new Value new Literal offset / oalign
  else
    normalized

# Calls offsetExpr with a size of 1, so that shiftBy is 0 and we don't shift.
stackOffsetExpr = (offset, offsetTy) ->
  offsetExpr SP, SP.computedType, offset, offsetTy

# Multiply by a size. If the size is a power of 2, use left shift.
multExpr = (base, size) ->
  # Is size a power of 2?
  if size and ((size & (size - 1)) is 0)
    new Parens new Op '<<', base, new Value new Literal (Math.log(size) / Math.log(2))
  else
    new Op '*', base, new Value new Literal size

class Binding
  constructor: (@type) ->

# This is like @type, but it also looks up the scope chain.
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

# Align an offset according to its size.
alignOffset = (offset, ty) ->
  size = ty.view.BYTES_PER_ELEMENT
  (((offset - 1) / size + 1) | 0) * size

# Number of units in alignment size.
alignmentUnits = (ty) -> ty.size / ty.view.BYTES_PER_ELEMENT

# Sanity check the type and compute the size. Expects synonyms to already have
# been computed.
#
# To keep things simple, we have the following restrictions:
#
#  - struct types are nominal
#  - pointers can only be taken on type names
#  - no subpart of a function type may be a function type
TypeName::lint = (types) ->
  throw TypeError "circular type synonym: #{@name}" if @linting
  return @linted if @linted
  @linting = true
  throw TypeError "cannot resolve type `#{@name}'" unless @name of types
  linted = types[@name]?.lint types
  delete @linting
  @linted = linted

PointerType::size = 4
PointerType::view = U32
PointerType::lint = (types) ->
  return this if @linted
  @linted = true
  @base = @base.lint types
  if @base instanceof ArrowType
    throw TypeError "cannot take pointers of function types"
  this
PointerType::baseAlignment = -> @base?.view.BYTES_PER_ELEMENT or 1

StructType::lint = (types) ->
  return this if @linted
  @linted = true
  fields = @fields
  field.type = field.type.lint types for field in fields
  # Make an imaginary first field whose offset and size is 0.
  prev = offset: 0, type: { size: 0 }
  # The size of the struct is the its maximum offset + the size of the largest
  # field with that offset.
  size = 0
  # Start off with the smallest view, U8.
  maxView = U8
  # An undefined offset tells the typechecker to fill it in from the
  # previous field. For example,
  #
  #   struct { [4] i :: int, j :: int }
  #
  # is the same as
  #
  #   struct { [4] i :: int, [8] j :: int }
  #
  # The first field's offset is 0 if undefined.
  #
  # The special form [-] means to use the same offset as the previous
  # field. For example,
  #
  #   struct { i :: int, [-] j :: int }
  #
  # is the same as
  #
  #   struct { [0] i :: int, [0] j ::
  #
  # Since there is an imaginary first field with an offset of 0, you can use
  # [-] on the first field too to make everything line up.
  #
  # The special form [+] means add the size of the previous field to the
  # previous field's offset for the current offset. This is the default
  # behavior when no offset attribute exists.
  #
  # Field offsets must be aligned to the type of the field.
  for field in fields
    ty = field.type
    # Record the max view encountered to set as the view of this struct.
    maxView = ty.view if ty.view.BYTES_PER_ELEMENT > maxView.BYTES_PER_ELEMENT
    if (offset = field.offset)?
      throw TypeError "struct field offsets cannot be negative" if offset < 0
      if offset < prev.offset
        printWarn "offset of field `#{field.name}' is smaller offset of previous field"
      if offset isnt alignOffset offset, ty
        throw TypeError "manual offset [#{offset}] cannot be aligned to `#{ty}'"
    else if field.usePreviousOffset
      # If the previous offset isn't aligned to the current field's size, move
      # both up.
      if (field.offset = alignOffset prev.offset, ty) isnt prev.offset
        prev.offset = field.offset
    else
      field.offset = alignOffset prev.offset + prev.type.size, ty
    size = s if (s = field.offset + ty.size) > size
    prev = field
  # Pointers of incompatible types cannot be at the same offset due to alignment.
  for field in fields when (ty = field.type) instanceof PointerType
    for field2 in fields when field2.offset is field.offset and
                              (ty2 = field2.type) instanceof PointerType
      # Print warnings about unioning incompatible pointer types, which is unsafe.
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

# Unify two types, if possible, into a single type. If assign is true, then
# this behaves asymmetrically for pointer types and automatic promotions of
# primitive types.
unify = (types, lty, rty, assign) ->
  # Compatibility is reflexive.
  return lty if lty is rty
  # If the left side is dynamic, the entire expression is dynamic.
  return unless lty and rty
  # Two pointer types are compatible iff their bases are size compatible.
  if lty instanceof PointerType and rty instanceof PointerType
    if assign
      # Assigning a narrower pointer to a wider one may mess up due to
      # alignment, since all views are aligned.
      if rty.base and rty.baseAlignment() < lty.baseAlignment()
        printWarn "incompatible pointer conversion from `#{rty}' to `#{lty}' may alter its value"
      return lty
    else
      # If we're not assigning, the base types have to be exactly the same.
      return lty if lty.base is rty.base
  # Two function types are compatible if their parameters and return types are
  # compatible.
  if lty instanceof ArrowType and rty instanceof ArrowType
    lptys = lty.params
    rptys = rty.params
    return unless lptys.length is rptys.length
    ptys = []
    for lpty, i in lptys
      ptys.push unify types, lpty, rptys[i], assign
    return new ArrowType ptys, unify(types, lty.ret, rty.ret, assign)
  if lty instanceof PointerType and rty in primTys
    printWarn "conversion from `#{rty}' to pointer without cast"
    return lty
  if lty in primTys and rty instanceof PointerType
    printWarn "conversion from pointer to `#{lty}' without cast"
    return lty
  # Primitive types follow C-like promotion rules.
  if lty in primTys and rty in primTys
    # If we're assigning, return the left type, else return the wider primitive.
    if lty.size isnt rty.size
      printWarn "conversion from `#{rty}' to `#{lty}' may alter its value"
      return if assign then lty else if lty.size > rty.size then lty else rty
    # Return the sign of the left type if they're the same size. This is just
    # to break the tie arbitrarily and to behave as expected for assignments.
    if lty.signed isnt rty.signed
      printWarn "conversion from `#{rty}' to `#{lty}' may alter its sign"
      return lty
  null

# Is this Op a dereference?
Op::isAssignable = Op::isDeref = -> not @second and @operator is '*'

# By default, computeType returns undefined, which means dynamic.
Base::computeType = (r, o) ->

# Casting coerces the expression to a certain type.
Cast::computeType = (r, o) ->
  return @computedType if @typeCached
  @typeCached = true
  @computedType = @type.lint o.types

# Simple identifiers and integer literals may be typed.
Literal::computeType = (r, o) ->
  return @computedType if @typeCached
  @typeCached = true
  @computedType = if @value is 'null'
    anyPtrTy
  else if @isAssignable()
    o.scope.binding(@value)?.type
  else if @isSimpleNumber()
    intTy

# Assignments do asymmetric type unification.
Assign::computeType = (r, o) ->
  return @computedType if @typeCached
  @typeCached = true
  return unless lty = @variable.unwrapAll().computedType
  # As a convenience if the left-hand side is a pointer and the right-hand
  # side is 0, replace the right-hand side with null, which has the type *any
  # to suppress int-to-pointer warnings.
  value = @value.unwrapAll()
  if lty instanceof PointerType and value instanceof Literal and value.value is '0'
    value.computedType = anyPtrTy
  rty = value.computedType
  # Handle pointer arithmetic complex assignments.
  context = @context
  if (context is '+=' or context is '-=') and lty instanceof PointerType and rty in primTys
    return @computedType = lty
  else if context is '-=' and lty instanceof PointerType and rty instanceof PointerType
    return @computedType = intTy if unify o.types, lty.base, rty.base
  unless @computedType = unify o.types, lty, rty, true
    throw TypeError "incompatible types: assigning `#{tystr(rty)}' to `#{lty}'"

# Accesses on struct types may be typed. If we arrived at this case it's
# because unwrapAll() didn't manage to unwrap value, i.e. this is a properties
# access.
Value::computeType = (r, o) ->
  return @computedType if @typeCached
  @typeCached = true
  if baseTy = @base.unwrapAll().computedType
    for prop in @properties
      baseTy = baseTy.base if baseTy instanceof PointerType
      return unless baseTy instanceof StructType
      throw TypeError "cannot soak struct field names" if prop.soak
      fieldName = prop.name.unwrapAll().value
      field = prop.computedField = baseTy.names[fieldName]
      throw TypeError "unknown struct field name `#{fieldName}'" unless field
      baseTy = field.type
    @computedType = baseTy

# Functions may be typed if their parameters are typed and all return
# expression types are compatible.
Code::computeType = (r, o) ->
  return @computedType if @typeCached
  @typeCached = true
  # Cache the stack-allocated variables and their offsets.
  @spOffsets = spOffsetMap o.scope
  @frameSize = o.scope.frameSize
  # Arriving in this function means that all the parameters typechecked, since
  # this is called after the body has been processed. So we just need to
  # collect the return expressions and compatible their types.
  types = o.types
  for rexpr in returnExpressions @body
    unless rty
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
  throw TypeError "calling a non-function type `#{fty}'" unless fty instanceof ArrowType
  paramTys = fty.params
  args = @args
  types = o.types
  for pty, i in fty.params
    # If fewer arguments than there are parameters were passed, this will be
    # `undefined` and interpreted as the type `any`.
    aty = args[i]?.computedType
    if pty and not unify types, pty, aty, true
      throw TypeError "incompatible types: passing arg `#{tystr(aty)}' to param `#{tystr(pty)}'"
  # If all the arguments checked, the call gets the return type.
  @computedType = fty.ret

# Allocations, pointer arithmetic, and foldably constant arithmetic
# expressions may be typed.
ARITH   = [ '+', '-', '*', '/' ]
BITWISE = [ '<<', '>>', '>>>', '~', '&', '|' ]
COMPARE = [ '===', '!==', '<', '>', '<=', '>=' ]

Op::computeType = (r, o) ->
  return @computedType if @typeCached
  @typeCached = true

  op  = @operator

  if @isUnary()
    first = @first.unwrapAll()
    return @computedType = if op is 'new' and first.value of o.types
      ty1 = o.types[first.value]
      throw TypeError 'cannot allocate type with size 0' unless ty1?.size
      Scope.root.needsMalloc = yes
      new PointerType ty1
    else if op is 'delete' and (ty1 = first.computedType)
      throw TypeError 'cannot free non-pointer type' unless ty1 instanceof PointerType
      Scope.root.needsMalloc = yes
      null
    else if op is 'sizeof'
      ty1 = @first = @first.lint o.types
      throw TypeError "cannot determine size of type `#{ty1}'" unless ty1.size
      intTy
    else if op is '&' and (ty1 = first.computedType)
      throw TypeError "taking reference of an untyped expression:\n#{@first}" unless ty1
      throw TypeError "taking reference of a function type" if ty1 instanceof ArrowType
      throw TypeError "taking reference of non-assignable" unless first.isAssignable()
      # Can't take references of upvars.
      if first instanceof Literal
        name  = first.value
        scope = o.scope
        unless scope.check name, true
          throw TypeError "taking reference of non-local or undefined variable `#{name}'"
        putOnStack scope, name
      new PointerType ty1
    else if op is '*' and (ty1 = first.computedType)
      throw TypeError "dereferencing an untyped expression:\n#{@first}" unless ty1
      throw TypeError "dereferencing a non-pointer type" unless ty1 instanceof PointerType
      ty1.base
    else if (op is '++' or op is '--') and ty1 = first.computedType
      ty1 if ty1 instanceof PointerType or ty1 in primTys

  ty1 = @first.unwrapAll().computedType
  ty2 = @second.unwrapAll().computedType

  # Commute.
  if ty2 instanceof PointerType
    tmp = ty1
    ty1 = ty2
    ty2 = tmp

  @computedType = if (op is '+' or op is '-') and ty1 instanceof PointerType and ty2 in primTys
    ty1
  else if op is '-' and ty1 instanceof PointerType and ty2 instanceof PointerType
    unless unify o.types, ty1.base, ty2.base
      printWarn "pointer subtraction on incompatible pointer types `#{ty1}' and `#{ty2}'"
    intTy
  else if op is '%'
    intTy
  else if op in COMPARE
    if ty1 instanceof PointerType and ty2 instanceof PointerType and
       not unify o.types, ty1, ty2
      printWarn "comparison between incompatible pointer types `#{ty1}' and `#{ty2}'"
    intTy
  else if op in BITWISE
    intTy
  else if op in ARITH and ty1 in primTys and ty2 in primTys
    unify o.types, ty1, ty2

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
#   f :: (int) -> int
#   f =  (x) -> x
#
# is equivalent to
#
#   f :: (int) -> int
#   f =  (x) :: (int) -> x
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
  # positions and propagate like we do in Assign::primeComputeType.
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
      throw TypeError "arrow type has different number of parameters than function"
    types = o.types
    for { name }, i in @params
      unless name instanceof Literal
        throw TypeError "cannot type complex parameter `#{name}'"
      # Lint just in case the user manually declared the parameter types and
      # thus the types were not linted before this point.
      ptys[i] = ptys[i].lint types
      (new DeclareType [new Value(name)], ptys[i]).declareType r, o
  # Hoist all the DeclareTypes to the top and process them. We shouldn't cross
  # scope here.
  @body.foldChildren null, 'declareType', null, types: o.types, scope: o.scope
  return

# Declaring a type adds the type to the scope.
DeclareType::declareType = (r, o) ->
  type  = @type.lint o.types
  scope = o.scope
  for v in @variables
    name = v.unwrapAll().value
    throw TypeError "cannot redeclare typed variable `#{name}'" if scope.check name
    scope.add name, new Binding type
    putOnStack scope, name if type instanceof StructType
  return

# Put a variable on the stack and increment the frame size.
putOnStack = (scope, name) ->
  bind = scope.binding name, true
  bind.onStack = true
  bind.spOffset = alignOffset scope.frameSize, bind.type
  scope.frameSize += bind.spOffset + bind.type.size
  return

# Condense a typed scope to a map of variable names to sp offsets.
spOffsetMap = (scope) ->
  map = {}
  for { name, type: bind } in scope.variables when bind.onStack
    map[name] = bind.spOffset
  map

# Dereference something in a heap view.
makeDeref = (o, base, baseTy, offset, offsetTy) ->
  new Value offsetTy.view(o), [new Index offsetExpr base, baseTy, offset, offsetTy]

# Generate an inline memcpy.
inlineMemcpy = (o, dest, src, ty) ->
  scope = o.scope
  stmts = []
  # Store the pointer to the struct we're copying to.
  destPtr = new Literal scope.freeVariable 'dest'
  stmts.push new Assign new Value(destPtr), dest
  # Store the pointer to the struct we're copying from.
  srcPtr = new Literal scope.freeVariable 'src'
  stmts.push new Assign new Value(srcPtr), src
  # Unroll the copy loop over the bytes.
  if ty instanceof StructType
    # We can do better than byte-by-byte if we're memcpying a struct. We need
    # to manually set the computedType so they get transformed properly in
    # Value::transform.
    for field in ty.fields
      access = new Access new Literal field.name
      access.computedField = field
      fty = field.type
      destProp = new Value destPtr, [access]
      destProp.computedType = fty
      srcProp = new Value srcPtr, [access]
      srcProp.computedType = fty
      assign = new Assign destProp, srcProp
      assign.computedType = fty
      stmts.push assign
  else
    for i in [0...ty.size]
      offset = new Value new Literal i
      stmts.push new Assign new Value(U8(o), [new Index new Op '+', new Value(destPtr), offset]),
                            new Value(U8(o), [new Index new Op '+', new Value(srcPtr), offset])
  stmts.push new Value destPtr
  new Value new Parens new Block stmts

# Reflect a heap-allocated struct as a JavaScript object literal.
structLiteral = (v, ty, o) ->
  ptr = new Literal o.scope.freeVariable 'ptr'
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
    propList.push new Assign new Value(new Literal fname), propValue.transform(), 'object'
  obj = new Value new Obj propList
  new Value new Parens new Block [new Assign(new Value(ptr), v), obj]

# Transform a function to have the right stack pointer computations upon entry
# and exit. The safe way is to wrap the entire body of the function in a
# try..finally block to account for possible throws. If the user indicated
# gotta-go-fast, we'll only emit stack pointer computations for explicit
# returns.
stackFence = (o, exprs, frameSize, isRoot) ->
  exprs.unshift new Assign SP, normalizePtr(SPREAL, U32.BYTES_PER_ELEMENT, 1)
  exprs.unshift new Assign SPREAL, new Value(new Literal frameSize), '-='
  restoreStack = new Assign SPREAL, new Value(new Literal frameSize), '+='
  if opts.unsafe
    exprs.push restoreStack if isRoot
  else
    exprs[0] = new Try new Block(exprs.slice()), null, null, new Block [restoreStack]
    exprs.length = 1
  # The stack uses U32, so record it manually.
  U32(o)
  return

Cast::transform = (r, o) ->
  lty = @computedType
  rty = @expr.unwrapAll().computedType
  return unless lty instanceof PointerType and rty instanceof PointerType
  normalizePtr @expr, lty.baseAlignment(), rty.baseAlignment()

# Add SP computations and bring in heap views if needed.
Code::transform = (o) ->
  o.returnType = @computedType?.ret
  if frameSize = @frameSize
    o.spOffsets = @spOffsets
    o.frameSize = frameSize
    stackFence o, @body.expressions, frameSize
  return

# Add SP computation and pointer conversions to explicit returns.
Return::transform = (o) ->
  # First transform for pointer conversion.
  if (ty = o.returnType) and ty instanceof PointerType and expr = @expression
    lalign = ty.baseAlignment();
    ralign = expr.unwrapAll().computedType.baseAlignment();
    @expression = normalizePtr @expression, lalign, ralign
  # Then transform for any stack fencing we need to do.
  return unless (frameSize = o.frameSize) and opts.unsafe
  restoreStack = new Assign SPREAL, new Value(new Literal frameSize), '+='
  if expr = @expression
    tmp = new Value new Literal o.scope.freeVariable 't'
    body = [new Assign(tmp, expr), restoreStack, tmp]
  else
    body = [restoreStack, undefExpr]
  @expression = new Value new Parens new Block body
  return

# Need to convert pointers when passing them as arguments.
Call::transform = (o) ->
  return unless fty = @variable?.unwrapAll().computedType
  paramTys = fty.params
  args = @args
  for pty, i in fty.params
    if pty instanceof PointerType
      lalign = pty.baseAlignment()
      ralign = args[i].computedType.baseAlignment()
      args[i] = normalizePtr args[i], lalign, ralign
  return

# Transform stack allocated variables to dereference sp + offset.
Literal::transform = (o) ->
  return unless (ty = @computedType)
  # This matters for TI: null will cause the typeset of pointers to be dimorphic.
  @value = '0' if @value is 'null' and ty instanceof PointerType
  return unless o.frameSize
  spOffsets = o.spOffsets
  if (name = @value) of spOffsets
    new Value U32(o), [new Index stackOffsetExpr spOffsets[name], ty]

# Transform stack allocated variables to sp + offset only, no dereference.
stackOffsetTransform = (o) ->
  stackOffsetExpr o.spOffsets[@value], @computedType

# Transform this Value into a new Value that does offset index lookups on
# the heap.
Value::transform = (o) ->
  return unless @computedType
  props = @properties
  # Non-access values get transformed at the inner level.
  return unless props.length
  base  = @base
  inner = base.unwrapAll()
  # If we're explicitly dereferencing the struct base, treat it like we
  # weren't.
  v = if inner.isDeref?()
    inner.first
  else if inner.computedType instanceof PointerType
    base
  else
    # If it's not a pointer access and not a dereference, the base must be
    # stack allocated. Make sure it gets transformed into an offset.
    base.transform = stackOffsetTransform
    base
  vty = v.computedType
  cumulativeOffset = 0
  for prop in @properties
    field = prop.computedField
    if (fty = field.type) instanceof StructType
      cumulativeOffset += field.offset
    else
      v = makeDeref o, v, vty, field.offset + cumulativeOffset, fty
      vty = fty
      cumulativeOffset = 0
  if fty instanceof StructType and cumulativeOffset isnt 0
    # This is not a pointer, but transform a pointer anyways so memcpy can
    # work. Typechecking ensures that this isn't used like a pointer.
    new Op '+', v, new Value new Literal cumulativeOffset
  else
    v

# Do struct copy semantics here since it requires a non-local transformation,
# i.e. it can't be compiled by transforming the lval and rval individually.
Assign::transform = (o) ->
  return unless lty = @computedType
  if lty instanceof PointerType
    rty = @value.unwrapAll().computedType
    if rty instanceof PointerType
      lalign = lty.baseAlignment()
      ralign = rty.baseAlignment()
      @value = normalizePtr @value, lalign, ralign
    else if rty in primTys and (au = alignmentUnits lty.base) isnt 1
      @value = new Op('*', @value, new Value new Literal au)
    return
  if lty instanceof StructType
    lval = @variable.unwrapAll()
    inlineMemcpy o, (if lval.isDeref?() then lval.first else @variable), @value, lty

# Typed new and delete are transformed to malloc and free, and pointer
# arithmetic also needs to be transformed.
Op::transform = (o) ->
  return unless @computedType or @first.computedType
  op = @operator
  if @isUnary()
    if op is 'new' and ty1 = @computedType
      new Call MALLOC, [new Value new Literal ty1.base.size]
    else if op is 'delete'
      new Call FREE, [@first]
    else if op is 'sizeof'
      new Literal @first.size
    else if op is '&' and ty1 = @computedType.base
      if (inner = @first.unwrapAll()) instanceof Literal and o.frameSize
        spOffsets = o.spOffsets
        if (name = inner.value) of spOffsets
          stackOffsetExpr spOffsets[name], ty1
      else
        @first
    else if op is '*'
      # This is only called when this deref is _not_ the base of a struct
      # access, as in struct accesses, dereferencing is the same as not
      # dereferencing, since . is extended to work like -> in C.
      ty1 = @first.computedType
      makeDeref o, @first, ty1, 0, ty1
    else if (op is '++' or op is '--') and
            (ty1 = @computedType) instanceof PointerType and
            (au = alignmentUnits ty1.base) isnt 1
      # If p :: *T, p++ desugars to (p += sizeof T, p - sizeof T).
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
    ty1 = @first.computedType
    ty2 = @second.computedType
    if (op is '+' or op is '-') and
       ((ty1 instanceof PointerType and ty2 in primTys and
         (au = alignmentUnits ty1.base) isnt 1) or
        (ty2 instanceof PointerType and ty1 in primTys and
         (au = alignmentUnits ty2.base) isnt 1))
      size = new Value new Literal au
      if ty1 instanceof PointerType
        new Op op, @first, new Op('*', @second, size)
      else
        new Op op, new Op('*', @first, size), @second
    else if op in COMPARE and
         ty1 instanceof PointerType and ty2 instanceof PointerType
      lalign = ty1.baseAlignment()
      ralign = ty2.baseAlignment()
      # By convention always normalize the second operand.
      new Op op, @first, normalizePtr(@second, lalign, ralign)

# Primitive types as found in C.
class PrimitiveType
  constructor: (@size, @debugName, @view, @signed) ->
  lint: (types) -> this
  toString: -> @debugName

# Cache this for typing null values.
anyPtrTy = new PointerType null
byteTy   = new PrimitiveType 1, 'byte',  U8,  no
shortTy  = new PrimitiveType 2, 'short', I16, yes
intTy    = new PrimitiveType 4, 'int',   I32, yes
uintTy   = new PrimitiveType 4, 'uint',  U32, no

# Sized primitive types.
primTys  = [ byteTy, shortTy, intTy, uintTy ]

# The local stack pointer is a u32.
SP.computedType = uintTy
# The actual stack pointer is a u8.
SPREAL.computedType = byteTy
SPREAL.transform = null

requireExpr = (name) ->
  new Call new Value(new Literal 'require'), [new Value new Literal "'#{name}'"]

exports.analyzeTypes = (root, o) ->
  usesTypes = no
  root.traverseChildren yes, (node) ->
    if node instanceof DeclareType
      usesTypes = yes
      return no
  return unless usesTypes

  # Global options.
  opts.warn   = o.warn
  opts.unsafe = o.unsafe

  initialTypes = any: null, byte: byteTy, short: shortTy, int: intTy, uint: uintTy
  types = root.foldChildren initialTypes, 'collectType', null, immediate: true
  types[name] = ty.lint types for name, ty of types when ty

  scope = newTypedScope null, root, null
  options = types: types, scope: scope
  root.foldChildren null, 'declareType', null, options
  options.crossScope = true
  root.foldChildren null, 'primeComputeType', 'computeType', options
  root.spOffsets = spOffsetMap scope
  root.frameSize = scope.frameSize
  root.transformRoot = (o) ->
    # Require the heap. This has to be done using o.scope.assign to make sure
    # that it comes before the cached views.
    o.scope.assign HEAP.base.value, "require('heap/heap')"
    # Do the stack fence for the module.
    exprs = @expressions
    stackFence o, exprs, frameSize, yes if frameSize = scope.frameSize
    # Bring in malloc if this module needs it.
    if scope.needsMalloc
      obj = new Value new Obj [MALLOC, FREE]
      exprs.unshift new Assign obj, requireExpr 'heap/malloc'
  types
