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


