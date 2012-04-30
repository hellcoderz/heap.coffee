#
# `type.coffee' contains all the code having to do with analyzing types for
# generating code with a manual heap.
#
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# !! THIS IS NOT A GOOD TYPE SYSTEM !!
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#
# Only local variables may be typed and types are file-local. To import
# external typed stuff unsafe casts are required.
#

{Scope} = require './scope'
{Base, Parens, Block, Value, Literal, Op, Assign,
 Code, Index, Access, Call, Return, Obj, While
 TypeAssign, DeclareType, Cast,
 TypeName, PointerType, ArrowType, StructType} = require './nodes'
{flatten, extend, tystr} = require './helpers'

# HEAP is the byte-sized view.
HEAP   = new Literal 'H'
# Views of other sizes.
I16H   = new Literal 'I16H'
U16H   = new Literal 'U16H'
I32H   = new Literal 'I32H'
U32H   = new Literal 'U32H'
# The frame pointer.
FP     = new Literal 'FP'
MALLOC = new Value new Literal 'malloc'
FREE   = new Value new Literal 'free'
MEMCPY = new Value new Literal 'memcpy'

# Global option for if we should print warnings.
opts = { warn: false }
printWarn = (line) -> process.stderr.write 'warning: ' + line + '\n' if opts.warn

offsetExpr = (base, offset, size) ->
  op = if offset isnt 0
    new Op '+', base, new Value new Literal offset
  else
    base
  shiftBy = Math.log(size) / Math.log(2)
  if shiftBy isnt 0
    new Op '>>', op, new Literal shiftBy
  else
    op

multExpr = (base, size) ->
  new Parens new Op '<<', base, new Literal (Math.log(size) / Math.log(2))

# This is like @type, but it also looks up the scope chain.
Scope::typeOf = (name, immediate) ->
  found = @type(name)
  return found if found or immediate
  @parent?.typeOf name

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
PointerType::lint = (types) ->
  return this if @linted
  @linted = true
  @base = @base.lint types
  if @base instanceof ArrowType
    throw TypeError "cannot take pointers of function types"
  this

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
  for field in fields
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
    # The speical form [+] means add the size of the previous field to the
    # previous field's offset for the current offset. This is the default
    # behavior when no offset attribute exists.
    if (offset = field.offset)?
      throw TypeError "struct field offsets cannot be negative" if offset < 0
      if offset < prev.offset
        printWarn "offset of field `#{field.name}' is smaller offset of previous field"
    else if field.usePreviousOffset
      field.offset = prev.offset
    else
      field.offset = prev.offset + prev.type.size
    size = s if (s = field.offset + field.type.size) > size
    prev = field
  @size = size
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
  # Two pointer types are compatible iff their bases are compatible.
  if lty instanceof PointerType and rty instanceof PointerType
    # If we're assigning, *any can be assigned to any pointer and keep the
    # type of the original pointer.
    return lty if assign and not rty.base
    return new PointerType unify types, lty.base, rty.base, assign
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
Op::isDeref = -> not @second and @operator is '*'

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
    o.scope.typeOf @value
  else if @isSimpleNumber()
    intTy

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

# Functions are be typed if their parameters are typed and all return
# expression types are compatible.
Code::computeType = (r, o) ->
  return @computedType if @typeCached
  @typeCached = true
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

# Allocations, pointer arithmetic, and foldably constant arithmetic
# expressions may be typed.
Op::computeType = (r, o) ->
  return @computedType if @typeCached
  @typeCached = true

  op  = @operator

  if @isUnary()
    first = @first.unwrapAll()
    return @computedType = if op is 'new' and first.value of o.types
      ty1 = o.types[first.value]
      throw TypeError 'cannot allocate type with size 0' unless ty1?.size
      new PointerType ty1
    else if op is 'delete' and (ty1 = first.computedType)
      throw TypeError 'cannot free non-pointer type' unless ty1 instanceof PointerType
      throw TypeError 'cannot free on-stack variables' if ty1.onStack
      unitTy
    else if op is 'sizeof'
      ty1 = @first = @first.lint o.types
      throw TypeError "cannot determine size of type `#{ty1}'" unless ty1.size
      # Replace the operand with the type itself.
      intTy
    else if op is '&' and (ty1 = first.computedType)
      throw TypeError "taking reference of an untyped expression:\n#{@first}" unless ty1
      throw TypeError "taking reference of a function type" if ty1 instanceof ArrowType1
      new PointerType ty1
    else if op is '*' and (ty1 = first.computedType)
      throw TypeError "dereferencing an untyped expression:\n#{@first}" unless ty1
      throw TypeError "dereferencing a non-pointer type" unless ty1 instanceof PointerType and not ty1.onStack
      ty1.base

  ty1 = @first.unwrapAll().computedType
  ty2 = @second.unwrapAll().computedType

  # Commute.
  if ty2 instanceof PointerType
    tmp = ty1
    ty1 = ty2
    ty2 = tmp

  ARITH_OPS   = [ '+', '-', '*', '/' ]
  BITWISE_OPS = [ '<<', '>>', '>>>', '~', '&', '|' ]

  @computedType = if (op is '+' or op is '-') and ty1 instanceof PointerType and ty2 in primTys
    ty1
  else if op is '-' and ty1 instanceof PointerType and ty2 instanceof PointerType
    intTy if unify o.types, ty1.base, ty2.base
  else if op is '%'
    intTy
  else if op in BITWISE_OPS
    ty1
  else if op in ARITH_OPS and ty1 in primTys and ty2 in primTys
    unify o.types, ty1, ty2

# Gather return expressions.
returnExpressions = (body) ->
  exprs = body.expressions
  body.foldChildren [exprs[exprs.length - 1]], 'returnExpression', null, {}

nullLit = new Literal 'null'
nullLit.computedType = anyPtrTy
nullExpr = new Value nullLit

Return::returnExpression = (exprs, o) ->
  # @expression could be undefined, which means it's returning null.
  exprs.push @expression or nullExpr
  exprs

# Add parameter and return types to the typed scope.
newTypedScope = (p, e, m) ->
  scope = new Scope p, e, m
  scope.variables.length = 0
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
     (ty = o.scope.typeOf name.value) instanceof ArrowType
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
      (new DeclareType new Value(name), ptys[i]).primeComputeType r, o
  return

# Declaring a type adds the type to the scope.
DeclareType::primeComputeType = (r, o) ->
  type = @type.lint o.types
  # Stack-allocated pointers to structs
  if type instanceof StructType
    type = new PointerType type, yes
  name = @variable.unwrapAll().value
  scope = o.scope
  throw TypeError "cannot redeclare typed variable `#{name}'" if scope.check name
  scope.add @variable.unwrapAll().value, type
  return

# Dereference something in a heap view.
makeDeref = (base, offset, ty) ->
  throw TypeError "unknown view on type `#{ty}'" unless ty.view
  new Value ty.view, [new Index offsetExpr base, offset, ty.size]

# Generate an inline memcpy.
inlineMemcpy = (dest, src, ty, o) ->
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
      stmts.push new Assign new Value(HEAP, [new Index new Op '+', new Value(destPtr), offset]),
                            new Value(HEAP, [new Index new Op '+', new Value(srcPtr), offset])
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

# A typed value with properties can only a struct access.
#
# Transform this Value into a new Value that does offset index lookups on
# HEAP.
Value::transform = (o) ->
  props = @properties
  return unless @computedType and props.length
  # If we're explicitly dereferencing the struct base, treat it like we
  # weren't.
  v = if (inner = @base.unwrapAll()).isDeref?() then inner.first else @base
  cumulativeOffset = 0;
  for prop in props
    field = prop.computedField
    if (ty = field.type) instanceof StructType
      cumulativeOffset += field.offset
    else
      v = makeDeref v, field.offset + cumulativeOffset, ty
      cumulativeOffset = 0
  if ty instanceof StructType and cumulativeOffset isnt 0
    # This is not a pointer, but transform a pointer anyways so memcpy can
    # work. Typechecking ensures that this isn't used like a pointer.
    new Op '+', v, new Value new Literal cumulativeOffset
  else
    v

# Do struct copy semantics here since it requires a non-local transformation,
# i.e. it can't be compiled by transforming the lval and rval individually.
Assign::transform = (o) ->
  lval = @variable
  ty = @computedType
  context = @context
  if (context is '+=' or context is '-=')
    lty = @variable.unwrapAll().computedType
    rty = @value.unwrapAll().computedType
    if lty instanceof PointerType and rty in primTys
      @value = multExpr @value, lty.base.size
      return this
    else if lty instanceof PointerType and rty instanceof PointerType
      return offsetExpr this, 0, lty.base.size
  else if lval.isDeref?() and ty instanceof StructType
    inlineMemcpy lval.first, @value, ty, o

# Typed new and delete are transformed to malloc and free, and pointer
# arithmetic also needs to be transformed.
Op::transform = (o) ->
  return unless @computedType
  op = @operator
  if @isUnary()
    if op is 'new' and ty = @computedType
      # TODO when ty.onStack
      new Call MALLOC, [new Value new Literal ty.base.size]
    else if op is 'delete'
      new Call FREE, [@first]
    else if op is 'sizeof'
      new Literal @first.size
    else if op is '&'
      # TODO
      @first
    else if op is '*'
      # This is only called when this deref is _not_ the base of a struct
      # access, as in struct accesses, dereferencing is the same as not
      # dereferencing, since . is extended to work like -> in C.
      makeDeref @first, 0, @first.computedType
  else
    ty1 = @first.computedType
    ty2 = @second.computedType
    if (op is '+' or op is '-') and ty1 instanceof PointerType and ty2 in primTys
      new Op op, @first, multExpr(@second, ty1.base.size)
    else if (op is '+' or op is '-') and ty1 in primTys and ty2 instanceof PointerType
      new Op op, multExpr(@first, ty2.base.size), @second
    else if op is '-' and ty1 instanceof PointerType
      this.transform = null
      # Typechecking already ensures that ty2 is ty1.
      offsetExpr this, 0, ty1.base.size

# Pointers are 4-byte aligned for now.
PointerType::view = U32H

# Primitive types as found in C.
class PrimitiveType
  constructor: (@size, @debugName, @view, @signed) ->
  lint: (types) -> this
  toString: -> @debugName

# Cache this for typing null values.
anyPtrTy = new PointerType null
byteTy   = new PrimitiveType 1, 'byte',  HEAP, yes
shortTy  = new PrimitiveType 2, 'short', I16H, yes
intTy    = new PrimitiveType 4, 'int',   I32H, yes
uintTy   = new PrimitiveType 4, 'uint',  U32H, no
# Sized primitive types.
primTys  = [ byteTy, shortTy, intTy, uintTy ]

exports.analyzeTypes = (root, o) ->
  usesTypes = no
  root.traverseChildren yes, (node) ->
    if node instanceof DeclareType
      usesTypes = yes
      return no
  return unless usesTypes
  opts.warn = o.warn

  initialTypes = any: null, byte: byteTy, short: shortTy, int: intTy, uint: uintTy
  types = root.foldChildren initialTypes, 'collectType', null, immediate: true
  types[name] = ty.lint types for name, ty of types when ty

  options = types: types, scope: newTypedScope(null, root, null), crossScope: true
  root.foldChildren null, 'primeComputeType', 'computeType', options

  types
