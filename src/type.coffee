#
# `type.coffee' contains all the code having to do with analyzing types for
# generating code with a manual heap.
#
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# !! THIS IS NOT A GOOD TYPE SYSTEM !!
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#
# Only local variables may be typed.
#

{Scope} = require './scope'
{Base, Parens, Block, Value, Literal, Op, Assign,
 Code, Index, Access, Call, Return, Obj, While
 TypeAssign, DeclareType, Ref, Deref,
 TypeName, PointerType, ArrowType, StructType} = require './nodes'
{flatten, extend} = require './helpers'

# HEAP is the byte-sized view.
HEAP   = new Literal 'H'
HEAPV  = new Value HEAP
STACK  = new Literal 'S'
STACKV = new Value STACK
# Views of other sizes.
I16H   = new Literal 'I16H'
U16H   = new Literal 'U16H'
I32H   = new Literal 'I32H'
U32H   = new Literal 'U32H'
MALLOC = new Value new Literal 'malloc'
FREE   = new Value new Literal 'free'
MEMCPY = new Value new Literal 'memcpy'

shiftBy = (size) -> Math.log(size) / Math.log(2)

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

Block::foldChildren = (r, pre, post, o) ->
  super(r, pre, post, (extend {}, o))

Code::foldChildren = (r, pre, post, o) ->
  return r unless o.crossScope
  super(r, pre, post, o)

# Collect type synonyms.
TypeAssign::collectType = (types) ->
  types[@name] = @type
  # For debugging, types print out the first name they're aliased to.
  @type.debugName ?= @name
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
  throw TypeError "cannot resolve type `#{@name}'" unless ty = types[@name]
  linted = ty.lint types
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
  field.type = field.type.lint types for field in @fields
  size = 0
  for field in @fields
    field.offset = size
    size += field.type.size
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

# Are two types compatible, i.e. can they be assigned to each other?
unify = (types, ty1, ty2) ->
  # Compatibility is reflexive.
  return ty1 if ty1 is ty2
  # Undefined, or dynamic, and anything is the other thing.
  return ty1 unless ty2
  return ty2 unless ty1
  # A null or malloc or something is compatible with any pointer type.
  return ty1 if ty1 instanceof PointerType and ty2 is anyPtrTy
  return ty2 if ty2 instanceof PointerType and ty1 is anyPtrTy
  # Two pointer types are compatible iff their bases are compatible.
  if ty1 instanceof PointerType and ty2 instanceof PointerType
    base = unify types, ty1.base, ty2.base
    return new PointerType base if base
  # Two function types are compatible if their parameters and return types are
  # compatible.
  if ty1 instanceof ArrowType and ty2 instanceof ArrowType
    ptys1 = ty1.params
    ptys2 = ty2.params
    return unless ptys1.length is ptys2.length
    ptys = []
    for pty1, i in ptys1
      return unless pty = unify types, pty1, ptys2[i]
      ptys.push pty
    return new ArrowType ptys, rty if rty = unify types, ty1.ret, ty2.ret
  null

# By default, computeType returns undefined, which means dynamic.
Base::computeType = (r, o) ->

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
  return unless lhTy = @variable.unwrapAll().computeType r, o
  rhTy = @value.unwrapAll().computeType r, o
  # We don't have a more sophisticated subtyping story, so we do the
  # asymmetric typechecking here manually.
  throw TypeError 'cannot assign untyped to typed' unless rhTy
  unless @computedType = unify o.types, lhTy, rhTy
    throw TypeError "incompatible types in assignment: `#{lhTy}' and `#{rhTy}'"

# Accesses on struct types may be typed. If we arrived at this case it's
# because unwrapAll() didn't manage to unwrap value, i.e. this is a properties
# access.
Value::computeType = (r, o) ->
  return @computedType if @typeCached
  @typeCached = true
  if baseTy = @base.unwrapAll().computeType r, o
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
# expression types unify.
Code::computeType = (r, o) ->
  return @computedType if @typeCached
  @typeCached = true
  # Arriving in this function means that all the parameters typechecked, since
  # this is called after the body has been processed. So we just need to
  # collect the return expressions and unify their types.
  types = o.types
  rty = null
  rty = unify types, ty.computedType, rty for ty in returnExpressions @body
  @computedType = new ArrowType @paramTypes, rty

# Allocations, pointer arithmetic, and foldably constant arithmetic
# expressions may be typed.
Op::computeType = (r, o) ->
  return @computedType if @typeCached
  @typeCached = true

  op  = @operator

  # Typed unary operations like dereferencing are separate nodes.
  if @isUnary()
    first = @first.unwrapAll()
    return @computedType = if op is 'new' and (ty1 = o.types[first.value])
      throw TypeError 'cannot allocate type with size 0' unless ty1.size
      new PointerType ty1
    else if op is 'delete' and (ty1 = first.computeType r, o)
      throw TypeError 'cannot free non-pointer type' unless ty1 instanceof PointerType
      throw TypeError 'cannot free on-stack variables' if ty1.onStack
      unitTy

  ty1 = @first.unwrapAll().computeType r, o
  ty2 = @second.unwrapAll().computeType r, o

  # Commute.
  if ty2 instanceof PointerType
    tmp = ty1
    ty1 = ty2
    ty2 = tmp

  ARITH_OPS = [ '+', '-', '*', '/', '<<', '>>', '>>>', '~', '&', '|' ]
  primTys   = [ byteTy, shortTy, intTy, uintTy ]

  @computedType = if op is '+' and ty1 instanceof PointerType and ty2 in primTys
    ty1
  else if op is '-' and ty1 instanceof PointerType and ty2 instanceof PointerType
    intTy if unify o.types, ty1.base, ty2.base
  else if op in ARITH_OPS and ty1 in primTys and ty2 in primTys
    intTy

# Reference gets you a pointer type.
Ref::computeType = (r, o) ->
  return @computedType if @typeCached
  @typeCached = true
  ty = @expr.unwrapAll().computeType r, o
  throw TypeError "taking reference of an untyped expression:\n#{@expr}" unless ty
  throw TypeError "taking reference of a function type" if ty instanceof ArrowType
  @computedType = new PointerType ty

# Dereferencing gets the base type of the pointer type.
Deref::computeType = (r, o) ->
  return @computedType if @typeCached
  @typeCached = true
  ty = @expr.unwrapAll().computeType r, o
  throw TypeError "dereferencing an untyped expression:\n#{@expr}" unless ty
  throw TypeError "dereferencing a non-pointer type" unless ty instanceof PointerType and not ty.onStack
  @computedType = ty.base

# Gather return expressions.
returnExpressions = (body) ->
  exprs = body.expressions
  body.foldChildren [exprs[exprs.length - 1]], 'returnExpression', null, {}

Return::returnExpression = (exprs, o) ->
  exprs.push @expression
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
    # Remember the parameter and return types on the right-hand side.
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
  if offset isnt 0
    offsetOp = new Op '+', base, new Value new Literal offset
  else
    offsetOp = base
  new Value ty.view, [new Index new Op '>>', offsetOp, new Literal shiftBy ty.size]

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
  v = if (inner = @base.unwrapAll()) instanceof Deref then inner.expr else @base
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
  return unless lval instanceof Deref and ty instanceof StructType
  inlineMemcpy lval.expr, @value, ty, o

# Typed new and delete are transformed to malloc and free, and pointer
# arithmetic also needs to be transformed.
Op::transform = (o) ->
  op = @operator
  if op is 'new' and ty = @computedType
    m = if ty.onStack then STACKV else HEAPV
    new Call MALLOC, [m, new Value new Literal ty.base.size]
  else if op is 'delete' and @first.computedType
    new Call FREE, [HEAPV, @first]
  else if @computedType and not @isUnary()
    if op is '+' and (ty = @first.computedType) instanceof PointerType
      new Op '+', @first, new Op('*', @second, new Literal ty.base.size)
    else if op is '+' and (ty = @second.computedType) instanceof PointerType
      new Op '+', new Op('*', @first, new Literal ty.base.size), @second
    else if op is '-' and (ty = @first.computedType) instanceof PointerType
      this.transform = null
      # Typechecking already ensures that @second.computedType is ty.
      new Op '>>', this, new Literal(shiftBy ty.base.size)

# TODO
Ref::transform = (o) ->
  @expr

# This is only called when this deref is _not_ the base of a struct access, as
# in struct accesses, dereferencing is the same as not dereferencing, since
# . is extended to work like -> in C.
Deref::transform = (o) ->
  makeDeref @expr, 0, @expr.computedType

# Pointers are 4-byte aligned for now.
PointerType::view = U32H

# Primitive types as found in C.
class PrimitiveType
  constructor: (@size, @debugName, @view) ->
  lint: (types) -> this
  toString: -> @debugName

# The any pointer type, or unity type are not exported to the language, but
# used internally. The any pointer type is used to typecheck null, and the
# unit type is used to type free.
anyPtrTy = new PrimitiveType 0, '*'
unitTy   = new PrimitiveType 0, '()'
byteTy   = new PrimitiveType 1, 'byte', HEAP
shortTy  = new PrimitiveType 2, 'short', I16H
intTy    = new PrimitiveType 4, 'int', I32H
uintTy   = new PrimitiveType 4, 'uint', U32H

primitiveTypes =
  byte:  byteTy
  short: shortTy
  int:   intTy
  uint:  uintTy

exports.analyzeTypes = (root) ->
  return unless root.containsType DeclareType

  types = root.foldChildren primitiveTypes, 'collectType', null, immediate: true
  types[name] = ty.lint types for name, ty of types

  options =
    types: types,
    scope: newTypedScope(null, root, null)
    crossScope: true
  root.foldChildren null, 'primeComputeType', 'computeType', options

  types
