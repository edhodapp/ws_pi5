/* NTP protocol constants and struct offsets */

/* NTP packet offsets (relative to UDP payload) */
.equ NTP_FLAGS,         0       /* LI(2) | VN(3) | Mode(3) */
.equ NTP_STRATUM,       1
.equ NTP_POLL,          2
.equ NTP_PRECISION,     3
.equ NTP_ROOT_DELAY,    4
.equ NTP_ROOT_DISP,     8
.equ NTP_REF_ID,        12
.equ NTP_REF_TS,        16
.equ NTP_ORIG_TS,       24
.equ NTP_RX_TS,         32
.equ NTP_TX_TS,         40
.equ NTP_PKT_LEN,       48

/* Protocol values */
.equ NTP_CLIENT_FLAGS,  0x23    /* LI=0, VN=4, Mode=3 (client) */
.equ NTP_SERVER_MODE,   4
.equ NTP_PORT,          123

/* Epoch conversion: NTP epoch (1900) to Unix epoch (1970) */
.equ NTP_UNIX_OFFSET_HI, 0x83AA    /* upper 16 bits of 0x83AA7E80 */
.equ NTP_UNIX_OFFSET_LO, 0x7E80    /* lower 16 bits of 0x83AA7E80 */

/* Poll interval */
.equ NTP_POLL_SECS,     64

/* NTP request frame size: ETH(14) + IP(20) + UDP(8) + NTP(48) = 90 */
.equ NTP_FRAME_LEN,     90

/* ntp_state struct offsets (32 bytes, .data) */
.equ NTPS_SYNC_SECS,    0       /* u64 — Unix seconds at last sync */
.equ NTPS_SYNC_TICKS,   8       /* u64 — counter ticks at last sync */
.equ NTPS_TIMER_FREQ,   16      /* u64 — CNTFRQ_EL0 cached */
.equ NTPS_SYNCED,        24      /* u32 — 1 after first successful sync */
.equ NTPS_PAD,           28      /* u32 — padding */
.equ NTPS_SIZE,          32

/* ntp_send_ctx struct offsets (32 bytes, .data) */
.equ NTPC_DWC2_BASE,    0       /* u64 — DWC2 register base */
.equ NTPC_ECM_STATE,    8       /* u64 — ecm_state pointer */
.equ NTPC_TX_BUF,       16      /* u64 — tx buffer pointer */
.equ NTPC_TIMER_POOL,   24      /* u64 — timer pool pointer */
.equ NTPC_SIZE,          32

/* NTP source port for outbound requests */
.equ NTP_SPORT,         12345
