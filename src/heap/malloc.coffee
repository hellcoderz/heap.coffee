# `malloc.coffee` contains an implementation of the sample malloc and free as
# they appear in K&R. Some details had to be changed due to not having static
# globals. This is implicitly `require`d in every file that uses new and
# delete. The programmer should never need to manually `require` it.
#
#   +---------------+ -
# 0 | Heap  Pointer |
# 1 | Stack Pointer |
#   +---------------+ <- Heap Pointer
#   |               |
#   |               | |
#   |     HEAP      | | Malloc Region
#   |               | v
#   |               |
#   +---------------+
#   |               |
#   |               | ^
#   |     STACK     | |
#   |               | |
#   |               |
#   +---------------+ <- Stack Pointer

type header = struct
  ptr  :: *header
  size :: uint

freep :: *header
freep = null

malloc :: (uint) -> *any
malloc = (nbytes) ->
  p, prevp :: *header
  nunits   :: uint

  nunits = (nbytes + sizeof header - 1) / sizeof header + 1
  unless prevp = freep
    # Haven't allocated a free list yet, do it now.
    prevp = freep = _U32[0] as *any
    _U32[0] += sizeof header
    freep.ptr  = freep
    freep.size = 0

  p = prevp.ptr
  loop
    if p.size >= nunits
      if p.size is nunits
        prevp.ptr = p.ptr
      else
        p.size -= nunits
        p += p.size
        p.size = nunits
      freep = prevp
      return p + 1
    if p is freep
      return null unless p = morecore nunits
    prevp = p
    p = p.ptr
  null

NALLOC :: int
NALLOC = 1024

morecore :: (uint) -> *header
morecore = (nu) ->
  _U8 = _HEAP.U8
  nu = NALLOC if nu < NALLOC
  bytesNeeded = nu * sizeof header
  return null if _U32[0] + bytesNeeded >= _U8.length
  up :: *header
  up = _U32[0] as *any
  up.size = nu;
  _U32[0] += bytesNeeded
  free up + 1
  freep

free :: (*any) -> any
free = (ap) ->
  bp, p :: *header

  bp = (ap as *header) - 1

  p = freep
  until (bp > p and bp < p.ptr)
    if p >= p.ptr and (bp > p or bp < p.ptr)
      break
    p = p.ptr

  if (bp + bp.size is p.ptr)
    bp.size += p.ptr.size
    bp.ptr = p.ptr.ptr
  else
    bp.ptr = p.ptr

  if (p + p.size is bp)
    p.size += bp.size
    p.ptr = bp.ptr
  else
    p.ptr = bp

  freep = p
  return

exports.malloc = malloc
exports.free   = free
