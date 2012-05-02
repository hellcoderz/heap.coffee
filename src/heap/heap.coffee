# `heap.coffee` contains the actual heap instantiation for programs that use
# types. This is implicitly `require`d in every file that uses types. The
# programmer should never need to manually `require` it.

# Tweak accordingly.
HEAPSIZE = 1024 * 1024

buf = new ArrayBuffer HEAPSIZE

exports. _I8 = new   Int8Array buf
exports. _U8 = new  Uint8Array buf
exports._I16 = new  Int16Array buf
exports._U16 = new Uint16Array buf
exports._I32 = new  Int32Array buf
exports._U32 = new Uint32Array buf

# The first int32 in the heap is the heap pointer, pointing to where the
# heap starts in bytes. This grows down.
exports._U32[0] = 8

# The second int32 in the heap is the stack pointer, pointing to where the
# stack starts in bytes. This grows up.
exports._U32[1] = HEAPSIZE
