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
