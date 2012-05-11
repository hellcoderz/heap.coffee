# `type.coffee` contains all the code having to do with analyzing types for
# generating code with a manual heap. Only local variables may be typed and
# types are file-local. To import external typed stuff unsafe casts are
# required.

{Scope} = require './scope'
{Base, Parens, Block, Value, Literal, Op, Assign, Try, If, Switch, Param,
 Code, Index, Access, Call, Return, Obj, While, Comment, Arr, Obj,
 TypeAssign, DeclareType, Cast, TypeArr, TypeObj, TypeObjField,
 TypeName, PointerType, ArrowType, StructType} = require './nodes'
{flatten, last, extend, tystr} = require './helpers'

# Raise a type error with line information.
error = (node, msg) ->
  err = new TypeError msg
  err.lineno = node.lineno
  throw err

#### Constants and Utilities

# The heap module that holds all the views.
HEAP    = new Value new Literal '_HEAP'

# Views.
class ViewLiteral extends Literal
  constructor: (@value, @BYTES_PER_ELEMENT) ->

  compileNode: (o) ->
    name = @value
    o.scope.assign name, "#{HEAP.base.value}.#{name.substr name.lastIndexOf('_') + 1}"
    super o

I8     = new ViewLiteral '_I8',  1
U8     = new ViewLiteral '_U8',  1
I16    = new ViewLiteral '_I16', 2
U16    = new ViewLiteral '_U16', 2
I32    = new ViewLiteral '_I32', 4
U32    = new ViewLiteral '_U32', 4
F32    = new ViewLiteral '_F32', 4
F64    = new ViewLiteral '_F64', 8

# The cached stack pointer.
SP      = new Value new Literal '_SP'
# The actual stack pointer.
SPREAL  = new Value U32, [new Index new Value new Literal 1]
# Memory operations.
MALLOC  = new Value new Literal 'malloc'
FREE    = new Value new Literal 'free'
MEMCPY  = new Value new Literal 'memcpy'

# Global option for if we should print warnings.
opts = { warn: false, unsafe: false }
printWarn = (line) -> process.stderr.write 'warning: ' + line + '\n' if opts.warn

# Ensure that a variable is fresh by getting a fresh name just-in-time.
class FreshLiteral extends Literal
  constructor: (@value, @type) ->

  compileNode: (o) ->
    @value = o.scope.freeVariable @value
    @compileNode = Literal::compileNode
    super o

  typeTransformNode: (o) ->
    this

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
    op = '>>'
  else
    ratio = lalign / ralign
    op = '<<'
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
stackOffsetExpr = (o, offset, offsetTy) ->
  offsetExpr SP, i32ty, offset, offsetTy

# Multiply by a size. If the size is a power of 2, use left shift.
multExpr = (base, size) ->
  # Is size a power of 2?
  if size and ((size & (size - 1)) is 0)
    new Parens new Op '<<', base, new Value new Literal (Math.log(size) / Math.log(2))
  else
    new Op '*', base, new Value new Literal size

# Transform a function to have the right stack pointer computations upon entry
# and exit. The safe way is to wrap the entire body of the function in a
# `try..finally` block to account for possible throws. If the user indicated
# `gotta-go-fast`, we'll only emit stack pointer computations for explicit
# returns.
stackFence = (o, exprs, frameSize, isRoot) ->
  t = new Assign SP, normalizePtr(SPREAL, U8.BYTES_PER_ELEMENT, I32.BYTES_PER_ELEMENT)
  exprs.unshift new Assign SP, normalizePtr(SPREAL, U8.BYTES_PER_ELEMENT, I32.BYTES_PER_ELEMENT)
  exprs.unshift new Assign SPREAL, new Value(new Literal frameSize), '-='
  restoreStack = new Assign SPREAL, new Value(new Literal frameSize), '+='
  if opts.unsafe
    exprs.push restoreStack if isRoot
  else
    exprs[0] = new Try new Block(exprs.slice()), null, null, new Block [restoreStack]
    exprs.length = 1
  return

# Coerce to an integral type.
coerceIntegral = (width, signed) -> (expr, ty) ->
  return expr unless ty isnt this
  # Do we need to truncate? Bitwise operators automatically truncate to 32
  # bits in JavaScript so if the width is 32, we don't need to do manual
  # truncation.
  tywidth = ty.size << 3
  if width isnt 32 and tywidth > width
    c = new Op '&', expr, new Value new Literal '0x' + ((1 << width) - 1).toString(16)
    # Do we need to sign extend?
    if signed
      shiftBy = new Value new Literal 32 - width
      c = new Op '>>', new Op('<<', c, shiftBy), shiftBy
    c
  else if width isnt tywidth or ty.signed isnt signed
    new Op (if signed then '|' else '>>>'), expr, new Value new Literal '0'
  else
    expr

# Dereference something in a heap view.
makeDeref = (o, base, baseTy, offset, offsetTy) ->
  new Value offsetTy.view, [new Index offsetExpr base, baseTy, offset, offsetTy]

# Generate an inline memcpy.
inlineMemcpy = (o, dest, src, ty) ->
  stmts = []
  # Store the pointer to the struct we're copying to.
  destPtr = new Value new FreshLiteral 'dest'
  stmts.push new Assign destPtr, dest
  # Store the pointer to the struct we're copying from.
  srcPtr = new Value new FreshLiteral 'src'
  stmts.push new Assign new Value(srcPtr), src
  # Unroll the copy loop over the bytes.
  align = ty.view.BYTES_PER_ELEMENT
  for i in [0...alignmentUnits ty]
    stmts.push new Assign makeDeref(o, destPtr, ty, i * align, ty),
                          makeDeref(o, srcPtr, ty, i * align, ty)
  stmts.push new Value destPtr
  new Value new Parens new Block stmts

# Find the last executed node.
lastNonCommentOrDecl = (list) ->
  i = list.length
  return [list[i], i] while i-- when list[i] not instanceof Comment and
                                     list[i] not instanceof TypeAssign and
                                     list[i] not instanceof DeclareType
  null


# Many of the algorithms we do here are more naturally expressed as folds.
# Also, instead of passing in a function, pass in a prop to be called on each
# child, which pushes the typecase into the VM.
Base::foldChildren = (r, m, o) ->
  return r unless @children
  if o.immediate
    for attr in @children when @[attr]
      for child in flatten [@[attr]]
        r = if typeof child[m] is 'function' then child[m](r, o) else r
  else
    for attr in @children when @[attr]
      for child in flatten [@[attr]]
        r = child.foldChildren r, m, o
  if typeof @[m] is 'function' then @[m](r, o) else r

Code::foldChildren = (r, m, o) ->
  return r unless o.crossScope
  super r, m, o

# Gather return expressions.
collectReturns = (body) ->
  exprs = body.expressions
  body.foldChildren [], 'collectReturn', {}

undefExpr = new Value new Literal 'undefined'

Return::collectReturn = (exprs, o) ->
  exprs.push this
  exprs

#### Build Typed Scope

# A box used to record a local variable's type and other metadata.
class Binding
  constructor: (@type) ->

# This is like *Scope::type*, but it also looks up the scope chain.
Scope::binding = (name, immediate) ->
  found = @type name
  return found if found or immediate
  @parent?.binding name

# Add parameter and return types to the typed scope.
newTypedScope = (p, e, m) ->
  scope = new Scope p, e, m
  scope.variables.length = 0
  scope.frameSize = 0
  scope

# Declaring a type associates a type with the variable in the current
# scope.
declare = (scope, v, ty, variables) ->
  if v instanceof Value
    error v, "cannot type properties" if v.hasProperties()
    v = v.base
  if v instanceof Literal
    return unless ty
    if ty instanceof TypeArr or ty instanceof TypeObj
      error v, "cannot type non-destructuring variable `#{v.value}' with destructuring type `#{ty}'"
    name = v.value
    error v, "cannot redeclare variable `#{name}'" if scope.check name
    bind = new Binding ty
    scope.add name, bind
    variables?.push { name, type: ty, binding: bind }
    putOnStack scope, name if ty instanceof StructType
    return
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

# Put a variable on the stack and increment the frame size.
putOnStack = (scope, name) ->
  bind = scope.binding name, true
  bind.onStack = true
  bind.spOffset = alignOffset scope.frameSize, bind.type
  scope.frameSize = bind.spOffset + bind.type.size
  return

DeclareType::declareType = (scope, o) ->
  declare scope, v, @type.lint(o.types), @variables for v in @typeables
  scope

Param::declareType = (scope, o) ->
  # Lint just in case the user manually declared the parameter types and
  # thus the types were not linted before this point.
  declare scope, @name, @type?.lint(o.types), (@variables = [])
  scope

Op::putOnStack = (scope, o) ->
  if @operator is '&' and (inner = @first.unwrapAll()) instanceof Literal
    name = inner.value
    putOnStack scope, name if scope.check name, true
  scope

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

PointerType::coerce = (expr, ty) ->
  return expr unless ty instanceof PointerType and ty isnt this
  return expr if expr.unwrapCast?().value is '0'
  normalizePtr expr, ty.baseAlignment(), this.baseAlignment()

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

#### Type Checking and Transformation

# Cast a node as a particular type.
cast = (node, ty) ->
  new Cast node, ty, true

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
  # Destructurings.
  if lty instanceof TypeObj and rty instanceof TypeObj
    return unless lty.fields.length is rty.fields.length
    fields = []
    for { name, type: lfty } in lty.fields
      return unless fty = unify types, lfty, rty.names[name]?.type, assigning
      fields.push new TypeObjField name, fty
    return new TypeObj fields
  if lty instanceof TypeArr and rty instanceof TypeArr
    return unless lty.elements.length is rty.elements.length
    elements = []
    for ty, i in lty.elements
      return unless ety = unify types, ty, rty.elements[i], assigning
      elements.push ety
    return new TypeArr elements
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

Base::typeTransform = (o) ->
  @typeTransformNode (extend {}, o)

typeTransformArray = (o, a) ->
  for el, i in a
    if el instanceof Array and el.length
      typeTransformArray el
    else
      a[i] = el.typeTransform o

Base::typeTransformNode = (o) ->
  for attr in @children when child = @[attr]
    if child instanceof Array and child.length
      typeTransformArray o, child
    else
      @[attr] = child.typeTransform o
  this

Literal::typeTransformNode = (o) ->
  if o.isValue
    # Only literals that are values should get types. We don't want to
    # transform properties. Simple identifiers and integer literals may be
    # typed.
    val = @value
    if val is 'null' or (val is '0' and o.wantsToBePointer)
      # This matters for TI: `null` will cause the typeset of pointers to be
      # dimorphic.
      @value = '0'
      cast this, anyPtrTy
    else if @isAssignable() and bind = o.scope.binding val
      ty = bind.type
      if bind.onStack
        offset = stackOffsetExpr o, bind.spOffset, ty
        unless o.scope.check val, true
          error this, "cannot close over non-local on-stack variable `#{name}'"
        if ty instanceof StructType
          cast offset, ty
        else
          cast new Value(ty.view, [new Index offset]), ty
      else
        cast this, ty
    else if @isSimpleNumber()
      i = parseInt val
      ty = if (i | 0) is i then i32ty else if (i >>> 0) is i then u32ty else f64ty
      cast this, ty
    else if not isNaN Number val
      cast this, f64ty
    else
      this
  else
    this

# Only constant indices may be typed.
Index::isConstant = ->
  idx = @index.unwrapValue()
  return idx instanceof Value and (idx.isString() or idx.isSimpleNumber())

# Similar from `Value::cacheReference`, except that it uses
# **FreshLiteral**. We can't ever get a complex `name` that isn't pointer
# arithmetic and still be typed, so we remove that case.
Value::cacheTransformReference = (ty) ->
  name = last @properties
  if @properties.length < 2 and not @base.isComplex()
    casted = cast this, ty
    return [casted, casted]  # `a` `a.b`
  base = new Value @base, @properties[...-1]
  if base.isComplex()  # `a().b`
    bref = new Value new FreshLiteral 'base'
    base = new Value new Parens new Assign bref, base
  return [cast(base, ty), cast(bref, ty)] unless name  # `a()`
  [cast(base.add(name), ty), cast(new Value(bref or base.base, [name]), ty)]

# Values are typed if they're declared to be typed, a literal of one of the
# primitive types, or a property access on a typed property. The latter can
# only happen on property accesses of object and array literals where the
# constituents are typed.
Value::typeTransformNode = (o) ->
  o.isValue = yes
  return this unless vty = (v = @base.typeTransform o).type
  cumulativeOffset = 0
  for prop, i in @properties
    vty = vty.base if vty instanceof PointerType
    if prop instanceof Access
      fieldName = prop.name.unwrapAll().value
    else if prop instanceof Index and prop.isConstant()
      fieldName = prop.index.unwrapAll().value
    else
      return this
    if vty instanceof StructType
      field = vty.names[fieldName]
      error this, "unknown struct field name `#{fieldName}'" unless field
      if (fty = field.type) instanceof StructType
        cumulativeOffset += field.offset
      else
        v = makeDeref o, v, vty, field.offset + cumulativeOffset, fty
        vty = fty
        cumulativeOffset = 0
    else if vty instanceof TypeObj
      unless vty = vty.names[fieldName]?.type
        return this
      v = new Value v, [prop]
    else if vty instanceof TypeArr
      unless vty = vty.elements[fieldName]
        return this
      v = new Value v, [prop]
  if cumulativeOffset isnt 0
    v = offsetExpr v, vty, cumulativeOffset, fty
  cast new Value(v), vty

# Applications may be typed if the function is typed and the parameter types
# unify asymmetrically.
Call::typeTransformNode = (o) ->
  fty = (@variable = @variable.typeTransform o).type
  error this, "calling a non-function type `#{fty}'" unless fty instanceof ArrowType
  types = o.types
  paramTys = fty.params
  args = @args
  for pty, i in fty.params
    # If fewer arguments than there are parameters were passed, this will be
    # `undefined` and interpreted as the type `any`.
    aty = (args[i] = args[i]?.typeTransform o)?.type
    if pty and not unify types, pty, aty, true
      error this, "incompatible types: passing arg `#{tystr(aty)}' to param `#{tystr(pty)}'"
  # If all the arguments checked, the call gets the return type.
  cast this, fty.ret

# An object literal may be typed pointwise.
Obj::typeTransformNode = (o) ->
  fields = []
  props = @properties
  for prop, i in props
    if prop.isComplex()
      propName = prop.variable.unwrapAll().value.toString()
      propVar = prop.variable
      propValue = prop.value
    else
      propName = prop.unwrapAll().value.toString()
      propVar = prop
      propValue = prop
    propTy = (propValue = propValue.typeTransform o).type
    if propTy
      props[i] = new Assign propVar, propValue, 'object'
      fields.push new TypeObjField propName, propTy
  cast this, (new TypeObj fields if fields.length)

# An array literal may be typed pointwise.
Arr::typeTransformNode = (o) ->
  fields = []
  els = @objects
  for el, i in els
    elty = (el[i] = el.typeTransform o).type
    fields.push elty
    someTyped = yes if elty
  cast this, (new TypeArr fields if someTyped)

# An assignment is typed if the left side is typed and the two sides' types
# unify asymmetrically.
Assign::typeTransformNode = (o) ->
  lty = (variable = @variable.typeTransform o).type

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
  # *only* when the binding for f is a *syntactic* function. If not, you would
  # have to declare the types of arguments manually.
  if (fn = @value.unwrapAll()) instanceof Code and lty instanceof ArrowType
    # Remember the parameter and return types on the right-hand side. The
    # return type is only used to propagate the types further, if it is
    # another arrow type.
    fn.paramTypes ?= lty.params
    fn.returnType ?= lty.ret

  o.wantsToBePointer = lty instanceof PointerType and not context
  rty = (value = @value.typeTransform o).type
  unless lty
    @variable = variable
    @value = value
    return this

  # Are we assigning into a view?
  autoCoerce = variable.unwrapCast().base instanceof ViewLiteral

  # Desugar compound assignments, since we need to coerce.
  if context = @context
    op = context.substr 0, context.indexOf '='
    [left, right] = variable.expr.cacheTransformReference variable.type
    # Only expand compound assignment if we're not assigning into a view and
    # we don't need to cache reference to preserve semantics.
    unless autoCoerce and left.expr is variable.expr
      return (new Assign left, new Op(op, right, value)).typeTransform o
    rty = binopType o, op, lty, rty

  unless ty = unify o.types, lty, rty, true
    msg = "incompatible types: assigning `#{tystr(rty)}' to `#{lty}'"
    if context
      error variable, msg + " using #{context}"
    else
      error variable, msg

  if lty instanceof StructType
    cast inlineMemcpy(o, variable, value, lty), lty
  else if lty instanceof TypeObj or lty instanceof TypeArr
    # Transform destructuring if we're doing some kind of typed thing.
    ref = new FreshLiteral 'ref', lty
    assigns = [new Assign new Value(ref), value]
    pattern = variable.expr
    isObject = pattern.isObject()
    for obj, i in pattern.base.objects
      idx = i
      if isObject
        if obj instanceof Assign
          {variable: {base: idx}, value: obj} = obj
        else
          # Everything in this branch is untyped, so they shouldn't have any
          # casts.
          if obj.base instanceof Parens
            [obj, idx] = new Value(obj.unwrapAll()).cacheTransformReference()
          else
            idx = if obj.this then obj.properties[0].name else obj
      if typeof idx is 'number'
        idx = new Literal idx
        acc = no
      else
        acc = isObject and idx.isAssignable() or no
      val = new Value ref, [new (if acc then Access else Index) idx]
      assigns.push (new Assign obj, val, null, param: @param).typeTransform o
    assigns.push new Value ref
    cast new Value(new Parens new Block assigns), lty
  else
    @variable = variable
    if autoCoerce
      if context and lty instanceof PointerType and (au = alignmentUnits lty.base) isnt 1
        @value = cast multExpr(value, au), lty
      else
        @value = value
    else
      @value = cast value, lty
    cast this, lty

# A function may be typed if its parameters are typed and the types of all its
# return expressions unify.
Code::typeTransformNode = (o) ->
  # If the declared return type is an arrow type, recur on all return
  # positions and propagate.
  if rty = @returnType instanceof ArrowType
    for rexpr in returnExpressions @body when rexpr instanceof Code
      rexpr.paramTypes ?= rty.params
      rexpr.returnType ?= rty.ret
  scope = newTypedScope o.scope, @body, this
  ptys = @paramTypes
  if ptys
    if ptys.length isnt @params.length
      error this, "arrow type has different number of parameters than function"
    types = o.types
    for param, i in @params
      param.type = ptys[i]
      scope = param.declareType scope, o

  # Hoist all the **DeclareType**s to the top and process them.
  o.scope = @body.foldChildren @body.foldChildren(scope, 'declareType', o), 'putOnStack', o

  # Convert the last expression to an explicit return.
  exprs = @body.expressions
  [implicitReturn, i] = lastNonCommentOrDecl exprs
  exprs[i] = new Return implicitReturn unless implicitReturn.jumps()

  # Copy parameters that are passed by value and live on the stack.
  if frameSize = o.scope.frameSize
    for param in @params
      for arg in param.variables when arg.binding.onStack
        plh = new Value new Literal arg.name
        # The cast is to prevent transforming the right-hand side to a stack
        # dereference.
        prh = cast new Value(new Literal arg.name), arg.binding.type
        exprs.unshift new Assign plh, prh
    # Do the stack fence.
    stackFence o, exprs, frameSize if frameSize

  body = @body.typeTransform o
  body = body.expr if body instanceof Cast

  # Unify the return types and do the stack thing. We should pull the types
  # directly out since they've been transformed already above.
  types = o.types
  for ret, i in rets = collectReturns body
    rexpr = ret.expression
    if i is 0
      rty = rexpr?.type
    else
      rty = unify types, rexpr?.type, rty

  unsafeSpRestore = frameSize and opts.unsafe
  if unsafeSpRestore or rty
    if unsafeSpRestore
      restoreStack = new Assign SPREAL, new Value(new Literal frameSize), '+='
    for ret in rets
      hasExpr = ret.expression?
      ret.expression = cast ret.expression, rty if rty and hasExpr
      if unsafeSpRestore
        if hasExpr
          expr = ret.expression
          tmp = new Value new FreshLiteral 't', expr.type
          b = [new Assign(tmp, expr), restoreStack, tmp]
        else
          b = [restoreStack, undefExpr]
        ret.expression = new Value new Parens new Block b

  @body = body
  cast this, new ArrowType(ptys, rty)

# Binary operations may be type depending on the operation. Bitwise operators
# and comparisons always produce i32.
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

Op::typeTransformNode = (o) ->
  op  = @operator
  if @isUnary()
    if op is 'new' and @first.unwrapAll().value of o.types
      ty1 = o.types[@first.unwrapAll().value]
      error this, "cannot allocate unsized type `#{ty1}'" unless ty1?.size
      Scope.root.needsMalloc = yes
      cast new Call(MALLOC, [new Value new Literal ty1.size]), new PointerType ty1
    else if op is 'delete' and [first, ty1] = @first.typeTransform o and ty1
      error this, 'cannot free non-pointer type' unless ty1 instanceof PointerType
      Scope.root.needsMalloc = yes
      cast new Call(FREE, [first]), unit
    else if op is 'sizeof'
      ty1 = @first = @first.lint o.types
      error this, "cannot determine size of type `#{ty1}'" unless ty1.size
      cast new Literal(ty1.size), i32ty
    else if op is '&'
      ty1 = (first = @first.typeTransform o).type
      error this, "taking reference of an untyped expression `#{@first.compile o}'" unless ty1
      error this, "taking reference of a function type" if ty1 instanceof ArrowType
      error this, "taking reference of non-assignable" unless @first.isAssignable()
      ty = new PointerType ty1
      addr = if ty1 instanceof StructType then first else first.expr.properties[0].index
      cast addr, ty
    else if op is '*'
      ty1 = (first = @first.typeTransform o).type
      error this, "dereferencing untyped expression" unless ty1
      error this, "dereferencing a non-pointer type" unless ty1 instanceof PointerType
      if ty1 = ty1.base instanceof StructType
        cast first, ty1
      else
        cast makeDeref(o, first, ty1, 0, ty1), ty1
    else if (op is '++' or op is '--') and
            (ty1 = (first = @first.typeTransform o).type) and
            (ty1 instanceof PointerType or ty1 in numeric)
      [left, right] = first.expr.cacheTransformReference ty1
      tmp = new Value new FreshLiteral 't', ty1
      asn = new Assign right, new Value(new Literal '1'), if op is '++' then '+=' else '-='
      assigns = [new Assign(tmp, left), asn.typeTransform(o), tmp]
      cast new Value(new Parens new Block assigns), ty1
    else
      @first = @first.typeTransform o
      this
  else
    ty1 = (@first = @first.typeTransform o).type
    ty2 = (@second = @second.typeTransform o).type
    # Commute.
    pointerSecond = ty2 instanceof PointerType
    ty = binopType o, op, (if pointerSecond then ty2 else ty1),
                          (if pointerSecond then ty1 else ty2), this
    if (op is '+' or op is '-') and
       ((ty1 instanceof PointerType and ty2 in integral and
         (au = alignmentUnits ty1.base) isnt 1) or
        (ty2 instanceof PointerType and ty1 in integral and
         (au = alignmentUnits ty2.base) isnt 1))
      if ty1 instanceof PointerType
        @second = multExpr @second, au
      else
        @first = multExpr @first, au
    else if op in COMPARE and
         ty1 instanceof PointerType and ty2 instanceof PointerType
      # By convention always normalize the second operand.
      @second = cast @second, ty1
    cast this, ty

# Parenthesized expressions gets the type of the expression.
Parens::typeTransformNode = (o) ->
  @body = @body.typeTransformNode o
  cast this, @body.type

# A block gets the type of its tail expression.
Block::typeTransformNode = (o) ->
  return super o unless o.isValue
  for expr, i in exprs = @expressions
    exprs[i] = expr.typeTransform o
    if i is exprs.length - 1
      unless expr.jumps()
        ty = exprs[i].type
        return cast this, ty
      return this

# A switch gets the unified type of all its cases.
Switch::computeNodeType = (o) ->
  return super o unless o.isValue
  @subject = @subject.typeTransform o
  types = o.types
  caseTys = []
  someCaseJumps = false
  someCaseTyped = false
  for c, i in @cases
    block = c.block
    if block.jumps()
      ty = null
      someCaseJumps = true
    else
      ty = (c.block = block.typeTransform o).type
    caseTys.push ty
    someCaseTyped = true if ty
    if i is 0
      cty = ty
    else
      cty = unify types, ty, cty
  if @otherwise
    otherwiseTy = (@otherwise = @otherwise.typeTransform o).type
    cty = unify types, otherwiseTy, cty
  if someCaseTyped and not cty
    if someCaseJumps
      printWarn "cannot type switch with jumps"
    else
      printWarn "branches of switch have different types: `#{(tystr(ty) for ty in caseTys).join('\', `')}'"
  cast this, cty

# An if gets the unified type of both of its branches.
If::typeTransformNode = (o) ->
  return super o unless o.isValue
  @condition = @condition.typeTransform o
  thenTy = (@body = @body?.typeTransform o)?.type
  elseTy = (@elseBody = @elseBody?.typeTransform o)?.type
  ty = unify o.types, thenTy, elseTy
  if (thenTy or elseTy) and not ty
    printWarn "branches of if have different types: `#{tystr(thenTy)}' and `#{tystr(elseTy)}'"
  cast this, ty

# Casting coerces the expression to a certain type during compilation.
Cast::typeTransformNode = (o) ->
  unless @generated
    @type = @type.lint o.types
    @expr = @expr.typeTransform o
  this

#### Driver

# Primitive types as found in C.
class PrimitiveType
  constructor: (@size, @debugName, @view, @signed, @coerce) ->
  lint: (types) -> this
  toString: -> @debugName

# Cache this for typing null values.
anyPtrTy = new PointerType null

# Builtin primitives.
unit  = new PrimitiveType 0, 'unit'
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

requireExpr = (name) ->
  new Call new Value(new Literal 'require'), [new Value new Literal "'#{name}'"]

exports.analyzeTypes = (root, o = {}) ->
  usesTypes = no
  root.traverseChildren yes, (node) ->
    if (node instanceof DeclareType) or (node instanceof TypeAssign) or
       (node instanceof Op and node.isUnary() and
        (node.operator is '&' or node.operator is '*')) or
       (node instanceof Code and node.paramTypes)
      usesTypes = yes
      return no
  return root unless usesTypes

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

  # Collect all type synonyms.
  types = root.foldChildren initialTypes, 'collectType', immediate: true
  types[name] = ty.lint types for name, ty of types when ty

  # Build the type scope.
  o = { types: types }
  scope = newTypedScope null, root, null
  o.scope = root.foldChildren root.foldChildren(scope, 'declareType', o), 'putOnStack', o

  # Do the stack fence for the module.
  exprs = root.expressions
  if frameSize = o.scope.frameSize
    o.frameSize = frameSize
    stackFence o, exprs, frameSize, yes

  # Do the actual transform
  root.typeTransform o

  # Bring in `malloc` if this module needs it.
  if Scope.root.needsMalloc
    obj = new Value new Obj [MALLOC, FREE]
    exprs.unshift new Assign obj, requireExpr 'heap/malloc'

  # Add a transform hook that requires the heap module.
  root.transformRoot = (o) ->
    # Require the heap. This has to be done using `o.scope.assign`, to make sure
    # that it comes before the cached views.
    o.scope.assign HEAP.base.value, "require('heap/heap')"

  root
