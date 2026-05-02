/*
 * include/dhcp.inc — DHCP client constants (D017).
 *
 * State and event ordinals are NORMATIVE — the verify script reads
 * tests/func/dhcp_fsa_vectors.tsv and indexes the transition table
 * by (state * DHCP_NEVENTS + event). Reordering or renumbering
 * either set requires updating the .py state/event maps in lockstep.
 *
 * Transition-table entry layout matches include/vmio.inc's TRANS_*:
 *   +0  next_state   u32  (DHCP_NEXT_NONE = 0xFFFFFFFF means "no transition")
 *   +4  pad          u32
 *   +8  handler_ptr  u64  (0 = no handler)
 *  size 16 B
 */

.equ DHCP_NSTATES,         6
.equ DHCP_NEVENTS,         9

/* States — order MUST match scripts/verify_dhcp_fsa_table.py STATES. */
.equ S_INIT,               0
.equ S_SELECTING,          1
.equ S_REQUESTING,         2
.equ S_BOUND,              3
.equ S_RENEWING,           4
.equ S_REBINDING,          5

/* Events — order MUST match scripts/verify_dhcp_fsa_table.py EVENTS. */
.equ E_START,                  0
.equ E_TIMER_RETRANS_RETRY,    1
.equ E_TIMER_RETRANS_GIVEUP,   2
.equ E_TIMER_T1,               3
.equ E_TIMER_T2,               4
.equ E_TIMER_LEASE,            5
.equ E_RX_OFFER_VALID,         6
.equ E_RX_ACK_VALID,           7
.equ E_RX_NAK_VALID,           8

/* Transition-table entry layout — same shape as include/vmio.inc but
 * we redeclare the offsets so dhcp_fsa.S has no dependency on
 * vmio.inc (the DHCP FSA is single-instance, no queues, no ways). */
.equ DHCP_TRANS_NEXT,      0
.equ DHCP_TRANS_HANDLER,   8
.equ DHCP_TRANS_SIZE,      16

/* Sentinel u32 marking "table cell has no state transition". The
 * step function leaves dhcp_fsa_state untouched when next == this
 * value, regardless of whether a handler ran. */
.equ DHCP_NEXT_NONE,       0xFFFFFFFF
