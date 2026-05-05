# Test Plan

Top-down inventory of every test in this project. Read with
[`TESTING.md`](../TESTING.md), which is the gating-policy companion
(when each gate runs, perf-regression policy, ratchet rules). This
doc answers *what does each test actually exercise* — start at the
top and work down to find the right level for the question you have.

Conventions:

- **Status: active** — currently runs as part of some gate.
- **Status: planned** — designed, not yet implemented.
- **Status: superseded** — replaced by a higher-level test that
  subsumes its coverage; kept here for historical traceability.
- Test counts are point-in-time snapshots. The authoritative count
  is whatever `make test` and the hardware suite collectively report.

---

## 1. Multi-day burn-in / soak

**Status: planned.**

Long-running stability test against real hardware on a real network.
The kernel is all-static-allocation (no malloc), so the failure
modes burn-in catches are **fixed-pool exhaustion** and **state
non-release**, not byte-level leaks: TCONN slots stuck in TIME_WAIT
under rapid-connect (a known case — `test_repeated_bursts` in the
L4 suite reproduces a ~60 s wedge of this shape), VMIO ways that
didn't post-gate-dedup correctly, timer pool slots that never got
cancelled, FSAs that wedge into a stuck state and never recover,
ARP cache poisoning that compounds over hours, and lease-renewal
edge cases that only appear after T1 has fired ten times.

- **Driver:** `scripts/burn_in.sh` (planned)
- **Cadence:** weekly cron, when the host is quiet
- **Duration:** 24+ h
- **Sampled signals:** ICMP reachability every minute, the kernel's
  `/status` and `/fsa_stats` HTTP endpoints (request count, TCONN
  occupancy, VMIO ways active, timer slots in use, GENET RX
  discards, FSA engine telemetry), lease-renewal timestamps,
  kernel panic LED via UART monitor, laptop-side dnsmasq + avahi
  cache snapshots.
- **Output:** `hw_test/burn_in_runs/<YYYY-MM-DD>.md` (directory to
  be created when the suite lands) with the trend graph and any
  anomaly call-outs. The counters from `/status` are the primary
  signal — a slot pool that never returns to baseline after a load
  burst is the canonical "we didn't release something on the error
  path" finding.

This is the highest-altitude test in the suite. A green burn-in run
is the strongest evidence we have that the appliance behaves
correctly over the timescales an end user will actually deploy on.
Until it lands, this gap is the single biggest known weakness in
the verification story — the existing pre-push gate proves point
correctness but not duration.

---

## 2. DHCP-dynamics suite

**Status: planned.**

Exercises the kernel DHCP / mDNS code paths that don't fire in a
single-flash run. Each test mutates dnsmasq state mid-session and
waits for the Pi to react. Slow (multi-minute per test) and stateful
(dnsmasq config gets rewritten between tests), so this gate runs
nightly, not on every push.

- **Driver:** `scripts/dhcp_dynamics_tests.sh` (planned)
- **Cadence:** nightly cron
- **Prerequisite:** `make rig-setup` (one-time, see
  [`hw_test/TOOLS_SETUP.md` §6b](../hw_test/TOOLS_SETUP.md))
  so the test fixture can manage `dnsmasq` lifecycle without sudo.

Test inventory (planned):

- `test_short_lease_renewal_stays_at_same_ip` — 2 m lease, watch
  T1/T2 fire repeatedly, assert IP stable + no extra probe cycle.
- `test_dhcpnak_rebind_updates_mdns` — force `dhcp-host` directive
  to a different IP, restart dnsmasq, watch the rebind through the
  kernel's `mdns_kick` IP-change branch (commit `0862993`).
- `test_scope_change_assigns_from_new_range` — change the pool
  entirely (e.g. `10.0.0.50,10.0.0.60`), restart, assert Pi ends up
  in the new range.
- `test_unclean_reset_recovers` — DTR-reset mid-session, assert Pi
  comes back, gets a lease, mDNS re-announces, HTTP serving resumes.
- `test_arp_collision_does_not_brick_pi` — laptop sends gratuitous
  ARP claiming the Pi's IP from a different MAC; assert Pi's
  legitimate ARPs still get the right sender-MAC. Needs scapy
  raw-socket access (already covered by the venv-python caps in
  [`hw_test/TOOLS_SETUP.md` §6](../hw_test/TOOLS_SETUP.md); no
  per-test sudo).

Each test corresponds 1:1 to a real failure mode an end user could
hit on a consumer router with non-sticky leases.

---

## 3. Dual-config gate (static + DHCP)

**Status: active.**

Runs the full pre-push gate twice: once with the rig in static-IP
mode and once in DHCP mode. Each pass exits independently so a
flake in pass 1 doesn't mask a real failure in pass 2 (D019).

- **Driver:** `scripts/dual_config_tests.sh`
- **Cadence:** before a release tag, or any commit touching the
  config-parser / network-init / dnsmasq-side code
- **Duration:** ~50–60 min (two ~25–30 min full passes)
- **Per pass:** `NETWORK_MODE=static|dhcp NETWORK_CONF=…
  scripts/pre_push_tests.sh`
- **What it pins:** the `static_only` / `dhcp_only` pytest markers
  filter cleanly per pass; D017 DHCP failure is loud (`panic_d`),
  not silent fallback; D019 chainloader-SD UART config-push works
  the same way for both modes.

---

## 4. Pre-push gate (A + B + C + perf)

**Status: active.**

The contract every push satisfies. Bash-pipeline of the four buckets
in order (lints → QEMU → hardware → perf). Fired by the git
pre-push hook installed at `.git/hooks/pre-push`.

- **Driver:** `scripts/pre_push_tests.sh`
- **Cadence:** every `git push` (the hook is unconditional)
- **Duration:** ~25–30 min on a quiet host. This is long for a
  pre-push gate; the trade-off is deliberate (single-operator
  project, push events are infrequent, hardware coverage is
  high-value-per-run). A future split into "smoke pre-push +
  asynchronous full gate" is on the table if the cadence becomes
  painful, but `--no-verify` is not the answer.
- **Single-config default:** `NETWORK_MODE=static`,
  `NETWORK_CONF=hw_test/network-static.conf` — set by
  `pre_push_tests.sh` itself unless the caller (e.g.
  `dual_config_tests.sh`) overrides.
- **Output gate:** pre-push hook returns non-zero on any failure;
  the push is rejected.

Composition (each bucket has its own dedicated section below):

- A: `scripts/local_tests.sh` → §11 / §10
- B: `scripts/qemu_tests.sh` → §7 / §8
- C functional: `scripts/hw_tests.sh L2 L3 L4 L5` → §5
- C perf: `scripts/perf_push.sh` → §6

---

## 5. Hardware functional layers (Bucket C, default kernel build)

**Status: active.** ~180 tests across 8 L2 files, 7 L3 files, 4 L4
files, and 5 L5 files. Each layer flashes its own fresh kernel to
avoid accumulated state. Authoritative count is whatever
`scripts/hw_tests.sh L2 L3 L4 L5` reports on the day.

- **Driver:** `scripts/hw_tests.sh L2 L3 L4 L5`
- **Per-layer wrapper:** `pytest -m {l2|l3|l4|l5} hw_test/`
- **Boot expectations:** kernel prints `GENET Gigabit Ethernet
  initialized` within 150 s of flash. The 150 s budget is generous
  on purpose — the HEX upload itself takes ~70 s at 115 200 baud
  and post-upload init runs another few seconds. Real boot
  regressions (an init that takes 10 → 30 s) won't bust the budget
  and would slip past this gate; nightly perf already pins
  init-path timing where it matters.
- **Resolver:** picks up `PI4_IP` from `/tmp/dnsmasq-wspi5.leases`
  in DHCP mode or the rig default `10.0.0.2` (an end user's static
  IP can be anything `network.conf` says). 15 s post-flash ping
  retry covers the DHCP exchange + kernel init lag in DHCP mode.

### L2 — Ethernet / data-link

- `test_l2_dsb.py` — DSB barriers in `genet_recv` / `genet_send`
  against ring-boundary copies.
- `test_l2_dump_state.py` — UART dump of GENET register snapshot
  after a controlled wedge sequence.
- `test_l2_linkflap.py` — admin-down / admin-up the laptop NIC
  mid-burst; verify Pi recovers ARP / IP routing.
- `test_l2_malformed.py` — runts (14–59 B), oversize (1515–1600 B),
  bogus ethertypes (0x0000, 0x0001, 0x88cc, 0x9999, 0xFFFF, 0x8100),
  zero-payload ARP, multicast-dst, stranger-unicast-dst.
- `test_l2_reachability.py` — unicast/broadcast ARP, MAC stability
  across probes, max-frame ICMP (1472 B payload → 1514 wire), RTT
  baseline ceiling.
- `test_l2_ring.py` — burst at every interesting RX-ring boundary
  (1, 50, 255, 256, 257, 512, 1024 frames).
- `test_l2_rx_errors.py` — synthetic RX-error injection through
  `genet_rx_err` perf hooks.
- `test_l2_speed.py` — link speed advertisement and MII state.

### L3 — IPv4 / ICMP / reassembly

- `test_l3_reachability.py` — happy-path ping.
- `test_l3_icmp.py` — echo / echo-reply correctness, payload
  preservation across full MTU.
- `test_l3_icmp_errors.py` — destination-unreachable, time-exceeded
  generation paths.
- `test_l3_dst_filter.py` — drop datagrams whose destination IP
  isn't ours, broadcast, or our subnet's directed broadcast.
- `test_l3_frag.py` — IP-fragment reassembly (the `tests/func/
  reasm_func.pict` model exercised against real hardware).
- `test_l3_malformed_ip.py` — IHL > 5 (D001), bad version, bogus
  protocol numbers, truncated header.
- `test_l3_perf.py` — L3 throughput baseline.

### L4 — TCP

- `test_tcp_handshake.py` — SYN / SYN-ACK / ACK timing, options
  (WSCALE per RFC 7323, SACK-permitted per RFC 2018, timestamps
  per RFC 7323).
- `test_tcp_data.py` — bulk transfer, segment merging,
  congestion-window growth.
- `test_tcp_concurrent.py` — multiple simultaneous connections at
  the 128-conn cap.
- `test_l4_perf.py` — TX / RX throughput, retransmit timing.

### L5 — HTTP / appliance / DHCP / mDNS

- `test_http_appliance.py` — packaged static-site responses, route
  matching, slab placeholder mechanism.
- `test_http_get.py` — keep-alive, chunked encoding, HEAD-method
  body suppression, error responses.
- `test_http_concurrent.py` — pipelined requests, connection-reuse.
- `test_dhcp.py` — DHCP-acquired-IP membership in the lease pool,
  HTTP via the leased address. **Marker:** `@dhcp_only`.
- `test_mdns.py` — `avahi-resolve wspi5.local` returns the Pi's
  current IP. **Marker:** `@dhcp_only` for the resolve-matches-PI4_IP
  variant; the unknown-name negative test runs in either mode.

### Diagnostic / wedge probes / older smoke tests

- `test_burst_wedge.py`, `test_wedge_v2_probe.py` — repro-cases for
  historical hardware-wedge incidents. Status: **superseded by
  `test_l2_ring.py`** but kept as regression guards.
- `test_ping.py` — minimal ICMP smoke test from before
  `test_l3_icmp.py` existed. Status: **superseded** by the L3
  suite; kept because it's harmless and runs in seconds.

### Perf diagnostics also under L5/Bucket C

- `test_dispatch_perf.py` — dispatch-loop cost at the L2/L3
  boundary. Listed here for completeness; runs as part of the
  `perf-dispatch` flavor in §6 rather than the per-layer L2/L3/L4/L5
  functional sweep.

---

## 6. Hardware perf (Bucket C, per-flavor builds)

**Status: active.** Each flavor compiles a kernel with a different
`PERF=` knob enabled and runs the matching pytest selection.

- **Driver:** `scripts/perf_push.sh` (loose, 1 run × 75 % tolerance)
  for the pre-push gate; `scripts/perf_nightly.sh` (best-of-3 ×
  50 % tolerance) for nightly.
- **Flavors:** `PERF=recv` (L2), `PERF=dispatch` (L2/L3 boundary),
  `PERF=l3` (L3), `PERF=send` (L4 TX path).
- **Trend log:** `hw_test/perf_runs.log`, append-only. Every run's
  `BURST_STATS` and `PERF_STATS` lines are recorded; `perf_check.py`
  compares the latest against the median of the last 10 runs.
- **Policy:** see `TESTING.md`'s perf section for the gating ratchet
  + baseline-reset escape hatch.

---

## 7. QEMU functional / PICT-driven (Bucket B)

**Status: active.**

Vector-driven exhaustive coverage of state machines and parsers.
Each PICT model generates a TSV of test cases that the kernel runs
under QEMU `raspi3b`.

- **Driver:** `scripts/qemu_tests.sh` then `make test-functional`
- **Tooling:** [PICT](https://github.com/microsoft/pict) for
  combinatorial vector generation.

Models + lock-in:

- `tests/func/tcp_func.pict` → executed by `tests/test_tcp_func*.S`.
- `tests/func/reasm_func.pict` → `tests/test_reasm_func.S`.
- `tests/func/http_fsa.pict` → vectors fed to `tests/test_http.S`,
  which drives the HTTP/1.1 request-parser FSA cell-by-cell.
- `tests/func/http_output_fsa.pict` + `http_output_fsa_vectors.tsv`
  → cross-checked against the compiled kernel's transition table by
  `make verify-fsa-table` (the table-vs-ELF check pins the spec to
  the implementation by construction).
- `tests/func/dhcp_fsa.pict` + `dhcp_fsa_vectors.tsv` → similar
  cross-check via `make verify-dhcp-fsa-table`.
- `tests/func/network_conf_vectors.tsv` → drives
  `tests/test_config_parser_vectors.S`.

---

## 8. QEMU unit suite (Bucket B)

**Status: active.** ~480 tests at last count, registered in
`tests/test_main.S` (158 `bl test_*` lines and rising).

- **Driver:** `make clean && make test`
- **Runtime:** ~3 min on a quiet host
- **Target:** QEMU `raspi3b` with the test-uart wrapper
- **Output:** each test calls `test_pass` or `test_fail` with a
  string label; harness aggregates and exits non-zero on any fail.

Files (per protocol / subsystem):

| File | Subject |
|---|---|
| `tests/test_eth.S` | Ethernet frame validation, ethertype dispatch |
| `tests/test_arp.S` | ARP request/reply, sender-MAC extraction |
| `tests/test_ip.S` | IPv4 parser, IHL guard (D001), checksum |
| `tests/test_icmp.S` | Echo build, error-message generation |
| `tests/test_udp.S` | Header parse, demux to mDNS / DHCP / NTP |
| `tests/test_tcp.S` | TCP segment build, parse, FSA stubs |
| `tests/test_http.S` | HTTP/1.1 parser FSA |
| `tests/test_http_output_fsa.S` | Output FSA — every transition cell |
| `tests/test_mdns.S` | mDNS responder + state machine + IP-change kick |
| `tests/test_dhcp.S` | DHCP option parse + builders |
| `tests/test_dhcp_fsa.S` | DHCP client FSA — every transition cell |
| `tests/test_ntp.S` | NTP packet build/parse, Gregorian leap-year math used by the HTTP `Date:` header |
| `tests/test_md5.S` | MD5 (currently unused by the kernel; reserved) |
| `tests/test_timer.S` | Timer pool: set, cancel, fire, wraparound |
| `tests/test_hex_parse.S` | Intel HEX parser (chainloader payload format) |
| `tests/test_genet_rx_err.S` | GENET RX-error perf-counter wiring |
| `tests/test_config_parser*.S` | network.conf parser, vector-driven |
| `tests/test_net.S` | Top-of-stack glue (recv-one dispatch) |
| `tests/test_store.S` | TCP send-buffer ring |
| `tests/test_vmio_engine.S` `_queue.S` | VMIO send-path FSA + queue |
| `tests/test_example.S` | Smoke / template, kept as a reference |

`tests/test_func_main.S`, `tests/test_tcp_func.S`,
`tests/test_tcp_func_hand.S`, and `tests/test_reasm_func.S` belong
to §7 (the PICT-driven functional suite) and run via `make
test-functional`, not `make test`.

---

## 9. Fuzz suites

**Status: active.**

LibFuzzer-style harnesses against the protocol stack. Seeds in
`fuzz/corpus/` (single-packet) and `fuzz/corpus_seq/` (multi-packet
TCP sequences).

- **Build:** `make fuzz` (single-packet), `make fuzz-seq`
  (multi-packet).
- **Corpus generation:** `make fuzz-corpus`, `make fuzz-corpus-seq`.
- **Single-packet seeds (`fuzz/gen_corpus.py`):** 23 entries —
  every L2/L3/L4 ethertype + protocol combination, malformed
  variants.
- **Multi-packet seeds (`fuzz/gen_corpus_seq.py`):** 16 entries —
  full TCP scenarios (handshake, OOO merge, simultaneous close,
  duplicate SYN flood, timestamp negotiation, bad-sequence reject).
- **`http_poll` integration** runs alongside the protocol fuzz so
  application-layer crashes are caught.

These run under address-sanitized builds during fuzz cycles, not in
the pre-push gate.

---

## 10. Python unit tests (Bucket A)

**Status: active.**

- **Driver:** `pytest scripts/test_*.py hw_test/test_*_unit.py`
- **Runtime:** ~1 s collectively
- **No hardware, no QEMU.** Pure Python with mocks.

| File | Subject |
|---|---|
| `scripts/test_intel_hex.py` | Intel HEX builder (34 tests, **100 % mutation score** under mutmut) |
| `scripts/test_hw_send.py` | DTR reset, termios deadline, kill-stale, `--network-conf` arg parsing |
| `scripts/test_lint_network_conf.py` | network.conf linter |
| `scripts/test_lint_dhcp_fsa_vectors.py` | DHCP FSA TSV format/shape lint |
| `scripts/test_mk_appliance.py` | Appliance-image packager |
| `scripts/test_d010_regression.py` | D010 always-via-gateway routing regression guard |
| `scripts/test_adapter.py` | hw_send.py port adapter abstraction |
| `hw_test/test_link_unit.py` | netlink helpers in `link.py` (link up/down, MTU, MAC, ring resize) |
| `hw_test/test_wire_unit.py` | `RawL2Socket`, `WireCapture`, frame send + pcap parse helpers in `wire.py` |
| `hw_test/test_eth_frames_unit.py` | Frame builders in `eth_frames.py` |
| `hw_test/test_ip_frames_unit.py` | IP-level frame builders |

---

## 11. Static analysis (Bucket A)

**Status: active.** Blocks any commit that fails.

- **Driver:** `~/tools/code-review/run-python-gates.sh`, fired
  pre-commit by `~/tools/code-review/pre-commit-hook.sh` and by the
  Claude Code commit hook. **Operator-specific path** — these
  scripts live outside the repo, in the operator's `~/tools/`
  shared across sibling projects (per `~/PRODUCTS.md`). A new
  operator either installs `~/tools/code-review/` from its own
  repo or adapts the hook to call equivalent commands. The
  contract (flake8, pylint, mypy, pytest with branch coverage) is
  what's binding; the script wrapper is convenience.
- **Tools:**
  - `flake8` — line length (79), basic style.
  - `pylint --rcfile=~/.claude/pylintrc` — Google Python Style Guide.
  - `mypy --strict` (with `mypy.ini` excludes for test files using
    pytest fixtures).
  - `pytest --cov --cov-branch` — Python branch coverage.
- **Files in scope:** every `.py` file the linter knows about; the
  excludes list is in `mypy.ini`.

---

## 12. Pre-commit / pre-push hook chain

**Status: active.** Not tests themselves; the orchestration that
runs them. The pre-commit pieces sit outside the repo in the
operator's `~/tools/` and apply across sibling projects — see §11
on operator-specific paths and how to substitute equivalents.

- **Pre-commit (`~/tools/code-review/pre-commit-hook.sh`):**
  - Quality gates (§11) — blocking.
  - Gemini independent review (advisory) — runs against staged .py
    and .S files via `~/tools/code-review/gemini-review.sh`. Has a
    per-invocation timeout because Gemini silently hangs on rate /
    token limits in heavy-use sessions.
- **Pre-commit (Claude Code session):** spawned subagent reviews
  staged code with no project context, comparing against
  `~/tools/code-review/review-prompt.txt`. Findings addressed
  before the commit lands.
- **Pre-push (`.git/hooks/pre-push`):** invokes
  `scripts/pre_push_tests.sh` (§4). Push rejected on non-zero exit.

---

## Coverage cross-references

These docs are coverage targets for specific RFCs / specs and live
alongside (not inside) the test inventory:

- [`l3_rfc1122_compliance.md`](l3_rfc1122_compliance.md) — IP/ICMP
- [`l4_rfc1122_compliance.md`](l4_rfc1122_compliance.md) — TCP
  (RFC 9293, 7323, 5681, 5961 — all 8 audit defects closed)
- [`PANIC_PATTERNS.md`](PANIC_PATTERNS.md) — Morse panic LED
  catalogue; tests assert against these patterns where applicable.

## Decision provenance

Most test files include a D-number reference in their prologue or
commit history pointing at the design decision in
[`DECISIONS.md`](DECISIONS.md) that motivated them. Cite by
D-number when adding new tests or removing existing ones; the log
is append-only by convention so the trail back to "why does this
test exist" is permanent.
