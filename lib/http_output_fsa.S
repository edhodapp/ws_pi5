/*
 * http_output_fsa.S — VMIO-driven HTTP response send path.
 *
 * Parallel build behind --defsym HTTP_OUTPUT_FSA=1. When the flag is
 * off this file is not linked at all (see Makefile SHARED_OBJS
 * conditional) so the legacy send path in lib/http.S is untouched.
 *
 * When the flag is on:
 *   - http_init calls http_output_fsa_init which wires up the per-HCONN
 *     FSA state and the shared vmio_engine
 *   - http_poll delegates the send path to http_output_fsa_poll (the
 *     call site is gated by the same .ifdef)
 *   - The legacy send path still compiles, for bisect-ability — cutover
 *     commit deletes it in a single reviewable diff.
 *
 * STATES  (stored in O_STATE per HCONN, distinct from HCONN_STATE which
 *          continues to track the input-side lifecycle):
 *   O_IDLE        no response queued
 *   O_SETUP       hdr+body installed; waiting for first tx window
 *   O_TX          emitting chunks; boundary (hdr vs body) resolved
 *                 dynamically inside h_send via RESP_PTR vs HDR_LEN
 *   O_DRAINING    all bytes queued to TCP; waiting for sndbuf drain
 *   O_CLOSE       close + hconn reset
 *   O_KEEPALIVE   reset hconn to RECV_HDR for pipelined next request
 *
 * EVENTS (posted via http_output_fsa_post, which enforces the
 *         per-(way, event_code) gating invariant):
 *   E_RESP_READY    route dispatch produced hdr+body
 *   E_WIN_OPEN      tcp_send_ready transitioned 0 -> non-zero
 *   E_CHUNK_SENT    send handler wrote one frame; may loop
 *   E_ALL_QUEUED    last byte of response handed to TCP
 *   E_ALL_DRAINED   sndbuf_unacked reached zero for a draining conn
 *   E_TCP_CLOSED    TCP left ESTABLISHED while output FSA was active
 *
 * See DESIGN notes in the task description — the transition table
 * lands in commit 2, happy-path handlers in commit 3.
 */

.include "vmio.inc"

.ifdef HTTP_OUTPUT_FSA

.section .text

/* Intentional no-op placeholder so the flag-on build produces a non-
 * empty object. Real functions land in commit 2. Exporting the
 * symbol makes grepping for the feature trivially easy. */
.global http_output_fsa_stub
http_output_fsa_stub:
    ret

.endif
