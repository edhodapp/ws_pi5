/* In-RAM ring-buffer store.
 *
 * A store is a small BSS region shaped like:
 *   offset 0:  u32 records_written (monotonic; wraps at 2^32)
 *   offset 4:  u32 record_bytes    (fixed size of each record)
 *   offset 8:  u32 capacity        (must be power of 2)
 *   offset 12: u32 pad
 *   offset 16: record data (capacity * record_bytes)
 *
 * Capacity must be a power of 2 so wrap-around is a mask AND.
 * Total store footprint = 16 + capacity * record_bytes.
 *
 * API (lib/store.S):
 *   store_init(x0: store, w1: record_bytes, w2: capacity)
 *   store_append(x0: store, x1: data_ptr)   — copies record_bytes from data_ptr
 *   store_count(x0: store) -> w0            — min(records_written, capacity)
 *   store_read(x0: store, w1: index, x2: out_ptr) -> w0 = bytes_copied
 *     index 0 = oldest, count-1 = newest; returns 0 if out of range.
 */

.equ STORE_WRITTEN,    0
.equ STORE_REC_BYTES,  4
.equ STORE_CAP,        8
.equ STORE_DATA,       16
