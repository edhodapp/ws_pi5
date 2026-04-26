# Testing discipline

The project's test suite splits into three buckets by what each one needs to run. When someone says "the full test suite," it means **A + B + C**, in that order.

## Bucket A — Local (no emulator, no hardware)

Fast, runs anywhere. Pre-commit hook material.

- **Python lints**: flake8, pylint --rcfile=~/.claude/pylintrc, mypy --strict
- **Python unit tests**: `hw_test/test_*_unit.py` — exercise `link.py`, `wire.py`, `eth_frames.py`, `ip_frames.py` helpers using mocks. ~1 s.
- **PICT vector generation sanity**: run `pict tests/func/*.pict /o:max` and verify the produced .tsv files are non-empty / well-formed. Catches breakage in the test-data tool without spending a QEMU run.
- **Gemini review** (advisory): `~/tools/code-review/gemini-review.sh` on staged .py and .S files.

Total: ~30 s.

## Bucket B — QEMU (always with a clean-build wrapper)

Validates kernel logic in emulation. Each invocation must `make clean` first because Pi 4 vs raspi3b builds aren't binary-compatible.

- `make clean && make test` — unit tests on QEMU raspi3b (the asm/C unit suite — `lib/`, `include/` logic, the FSA tables, etc.)
- `make clean && make test-functional` — PICT vectors *executed* against the QEMU kernel. Vector *generation* lives in Bucket A; this bucket runs them on the kernel.
- Wrap in `scripts/qemu_tests.sh` so the rebuild discipline is mechanical.

Total: ~3 min.

## Bucket C — Hardware (Pi 4 with chainloader)

Real hardware integration. Each layer needs its own fresh flash to avoid accumulated state across phases.

Functional layers (chainloader-flashed default build):
- **L2** (`-m l2`): Ethernet/data-link integration — link, ring, malformed frames, RX errors, reachability
- **L3** (`-m l3`): IPv4, ICMP, reassembly, fragmentation, malformed IP
- **L4** (`-m l4`): TCP — handshake, data, concurrent
- **L5** (`-m l5`): HTTP — appliance, GET, concurrent, POST, error paths

Per-layer perf (each its own flash with the matching `PERF=` flavor):
- L2 perf: `make PLATFORM=pi4 PERF=recv`
- L2/L3 boundary: `make PLATFORM=pi4 PERF=dispatch`
- L3 perf: `make PLATFORM=pi4 PERF=l3`
- L4 perf (TX path): `make PLATFORM=pi4 PERF=send`

Wrap in `scripts/hw_tests.sh L2 L3 L4 L5 perf`. The script handles flashing between phases and restoring the default build at the end.

Total: ~10 min for the full pass (functional + perf).

### Perf policy: two gates, ratchet, baseline-reset escape hatch

Functional correctness is the contract; perf is the goal we keep moving toward, not a regression we ignore.

**Two gates, calibrated for what they need to catch:**

| Gate | Driver | Runs/phase | Tolerance | Purpose |
|---|---|---|---|---|
| Pre-push (loose) | `scripts/perf_push.sh` | 1 | 75 % | Catch "we did something really horrible" before a push. Don't fight host-side single-run jitter. |
| Nightly (strict) | `scripts/perf_nightly.sh` | 3 (best-of) | 50 % | The real perf bar. Best-of-3 absorbs single-run tail jitter; runs only when the laptop is actually quiet. |

**Default rule**: every perf run is compared against the all-time best for that `(flavor, burst_size, metric)` recorded in `hw_test/perf_runs.log`. A run **fails** if any metric is more than the gate's tolerance worse than the all-time best (lower `wire_pps`, higher `send_ms`/`total_ms`/`recv_ns`/etc.). A run that beats the standard automatically becomes the new bar — the standard is recomputed from history on every check, so improvements ratchet upward without manual intervention.

**Nightly cron install** (system local time — `crond` honors local TZ; the deadline aligns with sleep, not UTC):
```
crontab -e
0 0 * * * /home/ed/ws_pi5/scripts/perf_nightly.sh >> /tmp/perf_nightly.log 2>&1
```
The nightly waiter polls `/proc/loadavg` every 5 min; fires the strict perf cycle as soon as 1-min load drops below 1.5; gives up at 08:00 local if the laptop never goes idle (Ed didn't sleep that day). Log timestamps inside `perf_runs.log` stay UTC — the trigger is local-clock-aligned, the data is timezone-neutral.

**Escape hatch** for intentional perf cost:
- A planned change (a new feature, a correctness fix that costs throughput) that is expected to lower perf needs an explicit `BASELINE_RESET` marker in `perf_runs.log` along with a written rationale.
- Use `scripts/perf_set_baseline.sh <flavor> "<rationale>"` to append the marker.
- Subsequent `perf_check.py` runs ignore prior runs of that flavor — the next run sets the new floor.
- The marker is permanent in the log, paired with a UTC timestamp and the rationale; `git log -- hw_test/perf_runs.log` shows when each baseline shifted and why.

This makes the perf direction policy explicit: perf only flows downward by deliberate, documented decision.

## Driver scripts

| Bucket | Driver | Scope |
|---|---|---|
| A | (folded into pre-commit hook + `~/tools/code-review/run-python-gates.sh`) | Lints, unit, PICT-gen sanity, Gemini review |
| B | `scripts/qemu_tests.sh` | QEMU unit + functional, with `make clean` per phase |
| C | `scripts/hw_tests.sh L2 L3 L4 L5 perf` | Hardware, with reflash per phase |

### Hook installation and what fires when

Every-commit feedback should be cheap; every-push feedback should be thorough. The split:

**`.git/hooks/pre-commit`** → `.claude/hooks/commit-gates.sh` (already installed)
- Python quality gates (Bucket A lints, blocking)
- Gemini independent review (advisory)
- `make test` — QEMU unit suite (Bucket B / phase 1, blocking)
- ~30–60 s. Fires on every `git commit`.
- **Gap**: doesn't currently run `hw_test/*_unit.py` (pure-Python helper unit tests) or PICT-gen sanity. Both are cheap; folding them in is a future cleanup.

**`.git/hooks/pre-push`** → `scripts/pre-push-integration.sh` → `scripts/pre_push_tests.sh` (already installed)
- Bucket A (lints + Python unit + PICT-gen)
- Bucket B (`make test` + `make test-functional`)
- Bucket C functional (L2 L3 L4 L5)
- Bucket C perf via `scripts/perf_push.sh` (1 run, 75 % tolerance — loose gate; the strict best-of-3 / 50 % gate is the nightly cron)
- ~14 min. Fires on every `git push`. **The honest "full test suite."**

### Manual invocation

| Want to run | Command |
|---|---|
| Bucket A only | `scripts/local_tests.sh` |
| Bucket B only | `scripts/qemu_tests.sh` |
| One Bucket-C layer | `scripts/hw_tests.sh L4` |
| Multiple Bucket-C layers | `scripts/hw_tests.sh L2 L4 L5` |
| Bucket C functional only | `scripts/hw_tests.sh L2 L3 L4 L5` |
| Loose perf gate (1 run, 75 %) | `scripts/perf_push.sh` |
| Strict perf cycle (best-of-3, 50 %) on demand | `scripts/hw_tests.sh perf` |
| Strict perf cycle, wait for quiet host first | `scripts/perf_nightly.sh` |
| Full pre-commit-heavy run (A + B + C-functional, no perf) | `scripts/pre_commit_tests.sh` |
| Full pre-push run (A + B + C-functional + loose perf) | `scripts/pre_push_tests.sh` |
| Reset perf baseline (after intentional regression) | `scripts/perf_set_baseline.sh PERF=recv "rationale"` |

**Remote CI (no Pi access)** can run A + B but not C. Reserve C for local pre-push or manual runs where the Pi is attached.

## When in doubt

If someone says "run the tests" without specifying scope, ask which bucket(s). The default for "full test suite" is A + B + C in order.

This is the first Claude-collaborated project, predating the test-discipline conventions in newer projects. The discipline is being retrofit — see `debug_log_0x80000.md` and the session notes that motivated this restructuring.
