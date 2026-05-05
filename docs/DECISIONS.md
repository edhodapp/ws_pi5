# Design Decisions

Every deliberate deviation from a specification, standard practice, or
RFC requirement is recorded here. So is every architectural decision
whose rationale is non-obvious from the code alone.

## Conventions

- **Numbering is sequential and never renumbered.** `D001, D002, …`
  Entries appear in creation order. Once a D-number is assigned, it
  is permanent — even if the decision is later superseded.

- **Entry content is immutable.** Once written, the decision text and
  rationale are never edited or deleted. The one permitted addition
  is the supersession annotation described below.

- **Supersession is bidirectional** so traceability works in either
  direction without scanning the whole log:
  1. The new entry opens with a back-pointer:
     `**Supersedes:** D003 (deprecated YYYY-MM-DD HH:MM UTC). [reason]`
  2. The superseded entry gets an append-only annotation prepended:
     `**DEPRECATED YYYY-MM-DD HH:MM UTC — superseded by D00N.** [reason]`
     with the original body intact below it.

- Chained supersessions (D003 → D00N → D00M) annotate each link so a
  reader landing on any entry finds the predecessor or successor in
  one step.

- Timestamps include UTC time when same-day ordering matters.

This format is shared with sibling projects in `~/PRODUCTS.md`. See
`~/.claude/CLAUDE.md` for the canonical convention statement.

---

## D001 — IP options not supported (RFC 1122 §3.2.1.8)

**Decision:** Drop all IP datagrams with IHL > 5 (options present).

**Rationale:** Single-host bare-metal web server on a direct cable.
No forwarding, no source routing, no record route. Packets with
options are dropped safely (not misinterpreted). Zero attack surface
from option parsing bugs.

**Revisit if:** Source routing or record route needed for diagnostics.

**Date:** 2026-04-09

---

## D002 — ICMP Time Exceeded for reassembly timeout

**History:**
- 2026-04-11: Deferred — "diagnostic value only for a host on a
  direct cable where fragmentation shouldn't happen."
- 2026-04-12: Reversed — implement it. This is a MUST requirement
  and we'd already considered it twice. The flip-flop itself proved
  the decision wasn't being tracked properly, motivating this
  DECISIONS.md file.

**Decision:** Implement ICMP Time Exceeded (type 11, code 1) when a
reassembly slot times out.

**Date:** 2026-04-12

---

**Note on D003–D015:** the decisions D003–D013 and D015 were made
across the network-config redesign sessions of 2026-04-27 and
2026-04-28; D014's test-plan content was drafted 2026-04-29 and is
dated accordingly. They are formally logged together for ease of
reading. Earlier informal numbering used during the redesign session
(D1–D13 in chat / task descriptions) does NOT correspond to the
D-numbers below — the new numbers are creation-order in this log.

---

## D003 — network.conf as the user-facing config file

**Decision:** A text file `network.conf` at the FAT root of the SD
card carries the network configuration for the appliance. Format:
- Magic sentinel as the first line: `# WSPI5CFG\n`
- `key=value` lines, one per setting
- `#` introduces a comment to end-of-line
- Required keys: `ip`, `netmask`, `gateway`, `hostname`
- Optional keys: `ntp_server`, `mac`
- IPs are dotted-decimal (`10.0.0.2`)
- Netmask is dotted-decimal (`255.255.255.0`), not CIDR
- Hostname per D006

**Rationale:** Non-developer users edit a single text file from any
laptop with a text editor and a card reader. The magic sentinel
catches "user pasted random text into the wrong file" failures
loudly. Dotted-decimal netmask matches what consumer routers display;
CIDR notation surprises non-network users. The four required keys
are the minimum to reach any home network; everything else has a
sensible default.

**Date:** 2026-04-28

---

## D004 — Pi firmware loads network.conf via initramfs at INITRAMFS_ADDR

**Decision:** The Pi firmware loads `network.conf` to physical
address `INITRAMFS_ADDR = 0x20000000` via an `initramfs network.conf
0x20000000` line in `config.txt`. `boot.S` saves the firmware-passed
`x0` (DTB pointer) at the top of entry. `INITRAMFS_ADDR` is defined
once in the Makefile and passed via `-D` to both asm and any tooling
that needs to know the address.

**Rationale:** Firmware-loaded blob is simpler than asking the
kernel to read FAT itself — we'd have to write a FAT driver. The
firmware already has one. `0x20000000` is well above the kernel
load address (`0x80000`) and BSS, with no risk of overlap on any
build target. Single Makefile knob keeps asm and any future linter /
tool in sync.

**Date:** 2026-04-28

---

## D005 — net_cfg.S writable, parser-populated

**Decision:** Move `net_our_mac`, `net_our_ip`, `net_gw_ip`,
`net_ntp_ip` from `.rodata` to `.data`. Add new labels `net_netmask`,
`net_hostname`, `net_hostname_len`. On Pi 4 builds the defaults are
zero — the parser must populate them at boot or panic. On QEMU the
existing `10.0.2.x` defaults remain, since QEMU has no SD card and
no `network.conf`.

**Rationale:** Existing code treated these as compile-time constants
in read-only data. The new model treats them as boot-time runtime
state populated from `network.conf`. Section move is required for
mutability. Zero defaults on Pi 4 force the parser path to actually
run; a forgotten parser call would crash on the first network use
rather than silently using bogus defaults.

**Date:** 2026-04-28

---

## D006 — Hostname validation per RFC 1123

**Decision:** Hostnames must contain only LDH characters (letters,
digits, hyphens), be 1–63 octets long, and begin with a letter or
digit (not a hyphen). Two helpers in `config_parser.S` enforce this:
`hostname_validate` (called at parse time, panics on violation) and
`hostname_case_eq` (case-insensitive equality used by the mDNS
responder).

**Rationale:** mDNS queries arrive case-insensitive per RFC 6762
§16; a strict-equality match would silently fail to answer queries
that DNS resolvers normalize. RFC 1123 first-char rule rejects
hostnames like `-foo` that some routers treat as flags. 63-octet
limit matches DNS label length.

**Date:** 2026-04-28

---

## D007 — GENET MDF: single hardcoded mdns_mac, no table

**Decision:** Program the GENET MAC Destination Filter (MDF) with a
single hardcoded multicast MAC for IPv4 mDNS (`01:00:5e:00:00:fb`).
A single label `mdns_mac` in the GENET driver. No table abstraction,
no array, no loop.

**Rationale:** Today exactly one multicast filter slot is in use
(mDNS). Sizing an array for "future entries that may never come"
wastes complexity for nothing measurable. If a second multicast
group is ever needed, a refactor at that point is cheaper than the
abstraction tax paid for every reader of the current code. See
`feedback_no_premature_tables.md` in memory for the lesson learned
during the redesign — an earlier iteration of this design did try a
table and was reverted before landing.

**Date:** 2026-04-28

---

## D008 — mDNS responder: RFC 6762 subset (A + ANY queries only)

**Decision:** Implement an mDNS responder per RFC 6762 with the
following deliberate subset:
- Answer A-record queries and ANY-record queries for our hostname.
- No AAAA (we are IPv4 only), PTR, SRV, or TXT records.
- Probe at boot: 3 queries 250 ms apart per RFC 6762 §8.1.
- Announce at boot: 2 responses 1 s apart per RFC 6762 §8.3.
- No goodbye packet on shutdown — bare-metal has no graceful
  shutdown event to hook.
- No runtime conflict detection after announcement — if a peer
  appears later with the same name, both will answer. The probe
  catches the only case we care about (boot-time conflict).
- Probe-conflict halts the system with panic pattern N (see D013).

**Rationale:** A-record answer is what `<hostname>.local` resolution
needs. ANY queries are what `dig` and `avahi-resolve` typically
issue; answering them keeps diagnostic tools working. AAAA requires
IPv6 we don't have. PTR / SRV / TXT are service-discovery features
out of scope for a single-host appliance. Probe + announce is
mandatory per RFC 6762; the halt-on-conflict policy is intentionally
strict because a name collision on a home network is a configuration
bug the user wants to know about, not silently route around.

**Date:** 2026-04-28

---

## D009 — UDP demux: extend if/elseif chain, no port table

**Decision:** Add the new mDNS UDP path (port 5353) to the existing
if/elseif chain in `lib/udp.S` rather than introducing a port→handler
table.

**Rationale:** Three UDP-port-bound services today: NTP (123),
mDNS (5353), and (potentially) future. Same reasoning as D007 —
a 3-entry table read uniformly is more complex than three branches
read in order, and the branches make the dispatch order explicit
and grep-able.

**Date:** 2026-04-28

---

## D010 — Stack uses always-via-gateway routing; no subnet awareness

**Decision:** Three coordinated rules:
1. The IP stack sends every outbound packet to the gateway MAC and
   swaps the source MAC of replies into the destination. No
   subnet-mask-based routing decision exists in the production
   code path.
2. The unused `NET_MASK_NBO` constant and any sibling
   `NET_*_NBO` macros that became dead with this rule are deleted
   from `include/net.inc` (see I13).
3. The user-facing `netmask` key in `network.conf` is accepted
   but recorded for documentation only; it does not influence the
   routing decision today. A regression-guard test pins this
   invariant — re-introducing a `NET_MASK_NBO` read in production
   code will fail CI.

**Rationale:** Subnet-aware routing is correct for general-purpose
hosts but unnecessary for a single-host appliance on a directly-
attached LAN. Removing the subnet logic eliminates a class of
configuration bugs (wrong netmask → mysterious connectivity
failures) and shrinks the code. Accepting `netmask=` in
`network.conf` keeps the user mental model simple — every
consumer-router config screen shows a netmask, so requiring one
matches the user's existing context — without coupling the runtime
to it.

**Audit evidence (2026-04-28):** at the time the rules above were
adopted, an audit confirmed no existing code path read
`NET_MASK_NBO` or applied `/24` logic. The audit is the *evidence*
that adopting these rules was a no-op for behavior; the rules
themselves stand on their own going forward.

**Date:** 2026-04-28

---

## D011 — Factory MAC via mailbox tag, panic on read failure

**Decision:** At boot, read the factory MAC address via the VC
mailbox tag `0x00010003` (`GET_BOARD_MAC_ADDRESS`). If the read
fails AND the user has not provided a `mac=` override in
`network.conf`, halt with panic pattern M (see D013).

**Explicitly not:** Fall back to a hardcoded MAC like
`02:00:00:00:00:01` on read failure.

**Rationale:** A hardcoded fallback would create an instant ARP war
the moment two ws_pi5 Pis end up on the same LAN — every device
would map the IP to whichever Pi answered last, with traffic
flapping wildly. Ed has personally chased a duplicate-MAC ARP war
on a corporate network and weighs that failure mode as first-class.
The `mac=` override exists for diagnostic and testing scenarios
(e.g. cycling MACs deliberately) but is opt-in.

**Date:** 2026-04-28

---

## D012 — Linter is the executable spec; asm parser is locked to it

**Decision:** `scripts/lint_network_conf.py` is the canonical
specification of `network.conf` validity. A shared
`tests/func/network_conf_vectors.tsv` file holds PASS and FAIL
vectors. The Python linter (used as a flash-time gate via
`mk_sd.sh`) and the bare-metal asm parser are BOTH required to
agree with the TSV. Implementation order is locked: write the
linter and the TSV BEFORE the asm parser.

**Rationale:** Two implementations of "what is a valid config"
will diverge unless they share an authoritative test corpus.
Linter-first ordering ensures the asm parser is built against a
fixed target, not against itself. The TSV is human-readable
plain-text — easy to extend, easy to diff, easy to grep. Vector
files have proven their worth in the FSA work
(`tests/func/http_output_fsa_vectors.tsv` pinned the HTTP output
state machine the same way).

**Date:** 2026-04-28

---

## D013 — Six-pattern panic LED catalog

**Decision:** When the appliance hits an unrecoverable boot-time
condition, halt and blink the activity LED (GPIO 42) in one of six
distinguishable patterns. Six panic codes are normative HERE — the
letter-to-meaning mapping is fixed by this entry. Other entries
(D008, D011) reference these letters; renaming them requires a new
D-entry, not a silent edit:

| Code | Meaning              |
|------|----------------------|
| N    | Network conf invalid |
| G    | Gateway unreachable  |
| I    | Init failed          |
| M    | MAC unreadable       |
| K    | Kernel panic         |
| U    | Unknown / catch-all  |

The visual blink patterns themselves (timing, pulse counts) are
documented separately in `docs/PANIC_PATTERNS.md` and may be tuned
for human readability without touching this entry — that file holds
the *visual* specification; this entry holds the *naming* contract.

**Rationale:** A user with no serial console needs SOME way to
distinguish "wrong netmask in network.conf" from "Ethernet cable
unplugged" from "kernel panic." The LED is the only output channel
present on every Pi 4. Six categories cover the boot-time failure
domains identified during the redesign; a wider catalog would
exceed what humans can distinguish by eye.

**Date:** 2026-04-28

---

## D014 — Test plan for the network-config redesign

**Decision:** The redesign is "done" when the following acceptance
criteria all pass simultaneously on a real Pi 4. Three tiers
matching the project's A/B/C bucket discipline.

**A bucket — must pass on every commit (pre-commit gate):**
- A1. `scripts/lint_network_conf.py` accepts every PASS entry in
  `tests/func/network_conf_vectors.tsv` and rejects every FAIL
  entry with the documented exit code and error message.
- A2. The asm config parser consumes the same TSV and produces
  byte-identical results to the linter for PASS vectors; rejects
  FAIL vectors with the documented panic pattern code.
- A3. `hostname_validate` and `hostname_case_eq` unit tests cover
  RFC 1123 LDH rules, length 1–63, first-char rule, case-insensitive
  equality.
- A4. mDNS responder unit tests cover A-query, ANY-query, and
  AAAA/PTR/SRV/TXT explicitly returning no answer.

**B bucket — must pass on every commit (QEMU regression):**
- B1. Existing 480 unit tests still pass.
- B2. New `test_config_load.S` loads a synthetic `network.conf`
  blob at `INITRAMFS_ADDR`, parses, asserts `net_our_ip / netmask /
  gw_ip / hostname / hostname_len` populate correctly.
- B3. D010 regression-guard: assert no code path reads
  `NET_MASK_NBO`. Hard-fail if reintroduced.

**C bucket — must pass before push and on the nightly cron
(real Pi 4 hardware):**
- C1. **Cold install path** — fresh `mk_sd.sh` output to a
  never-touched SD card, default `network.conf`, boot, HTTP serves
  on the configured IP.
- C2. **User-customized config** — edit `network.conf` to a
  non-default `hostname=` and `ip=`, reboot, `dig @224.0.0.251
  -p 5353 <hostname>.local` resolves to the configured IP, and
  `curl http://<hostname>.local/` returns the home page.
- C3. **mDNS probe-conflict** — `avahi-publish -a wspi5.local
  <dev-machine-IP>` running on the dev machine, then boot Pi with
  `hostname=wspi5`. Pi must halt with panic pattern N within
  1 second of the probe phase. Pi UART must show the conflict
  message.
- C4. **mDNS coexistence** — `avahi-publish -a friendly.local
  <dev-machine-IP>` running, Pi running with `hostname=wspi5`.
  Both names resolve correctly. HTTP traffic to Pi unaffected
  during avahi-publish activity.
- C5. **Factory-MAC fallback halt** — synthesize a `network.conf`
  with no `mac=` override and force the mailbox `0x00010003` call
  to fail (test-only build flag). Pi must halt with panic pattern
  M, never falling back to `02:00:00:00:00:01`.
- C6. **End-to-end stranger test** — fresh git clone on a different
  machine, follow README literally on the 1 GB Pi, browse to
  `http://<hostname>.local/` from a third device. Any tribal-
  knowledge gap is a README defect to file. This is the README /
  D015 acceptance test.

**Perf regression methodology:**
- P1. Baseline: capture wrk-against-`/` numbers on current `main`
  (pre-mDNS) at 10/50/100 connections, 30 s, single client. Log
  under flavor `PERF=http_baseline`.
- P2. Post-redesign: same wrk parameters after the redesign lands.
  Allowed regression: ≤5 % on req/s at any connection count. Log
  under flavor `PERF=http_with_mdns`.
- P3. mDNS query load: during P2, run a parallel
  `avahi-resolve -n $(hostname).local` loop (100 iterations) from
  the dev machine. Allowed regression vs P2: ≤5 %.

**Implementation/test ordering:** Per D012 — linter-first. The
specific I-task sequence is tracked in the project task list and is
a process detail, not a decision. If the order ever changes, the
task list is updated; D014 stands.

**Rationale:** A/B/C bucket discipline is project policy
(`feedback_test_buckets.md`). The C-bucket criteria each test one
behavior end-to-end on real hardware — partial passes are not
sufficient. The "stranger test" (C6) is the ultimate acceptance
gate for D015 (README rewrite) — if the install path can't be
followed by a stranger from the README alone, the documentation is
the defect. The perf methodology gates the redesign against the
~51.8K req/s baseline; mDNS shares the single core and must not
materially degrade HTTP throughput.

**Date:** 2026-04-29

---

## D015 — README rewrite deferred until implementation lands

**Decision:** Defer the README rewrite until the network-config
redesign implementation is complete. The current README install
section is marked WIP in commit `e73d333` with a banner pointing
at the redesign-in-flight. The rewrite happens as the final
implementation task (I6) so the docs describe shipping reality
rather than aspiration.

**Rationale:** Writing user-facing install docs against a moving
target invites doc drift. The rewrite is small and entirely
mechanical (describe `network.conf` keys, the `<hostname>.local`
URL, the panic-pattern catalog). Doing it last means it lands
correct on first commit. The C6 acceptance test in D014 — a
stranger following the README literally — is the gate that the
rewrite is good enough.

**Date:** 2026-04-28

---

## D016 — Perf cron is data-gathering, not gating

**Decision:** The nightly perf cron (`scripts/perf_nightly.sh`)
records data into `hw_test/perf_runs.log` and exits non-zero only
on a hang or harness crash. Pytest assertion failures are recorded
as data points but do NOT fail the cron. `scripts/perf_check.py`
is invoked only by `scripts/pre-push-integration.sh`; the cron
calls `hw_tests.sh --data-only perf` which skips the regression
gate entirely.

A "hang" is defined as: a perf phase exceeding `PHASE_TIMEOUT_S`
wall-clock seconds (default 600 s, overridable via env var). Each
pytest run within a phase is wrapped in `timeout` with the
remaining phase budget; expired runs return exit 124 which the
runner translates into a HANG marker appended to `perf_runs.log`.

**Scope refinement of D014.** D014 still describes the test plan
and acceptance criteria; D016 narrows where the perf gate fires.
Pre-push integration retains the strict gating behaviour (D014's
P1/P2/P3 perf-regression methodology applies there).

**Rationale:** Across the runs observed during the
network-config redesign session and after, every cron failure was
either environmental noise (laptop USB scheduling, host
contention, cold-cache jitter) or a documented stochastic
behaviour we widened tolerance for (L2 1024-burst loss). Not
once did a cron failure flag a real bug we wouldn't have noticed
otherwise. The signal-to-noise ratio of per-run threshold gates
on a noisy rig is poor — a human reading the trend log catches
real drift better than any single-point comparison can.

A hang, by contrast, is unambiguous: the harness is broken, the
SUT is wedged, or a cable is unplugged. Always worth waking up an
operator. Hangs surface in `perf_runs.log` as `--- HANG ... ---`
markers alongside the data, so trend-readers see them in
context.

This applies the same "test at the right layer" principle that
drove the perf_check.py rewrite to gate on Pi-side counters
instead of laptop-observed wire_pps (commits 00db7f6, 7a465a0):
the metric the cron measures should not bake in noise the cron
can't distinguish from regression.

**Revisit if:** A real regression goes unnoticed in trend-watching
for more than ~3 days because the human review cadence missed it.
At that point, consider lightweight thresholding (e.g. flagging
deltas > 50 % from rolling-7-day median) rather than reverting
to per-run gates.

**Date:** 2026-04-30


## D017 — DHCP client v1: opt-in, mutually exclusive with static

**Decision:** Add a DHCPv4 client (RFC 2131 + RFC 2132 subset). A
new `dhcp=` field in `network.conf` selects the configuration
source:

  - `dhcp=no` (default) — current behaviour. The `ip=`,
    `netmask=`, and `gateway=` fields are required and used
    verbatim, exactly as D003/D006 specify.
  - `dhcp=yes` — DHCP is attempted. The `ip=`, `netmask=`, and
    `gateway=` fields are **ignored** if present (the linter
    accepts them but warns; the asm parser passes them through
    without applying them). On DHCP failure the kernel halts with
    `panic_d` (new pattern, see D013 amendment below). No
    fallback to the static fields — see "Why mutually exclusive"
    below.

The DHCP client is structurally a finite-state automaton driven
by a TSV transition table (`tests/func/dhcp_fsa_vectors.tsv`),
mirroring the http_output_fsa pattern from the appliance work.
A `make verify-dhcp-fsa-table` target cross-checks the asm-
compiled `dhcp_fsa_trans_table` symbol against the TSV at build
time. Protocol-level tests are PICT-driven from
`tests/func/dhcp_pict_model.txt`.

**Subset, deliberate omissions:**

  - Client only. No server, no relay, no DHCP-INFORM.
  - States: INIT, SELECTING, REQUESTING, BOUND, RENEWING,
    REBINDING. Skip INIT-REBOOT and REBOOTING — no lease
    persistence (no RTC, no flash; fresh DHCP each boot).
  - Mandatory options requested: subnet mask (1), router (3),
    lease time (51). Server identifier (54) is required in
    OFFER/ACK or the packet is rejected.
  - DNS (option 6) and domain name (15) are ignored. We use
    mDNS (D008) for name resolution and always-via-gateway
    routing (D010); name servers from DHCP would not be used.
  - No ARP probe of assigned address before claiming
    (RFC 2131 §2.2 SHOULD, not MUST). Trust the server. Add
    later if collision incidents are observed.
  - No DECLINE or RELEASE. If the assigned address turns out
    to be in use we'll see it surface as ARP weirdness; v2 can
    add the response.
  - No client identifier option (61). Servers identify by MAC.

**Retransmit / failure budget:**

  - SELECTING: send DISCOVER, wait for OFFER. Three retries with
    exponential backoff (4 s, 8 s, 16 s) per RFC 2131 §4.1. After
    the third retry expires with no OFFER → `panic_d`.
  - REQUESTING: send REQUEST, wait for ACK. Same backoff. Same
    panic on exhaustion.
  - BOUND: arm timer at T1 = lease/2.
  - RENEWING: REQUEST unicast to server. On T2 reached without
    ACK → REBINDING.
  - REBINDING: REQUEST broadcast. On lease expiry without ACK →
    INIT (re-discover).
  - NAK in any state → INIT.

**Why mutually exclusive (and not "DHCP primary, static
fallback"):** A static fallback is reachable only when DHCP
fails. Picking a fallback IP that won't collide requires the user
to know (a) their LAN's subnet, (b) the router's DHCP pool range,
and (c) which other devices have static assignments. Most home
users don't have all three. Worse, the bug is silent: DHCP works
99 % of the time, the static is never tried, then the day DHCP
hiccups (router reboot, lease churn) the wrong fallback IP causes
mysterious collision. Mutually exclusive failure is loud
(`panic_d` on the LED) and the user knows immediately to check
the DHCP server. Heritage static behaviour is preserved by
`dhcp=no` being the default.

**D013 amendment:** Add `panic_d` ("DHCP acquisition failed") to
the panic catalogue. Morse pattern: `─··` (three pulses, dah-dit-
dit). Update `docs/PANIC_PATTERNS.md` and `lib/panic.S` in the
same commit that lands the FSA, so the LED behaviour matches the
catalogue at all points in I16's history.

**D003/D006 amendment:** `dhcp=` is a new optional field. When
absent or `dhcp=no`, the behaviour described in D003/D006 is
unchanged. When `dhcp=yes`, the `ip=`/`netmask=`/`gateway=`
required-field rule is relaxed (the linter still accepts them,
prints a warning, and the asm parser stores but does not apply
them).

**Rationale for FSA-table-driven design:** Same as the HTTP
output FSA. The state machine has 6 states × 8 events = 48 cells;
hand-coded `cmp/b.eq` ladders for that drift quickly. A TSV
spec + asm table loader + verify-target keeps the spec, the
implementation, and the tests aligned by construction. PICT on
top covers protocol-level edge cases (option-mask-missing,
truncated OFFER, etc.) without us hand-enumerating them.

**Trigger for revisit:**

  - If a deployment hits a DHCP server that reliably refuses
    address acquisition for our request shape and we'd rather
    fall back than panic, revisit "no fallback" — but the right
    fix at that point is probably ARP-probed static fallback
    (RFC 5227), not the foot-gun version.
  - If we ever ship a build that needs to operate without DHCP
    (e.g. an isolated factory test rig), the `dhcp=no` mode
    already covers it; no change needed.

**Date:** 2026-05-01

---

## D018 — One kernel binary at 0x80000; chainloader self-relocates to 0x4000000

**Decision:** Both the SD-direct boot path and the UART chainloader
path link the kernel at the firmware default address (0x80000). The
chainloader image (`chainload/boot.S`) is also loaded by firmware at
0x80000 but copies itself to 0x4000000 on entry and jumps there
*before* doing any UART work, freeing 0x80000 to receive the
incoming kernel.

This supersedes the earlier "two binaries, two link addresses" build
shape (`make PLATFORM=pi4` for chainloader at 0x200000; `make
PLATFORM=pi4 SHIP=1` for SD-direct at 0x80000). The `SHIP=1` flag is
removed.

**Rationale:** The earlier split existed to keep ARM-side writes off
0x80000 during chainloader UART transfer — the BCM2711 GPU firmware
runs an active agent at 0x80000 *during the chainloader's UART
transfer phase* that corrupts the PL011 RX FIFO when ARM writes to
that region (see the README's "firmware 0x80000 conflict" section).
Loading the kernel at 0x200000 worked but doubled the build surface,
made the SHIP-vs-dev choice load-bearing for every commit's perf
gate, and meant the chainloader path could never inherit any work
that depended on the firmware-quiescence guarantee SD-direct
already had.

The agent is *not* active during firmware-side load of `kernel8.img`
at 0x80000 (the CPU is held off until hand-off) — that's why
SD-direct at 0x80000 always worked. By having the chainloader move
itself to 0x4000000 *before* opening the UART loop, we extend that
quiescence to the chainloader path: the chainloader's runtime
working set is at 0x4000000 and the incoming kernel HEX records
land at 0x80000, where the agent is dormant after firmware hand-off.

**Why not load the kernel at 0x4000000 instead?** The kernel's link
address has to match what firmware loads from `kernel8.img` for
SD-direct to work without a `kernel_address=` override in
`config.txt`. Pinning to firmware's default (0x80000) keeps SD-direct
no-config and lets the chainloader image be the only thing that
chooses where to live (which is invisible to anyone not building
the chainloader).

**Implementation:** commits `e899e7a` (drop SHIP=1, unify link
address), `7e3e774` (chainloader self-relocate stub), `905c2c2`
(I-cache invalidate + isb before `br x0`), `991b84c` (D-cache
invalidate before BSS zero, fix way-bit per platform).

**Trigger to revisit:** If a future SoC's firmware loads
`kernel8.img` at a different address (e.g. Pi 5 / BCM2712), the
chainloader's self-relocate destination (currently hardcoded
0x4000000) and the kernel's link address would need to be revisited
together. The unification keeps that to two related changes instead
of every Makefile target picking sides.

**Date:** 2026-05-04

---

## D019 — Dual-config rig: chainloader SD has no `network.conf`

**Decision:** A chainloader-mode SD card produced by `scripts/mk_sd.sh
--chainload` ships **no** `network.conf` and no `initramfs` directive
in `config.txt`. The kernel reads `network.conf` from `0x20000000`
(the firmware-default initramfs region), which the chainloader leaves
at DRAM-init zero unless `hw_send.py --network-conf <path>` prepends
the file's bytes as Intel HEX records targeting that address
alongside the kernel.

Cold-booting a chainloader SD without a UART-pushed config
intentionally panics with `panic_k` (config-parse error) because the
0xff/0x00 bytes at 0x20000000 fail the magic check. This is loud and
recoverable.

**Rationale:** The chainloader-mode SD is a development / test fixture,
not a shippable artifact. Coupling it to a static `network.conf`
inside the FAT partition would force every test pass to either reflash
the SD or push a different image — exactly the friction the
chainloader exists to eliminate. Decoupling the config from the SD
lets one SD serve both static and DHCP test passes via
`scripts/dual_config_tests.sh`, with each pass differing only in the
bytes pushed alongside the kernel (`hw_test/network-static.conf` vs
`hw_test/network-dhcp.conf`).

**Why panic instead of falling back to a hardcoded static config?**
Same reasoning as D017's "no static fallback when DHCP fails": a
silent fallback in this position would make a misconfigured rig look
like it was running, where in fact the kernel was on a wrong /
stale config. `panic_k` on the LED tells the operator immediately
that something didn't push the expected bytes. The rig harness'
post-flash ping check would also catch a wrong config quickly, but
"loud at the LED" is a strictly better diagnostic than "ARP timeout
deep inside pytest."

**Out of scope for end users.** SD-direct boot images built by
`scripts/mk_sd.sh --build` (the user-facing path) ship with a
default `network.conf` exactly as before — D019 changes the
chainloader-mode SD only.

**Implementation:** commit `76d0135` (`scripts/mk_sd.sh --chainload`
no longer ships `network.conf` or the `initramfs` directive;
`scripts/hw_send.py --network-conf` is the sole writer of
`0x20000000`).

**Date:** 2026-05-04
