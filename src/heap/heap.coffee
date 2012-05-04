# `heap.coffee` contains the actual heap instantiation for programs that use
# types. This is implicitly `require`d in every file that uses types. The
# programmer should never need to manually `require` it.

# Tweak accordingly.
HEAPSIZE = 1024 * 1024

buf = new ArrayBuffer HEAPSIZE

exports. I8 = new   Int8Array  buf
exports. U8 = new  Uint8Array  buf
exports.I16 = new  Int16Array  buf
exports.U16 = new Uint16Array  buf
exports.I32 = new  Int32Array  buf
exports.U32 = new Uint32Array  buf
exports.F32 = new Float32Array buf
exports.F64 = new Float64Array buf

# The first int32 in the heap is the heap pointer, pointing to where the
# heap starts in bytes. This grows down.
exports.U32[0] = 8

# The second int32 in the heap is the stack pointer, pointing to where the
# stack starts in bytes. This grows up.
exports.U32[1] = HEAPSIZE
