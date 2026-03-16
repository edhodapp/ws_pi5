/* VMIO FSA Engine — structure offsets and constants */

/* Event structure (32 bytes) */
.equ EVT_AUTO,     0       /* u16 — automaton number */
.equ EVT_WAY,      2       /* u16 — way number */
.equ EVT_CODE,     4       /* u16 — event code */
.equ EVT_FLAGS,    6       /* u16 — reserved */
.equ EVT_DST,      8       /* u64 — destination / app-defined */
.equ EVT_SRC,      16      /* u64 — source / app-defined */
.equ EVT_DATA,     24      /* u64 — data pointer / payload */
.equ EVT_SIZE,     32

/* Event queue (circular buffer, power-of-2 capacity) */
.equ Q_HEAD,       0       /* u32 — next slot to dequeue */
.equ Q_TAIL,       4       /* u32 — next slot to enqueue */
.equ Q_MASK,       8       /* u32 — capacity - 1 */
.equ Q_PAD,        12      /* u32 — alignment padding */
.equ Q_SLOTS,      16      /* start of event array */

/* Default queue capacity (must be power of 2) */
.equ Q_DEFAULT_CAP, 16
.equ Q_DEFAULT_MASK, 15

/* Queue size: header + N * EVT_SIZE */
.equ Q_DEFAULT_SIZE, 528   /* 16 + 16*32 */

/* Transition table entry (16 bytes) */
.equ TRANS_NEXT,    0       /* u32 — next state */
.equ TRANS_PAD,     4       /* u32 — padding */
.equ TRANS_HANDLER, 8       /* u64 — handler fn ptr (0 = no transition) */
.equ TRANS_SIZE,    16

/* Engine struct (48 bytes) */
.equ ENG_STATE,     0       /* u32 — current state */
.equ ENG_NSTATES,   4       /* u32 — number of states */
.equ ENG_NEVENTS,   8       /* u32 — number of event codes */
.equ ENG_PAD,       12      /* u32 — padding */
.equ ENG_TABLE,     16      /* u64 — pointer to transition table */
.equ ENG_HI_Q,      24      /* u64 — pointer to hi-priority queue */
.equ ENG_LO_Q,      32      /* u64 — pointer to lo-priority queue */
.equ ENG_CTX,       40      /* u64 — context pointer */
.equ ENG_SIZE,       48

/* Step return codes */
.equ STEP_OK,       0       /* event processed */
.equ STEP_IDLE,     1       /* both queues empty */
.equ STEP_NO_TRANS, -1      /* no transition for (state, evt_code) */
