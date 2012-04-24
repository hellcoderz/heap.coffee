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
{Base, Block, Value, Literal, Op, Assign, Code, Index, Call
 TypeAssign, DeclareType,
 Ref, Deref,
 TypeName, PointerType, ArrowType, StructType} = require './nodes'
{flatten, extend} = require './helpers'

HEAP   = new Literal '_H'
HEAPV  = new Value HEAP
STACK  = new Literal '_S'
STACKV = new Value STACK
MALLOC = new Literal '_malloc'
FREE   = new Literal '_free'

# This is like @type, but it also looks up the scope chain.
Scope::typeOf = (name, immediate) ->
  found = @type(name)
  return found if found or immediate
  @parent?.typeOf name

# Many of the algorithms we do here are more naturally expressed as folds.
# Also, instead of passing in a function, pass in a prop to be called on each
# child, which pushes the typecase into the VM.
Base::foldChildren = (r, m, o) ->
  r = if typeof @[m] is 'function' then @[m](r, o) else r
  return r unless @children

  if o.immediate
    for attr in @children when @[attr]
      for child in flatten [@[attr]]
        r = if typeof child[m] is 'function' then child[m](r, o) else r
  else
    for attr in @children when @[attr]
      for child in flatten [@[attr]]
        r = child.foldChildren r, m, o
  r

Block::foldChildren = (r, m, o) ->
  super(r, m, (extend {}, o))

Code::foldChildren = (r, m, o) ->
  return r unless o.crossScope
  super(r, m, (extend {}, o))

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
  if ty instanceof ArrowType
    throw TypeError "cannot type higher-order functions"
  @ret = ty
  for ty, i in @params
    ty = ty.lint types
    if ty instanceof ArrowType
      throw TypeError "cannot type higher-order functions"
    params[i] = ty
  this

# Are two types compatible, i.e. can they be assigned to each other?
unify = (types, ty1, ty2) ->
  # Compatibility is reflexive.
  return ty1 if ty1 is ty2

  # A null or malloc or something is compatible with any pointer type.
  return ty1 if ty1 instanceof PointerType and ty2 is anyPtrTy
  return ty2 if ty2 instanceof PointerType and ty1 is anyPtrTy

  # Two pointer types are compatible iff their bases are compatible.
  if ty1 instanceof PointerType and ty2 instanceof PointerType
    base = unify types, ty1.base, ty2.base
    return new PointerType base if base

  null

# A node is typed if it's inside a typed scope, the list of types is
# non-empty, and it's typable.
Base::isTyped = (o) ->
  types = o.types
  scope = o.typedScope
  return false unless types and scope
  !!(@computeType types, scope)

# By default, computeType returns undefined, which means dynamic.
Base::computeType = (types, scope) ->

# Simple identifiers and integer literals may be typed.
Literal::computeType = (types, scope) ->
  return @computedType if @typeCached
  @typeCached = true
  @computedType = if @value is 'null'
    anyPtrTy
  else if @isAssignable()
    scope.typeOf @value
  else if @isSimpleNumber()
    intTy

Assign::computeType = (types, scope) ->
  return @computedType if @typeCached
  @typeCached = true
  return unless lhTy = @variable.unwrapAll().computeType types, scope
  rhTy = @value.unwrapAll().computeType types, scope
  # We don't have a more sophisticated subtyping story, so we do the
  # asymmetric typechecking here manually.
  throw TypeError 'cannot assign untyped to typed' unless rhTy
  unless @computedType = unify types, lhTy, rhTy
    throw TypeError "incompatible types in assignment: `#{lhTy}' and `#{rhTy}'"

# Accesses on struct types may be typed. If we arrived at this case it's
# because unwrapAll() didn't manage to unwrap value, i.e. this is a properties
# access.
Value::computeType = (types, scope) ->
  return @computedType if @typeCached
  @typeCached = true
  if baseTy = @base.unwrapAll().computeType types, scope
    for prop in @properties
      baseTy = baseTy.base if baseTy instanceof PointerType
      return unless baseTy instanceof StructType
      throw TypeError "cannot soak field names" if prop.soak
      fieldName = prop.name.unwrapAll().value
      field = baseTy.names[fieldName]
      throw TypeError "unknown struct field name `#{fieldName}'" unless field
      prop.computedOffset = field.offset
      baseTy = field.type
    @computedType = baseTy

# Allocations, pointer arithmetic, and foldably constant arithmetic
# expressions may be typed.
Op::computeType = (types, scope) ->
  return @computedType if @typeCached
  @typeCached = true

  op  = @operator

  # Typed unary operations like dereferencing are separate nodes.
  if @isUnary()
    first = @first.unwrapAll()
    return @computedType = if op is 'new' and (ty1 = types[first.value])
      throw TypeError 'cannot allocate type with size 0' unless ty1.size
      new PointerType ty1
    else if op is 'delete' and (ty1 = first.computeType types, scope)
      throw TypeError 'cannot free non-pointer type' unless ty1 instanceof PointerType
      throw TypeError 'cannot free on-stack variables' if ty1.onStack
      unitTy

  ty1 = @first.unwrapAll().computeType types, scope
  ty2 = @second.unwrapAll().computeType types, scope

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
    intTy if unify types, ty1.base, ty2.base
  else if op in ARITH_OPS and ty1 in primTys and ty2 in primTys
    intTy

# Reference gets you a pointer type.
Ref::computeType = (types, scope) ->
  return @computedType if @typeCached
  @typeCached = true
  ty = @expr.unwrapAll().computeType types, scope
  throw TypeError "taking reference of an untyped expression:\n#{@expr}" unless ty
  throw TypeError "taking reference of a function type" if ty instanceof ArrowType
  @computedType = new PointerType ty

# Dereferencing gets the base type of the pointer type.
Deref::computeType = (types, scope) ->
  return @computedType if @typeCached
  @typeCached = true
  ty = @expr.unwrapAll().computeType types, scope
  throw TypeError "dereferencing an untyped expression:\n#{@expr}" unless ty
  throw TypeError "dereferencing a non-pointer type" unless ty instanceof PointerType and not ty.onStack
  @computedType = ty.base

# Type inference, if it can be called that. It collects type declarations and
# then wraps around @computeType.
#
# Type declarations are block-scoped, even though variables themselves aren't!
#
# Because of CoffeeScript's dynamicness, we can _override_ types of the same
# vars in the same block, i.e.:
#
#  x :: int
#  x = 0
#  ...
#  x :: *T
#  x = new T
#
# should work as expected in the same scope.
newTypedScope = newTypedScope = (p, e, m) ->
  scope = new Scope p, e, m
  scope.variables.length = 0
  scope

Block::inferType = (r, o) ->
  o.scope = newTypedScope o.scope, @body, this
  return

DeclareType::inferType = (r, o) ->
  types = o.types
  @type = @type.lint types
  # Stack-allocated pointers to structs
  if @type instanceof StructType
    @type = new PointerType @type, yes
  o.scope.add @variable.unwrapAll().value, @type
  return

Literal::inferType = (r, o) ->
  @computeType o.types, o.scope
  return

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
#   f =  (x) ->
#     x :: int
#     x
#
# _only_ when the binding for f is a _syntactic_ function. If not, you would
# have to declare the types of arguments manually.
Assign::inferType = (r, o) ->
  if (fn = @value.unwrapAll()) instanceof Code and
     (name = @variable.unwrapAll()) instanceof Literal and name.isAssignable()
    if (ty = o.scope.typeOf name.value) instanceof ArrowType
      exprs    = fn.body.expressions
      paramTys = ty.params
      for { name: p }, i in fn.params when paramTys[i] and p instanceof Literal
        exprs.unshift new DeclareType(p, paramTys[i])

  @computeType o.types, o.scope
  return

Value::inferType = (r, o) ->
  # If one of the field names is unknown, @computeType throws.
  @computeType o.types, o.scope
  return

Op::inferType = (r, o) ->
  @computeType o.types, o.scope
  return

Ref::inferType = (r, o) ->
  @computeType o.types, o.scope
  return

Deref::inferType = (r, o) ->
  @computeType o.types, o.scope
  return

# A typed value with properties can only a struct access.
#
# Transform this Value into a new Value that does offset index lookups on
# HEAP.
Value::transform = ->
  props = @properties
  return unless @computedType and props.length

  heapOffset = (idx, prop) ->
    new Value HEAP, [new Index new Op '+', idx,
                     new Value (new Literal prop.computedOffset)]
  # If we're explicitly dereferencing the struct base, treat it like we
  # weren't.
  getExpr = -> @expr
  inner = @base.unwrapAll()
  inner.transform = getExpr if inner instanceof Deref
  props.reduce heapOffset, @base

# Typed new and delete are transformed to malloc and free, and pointer
# arithmetic also needs to be transformed.
Op::transform = ->
  op = @operator
  if op is 'new' and ty = @computedType
    m = if ty.onStack then STACKV else HEAPV
    new Call new Value(MALLOC), [m, new Value(new Literal ty.base.size)]
  else if op is 'delete' and @first.computedType
    new Call new Value(FREE), [HEAPV, @first]
  else if @computedType and not @isUnary()
    if op is '+' and (ty = @first.computedType) instanceof PointerType
      new Op '+', @first, new Op('*', @second, new Literal ty.base.size)
    else if op is '+' and (ty = @second.computedType) instanceof PointerType
      new Op '+', new Op('*', @first, new Literal ty.base.size), @second
    else if op is '-' and (ty = @first.computedType) instanceof PointerType
      this.transform = null
      # Typechecking already ensures that @second.computedType is ty.
      new Op '>>', this, new Literal(Math.log(ty.base.size) / Math.log(2))

# TODO
Ref::transform = ->
  @expr

# This is only called when this deref is _not_ the base of a struct access, as
# in struct accesses, dereferencing is the same as not dereferencing, as . is
# extended to work like -> in C.
Deref::transform = ->
  new Value HEAP, [new Index @expr]

# Primitive types as found in C.
class PrimitiveType
  constructor: (@size, @debugName) ->
  lint: (types) -> this
  toString: -> @debugName

# The any pointer type is not exported to the language, but is used so null
# and malloc can be implicitly coerced to any pointer type.
anyPtrTy = new PrimitiveType 0, '*'
unitTy   = new PrimitiveType 0, '()'
byteTy   = new PrimitiveType 1, 'byte'
shortTy  = new PrimitiveType 2, 'short'
intTy    = new PrimitiveType 4, 'int'
uintTy   = new PrimitiveType 4, 'uint'

primitiveTypes =
  byte:  byteTy
  short: shortTy
  int:   intTy
  uint:  uintTy

exports.analyzeTypes = (root) ->
  return unless root.containsType DeclareType

  types = root.foldChildren primitiveTypes, 'collectType', immediate: true
  types[name] = ty.lint types for name, ty of types

  scope = newTypedScope null, root, null
  o = { types: types, scope: scope, crossScope: true }
  root.foldChildren null, 'inferType', o

  types
