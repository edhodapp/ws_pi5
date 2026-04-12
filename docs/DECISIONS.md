# Design Decisions

Every deliberate deviation from a specification, standard practice, or
RFC requirement is recorded here. If a decision has been revisited, the
history is preserved — not overwritten.

Each entry: what was decided, why, when, and under what conditions to
revisit.

---

## IP options not supported (RFC 1122 §3.2.1.8)

**Decision:** Drop all IP datagrams with IHL > 5 (options present).

**Rationale:** Single-host bare-metal web server on a direct cable.
No forwarding, no source routing, no record route. Packets with
options are dropped safely (not misinterpreted). Zero attack surface
from option parsing bugs.

**Revisit if:** Source routing or record route needed for diagnostics.

**Date:** 2026-04-09

---

## ICMP Time Exceeded for reassembly timeout

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
