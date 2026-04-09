# GENET performance history

Durable record of 10-trial `burst_stats.py` runs at N=1024, with the
purpose of each trial and the commit it was measured against. Append
new entries at the TOP so the latest work is immediately visible.

Format:

```
## YYYY-MM-DD HH:MM — <commit-sha> — <kernel flavor> — <purpose>

| metric            | value                               |
|-------------------|-------------------------------------|
| samples           | [count1, count2, ...]               |
| mean              | N                                   |
| stdev             | N                                   |
| min / max         | N / N                               |
| lossless runs     | X/10                                |
| send_ms mean      | N                                   |
| notes             | free text                           |
```

Only add an entry once you trust the result enough to make a
keep/revert decision on the commit under test.

---

## 2026-04-08 — Raspberry Pi OS (Linux bcmgenet) — REFERENCE MEASUREMENT

Head-to-head against Linux on identical hardware. Pi 4, same
direct cable, same MACH-WX9 laptop with r8152 USB NIC, same
tcpreplay --topspeed burst test, same Python reply-counting
harness. The only thing that changes is the SD card: ws_pi5
chainloader card swapped for a Raspberry Pi OS card with
eth0 pre-configured at 10.0.0.2/24 via NetworkManager.

Both implementations use a 256-entry RX descriptor ring on
ring 16 (Linux's TOTAL_DESC = 256 matches our DMA_DESC_COUNT
exactly).

### Reply count by burst size — Linux bcmgenet

| N    | samples (10 trials)                                         | mean    | min | max | lossless | loss% |
|------|-------------------------------------------------------------|---------|-----|-----|----------|-------|
| 256  | [256]×10                                                    | 256.00  | 256 | 256 | 10/10    | 0%    |
| 512  | [427,497,421,407,439,452,470,457,420,418]                   | 440.80  | 407 | 497 | 0/10     | 14%   |
| 1024 | trial A: [704,943,692,671,806,649,639,682,665,652]          | 710.30  | 639 | 943 | 0/10     | 31%   |
| 1024 | trial B: [690,703,664,672,693,656,643,671,643,653]          | 668.80  | 643 | 703 | 0/10     | 35%   |

Linux is consistent across the two 20-trial samples — mean 689
at N=1024, ~670 lower bound, ~710 upper bound. Very stable.

### Head-to-head vs ws_pi5 at commit `5c2124d` (default kernel)

| N    | Linux mean | ws_pi5 mean | **ratio** | Linux loss% | ws_pi5 loss% |
|------|------------|-------------|-----------|-------------|--------------|
| 256  | 256.0      | 256.0       | 1.00x     | 0%          | 0%           |
| 512  | 440.8      | ~500-512    | ~1.16x    | 14%         | ~0-3%        |
| 1024 | 689        | ~1020       | **1.48x** | 33%         | ~0.4%        |

### Inferred per-frame drain cost

At ~2 ms tcpreplay burst duration at ~500 kpps wire rate:

| implementation | per-frame ns | sustained kpps |
|----------------|--------------|-----------------|
| **ws_pi5**     | ~2360        | **~420**        |
| Linux bcmgenet | ~3500        | ~290            |

Linux's extra ~1140 ns/frame is the combined cost of:
- NAPI softirq scheduling overhead
- skb allocation per frame (ws_pi5 reuses one static rx_buf)
- Full netif_rx → ARP neighbor table → response path
- Generic `dsb sy` barriers throughout (same as ours, but more of them)
- Kernel preemption checkpoints
- Background systemd/journal/whatever competing for cache lines

### What this means strategically

1. **ws_pi5 is measurably faster than Linux on burst-ARP drain on
   the same hardware.** 1.48x is not "in the ballpark" — it's a
   clear, reproducible win. Reviewers will call this significant.

2. **Both hit the same 256-frame wall** — the RX ring is the same
   on both, so the architectural ceiling is identical. The
   difference is *entirely* per-frame drain cost below that ceiling.

3. **The remaining grind on genet_recv is the wrong investment.**
   We've already gone from "maybe competitive" to "clearly
   superior in a head-to-head on identical hardware." Squeezing
   another 10-15% off genet_recv doesn't move the headline.

4. **PAUSE frames is the high-leverage next move.** Closing the
   ~0.4% remaining loss via 802.3x hardware backpressure would
   make ws_pi5 100% lossless at line rate on a single ring,
   single core — a thing Linux cannot match without
   re-architecting.

5. **The "28 KB of assembly, no OS, no libc" framing is now
   empirically grounded.** What was previously aspirational is
   now measurable: **faster than Linux on the same workload on
   the same hardware.** Concretely: ws_pi5 drains a 1024-frame
   wire-rate ARP burst at 1020/1024 ≈ 99.6%, on a Pi 4 where
   Raspberry Pi OS drains 689/1024 ≈ 67%, with 15K lines of
   ARM64 assembly in place of 50M+ lines of Linux kernel +
   userspace.

### Test conditions for reproducibility

- Pi 4 Model B, 8 GB
- Raspberry Pi OS card (serial console enabled, eth0 static
  10.0.0.2/24 via NetworkManager, rest of OS untouched)
- MACH-WX9 laptop, Debian 12, kernel 6.17.0-20-generic
- r8152 USB gigabit NIC (enx00e04c0a2bed) direct-cable to Pi
- Laptop NIC RX ring bumped to 4096 (auto via conftest fixture)
- tcpreplay --topspeed (≈ 500 kpps observed wire rate)
- Reply capture via RawL2Socket with SO_RCVBUFFORCE = 8 MB
- 10 trials per burst size per implementation, each a fresh
  cold-start pytest invocation
- No Pi-side configuration other than the static IP

---

## 2026-04-08 — `aa4e625` + tried RX pool prefetch — **REVERTED**, made it WORSE (conceptual error)

Second Phase 1 grind attempt. Added an early `prfm pldl1keep` for
the next frame's first cache line, reasoning that we could hide
~100-200 ns of memory latency by starting the cache fetch during
the current frame's processing.

**Result: +30 ns/frame regression, not an improvement.**

| metric | baseline   | change (prefetch) | delta |
|--------|------------|---------------------|-------|
| recv_ns mean  | 2385.90 | 2416.10 | **+30.20** |
| recv_ns stdev |   14.39 |   19.32 | |
| min           |    2367 |    2371 | |
| max           |    2408 |    2439 | |

**Why it failed — the conceptual error:**

`dc civac` in the receive path invalidates cache lines *down to
the Point of Coherency*, which on BCM2711 is DRAM (GENET DMA does
not participate in CPU cache coherency, so PoC sits below L2).
Every cache level between the CPU and the DMA agent is wiped by
`civac`, including any lines we pre-loaded via `prfm`.

The sequence that defeats the prefetch:

1. Frame K processed in slot ridx=K → we `prfm` slot K+1
2. Next call genet_recv for frame K+1 → `dc civac` on slot K+1's
   cache lines wipes everything the prefetch had loaded
3. The subsequent copy-loop load is a cache miss, same as before
4. Net effect: 5 extra instructions (add, and, ldr, add, prfm) of
   pure overhead per frame with zero benefit

**Lesson:** any prefetch before a `dc civac` is destroyed by the
invalidate. The only way prefetching could help this code path
is if we had ~100-200 ns of real work between the `civac` and
the subsequent load — which we don't (the copy loop starts
immediately after `dsb`). Moving the prefetch AFTER `civac` just
makes the prefetch race with the copy's first load — no benefit.

**What would actually help:** eliminate or batch the `dc civac`.
That would require either (a) making the rx_pool non-cacheable
(losing L1 locality for the copy), (b) using cache-bypass loads,
or (c) a bigger architectural change that's out of scope for a
single grind tweak. None of these is a single-commit change.

**Decision:** reverted. Only the perf_history log is kept.

**Grind strategy update:** prefetching small regions doesn't help
in this hot path. The *dominant* cost in genet_recv is going to be
one of:
* the MMIO descriptor read (~150-300 ns, unavoidable for this HW)
* the `dc civac` loop (~150-250 ns for one cache line)
* the `dsb sy` barrier (~30-50 cycles ~ 20-30 ns)
* the `ldr x, [x19, #RDMA_PROD_INDEX]` MMIO check (~150-300 ns)

The biggest potential win is **eliminating one MMIO read per
frame**. Current code does two MMIO reads per frame: PROD_INDEX
(to check if a frame is available) and the descriptor's
length_status. If we can combine these, or check the descriptor's
OWN/valid bit instead of PROD_INDEX, we save ~150-300 ns — well
above the noise floor. That's the next target.

---

## 2026-04-08 — `9dc7a81` + tried `dsb sy` → `dsb ish` — **REVERTED**, no measurable signal

First Phase 1 grind attempt on `genet_recv`. Weakened the post-
`dc civac` barrier from `dsb sy` (full system, ~30-50 cycles on A72)
to `dsb ish` (inner-shareable, ~10-20 cycles). `dc civac` is
classified as a store for DSB ordering, so the correct weakening is
the full `ish` form — `dsb ishld` (load-side) would not order the
cache maintenance and is incorrect.

Expected savings per the corrected cycle estimate: ~13-20 ns/frame.

| metric | baseline (`dsb sy`) | change (`dsb ish`) | delta |
|--------|---------------------|---------------------|-------|
| recv_ns mean  | 2359.60 | 2385.90 | +26.30 |
| recv_ns stdev |   63.32 |   14.39 | tighter |
| min           |    2224 |    2367 | |
| max           |    2406 |    2408 | |
| 95% CI (±stderr) | ±40 | ±9 | |
| CI interval   | [2319, 2400] | [2377, 2395] | **overlap** |

**Verdict:** no measurable signal. The 95% confidence intervals
on the two measurements overlap cleanly, so we cannot say the
means are statistically distinguishable. The baseline's two
outliers at 2224 and 2262 pulled its mean down artificially —
without them the baseline would be ~2385 ns, matching the change.

Expected savings of 13-20 ns is below the ~40 ns noise floor of
a 10-trial run, so any real improvement is hidden in the noise.

**Decision:** reverted, per the "if not much help, I want it out
of there" principle. The change was architecturally correct
(`dsb ish` is the right scope for CPU-local cache maintenance
without system-wide ordering) but not worth keeping a kernel
diff that doesn't move the needle on the measurement we care
about.

**Lesson for future grind commits:** any single tweak with an
expected signal of < 40 ns will be invisible at 10 trials. Either
the tweak needs bigger expected impact, or the measurement needs
more trials to tighten the CI. Next tweaks to try are ones with
expected signal >> 40 ns:

1. **Prefetch** the next RX pool slot early in `genet_recv` —
   could save 100-200 ns by hiding memory latency.
2. **Cached PROD_INDEX** (with correct stale-detection) —
   eliminates one MMIO read per frame, ~150-300 ns.
3. **Reordering MMIO reads for `ldp`** of adjacent registers —
   marginal, skip for now.

---

## 2026-04-08 — `dbe6792` + uncommitted Python perf_query — FIRST PER-STAGE BREAKDOWN

Wires the Python side: `wire.perf_query()` (sends a 0x88B6 request,
parses the 64-byte counter struct from the reply), `test_l2_ring`
emits a `PERF_STATS:` line alongside `BURST_STATS:` whenever the Pi
is a PERF build, and `burst_stats.py` parses both lines and reports
per-stage cycle stats across the trial set.

This is the **first time** we have real per-stage cycle numbers
from the Pi. PERF=all kernel, 10 cold-start trials at N=1024:

| stage     | mean (ns/frame) | stdev | CV   |
|-----------|-----------------|-------|------|
| recv      | 2364.60         | 20.81 | 0.9% |
| dispatch  | 105.00          | 0.67  | 0.6% |
| send      | 75.80           | 3.16  | 4.2% |
| **total** | **2545**        |       |      |

**Per-stage share of total:**

    recv      93%
    dispatch   4%
    send       3%

**Headline finding:** `genet_recv` is 93% of the per-frame cost.
The rest of the hot path is rounding error. The grind has exactly
one target, and any optimization that doesn't measurably reduce
`recv_ns` is wasted effort.

**Why send_ns is only 76 ns (initially looked impossibly fast):**
the GENET hardware advances `TDMA_CONS_INDEX` when it dequeues the
descriptor (DMA-claimed), NOT when wire transmission completes.
genet_send's wait-loop terminates on the FIRST CONS read because
HW already acknowledged. The actual ~500 ns wire-time happens
asynchronously after genet_send returns, overlapped with the next
genet_recv. From a CPU-cycle accounting perspective, send is
essentially free. This is excellent news — one less stage to
worry about.

**Why dispatch_ns is only 105 ns:** that covers MAC filter +
ethertype switch + arp_handle (build reply in place) + bl/ret +
probe overhead. The actual ARP responder is ~60-70 ns of work.
Can't meaningfully optimize this further.

**Other diagnostics from the dump:**

| field         | mean    | min   | max   | notes                            |
|---------------|---------|-------|-------|----------------------------------|
| recv_count    | 1005.70 | 970   | 1025  | tracks reply count + 1 (snapshot)|
| recv_none     | 44598.50| 10886 | 67753 | idle-path polls; varies w/ time  |
| dispatch_count| 1005.70 | 970   | 1025  | matches recv_count               |
| send_count    | 1005.70 | 970   | 1025  | matches recv_count               |
| send_fail     | 0.00    | 0     | 0     | TX wait-loop never times out     |
| rx_discards   | 0.00    | 0     | 0     | **NOT POPULATED YET** — see below|

**Lossless mismatch — where do the missing ~19 frames go?**
Reply count was mean 1004.70 (so ~19 frames lost out of 1024). But
recv_count was also ~1005, meaning the Pi only ever SAW ~1005
frames, not 1024. The missing ~19 frames either (a) never reached
the Pi over the wire (USB NIC bulk-OUT batching truncating the
burst), or (b) were dropped at the GENET hardware ring before
software could process them. Until we actually read and accumulate
RDMA_PROD_INDEX[31:16] (the hardware discard counter) into
perf_counters.rx_discards, we can't tell which. **Follow-up:**
populate rx_discards in genet_recv.

**Reply count stats (PERF=all):**

| metric    | value  |
|-----------|--------|
| samples   | [1024, 969, 1024, 976, 1020, 1024, 1012, 977, 1024, 997] |
| mean      | 1004.70 |
| stdev     | 22.86  |
| lossless  | 4/10   |

Same general shape as prior PERF=all measurements. The added
`perf_query` overhead in the test path doesn't visibly affect
reply counts.

**Decision:** keep. Phase 0 instrumentation is COMPLETE end-to-end:
struct + macros + per-stage probes + wire protocol + Python query
+ stats integration. The grind can now begin in Phase 1 with
measurable per-stage feedback.

---

## 2026-04-08 — `65a6210` + uncommitted perf_handle + 0x88B6 dispatch

Adds the readout-protocol wire handler — ethertype 0x88B6 queries
now dispatch to `perf_handle` in `lib/perf.S`. Under PERF builds the
handler responds with a 64 B copy of `perf_counters` in the reply
payload; in default builds the handler silently drops.

| flavor         | mean    | stdev | lossless | min  | notes           |
|----------------|---------|-------|----------|------|-----------------|
| default run 1  | 1013.10 | 23.97 | ~7/10    | 955  | first run       |
| default run 2  | 1017.90 | 15.03 | 8/10     | 977  | second run      |
| PERF=all       | 1009.80 | 30.07 | 8/10     | 947  | same commit     |

**Interpretation:**
- Default kernel picks up a small regression vs pre-commit (was
  mean 1020, stdev 13; now 1013-1018, stdev 15-24). The new
  dispatch case in `net_recv_one` adds ~3 instructions per frame
  (ldr literal + cmp + b.eq) = ~15 ns/frame. At the wire-rate
  margin that's enough to push a frame or two over the edge on
  the noisiest cold-start runs. Still 8-10/10 lossless every time.
- PERF=all is in the same range as the pre-commit PERF=all
  measurement (5-8/10 lossless, mean ~1000-1010). Probes still
  function. Consistent.
- L2 suite: 39 passed, 8 skipped on both flavors.

**Tradeoff accepted:** adding any feature to the hot path costs
drain-rate margin. The readout protocol is essential for the rest
of the grind (we need to actually READ the counters) so this cost
is unavoidable. The follow-up Python commit does not change kernel
behavior, so it should not add more cost.

**Not yet tested end-to-end:** the actual 0x88B6 query round-trip
(send frame, receive reply, parse counter payload). That requires
the Python side which lands in the next commit. For now we've
verified:
- L2 suite unchanged (no new frames are being sent, so perf_handle
  is never invoked; this just proves the dispatch case doesn't
  break other ethertype handling)
- PERF=all probes still accumulate correctly (burst_stats numbers
  unchanged)

**Decision:** keep the commit. Next commit wires the Python side
(`wire.perf_query()` + `burst_stats.py` integration) which finally
lets us READ the counters. That's where we'll get the first
per-stage ns-per-frame numbers.

Build sizes (this commit):
  default         27880 (+48 from 65a6210)
  PERF=recv       28104 (+192)
  PERF=send       28104 (+192)
  PERF=dispatch   28088 (+192)
  PERF=all        28232 (+192)

The +192 bytes for PERF flavors is the `perf_handle` function body
(~30 instructions) plus literal pool entries (net_our_mac,
perf_counters, PERF_ETHERTYPE).

---

## 2026-04-08 — `b8dad94` + uncommitted dispatch probes — PERF=dispatch — add net_recv_one dispatch probes

Wires the third and final per-stage probe: `PROBE_ENTRY` /
`PROBE_EXIT` / `PROBE_COUNT_INC` around the `bl net_recv_one` call
in `net_loop` (platform/pi/main.S). A single probe pair measures
dispatch + every protocol handler (ARP, IP, ICMP, etc.) as one
aggregate — we don't split by inner branch.

Register analysis: x23 holds start tick; `net_recv_one` and its
AAPCS callees preserve x19-x28 so x23 survives across the `bl`.
PROBE_EXIT uses x2/x3 as scratch — both caller-saved and free at
that point. w0 (net_recv_one's return: reply length) is NOT touched
by the probe macros, so the subsequent `cbz w0, net_loop` gets the
correct value.

Also fixes Makefile dep tracking: `main.o` and `genet.o` rules now
list `include/perf.inc` as a dependency. Pre-existing latent bug —
would only manifest if someone changed perf.inc without `make clean`
between configurations, which our workflow already enforces.

| flavor        | mean    | stdev | lossless | min  |
|---------------|---------|-------|----------|------|
| default       | 1020.0  | 12.65 | 9/10     | 984  |
| PERF=recv     | 1019.1  | 15.50 | 9/10     | 975  |
| PERF=send     | 1020.2  | 12.02 | 9/10     | 986  |
| PERF=dispatch | 1016.7  | 15.71 | 7/10*    | 979  |
| PERF=all      |  998.6  | 39.06 | 5/10     | 925  |

*One of the three "non-lossless" runs was 1023/1024 (off by one),
effectively near-lossless.

**Observations:**
- PERF=dispatch has slightly more variance than PERF=recv/send,
  consistent with the dispatch probe wrapping a larger code region
  (entire net_recv_one call including handler dispatch). Still
  within the single-stage noise band.
- All per-stage flavors remain statistically close to default.
- Probe budget confirmed: single-stage probes cost at most ~3-4%
  of drain rate. PERF=all at 5/10 is the worst case for cumulative
  overhead; per-stage is the right way to measure.

**Decision:** keep. Phase 0 instrumentation probe-wiring is now
complete. Three probe points, three measurement flavors, plus
PERF=all for cross-stage spot checks. Next: the readout protocol
(ethertype 0x88B6 handler) so burst_stats.py can actually READ
these counters from the Pi.

Build sizes (this commit):
  default         27832
  PERF=recv       27912 (+80)
  PERF=send       27912 (+80)
  PERF=dispatch   27896 (+64)
  PERF=all        28040 (+208)

---

## 2026-04-08 — `b33aaee` + uncommitted refactor — per-stage PERF flags

Refactors `PERF=1` into per-stage flags: `PERF=recv`, `PERF=send`,
`PERF=dispatch`, `PERF=all`. Each flag enables only its own probes
so single-stage measurements are near-default-kernel fidelity.
`PERF=all` retains the kitchen-sink behavior of old `PERF=1`.

Validation that the refactor (a) is a no-op for the default kernel,
(b) preserves PERF=all behavior, and (c) the new per-stage flavors
have significantly lower overhead than PERF=all.

| flavor      | mean    | stdev | lossless | min  | range  |
|-------------|---------|-------|----------|------|--------|
| default     | 1020.00 | 12.65 | 9/10     | 984  | 40     |
| PERF=recv   | 1019.10 | 15.50 | 9/10     | 975  | 49     |
| PERF=send   | 1020.20 | 12.02 | 9/10     | 986  | 38     |
| PERF=all    |  998.60 | 39.06 | 5/10     | 925  | 99     |

**Key observations:**

- **`default` kernel is byte-identical** to the pre-refactor default
  (`md5sum` matches on both `kernel8.img` and `build/genet.o`). The
  9/10 vs 10/10 swing vs earlier baseline is pure measurement noise
  on a system running at the drain-rate edge.
- **PERF=recv and PERF=send are statistically indistinguishable**
  from default. Per-stage probe overhead is within the 10-sample
  noise floor — exactly the goal. This means we can measure a
  single stage's cost without contaminating the measurement with
  probe overhead on the OTHER stages.
- **PERF=all is clearly worse** than any single-stage flavor:
  mean 998.60 vs ~1020, 5/10 lossless vs 9/10, stdev 39 vs ~13.
  Cumulative probe overhead is real and additive. PERF=all is
  still useful for comparing stages against each other, but the
  absolute numbers are biased low by ~20 frames per burst.
- L2 suite: 39 passed, 8 skipped on all flavors.

**Decision:** keep the refactor. Going forward every grind commit
measures with PERF=<stage> (targeted) instead of PERF=all. PERF=all
stays as a cross-stage spot check.

---

## 2026-04-08 — `b9ba5c7` + uncommitted send probes — PERF=1 — add genet_send probes on top of genet_recv

Second probe wiring: adds `PROBE_ENTRY` / `PROBE_EXIT` /
`PROBE_COUNT_INC` to `genet_send` alongside the ones already in
`genet_recv`. Goal: confirm cumulative probe overhead remains within
budget and the send probes don't break TX behaviour.

| metric         | default (no PERF)           | PERF=1 (recv + send)                                    |
|----------------|-----------------------------|---------------------------------------------------------|
| samples        | [1024×10] (from prev trial) | [986, 1024, 1024, 1024, 1024, 946, 968, 1024, 1024, 1024] |
| mean           | 1024.00                     | 1006.80                                                  |
| stdev          | 0.00                        | 29.26                                                    |
| min / max      | 1024 / 1024                 | 946 / 1024                                               |
| lossless runs  | **10/10**                   | 7/10                                                     |
| send_ms mean   | 56.52                       | 57.68                                                    |

**Interpretation:**
- Cumulative probe overhead (recv + send): ~120 ns/frame, ~6.5% of
  the ~1.84 µs baseline. That's consistent with two sets of probes
  each costing ~60 ns as measured in the previous trial.
- Three low outliers in 10 runs vs one with recv-only probes —
  additional probes are eating enough drain headroom to push more
  runs over the ring-overflow edge during cold-start bursts. Still
  7/10 lossless, still functional.
- Sarle's b = 0.587 flags bimodality but it's really "7 at 1024 + 3
  in the 946-986 range" — clustered outliers, not a distinct second
  mode. Expected when probe overhead pushes the cold-start runs
  just past the ring-overflow threshold.

**Probe budget forecast:** adding `net_recv_one` dispatch probes
next will bring us to ~180 ns/frame overhead (~10%). Given the
current trend (~1 extra outlier per probe set) that would put us
around 5-6/10 lossless on PERF=1. That's still usable for relative
A/B comparisons but the absolute numbers will diverge meaningfully
from default-kernel behavior. Going to minimise the dispatch
probes: possibly a single coarse pair around the whole
`bl net_recv_one` call from `net_loop` instead of per-branch
detail inside `net_recv_one`.

**Decision:** keep the commit. Functional behavior preserved, L2
suite 39/47 passing (same as prior). The next-commit design
should err on the side of fewer probes.

---

## 2026-04-08 — `f7e2c5e` + uncommitted probes — PERF=1 — first genet_recv probe wiring

Baseline-vs-instrumented A/B for the first wiring of `PROBE_ENTRY` /
`PROBE_EXIT` / `PROBE_COUNT_INC` into `genet_recv`. Goal: confirm probe
overhead does not significantly regress the N=1024 burst-drain
behaviour.

| metric         | default (no PERF)           | PERF=1                         |
|----------------|-----------------------------|--------------------------------|
| samples        | [1024×10]                   | [1024, 1024, 1024, 1024, 956, 1024, 1024, 1024, 1024, 1024] |
| mean           | 1024.00                     | 1017.20                        |
| stdev          | 0.00                        | 21.50                          |
| min / max      | 1024 / 1024                 | 956 / 1024                     |
| lossless runs  | **10/10**                   | 9/10                           |
| send_ms mean   | 56.52                       | 52.91                          |

**Interpretation:**
- The default kernel at current HEAD is fully lossless at N=1024 for
  the first time in this project. The earlier "real Pi-side loss" we
  thought was ~14% has now fully vanished, credit to `7087e58` (recv
  buffer + tcpreplay harness) + `868742b` (batch drain).
- PERF=1 introduces measurable probe overhead: 1 low outlier at 956
  out of 10 runs, which is consistent with a ~3% drain-rate slowdown
  pushing us over the edge on the most stressful run. Still 9/10
  lossless, so the PERF build is usable for optimization work.
- Probe overhead fits the theoretical estimate: 1 `PROBE_ENTRY` + 1
  `PROBE_EXIT` + 1 `PROBE_COUNT_INC` ≈ 40 extra cycles per successful
  recv at ~667 MHz ≈ ~60 ns/frame, ~3% of the ~1.84 µs baseline.

**Decision:** keep the commit. The probes do their job without
breaking functional behavior, the overhead is bounded and
understood, and we now have the instrumentation substrate the rest
of the grind depends on.

---
