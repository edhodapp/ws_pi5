# wedge-v2 investigation log

Concurrent-burst wedge, take 2. The 38e6bc4 SP-alignment fix resolved a
CPU-halt-under-load mode (data abort from misaligned SP in
`tcp_sndbuf_build_frame`). The current symptom looks similar but is
distinct:

- After `test_repeated_bursts` (10 rounds × 10 concurrent HTTP, 100
  conns in ~5 s), TCP connections to port 80 are refused for ~60 s.
- Subsequent test files in the same L4 phase (`test_tcp_data`,
  `test_tcp_handshake`) all fail with `ConnectionRefusedError`.
- ICMP keeps working *during* the wedge — kernel main loop alive.
- **No `EXC:` line on UART** during the wedge — not a fault.
- Some reflashes after a wedge see `genet_init` hang (no
  "GENET Gigabit Ethernet initialized") even though the chainloader
  hands off cleanly. Physical power-cycle clears this.

That last bit is the genuinely concerning part — it implies hardware
state that survives the SoC-level reset, which a software-only
exhaustion theory doesn't explain.

## Phase D1 — clean repro & wedge profile

Goal: characterize the wedge mode precisely. Single test isolated,
fresh kernel, full UART capture.

### Method
- Power-cycle the Pi physically.
- Flash a fresh kernel via the chainloader.
- `HW_TEST=1 .venv/bin/pytest hw_test/test_tcp_concurrent.py::TestTCPConcurrentBurst::test_repeated_bursts -v`
- Capture UART throughout to `/tmp/wedge-v2-d1.log`.
- During-wedge probes:
  - `ping -c 5 10.0.0.2` — does ICMP still work?
  - `nc -zv -w 1 10.0.0.2 80` — when does TCP start answering again?
  - Time the recovery interval.
- After recovery: rerun the test once. Does it pass on the second try?
- After test: try a reflash. Does `genet_init` complete or hang?

### Output
A "wedge profile" with concrete numbers:
- Wedge starts at: round __ of 10
- ICMP RTT during wedge: __ ms (vs __ ms baseline)
- TCP first answers at: __ s post-wedge-start
- Reflash post-wedge: succeeds / hangs in genet_init
- UART output during wedge: (full text)

## Phase D2 — TCP state inspection

Add a `wire.perf_query(block="tcp")` query that returns per-TCONN
state + counts. Send during the wedge. Determines:
- Is the pool full of TIME_WAITs? (load-vs-capacity)
- Are some slots stuck in unexpected states? (state-machine bug)
- Is the listener slot still LISTEN? (tcp_init wedge)

## Phase D3 — GENET register dump

Add a `wire.perf_query(block="genet")` query for GENET register
state: TX/RX ring head/tail, DMA channel CS/CONBLK_AD/NEXTCONBK,
UMAC_CMD, RBUF/TBUF status. Compare healthy vs wedged snapshots.

## Phase D4 — Boot-time GENET dump

Add a kernel-boot register dump (very early in `_start`, before
genet_init) that prints the GENET register state firmware/previous-
kernel left for us. Compare:
- After physical power-cycle (works) → genet_init succeeds
- After DTR reflash post-wedge (broken) → genet_init hangs

Identifies which bit/register isn't getting cleared by the SoC
reset path.

## Phase D5 — Targeted fix

Based on D2/D3/D4 findings.

## Findings (filled as we go)

### D1 — wedge profile (2026-04-25 ~20:50)

Run sequence: physical power-cycle → fresh kernel via chainloader → wedge tests.

**1. test_repeated_bursts in isolation: PASSES.** 10 rounds × 10 conns, 100 % success. So the test alone against a clean kernel does NOT wedge.

**2. test_repeated_bursts after the L4 prefix (test_burst_wedge.py + test_concurrent_burst_survives[5,10,15,20]): WEDGES.**
- Round 1–8: 10/10 success
- Round 9: 9/10 (first failure)
- Round 10: 0/10 (full collapse)
- Post-test liveness `_verify_l4_alive` fails

Connection count math at wedge onset:
- 50 prior TCP conns (concurrent_burst_survives 5+10+15+20)
- + 80 in repeated_bursts rounds 1–8
- = 130 — almost exactly the 128 TCONN slot pool size

**3. During the wedge, ICMP works fine.** 0 % loss, normal RTT. CPU is alive, network loop running, just no TCP listener accepting.

**4. Recovery is FAST, not 60 s.** 25 s after the test reports FAILED, port 80 answers. Every probe at +0/+10/+20/+30/.../+80 s after that point succeeds. So the wedge clears in well under 25 s — likely just as soon as the oldest TIME_WAITs reap.

**5. Implication for the test design.** The test's `_verify_l4_alive` fires only ~1 s after the burst ends. That's faster than the recovery window. The test isn't catching a kernel bug — it's measuring "did the pool drain within 1 s," which is unrealistic when 130+ conns are in flight against a 128-slot table.

### Reframe of the wedge

Earlier hypothesis (pre-D1): kernel locks up under load, possibly hardware-state corruption that needs power-cycle.

Post-D1 evidence: kernel is fine throughout. Pool drains naturally in <25 s. The "GENET doesn't init after reflash" symptom seen earlier today may have been a separate transient (possibly stale hw_send process holding the serial port; we did kill some) that we incorrectly merged into the same picture.

### What this means for D2/D3/D4

- D2 (TCP state inspection during wedge) is still useful — confirms pool occupancy and validates the count.
- D3 (GENET register dump) is **lower priority** — no evidence GENET state is bad; ICMP works during the wedge.
- D4 (boot-time GENET state on power-cycle vs DTR-reflash) is **lower priority** unless we observe the genet-init-hang again on a clean repro.

### Next step options

A. **Confirm pool theory** — D2 lite. Add a one-shot debug print that emits TCP slot counts (LISTEN / ESTABLISHED / TIME_WAIT / CLOSED) on demand, capture during the wedge. If TIME_WAIT count is at or near 127 during round 10, theory confirmed.

B. **Fix the test design** — accept that "100 conns in 5 s against a 128-slot pool" is a measurement of "does the pool drain in 1 s" and rewrite the assertion to wait long enough for natural recovery, or reduce the burst rate.

C. **Production-grade fix** — increase TCONN pool size, or shorten TIME_WAIT timer, or add per-tuple TIME_WAIT slot reuse on matching new SYN. Each has its own tradeoffs.

Likely answer is some mix: A to confirm + (B *or* C). Probably C eventually because the pool-size constraint is real for users too — anyone ab-testing or wrk-ing the server hits the same wall.

## D2 — TCP slot-state inspection (instrumentation landed)

Added `PERF_CMD_DUMP_TCP = 5` to the existing 0x88B6 query protocol.
Always-on (no PERF gate) — pure inspection of `tcp_conn_table`.

### Wire format

Reply payload (64 bytes, little-endian):
- offsets 0..36: per-state u32 counts (CLOSED/LISTEN/SYN_RCVD/ESTABLISHED/CLOSE_WAIT/LAST_ACK/FIN_WAIT_1/FIN_WAIT_2/TIME_WAIT/CLOSING) at `state * 4`
- offset 40: u32 NONCLOSED total (= occupied pool size)
- offset 44: u32 TCP_MAX_CONNS (= 128, sanity tag)
- offsets 48..56: reserved (zero)
- offset 60: u32 magic = 0xDEADBEE2

### Code shape

- `include/perf.inc` — new constants `PERF_CMD_DUMP_TCP`, `PERF_TCP_*` offsets, `PERF_TCP_MAGIC_VALUE`.
- `lib/tcp.S` — new `tcp_state_count_dump(buf)` leaf function. Walks all 128 slots once, fills the 64-byte payload. Always compiled.
- `lib/perf.S` — `perf_handle` outer body de-gated. Dispatch tree now has cmd 5 always-on; cmd 0/1 still gated on `PERF_COUNTERS`, cmd 2 on `PLATFORM_PI4`, cmd 3/4 on `PERF_L3`. Unsupported commands fall through to silent drop.
- `tests/test_tcp.S` — two new unit tests:
  - `tcp_state_count_dump_basic` — mixed-state seed, exact per-state count assertions.
  - `tcp_state_count_dump_full_timewait` — wedge shape (1 LISTEN + 127 TIME_WAIT), validates the high TIME_WAIT path.
  Both pass under `make test` (484 total unit tests passing, was 482).
- `hw_test/wire.py` — `perf_query(block="tcp")` wrapper + `_parse_perf_tcp` decoder. Dispatch table refactored to keep pylint locals/branch counts at parity.
- `hw_test/test_wedge_v2_probe.py` — opt-in probe test (`WEDGE_V2_PROBE=1` env var). Reproduces the L4 prefix workload + repeated_bursts, queries TCP slot state after every burst, writes `wedge_v2_d2.log`. Off by default — running it deliberately wedges the Pi.

### Next: capture run

Reflash with the default Pi 4 build (no PERF flavor needed — TCP dump
is always-on), then:

```
WEDGE_V2_PROBE=1 HW_TEST=1 .venv/bin/pytest \
    hw_test/test_wedge_v2_probe.py -v -s
cat wedge_v2_d2.log
```

Theory is confirmed if TIME_WAIT climbs round-over-round and reaches
~127 the round where `ok < 10`. If TIME_WAIT stays low while `closed`
also drops to zero, the wedge has a different shape (look at
ESTABLISHED + FIN_WAIT_* totals).

### D2 — capture results (2026-04-26 ~05:02 UTC)

**The TIME_WAIT theory is WRONG. The pool is filling with CLOSE_WAIT.**

```
baseline:     listen=1 closed=127  nonclosed=1/128
PREFIX n=5:   listen=1 close_wait=5   closed=122  nonclosed=6/128
PREFIX n=10:  listen=1 close_wait=15  closed=112  nonclosed=16/128
PREFIX n=15:  listen=1 close_wait=30  closed=97   nonclosed=31/128
PREFIX n=20:  listen=1 close_wait=50  closed=77   nonclosed=51/128
round 1/10:   listen=1 close_wait=60  closed=67   nonclosed=61/128   ok=10
round 2/10:   listen=1 close_wait=70  closed=57   nonclosed=71/128   ok=10
round 3/10:   listen=1 close_wait=80  closed=47   nonclosed=81/128   ok=10
round 4/10:   listen=1 close_wait=90  closed=37   nonclosed=91/128   ok=10
round 5/10:   listen=1 close_wait=100 closed=27   nonclosed=101/128  ok=10
round 6/10:   listen=1 close_wait=110 closed=17   nonclosed=111/128  ok=10
round 7/10:   listen=1 close_wait=120 closed=7    nonclosed=121/128  ok=10
round 8/10:   listen=1 close_wait=127 closed=0    nonclosed=128/128  ok=7  ← onset
round 9/10:   listen=1 close_wait=127 closed=0    nonclosed=128/128  ok=0
round 10/10:  listen=1 close_wait=127 closed=0    nonclosed=128/128  ok=0
```

Every successful HTTP request leaves a slot stuck in CLOSE_WAIT. Zero
TIME_WAIT, zero ESTABLISHED, zero FIN_WAIT_*. Stuck where? — between
`peer_FIN_received_and_ACKed` and `our_application_called_tcp_close`.

### Reframe (correct)

The peer (`_http_get` in the probe) issues a normal HTTP/1.1 GET with
no `Connection: close` and then closes its socket immediately after
collecting the response. That sends a FIN. Our TCP stack ACKs the FIN
and transitions the connection to CLOSE_WAIT.

CLOSE_WAIT → LAST_ACK requires the **application** (the HTTP server)
to invoke `tcp_close` on the connection. The HTTP server isn't doing
that. The connection can only escape CLOSE_WAIT via the idle reaper
(`TCP_IDLE_CLOSEWAIT = 60 s`, `TCP_REAPER_INTERVAL = 30 s`), which is
why D1 saw recovery in <30 s rather than the ~60 s a TIME_WAIT theory
would have predicted. The recovery interval is the reaper's tick, not
TIME_WAIT's drain.

### Implication for the proposed fixes

D1's proposed D5 (bigger pool, shorter TIME_WAIT, per-tuple reuse)
were aiming at the wrong target.

The real fix is in `lib/http.S` (and/or its FSA wiring): when a peer
half-closes a connection that's idle (no in-flight request), call
`tcp_close` so we cleanly LAST_ACK and free the slot. Currently the
HTTP layer appears to ignore the peer-FIN and waits for the next
keep-alive request that never comes.

### Next step

Investigate `lib/http.S` to find where peer-side FIN is (or isn't)
plumbed into the HTTP keep-alive lifecycle, then fix it. A repro of
the same probe should show CLOSE_WAIT counts staying near 0 round
over round once the fix lands.

## D5 — fix landed

Bug location: `lib/http.S::http_poll`, `.Lhp_not_estab`. When the TCP
state moved off ESTABLISHED (because the peer FINed), the old code
just reset the application's `HCONN_STATE` to IDLE and skipped to the
next slot. It never invoked `tcp_close`, so connections with the
peer half-closed sat in CLOSE_WAIT forever (until the 60 s reaper).

Fix: in `.Lhp_not_estab`, if TCP state is `TCPS_CLOSE_WAIT` and HCONN
is not currently `HTTPS_SENDING` (output FSA owns those), branch into
the existing `.Lhp_do_close` path. That sends our FIN, transitions the
slot CLOSE_WAIT → LAST_ACK, and on the peer's final ACK the slot
returns to CLOSED for reuse. SENDING-during-FIN is left to the next
poll iteration: once `h_keepalive` returns the HCONN to IDLE, the
same path closes it.

### Capture after fix (2026-04-26 ~05:18 UTC)

Same probe, fresh boot:

```
all 10 rounds:  listen=1 closed=127 nonclosed=1/128   ok=10 fail=0
```

Steady state. Zero CLOSE_WAIT residue. Every connection cleanly
LAST_ACK → CLOSED → reused. The pool occupancy stays at 1 (the
listener) end-to-end.

Cost: ~6 instructions in the http_poll dispatch. No new failure modes
in the QEMU unit suite (484 tests still pass).

### Closing notes

The D1 hypothesis (TIME_WAIT exhaustion) was wrong but the diagnostic
infrastructure — PERF_CMD_DUMP_TCP — was the right move. Without the
per-state slot dump we'd have continued to reason about TIME_WAIT
recovery and tuned the wrong knobs (pool size, TIME_WAIT timer).
The dump took the theory from "plausible-sounding" to "falsifiable in
60 s" and the actual bug was visible the first time we ran it.

Lesson for future debugging: when a hypothesis names a specific TCP
state, cheap-instrument the slot distribution before tuning the
behavior of that state. The same PERF_CMD_DUMP_TCP query will be
useful for any future TCONN-pool bug.


