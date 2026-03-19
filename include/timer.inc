/* Timer pool — structure offsets and constants */

/* Slot layout (32 bytes) */
.equ SLOT_EXPIRY,    0       /* u64 — counter tick when timer fires */
.equ SLOT_CALLBACK,  8       /* u64 — function pointer (0 = inactive) */
.equ SLOT_CONTEXT,   16      /* u64 — passed as x0 to callback */
.equ SLOT_PAD,       24      /* u64 — reserved */
.equ SLOT_SIZE,      32

/* Pool header layout */
.equ TPOOL_CAP,      0       /* u32 — number of slots */
.equ TPOOL_PAD,      4       /* u32 — alignment padding */
.equ TPOOL_SLOTS,    8       /* start of slot array */

/* Default capacity */
.equ TPOOL_DEFAULT_CAP,  16
.equ TPOOL_DEFAULT_SIZE, 520  /* 8 + 16*32 */
