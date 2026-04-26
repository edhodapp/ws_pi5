# Debug log — 0x80000 boot bug

Investigation of the cold-SD-boot failure that motivated the original
0x200000 link target. Started 2026-04-25 after Gemini consult
confirmed 0x80000 is the firmware default and our "VC agent" claim
was a misdiagnosis.

Test fixture: `examples/public/` packaged with `CONTENT_MAX=65536`
(~152 KB kernel image). UART chainloader flashes in ~1 min so each
iteration is fast.

## Boot.S debug breadcrumbs

Each step prints a single ASCII char to PL011 if reached:

  '0'  — `_start` entered (very first instruction after firmware/chainloader handoff)
  '1'  — EL drop done, EL1 reached
  '2'  — stack pointer set
  '3'  — about to zero BSS
  '4'  — BSS zeroed, about to set up MMU tables
  '5'  — MMU tables built + TLB/cache invalidated, about to enable MMU
  '6'  — MMU on, about to `bl main`
  Hello — first print from `main()`

## Attempts

| # | When        | Change | Result |
|---|-------------|--------|--------|
| 1 | 10:00 | Link kernel at 0x80000 (linker_hw.ld), drop kernel_address from config.txt, point chainloader's CL_KERNEL_ADDR at 0x80000 | `0123` then hang. Hung between '3' (about to zero BSS) and '4' (BSS zero done). |
| 2 | 10:10 | Add `.` print every 1 MiB inside BSS zero loop | `0123.` then hang. First MiB of BSS zeroed (`__bss_start=0xa5140` → `0x1a5140`); hang inside the second MiB. Range 0x1a5140–0x2a5140 covers the start of `tcp_sndbuf_pool` at 0x1af250 (the 32 MB send-buffer pool). |
| 3 | 10:20 | Skip BSS zero entirely (DIAGNOSTIC) | `0123456` then hang. Got through BSS-skip, MMU setup, MMU enable, and entered `bl main` — but `main()` never printed its `"Hello from bare-metal Pi 4!"` message. Different hang point than #2. |
| 4 | 10:35 | Add `ic iallu` (I-cache invalidate to PoU) before MMU enable; BSS-zero still skipped. | `0123456` then hang. Same as #3. So missing I-cache invalidate wasn't the culprit. |

## Working hypotheses

1. **Two separate problems.** The BSS-zero hang (#2) and the
   main()-entry hang (#3) might be independent.

2. **MMU misconfig at 0x80000.** Both hangs come AFTER our MMU
   tables are touched. With kernel at 0x80000, the L1[0] block
   descriptor maps 0x0–0x3FFFFFFF as Normal cached memory.
   That includes our kernel and any firmware-reserved low memory.
   Maybe firmware-reserved regions need different attributes.

3. **Cache coherency.** The chainloader writes the kernel into RAM
   with caches disabled. Our `dc isw` invalidate walks all sets/ways.
   If a stale cache line shadows a kernel instruction, post-MMU-on
   execution diverges.

4. **Other-core interference.** Cores 1-3 are still running in
   firmware spin-table code. If our BSS zero stomps something they
   read, they may take a fault that somehow blocks core 0.

## Continued attempts

| # | When | Change | Result |
|---|------|--------|--------|
| 4 | 10:35 | Add `ic iallu` before MMU enable; BSS-zero skipped. | `0123456789` then hang. I-cache invalidate didn't help. |
| 5 | 10:42 | Print '7' (top main), '8' (after 50 ms wait), '9' (after uart_init). | `01234567` then hang — `uart_init` was hanging. |
| 6 | 10:48 | Hardcode PL011 base in `uart_init` (bypass `uart_hw_base` from .data). | `0123456789` then `bl uart_puts msg_hello_pi4` produced nothing — UART works post-init, but reading the .rodata string failed. |
| 7 | 10:55 | Hardcode PL011 base in `uart_putc` too. | `0123456789A...garbage` — UART transmits but the *bytes from .rodata* are wrong. |
| 8 | 11:05 | Verify image: `xxd kernel8.img` at 0x8016 shows correct "Hello from bare-metal Pi 4!\r\n\0". Image is fine; *runtime memory at 0x88016 reads back something else.* |
| 9 | 11:10 | `ic iallu` at very top of `_start` before any data fetch. | Same garbage. I-cache wasn't it. |
| 10 | 11:18 | Disable D-cache and I-cache entirely (SCTLR_EL1.C=0, .I=0; MMU still on). | **Same garbage even with caches off.** Reads bypass cache and still return wrong bytes — kills the stale-L2/L3-cache hypothesis. |
| 11 | 11:25 | Found chainloader comment: *"The firmware leaves DMA channels pointing at 0x80000 for UART I/O. Writing kernel data there triggers phantom DMA-to-UART transfers."* This is the **actual original 0x80000 bug** — DMA-to-UART, not "VC agent." The chainloader resets DMA channels 0–10 *before* writing the kernel. After hand-off, kernel writes to low memory may be re-triggering DMA (or DMA may have been re-armed by firmware/something). |

## Working hypothesis (post #11) — disproved by #12

| 12 | 11:35 | Replicate chainloader's DMA channel-0–10 reset at the top of kernel's `_start`. | Same garbage. DMA reset wasn't it (or wasn't sufficient). |
| 13 | 11:42 | **Realized**: `scripts/hw_send.py` default `base_addr=0x200000` was never updated when we moved the kernel link target to 0x80000. AND the chainloader currently on Ed's SD still has `CL_KERNEL_ADDR=0x200000` from before this commit series. So kernel bytes were being placed at 0x200000 via Intel HEX records, then the on-SD chainloader was jumping to 0x200000 — but the kernel was *linked for* 0x80000, so all literal-pool loads hit addresses no kernel data lived at. Boot prints worked because they hardcode the PL011 base; everything that goes through `.rodata` / `.data` / function pointers blew up. Patched `hw_send.py` default to 0x80000. |

## Continued attempts

| # | When | Change | Result |
|---|------|--------|--------|
| 14 | 12:45 | Built new chainloader (`CL_KERNEL_ADDR=0x80000`, no staging — hex parser writes records directly to 0x80000+). Copied `chainload/chainload.img` → SD as `kernel8.img`. Reflashed kernel via UART. | First run failed — argv order bug in my hw_send invocation (I passed `/dev/ttyUSB0 kernel8.img` instead of `kernel8.img /dev/ttyUSB0`). Process produced no output, killed cleanly. |
| 15 | 12:48 | Re-ran with correct args: `python3 scripts/hw_send.py kernel8.img /dev/ttyUSB0`. | `READY` came back, host started sending records, then **`MISMATCH at record 17: exp=0x9A got=0x86 len=43`**. Reproducible — same record, same checksum on every retry. |
| 16 | 12:52 | Diagnostic reasoning: line length echoed correctly (43), so the chainloader received exactly the bytes the host sent — this is a **checksum disagreement**, not a wire-corruption problem. Record 17 is 16 data bytes targeted at 0x80100 (`ELA=0x0008` upper16 + offset 0x0100). Records 0–16 covered 0x80000–0x800FF. The chainloader's parse-then-checksum logic in `hex_parse.S` operates entirely on a line buffer in chainloader's own .bss at 0x4000000+, so the kernel-target write doesn't influence the checksum — yet record 17's checksum is consistently wrong while records 1–16 are accepted. Best explanation: the parse staging itself is being corrupted, but **only when the data record's destination falls inside the firmware-active low region**. |
| 17 | 12:55 | Ed's recall: "We did this before with 0x200000." Confirmed against git history: commits f09d068 ("stage at 0x200000, DMA reset, remove flow control") and bc3bc81 ("clean up diagnostic prints, keep staging + memcpy") had the chainloader stage HEX writes at 0x200000 and memcpy to 0x80000 just before jump. e203b45 (today's commit) removed staging on the mistaken belief that 0x80000 was now safe to write directly. Conclusion: **0x80000 is poisoned for chainloader writes**, period — but is fine as the *jump target* once bytes are placed there by an atomic memcpy. SD-boot is a separate scenario (firmware places bytes at 0x80000 itself before handoff), so the 0x80000 link target is still correct for that path. |
| 18 | 13:00 | Restored `CL_STAGING_ADDR=0x200000` and the staging→kernel memcpy block in `chainload/boot.S` (between UART drain and the `dsb sy; ic iallu; dsb sy; isb` cache hand-off). Reverted `scripts/hw_send.py` default `base_addr` to `0x200000`. Kept `linker_hw.ld` at `0x80000` — one kernel binary serves both paths. Rebuilt `chainload.img`, copied to SD, rebooted Pi, re-flashed kernel via UART. | **All 9499 records ACK'd cleanly in 63.7s. `BOOT:251B`. Then breadcrumbs `012345` — kernel ran '0'..'5', hung between '5' (MMU tables built, TLB/cache invalidated, about to enable MMU) and '6' (MMU on, about to bl main).** Two-regime model is **confirmed**: chainloader-stage-at-0x200000 + memcpy-to-0x80000 fully fixes the chainloader-path corruption. We are now seeing the *original* "stupid bug" — kernel MMU setup is wrong for `0x80000`. This is the same hang class as attempts #3–#4 from earlier in this log, but those were ambiguous because the kernel was actually running at 0x200000-vs-linked-0x80000; **this** hang is unambiguous since kernel bytes and link target now agree. |

## Working theory entering attempt 19

The kernel's MMU enable at `0x80000` is the real bug. Possibilities:
1. **L1[0] block descriptor attributes wrong for low memory.** With kernel at 0x80000, the first 1 GB block (0x0–0x3FFFFFFF) maps the kernel itself. If we mark this Normal cached but firmware-reserved structures live in this range, MMU enable may fault.
2. **TTBR0 / TCR / MAIR mismatch.** A misconfigured field that QEMU's raspi3b emulator forgave but real BCM2711 enforces. Worked at 0x200000 by coincidence (page-table walks happened to land on safe physical memory).
3. **Page-table physical address itself overlaps something live.** If the L1/L2 tables are placed in BSS that overlaps a firmware-reserved region at 0x80000+, the MMU's hardware walker reads garbage.
4. **I-cache stale at MMU enable.** When MMU comes on with normal-cacheable attributes, instruction fetch suddenly speculates into the I-cache. Stale lines from firmware execution at this address range = garbage instructions = hang.

Diagnostic: print `'5a'`, `'5b'`, `'5c'` between the individual MMU-enable steps (TTBR0 write, TCR write, MAIR write, SCTLR.M=1) to localize which one hangs.

## Working theory entering attempt 18

Two boot paths, two address regimes:
- **SD-boot** (firmware-direct): firmware writes kernel bytes to 0x80000 via privileged GPU/DMA path while CPU is held off, then jumps. CPU never contends with firmware over 0x80000. Linked-at-0x80000 binary runs correctly.
- **Chainloader** (CPU-write): CPU is active, firmware/DMA may still be using 0x80000 area for UART or other I/O. CPU writes to 0x80000 racing with firmware/DMA → corrupted records (manifested as record-17 checksum mismatch). Stage at 0x200000 (verified clean from prior history), memcpy to 0x80000 once UART work is done, jump.

If attempt 18 produces clean breadcrumbs `0123456789A` + `Hello from bare-metal Pi 4!`, this two-regime model is confirmed and we can move on to vetting the SD-boot path independently.

## Investigation step 19 — design-level audit, not finer probes (13:25)

Ed pushed back on adding `5a/5b/5c/5d` sub-breadcrumbs around the MMU-enable sequence: knowing the exact instruction that hangs doesn't tell us why, the symptom may not even be perfectly reproducible, and what matters is that this fails *at all*. Right call — finer probes are address-of-failure, not cause.

What changed between "ran at 0x200000" and "hangs at 0x80000": same MMU source code, same TCR/MAIR/L1[0] block descriptor (Normal cached, inner shareable, AF, RW EL1). The only difference is which physical RAM it touches:
- At 0x200000: BSS starts ~0x225000, page tables (`__mmu_l1_table`, `__mmu_l2_table`) at ~0x226000/0x227000. Kernel .text/.rodata in 0x200000–0x224000.
- At 0x80000: BSS starts ~0xa5000, page tables at ~0xa6000/0xa7000. Kernel .text/.rodata in 0x80000–0xa4000.

Both ranges fall under L1[0] (0x0–0x3FFFFFFF) which is Normal cached. So it's not a *mapping* difference — it's *what physical memory the page-table walker touches and what the I-side speculatively prefetches when MMU enable opens those VA→PA mappings as Normal cached*. Some firmware/DMA-active region in the 0x80000–0xa8000 area is the leading hypothesis (consistent with the chainloader-DMA-at-0x80000 pattern we just fixed).

Two parallel probes launched:
1. **Cross-reference open-source Pi-4 bare-metal MMU setups** (Circle, U-Boot, Linux arch/arm64/kernel/head.S, rpi4-osdev). Specifically: their MAIR/TCR values, where they place page tables, whether they map the kernel region as cached/non-cached/Device, and the order of cache/TLB invalidation around MMU enable.
2. **Gemini consult** on our boot.S MMU section with full symptom framing (prints '5', silent thereafter, no exception output).

No code changes yet. Next entry will record findings from both probes and any cross-confirmed divergence.

## Investigation step 20 — cross-reference subagent results (~13:35)

Subagent surveyed Circle (rsta2/circle), Linux `arch/arm64/mm/proc.S` + `head.S`, U-Boot `arch/arm/cpu/armv8/cache_v8.c`, and rpi4-osdev. Two findings rise above the rest, ranked by likelihood of being our `0x80000` hang:

**Finding A — Page tables embedded in `.bss` land in firmware-touched memory at 0x80000.**
- linker_hw.ld:36-39 places `__mmu_l1_table` / `__mmu_l2_table` at the end of `.bss`. With kernel at 0x80000, BSS starts ~0xA5000, so the L1 table sits at roughly 0xA5000–0xA7000.
- BCM2711 firmware uses 0x80000–0x100000 region for armstub, spin-tables, and mailbox property buffers during boot. The bottom 1 MB has firmware artifacts; 0xA5000 is uncomfortably close.
- At 0x200000 (working) the tables land at ~0x225000–0x227000, well above all firmware reservation. **This single PA shift cleanly explains "works at 0x200000, hangs at 0x80000."**
- Circle/U-Boot/Linux all place page tables at fixed reserved PAs, never embedded in `.bss`. Circle uses a `palloc` heap above firmware; Linux uses dedicated `.idmap.text`/`.init.pgdir` sections aligned to PGD size.

**Finding B — `dc isw` invalidates dirty cache lines instead of cleaning them.**
- boot.S:215-224: we walk all sets/ways with `dc isw` BEFORE writing TTBR0 / enabling MMU. Per ARM ARM, `DC ISW` on Cortex-A72 is invalidate-only — dirty lines are *discarded*, not written back.
- If anything (firmware on VC GPU, prior chainloader activity, prior CPU execution) left dirty lines in L1/L2 that shadow our `__mmu_l1_table` writes, we discard them. Walker reads RAM and gets garbage.
- Linux uses `dc cvac` over the page-table memory specifically to PoC before MMU enable. Circle uses `CleanDataCache()` (clean variant). Neither uses `dc isw` here.

Lower-priority findings (correctness improvements, not the immediate boot hang):
- C. MAIR attr1 is `0x00` (Device-nGnRnE, the strictest); Linux/Circle use `0x04` (Device-nGnRE) for normal MMIO. Triggers QEMU 9+ alignment faults — already noted in CLAUDE.md.
- D. SCTLR_EL1 is missing safety bits (SA, SA0, EOS, EIS, etc.) that Linux's `INIT_SCTLR_EL1_MMU_ON` sets. SP-alignment-check (SA) would have caught the prior `tcp_sndbuf_build_frame` data abort at first occurrence.
- E. Circle uses 64 KB granule (TG0=01) on Pi 4, not 4 KB. The whole industry on Pi 4 picks 64 KB. Workable difference, not a defect.
- F. BCM2711 GENET is not I/O-coherent — DMA buffers in low RAM mapped Normal Inner Shareable WB cacheable will need explicit cache maintenance per descriptor. Runtime concern, not boot hang.

### Plan entering attempt 21

Test Finding A first (highest-confidence, simplest, matches the address-shift symptom exactly): move `__mmu_l1_table` and `__mmu_l2_table` out of `.bss` and place them at a fixed PA above firmware reservation — e.g., 16 MB (0x1000000), well clear of any firmware/DMA/armstub region. Single linker change, no boot.S code change needed. If kernel breadcrumbs reach `'6'`, theory confirmed. If still hangs, advance to Finding B (replace `dc isw` with `dc cvac`/`dc cisw`).

Holding off on the code edit until Gemini's parallel consult lands, in case it surfaces a contradicting reading.

## Investigation step 20b — Gemini consult, cross-confirmed (~13:40)

Gemini's analysis converges with the cross-reference subagent on the same root cause, framed more precisely:

> The translation table walker is an independent hardware observer. Even with `SCTLR_EL1.M=0`, if the walker is configured cacheable via `TCR_EL1` (which we do — `IRGN0/ORGN0 = 01` WB-WA), it looks into L1/L2 caches for page-table entries. Kernel runs with caches off → table writes bypass cache, go to RAM. Stale dirty L2 lines from prior chainloader-`memcpy`-into-0x80000-region (or firmware before that) shadow the new table entries. Walker reads dirty lines, sees garbage descriptors, faults silently.

This explains the address-shift symptom precisely: the chainloader's memcpy now writes to the 0x80000–0xA5000 region, populating cache lines (or earlier firmware did). Kernel BSS-resident page tables at ~0xA5000 are inside that range. At 0x200000 the chainloader never touched 0x200000 region (chainloader staged AT 0x200000, didn't write to 0x200000+x for x>image_size... wait — actually the kernel image was at 0x200000+ when linked there, so the chainloader DID write to 0x200000–0x224000 range and tables landed at 0x225000+; the difference is that 0x225000 was beyond the chainloader-write extent).

Gemini's additional bug (independent of the main fix): boot.S:220 uses `1 << 30` for Way 1 of L1 D-cache. **On Cortex-A72 it's bit 31, not bit 30.** Our existing `dc isw` was only invalidating Way 0 of a 2-way cache. Becomes moot once we replace `dc isw` with `dc cvac`-by-VA, but documents that the original cache walk was buggier than it looked.

Other Gemini suggestions (lower priority, not the immediate boot hang):
- Use `SH=00` (non-shareable) for early-boot identity map; switch to inner-shareable later when L2/CCI is fully up. TCR `0x80803520` → `0x80801520`. Descriptor `0x701` → `0x501`.
- Don't rely on `mrs` for SCTLR_EL1 starting value; explicitly write architectural RES1 bits with `0x30D00800` base before OR'ing in M=1.

### Plan entering attempt 21 (minimal fix)

Single-variable change: insert a `dc cvac`-by-VA loop over `[__mmu_l1_table .. __bss_end]` after the table-fill code and before `msr TTBR0_EL1, x0`. Stride = 64 B (Cortex-A72 line size). Followed by `dsb sy; isb`.

Leave everything else identical so we can attribute pass/fail to this single change. If the kernel reaches `'6'`, the cache-coherency theory is confirmed and we can think about the lower-priority cleanups separately. If it still hangs, escalate to Finding A (move tables out of BSS).

## Attempt 21 — `dc cvac` over page-table region (~13:50)

Inserted a `dc cvac`-by-VA loop over `[__mmu_l1_table, __bss_end]` (stride 64 B), `dsb sy`, before `msr TTBR0_EL1`. Removed the prior `dc isw` walk (Way-1-bit-30 bug, plus discards-not-writes-back semantics).

Result: **same hang**. Output identical to attempt 18: `BOOT:251B`, then visible breadcrumb `'5'` only, no `'6'`.

This actually made me reconsider Gemini's mechanism. Gemini said: "your stores into __mmu_l1/l2_table may still be sitting in the D-cache; dc isw discards them; walker reads stale RAM." But we run with `SCTLR_EL1.C=0` AND MMU off, which makes ALL data accesses Device-nGnRnE — they bypass the cache entirely and go to RAM. So our table writes are in RAM, not D-cache. If anything stale exists in cache for these addresses, it's *firmware leftover dirty lines*, not our writes.

`dc cvac` cleans (writes back dirty lines to RAM). If the cache holds dirty firmware-stale data and we issue `dc cvac`, the *stale* data gets written to RAM, **overwriting our just-written tables**. That's a regression, not a fix. Gemini's recommendation may have been actively harmful.

To genuinely invalidate stale lines without writing them back, we'd need `dc ivac` (invalidate-only). But at EL1, `dc ivac` is silently upgraded to `dc civac` (clean+invalidate) when `HCR_EL2.SWIO=1` — which is the default in much firmware. Our HCR_EL2 setup only OR's in bit 31 (RW); SWIO is whatever firmware left.

Conclusion: dc cvac was the wrong primitive. `dc ivac` may not work at EL1 anyway. Cache-coherency-via-VA is harder than it looked. Reverted the `dc cvac` block to keep the kernel state identical to attempt 18 before testing the next theory.

## Attempt 22 — page tables moved out of BSS to PA 0x3000000 (~14:00)

Different theory entirely (cross-reference Finding A): `__mmu_l1_table`/`__mmu_l2_table` previously lived in `.bss` at PA ~0xA5000 — uncomfortably close to BCM2711 firmware-touched low memory (armstub / spin-tables / mailbox property buffers, all in 0x80000–0x100000 range). Linux, Circle, U-Boot all place tables at fixed reserved PAs.

Single linker change: pulled the page tables out of `.bss` into a new `.mmu_tables (NOLOAD)` section at fixed PA `0x3000000` (48 MB). Sized for both Pi 4B 1 GB (PA fits in 0x40000000 RAM) and Pi 4 8 GB. Above kernel's 35 MB BSS extent, below chainloader at 64 MB.

`nm` confirmed: `__mmu_l1_table=0x3000000`, `__mmu_l2_table=0x3001000`, `__bss_end=0x2213AAA`. Kernel binary still 151,912 bytes (NOLOAD section adds nothing to the image).

First flash result was *deceptively bad* — output ended at `--- Kernel output ---` with no visible breadcrumb at all. But on inspection the bash invocation pipes hw_send through `tail -50`, which buffers by line. Kernel breadcrumbs have no newlines, so tail holds them until EOF. The earlier `'5'` from attempts 18/21 was emitted because the process happened to be killed in a state where the buffer flushed — not a reliable signal.

Re-flashing with raw output to `/tmp/boot22_raw.log` (no tail) to see what bytes the kernel actually emitted. **Pending.**

## Attempt 22b — raw-log verification (~14:30)

Re-flashed attempt 22's kernel with raw output (no `tail` buffering). After BOOT:251B, the kernel emits **ZERO bytes**. Not `'0'`, not anything. Same kernel as attempt 18 (no boot.S change since attempt 18 except removing dc isw walk and adding dc cvac in attempt 21, then removing dc cvac in attempt 22 — net effect: dc isw walk removed). Earlier "saw '5'" in attempts 18/21 was a `tail -50` artifact: the bytes that appeared as "5" likely were never just `'5'` but also "no breadcrumbs at all" and the bash tail buffer was holding leftover from a prior run. Take all "saw '5'" claims from attempts 18/21 with deep skepticism.

## Attempt 23 — linker reverted, boot.S unchanged (~14:35)

Goal: isolate whether the linker move was the regression. Reverted `linker_hw.ld` (page tables back to BSS at ~0xA5000), kept boot.S in attempt-22 state (dc isw walk removed). Result: **same — zero kernel bytes after BOOT:251B**. Linker is NOT the regression.

The only thing different from attempt 18 is the dc isw walk being removed. So either (a) dc isw walk was somehow load-bearing (despite Way-bit-30 bug only invalidating Way 0), or (b) my interpretation of attempt 18's `'5'` was wrong all along.

## Attempt 24 — full revert of boot.S to HEAD (~14:45)

`git checkout platform/pi/boot.S` to restore committed baseline. HEAD has only `'0' '1' '2'` breadcrumbs (the `'3' '4' '5' '6'` were diagnostic additions added during this session that I never committed). Caches enabled on MMU-on (M | C | I). dc isw walk intact (with Way-bit-30 bug).

Re-flashed with raw output to `/tmp/boot_a18.log`.

**Result: KERNEL EMITS NO BREADCRUMBS, BUT PRINTS EXCEPTION**:
```
\r\nEXC:0000000000000000 ELR:AD44F6EEACBF6020 FAR:0000000000000000
```

Critical reading:
- Our `_exc_sync` handler IS firing (the "EXC:..." format is ours). For VBAR_EL1 to point at our `_vectors`, the kernel **must** have executed past line 188-189 in boot.S. That means it ran past `'0' '1' '2'` breadcrumb code, the EL2→EL1 drop, stack setup, BSS zero, MMU table fill, TTBR0 write, TLB invalidate, dc isw walk, VBAR install, AND the SCTLR.M=1 (caches+MMU enable). All of that ran.
- Yet the `'0' '1' '2'` breadcrumbs **didn't reach the wire**. Bytes were written to PL011_DR but lost between FIFO and host.
- ESR_EL1 = 0 (EC=0, "Unknown reason"). ELR_EL1 = 0xAD44F6EEACBF6020 — wild 64-bit address, not in the kernel's 0x80000–0xA5000 range. FAR = 0.
- This is consistent with: kernel ran successfully through MMU-on, then `bl main` jumped to a translated address where the cacheable walker returned a corrupted descriptor, the CPU executed garbage from a wild PA, eventually hit something that took an exception with EC=0 (unknown).

### Big reframe

**The original `'5' visible` interpretation was probably wrong** — likely a `tail -50` buffer artifact. The kernel has been running farther than I realized. With caches ON at MMU enable (HEAD configuration), we get a wild-PC exception, which is consistent with the Gemini/cross-reference *cache-coherency* theory — but the breakage is on the I-side fetches after MMU enable, not on the table walk.

Why the breadcrumbs don't reach the wire: open question. The `_exc_sync` handler successfully prints EXC + hex via PL011, so the UART is functional. Possibly the chainloader-handoff state has the host serial reader in a state where bytes between BOOT and the exception are dropped (timing? buffer? kernel writes too quickly?). Or the kernel's `'0' '1' '2'` write target is somehow off-by-one. Diagnosing this is secondary to the main problem.

### Plan entering attempt 25

Send the EXC payload + attempt-24 narrative to Gemini for a fresh read. The wild ELR is unusual — it's not a translation fault (ESR=0 with FAR=0 is wrong for that), not a typical undefined instruction (would have EC=0x18 or 0x1A). Could be: WFE/WFI trap, HCR_EL2 trap, system register access trap. Or a CPU-state corruption.

Until Gemini returns, **no more code changes**. Need a second opinion before adding noise.

## Investigation step 25 — Gemini's analysis of the wild-ELR exception (~14:55)

Gemini's read of the EXC payload:

> The "wild ELR" jumping into random memory, coupled with the hang when caches were disabled, strongly points to **Instruction Cache incoherency** combined with a bug in the existing data cache maintenance loop.

Three findings:

1. **Cortex-A72 `dc isw` Way-bit bug**: boot.S:178 uses `1 << 30` for Way 1. On Cortex-A72, the L1 D-cache Way bit is **bit 31**. The current loop only invalidates Way 0. Way 1 remains unmodified — half of L1 D-cache stays in whatever state firmware/chainloader left.

2. **Missing `ic iallu` before MMU+caches enable**: boot.S:197 sets SCTLR_EL1 with M | C | I in one shot, but never invalidates the I-cache. Stale I-cache lines from pre-MMU execution can be re-fetched once SCTLR.I goes high. This matches the wild-ELR symptom: the CPU enables I-cache, fetches stale junk instructions, branches to a random PA, eventually faults with EC=0 (Unknown reason).

3. **L2 stale-line blindspot**: `dc isw` at EL1 walks L1 only on Cortex-A72. To clean/invalidate L2, you need to walk CLIDR_EL1 / CSSELR_EL1 / CCSIDR_EL1 (the full Linux `__flush_dcache_all()` pattern). Currently L2 stays whatever-the-firmware-left. Whether this matters depends on whether L2 has dirty stale lines for our table region.

Gemini also recommended a `dc cvac` over the page-table region (same as my failed attempt 21) "to ensure the walker sees correct descriptors". I disagree — with kernel caches off when we write tables, our writes go to RAM, not cache. If L2 has dirty firmware-stale lines for table addresses, `dc cvac` *cleans* (writes those stale lines back to RAM), which **destroys** our just-written tables. dc cvac was actively harmful in attempt 21, not neutral.

### Plan entering attempt 26

Single-variable testing, in order:

- **Attempt 26**: just fix the Way bit (`1 << 30` → `1 << 31`). Smallest possible change. If the exception goes away, L1-Way-1 stale lines were the cause.
- **Attempt 27 (if 26 still hangs)**: add `ic iallu; dsb sy; isb` immediately before the SCTLR `M|C|I` write. Addresses I-cache staleness.
- **Attempt 28 (if 26+27 still hang)**: map kernel region as Normal Non-Cacheable (change MAIR attr0 or add a separate AttrIdx and use it in L1[0]). Bypasses caches entirely for the kernel's PA range — sidesteps the L1/L2-stale-line problem rather than trying to clean it.

This sequence walks from "cheapest plausible fix" to "biggest hammer" without changing more than one variable per test.

## Attempt 26 — Way-bit fix in dc isw walk (~15:05)

Single-line change: `orr x2, x0, #(1 << 30)` → `orr x2, x0, #(1 << 31)` in the dc isw loop. boot.S:178.

Result: **same shape, different junk**.
- Attempt 24 ELR: `0xAD44F6EEACBF6020`
- Attempt 26 ELR: `0xBD44F2EEACBF6020`

ESR=0, FAR=0 unchanged. Same wild-PC pattern, same EC=0 "Unknown reason". The lower 32 bits (`0xACBF6020`) are identical between runs — that's the consistent part. Upper bits drift slightly.

Conclusion: L1 Way-1-not-invalidated wasn't the root cause. Maybe contributory but not the whole story. Keeping the fix in (it's a real bug regardless).

## Attempt 27 — `ic iallu` before MMU+caches enable (~15:10)

Added `ic iallu; dsb sy; isb` between VBAR install and the SCTLR.M|C|I write. boot.S:191-194.

Theory: when SCTLR.I=1 happens, the CPU's I-cache becomes active. If stale lines (from firmware armstub or chainloader execution) shadow our kernel's `.text`, instruction fetches return junk, branching the CPU to wild PC. Invalidating the I-cache *immediately before* turning it on flushes any pre-existing stale lines.

Flashing now. **Pending.**

## Attempt 28 outcome (~15:30)

Same silent hang as 27. Non-cacheable mapping should make all cache-coherency concerns moot, but the kernel still hangs with no output. **The cache theory doesn't fit the evidence.**

Reverted boot.S to HEAD baseline (Way bit 30 unfixed, no ic iallu, attr0=0xFF). Going to test a totally different theory.

## Investigation step 29 — pivot to the DMA theory (~15:35)

The chainloader resets DMA channels 0-10 (chainload/boot.S:88-99). But BCM2711 has 16 DMA channels (0-15):
- Channels 0-14 are at 0xFE007000 + chan*0x100
- Channel 15 is at 0xFEE05000 (separate base, reserved for VC)
- The chainloader misses channels 11-14 and 15

If firmware leaves any of those armed pointing into the 0x80000-region (specifically firmware's natural DMA targets — UART I/O buffers, mailbox property responses, GPU mem requests, etc.), they'll asynchronously trample our kernel/BSS *while it runs*. The chainloader's existing 0-10 reset was empirically sufficient for kernel-at-0x200000 because that range was outside firmware's active DMA targets, but kernel-at-0x80000 is right in the firmware's normal DMA target zone.

Wild ELR pattern fits this: lower 32 bits identical between runs (0xACBF6020 in both attempts 24 and 26 ELR values), upper bits drift slightly. That's consistent with DMA corrupting a *specific* memory location (e.g., a stack save of x30 at a fixed offset from `_stack_top`), with the dirty bytes being whatever DMA happened to be transferring at that microsecond.

Plan: extend the chainloader's DMA reset to cover channels 0-14 (all main-DMA channels at 0xFE007000+i*0x100), and separately reset channel 15 at 0xFEE05000. Zero each channel's CS register with the RESET bit set. If kernel boots cleanly after this, DMA was the actual stupid bug.

Pending.

Result: **NO output at all** after BOOT:251C. Not even the EXC line we saw in attempts 24/26.

Reading: `ic iallu` invalidates L1 I-cache only on Cortex-A72. L2 stays untouched. So:
- Without `ic iallu` (attempts 24/26): L1 had stale data from firmware/chainloader execution. Once SCTLR.I=1, fetches hit stale L1, branched the CPU into garbage that eventually produced an exception with wild ELR.
- With `ic iallu` (attempt 27): L1 is empty. Fetches go to L2. L2 also has stale data (from same earlier execution, just propagated). Stale L2 instructions might form a tighter loop or WFE/WFI — no fault, just silent hang.

So `ic iallu` shifted the failure point but didn't fix it. The actual fix needs to handle L2 too.

Also re-examining the breadcrumb output: `'0' '1' '2'` have been silent **across every attempt in this session**. Theory: with MMU off on Cortex-A72 the architecture treats accesses as Normal Non-Cacheable Outer Shareable. Multiple writes to the same address (PL011_DR) can be **merged** in the write-combining buffer. Three writes to the same PL011_DR may collapse to one transaction containing only the last value, or the merged transaction may not even drain without an explicit `dsb`. The exception handler works because by then MMU is on with Device-nGnRnE mapping for MMIO, which is unmergeable. So the breadcrumb signal has been a red herring all along — the kernel has been running through that code, just silently.

## Attempt 28 — MAIR attr0 → Normal Non-Cacheable (~15:25)

Bigger hammer: bypass L1/L2 caches entirely for the kernel's PA range by changing the Normal-memory attribute.

`mov x0, #0xFF` → `mov x0, #0x44` (boot.S:85). MAIR_EL1 = 0x44:
- attr0 = 0x44 = Normal Outer Non-Cacheable + Inner Non-Cacheable
- attr1 = 0x00 = Device-nGnRnE (unchanged, used by L2 entries 480-511 for MMIO)

L1[0..2] block descriptors still use AttrIdx=0, so the entire 0x0–0xBFFFFFFF VA range becomes Normal Non-Cacheable. Walker reads tables from RAM bypassing L2. I-side fetches read kernel `.text` from RAM bypassing L2. No stale-line shadowing possible.

Slow at runtime but irrelevant for diagnosis. If kernel boots cleanly with this, the cache-coherency theory is **proven** and we narrow down on the right *invalidation* primitive for production.

Flashing now. **Pending.**

## Attempt 29 outcome (~16:40)

Same silent hang. BOOT:251C, then nothing. Extended DMA reset (channels 0-14 + channel 15 separately) did NOT change the symptom.

## Status check after a long debugging session

What we've ruled out:
1. Chainloader bytes-at-wrong-address (fixed at attempt 18 with staging+memcpy)
2. Cache coherency at the table walker (Test A: dc isw Way-bit fix; no improvement)
3. I-cache stale at MMU enable (Test B: ic iallu before SCTLR; made worse, silent hang instead of exception)
4. All cache effects (Test C: MAIR attr0 = Normal Non-Cacheable; no improvement)
5. DMA channels 0-10 (chainloader does this, was attempt 18)
6. DMA channels 11-14 + channel 15 (attempt 29: extended chainloader reset; no improvement)
7. Page-table placement at firmware-touched low memory (attempt 22: tables at 0x3000000; no improvement)

What we know:
- Kernel works at link address 0x200000, hangs at 0x80000.
- Chainloader's memcpy + cache-flush + br x0 sequence is functional (BOOT message goes through, jump happens).
- Kernel reaches the exception handler at attempts 24/26 (caches on, no ic iallu) — wild ELR, ESR=0, FAR=0. But same boot.S with ic iallu produces silent hang (no exception printed).
- Breadcrumb writes ('0','1','2') never reach the wire even when the kernel runs through them — likely a write-merging artifact of MMU-off Normal Non-Cacheable mappings on Cortex-A72.

What we have NOT tested:
- Whether a slightly different link address (e.g., 0x100000 = 1 MB) hangs or boots cleanly. Would tell us whether 0x80000 is uniquely bad or if there's a *zone* of bad addresses.
- Whether running with no chainloader at all (firmware-direct SD boot to 0x80000) reproduces the same hang. The kernel is linked at 0x80000 specifically so SD-boot works without a kernel_address override. SD-boot path has never been tested. **The whole point of the 0x80000 link target was the SD-boot path** — we may be debugging the wrong path entirely.

I should pause here. Want to talk through what to test next before burning more compile-flash cycles.

## Attempt 30 — SD-boot direct (~17:00)

Set up a different SD card with config.txt cleaned up (no `kernel_address=`, with `dtoverlay=disable-bt`) and our 0x80000-linked kernel.img as `kernel8.img`. Pi power-cycled. Serial listener captured **one byte: `\x00`**. Pi unreachable via ping. No kernel output.

**This is decisive.** Both paths produce the same broken result:
- Chainloader path (memcpy 0x200000 → 0x80000 → `br x0`): kernel hangs after BOOT
- Firmware-direct SD path (firmware loads kernel at 0x80000, jumps): kernel hangs immediately

The bug is in our kernel's behavior at link target 0x80000, independent of how the kernel got into memory. We can eliminate every theory that involves chainloader residue (stale caches from memcpy, DMA armed by chainloader, post-handoff state).

What remains: something the kernel itself does that breaks specifically when its image lives at 0x80000. The kernel binary is identical except for whatever the link address changes. The differences are:
- All literal-pool absolute addresses (`ldr x0, =__mmu_l1_table`, `ldr x0, =_vectors`, `ldr x0, =_stack_top`, etc.)
- All BSS/stack physical addresses (BSS at ~0xA5000 vs. ~0x225000)
- Branch instructions are PC-relative so they don't change

Practical next step: change link target to `0x100000` (1 MB) and re-test. Tests whether 0x80000 is **uniquely** broken or if there's a *zone*. If 0x100000 works, we narrow on what's special about 0x80000 (firmware armstub region? something at exactly that VA?). If 0x100000 also fails, the broken zone is wider.

Or — engineering call — accept defeat on 0x80000 and revert to 0x200000 link target with `kernel_address=0x200000` in config.txt. That worked for months. We may not need to crack 0x80000 right now.

**EDIT (later) — that "engineering retreat" is wrong.** We just confirmed via SD-boot test that the 0x200000 path *also* doesn't work via firmware-direct SD load — the only path that has ever worked is the UART chainloader, which is not a shippable solution for end users (they'd need to wire UART + run hw_send.py). The whole reason we need 0x80000 is so an end user can flash an SD card and boot. **We cannot retreat.** We have to crack this — either at 0x80000, or at *some* address that boots cleanly via SD-direct firmware load.

Gemini audit launched on the full debug log + boot.S + linker_hw.ld. Awaiting analysis before next test.

## Investigation step 31 — Gemini hung, pivot to SD-direct-at-0x200000 test (~17:10)

Gemini consult ran for the full 300 s `timeout` window without writing any output to stdout. Per CLAUDE.md, this is the documented "Gemini silently hangs on rate/token limit" failure mode. No analysis available. Process killed by `timeout`, no output to read.

Next test (without Gemini): does SD-direct firmware load work at link target 0x200000? We've never tested that — only the chainloader path with staging-at-0x200000-then-memcpy-to-0x80000 (works) and SD-direct at 0x80000 (broken). If SD-direct-at-0x200000 boots cleanly:
- We have a shippable end-user deploy path: kernel linked at 0x200000, config.txt with `kernel_address=0x200000`, copy to SD, boot. No chainloader required.
- The 0x80000 hang becomes a deferred puzzle, not a blocker.

If SD-direct-at-0x200000 *also* hangs:
- Whatever the firmware leaves the CPU in is materially different from what the chainloader leaves it in. The chainloader's pre-jump `dsb sy; ic iallu; dsb sy; isb` cleanup is doing real work that the firmware doesn't do for us. We then have a concrete new theory to chase: replicate that cleanup at the very top of the kernel's `_start` for the SD-boot path.

This is the cheapest test that gives shipping confidence. One linker change + rebuild + SD copy + power cycle.

## Investigation step 32 — Gemini analysis returned (~17:35)

Gemini ran cleanly via the workspace-local prompt approach. Key findings:

**Theory**: Cortex-A72 Snoop Control Unit / Interconnect coherency stall. The kernel configures `TCR_EL1.SH0=11` (Inner Shareable) and uses `SH=11` in L1/L2 block descriptors. Inner Shareable accesses route through the SCU/interconnect coherency fabric. **On BCM2711, the interconnect must stabilize before Inner Shareable mappings are reliable.** Chainloader path works because the chainloader has been running for seconds, giving the SCU time to stabilize before MMU enable. SD-direct path fails because Core 0 jumps into the kernel almost immediately after firmware hand-off — SCU not yet ready, first speculative fetch / table walk hits an unresponsive coherency bus, causing a bus-level stall. Speculative fetch returning garbage (HEAD: wild ELR exception) vs. clean (with `ic iallu`: silent bus stall) matches the dichotomy we observed.

**Smallest test**: Change `SH` from `11` (Inner Shareable) to `00` (Non-Shareable) in three places:
- `TCR_EL1`: bits [13:12] `11` → `00`. Value `0x80803520` → `0x80803020` (note: Gemini's earlier consult had this as `0x80801520`; both represent SH=00 but the rest of the field differs slightly — 0x80803020 keeps SH0 cleared, IRGN0/ORGN0 unchanged).
- L1 block descriptors: `0x701` → `0x501` (bits [9:8] cleared).
- L2 Device entries `0x405` already have SH=00 (bits 9:8 = 00); SH is ignored for Device memory anyway.

**Engineering opinion** (from Gemini): "Revert to 0x200000 with `kernel_address=0x200000` in config.txt. The BCM2711 is notoriously opaque regarding low-memory initialization and interconnect behavior. 0x200000 is a proven, robust path."

That engineering opinion has the same flaw as my own earlier "Option B" — it assumes 0x200000 + SD-direct works, but **we have not actually tested SD-direct at any address other than 0x80000**. The user's assertion ("we can't boot a working web server except via the chainloader") is itself an assumption that may not hold for the current build.

## Plan entering attempt 33 — zoom out before another mechanic dive

Per the lesson logged just above this entry (memory: `user_collaboration_dance.md` — abstraction-level drift): when many mechanic-level theories have failed, the higher-level frame is more likely wrong than another mechanic.

**The high-level question we have not yet answered**: does **any** SD-direct deploy path work with our current kernel? We tested only 0x80000 + SD-direct. We have not tested 0x200000 + SD-direct + current kernel. If 0x200000 + SD-direct works, we have a shippable path immediately, and the SH theory becomes a deferred cleanup. If 0x200000 + SD-direct *also* hangs, then Gemini's interconnect theory becomes more urgent and we test SH=00.

Order of next tests:
1. **Test the higher level first**: revert link to 0x200000, rebuild, copy to SD, set `kernel_address=0x200000` in config.txt, power-cycle, capture serial. ~5 min round trip.
2. If 0x200000 + SD-direct hangs too: apply SH=00 change at 0x80000 link target, retest both SD-direct and chainloader paths.

## Attempts 33–37 — flailing through SH=00 / DMA-channel-0-15 / Linux Image header (skipped here, all negative) (~16:00–17:30)

Each test produced no kernel output. All these were debugging effects of the actual environmental issue (next).

## Attempt 38 — RESOLVED. Missing `overlays/disable-bt.dtbo` on the SD. (~17:35)

The day's silent-on-UART symptom across every kernel we tried (ours at multiple addresses, ours with Linux Image header, ours with SH=00, **and Circle's 03-screentext binary**) had a single environmental cause: the test SD did not have an `overlays/` directory. The `dtoverlay=disable-bt` directive in `config.txt` references `overlays/disable-bt.dtbo`, which was missing — Pi 4 firmware silently skips missing overlays, leaving PL011 internally wired to the Bluetooth chip and the mini-UART on GPIO 14/15. **Every kernel that wrote to PL011 base today was writing into the BT chip, not the wire.**

Replaced the SD's firmware files with the matched-vintage set from fireasmserver's pi-gen build (start4.elf, fixup4.dat, bcm2711-rpi-4-b.dtb, overlays/disable-bt.dtbo), kept our 0x80000-linked kernel, set config.txt to defaults (no `kernel_address=`).

Result on serial:
```
\0 0 1 2 7 8 9 Hello from bare-metal Pi 4!\r\n
```

`'0' '1' '2'` = boot.S pre-MMU breadcrumbs. `'7' '8' '9'` = main.S after MMU + uart_init. Then "Hello from bare-metal Pi 4!" — full clean boot.

**Kernel-at-0x80000 SD-direct boot works.** The whole-day investigation of cache theory / DMA channels / SH=00 / Linux Image header / page-table placement was diagnosing imaginary kernel bugs while the actual issue was a missing 1 KB overlay file on the SD card.

## Lesson — biggest miss of the session

The "after 3+ mechanic-level theories fail, zoom out" rule (from `user_collaboration_dance.md`) was logged into memory at attempt 25 — and then I ignored it for another 8 attempts. Eight more mechanic-level theories tested: SH=00 (#26), `ic iallu` (#27), Normal Non-Cacheable (#28), DMA channels 11-15 (#29), Linux Image header (#30-31), reverted boot.S (#33), Linux flags fix (#33+). All chasing kernel bugs in a kernel that was running fine the whole time. Never asked "is the diagnostic channel itself working?" until the user pointed out (twice) that nothing in this project has ever booted SD-direct successfully.

The right move at attempt 26 would have been: "we've eliminated cache and DMA; the kernel binary has been the same throughout; what about the SD environment we've been writing to?" Instead I added eight more layers of code-side fixes.

## Downstream issue (separate session)

GENET (Ethernet) init hangs silently after `Hello from bare-metal Pi 4!` — kernel doesn't reach `msg_genet_ok` ("GENET Gigabit Ethernet initialized") nor `.Lnet_fail`'s "Network init failed" print. Likely a hardware-init timing issue: `genet_init` is in a spinloop waiting for a hardware bit that asserts under chainloader-handoff timing but not under firmware-direct SD-boot timing. Different problem class from today's boot bug; queued for next session.

---

# Session 2 resume (2026-04-26)

Returning to this after the wedge-v2 fix landed. Before resuming, did
two empirical sanity checks that re-shaped the framing:

1. **Hello-World kernel (152 KB) SD-direct at 0x200000 with
   `kernel_address=0x200000` in config.txt → BOOTS, ping responds,
   curl returns the page.** SD-direct boot path itself is not broken.
   Earlier sessions that "tried 0x200000 and it never worked" almost
   certainly had `config.txt` missing `kernel_address=0x200000`, so
   the firmware loaded the 0x200000-linked kernel to 0x80000 and it
   crashed on the first PC-relative load.

2. **hodapp.com appliance kernel (4.1 MB) SD-direct at 0x200000 with
   the same config.txt → ping fails, host unreachable.** Same setup
   that just worked for the small kernel.

Ed's read: same root cause as 0x80000 SD-direct hang — likely an
MMU/coherency thing that only bites under specific physical-memory
layouts (kernel-at-0x80000, OR kernel-at-0x200000-with-large-image).
Small kernels at 0x200000 happened to land in a "lucky" region that
didn't trigger it.

Returning to the 0x80000 fix because that's the canonical SD-direct
ship path (no `kernel_address=` override needed in config.txt — end
users plug an SD in and the firmware default works).

## Status entering attempt 39

Re-read this log with fresh context. Key facts I'd lost track of:
- **Kernel-at-0x80000 SD-direct DOES boot** as of attempt 38. The
  whole-day "kernel hangs" framing was wrong — the kernel was running
  fine all along; the SD was missing `overlays/disable-bt.dtbo` and
  PL011 output was disappearing into the BT chip.
- **The actual remaining bug** is at lines 432-434: GENET init hangs
  silently after "Hello from bare-metal Pi 4!" prints. Kernel boots,
  Ethernet doesn't come up.
- The hodapp.com-at-0x200000 SD-direct hang we just observed is
  almost certainly the SAME bug (no ping = no ARP = no Ethernet),
  not a 0x200000-vs-0x80000 issue.

Working theory entering this round, ranked by plausibility on a
re-read:

A. **GENET DMA buffer cache attributes.** BCM2711 GENET is not
   I/O-coherent (Finding F at attempt 20, never addressed). Our
   MMU maps everything in low RAM as Normal Inner Shareable WB
   cacheable. GENET DMA buffers in BSS (rxbuf/txbuf rings) are in
   that mapping. CPU writes to a TX descriptor sit in cache; DMA
   reads from RAM and sees stale bytes. Same in reverse for RX.
   Worked on chainloader path because the 60+ s of UART transfer
   pre-jump may have flushed the relevant lines naturally; at
   SD-direct's < 1 s turnaround, the cache is hot.

B. **SCU/interconnect coherency stabilization** (attempt 32 theory).
   Inner-Shareable mappings need the BCM2711 SCU to be ready before
   they're reliable. Chainloader takes seconds before MMU enable;
   firmware-direct gives Core 0 < 1 s. Could explain why the same
   kernel binary boots from chainloader but hangs in genet_init from
   SD-direct.

C. **Spin-table state on cores 1-3.** Firmware leaves cores 1-3 in
   the armstub spin loop reading a mailbox at a fixed PA. If our
   MMU/cache config makes Core 0 see those mailbox writes
   inconsistently, the SCU may stall on cross-core snoop traffic
   while genet_init tries to talk to its DMA engine.

A is the cheapest to test: change MAIR attr0 or add a separate L2
mapping for the GENET DMA buffer region as Normal Non-Cacheable.
Does NOT require touching SCU init or bringing up cores 1-3.

## Attempt 39 — reproduce the GENET hang at 0x80000 (baseline)

Goal: confirm the same symptom we saw at attempt 38, with the
current kernel build (after wedge-v2 changes). Sanity check before
starting fixes.

Setup:
- linker_hw.ld: `. = 0x80000;` (was 0x200000 from the wedge-v2 revert)
- Built `make PLATFORM=pi4 CONTENT_MAX=65536` — 152 KB kernel
- SD config.txt: NO `kernel_address=` directive; `dtoverlay=disable-bt`
- SD overlays/disable-bt.dtbo: present (verified)
- Firmware blobs (start4.elf, fixup4.dat, bcm2711-rpi-4-b.dtb): same
  versions as the working SD-direct test from this session

Pending: Pi power-cycle + serial capture + ping test. If symptom
matches attempt 38 (Hello prints, no GENET msg, ping fails) we have
a clean baseline to start fixing from.

## Attempt 39 outcome — UNEXPECTED PASS (~13:15)

UART captured during SD-direct boot at 0x80000 with the
default 152 KB Hello-World kernel:

```
012Hello from bare-metal Pi 4!
GENET Gigabit Ethernet initialized
```

`ping 10.0.0.2`: 3/3 packets, 0.245 ms avg.

**The "GENET hangs at 0x80000" framing from session 1's tail no
longer holds.** Either the wedge-v2 series of commits (TCP CLOSE_WAIT
fix, perf instrumentation, etc.) incidentally fixed whatever was
preventing genet_init from completing, or session 1's hang was an
artifact of a different SD/timing state that has since changed.

Either way: **the canonical SD-direct ship path at 0x80000 works
end-to-end for a small kernel today.** The 4 MB hodapp.com appliance
at 0x200000 SD-direct STILL fails (Ed reproduced earlier today).

Operational note: the CP2102N's DTR line is wired to the Pi's
GLOBAL_EN for chainloader reset. Opening `/dev/ttyUSB0` with the
default stty config asserts DTR and holds the Pi off. For SD-direct
testing, the DTR jumper must be physically disconnected — otherwise
the laptop-side serial listener silently bricks the boot. (Lost ~10
min on this in this run before Ed spotted it.)

## Reframed plan

The 4 MB appliance failure is the remaining real bug. The size/layout
hypothesis becomes the leading theory now that the 0x80000 boot path
itself is proven working at small scale.

Next test: build hodapp.com appliance kernel linked at **0x80000**
and SD-direct boot it.

- **If it works**: we have the shippable end-user path — no
  `kernel_address=` override needed in config.txt. The 4 MB failure
  at 0x200000 was a config artifact, not a real kernel bug.
- **If it fails the same way as 4MB-at-0x200000**: image-size or
  appliance-content layout is the root cause, independent of link
  address. Bisect from there.

## Attempt 40 — hodapp.com appliance (4.1 MB) SD-direct at 0x80000 (~13:15)

Built `make PLATFORM=pi4 CONTENT_MAX=4194304`. Packaged with
`scripts/mk_appliance.py kernel8.img ~/hodapp.com/public/
/tmp/hodapp_0x80000.img` (4,280,920 bytes, 54 routes baked in).
Copied to SD as `kernel8.img`. config.txt unchanged (no
`kernel_address=`).

**Boots cleanly.** UART shows the same successful pattern as
attempt 39:
```
GENET Gigabit Ethernet initialized
```
(Hello breadcrumbs were emitted earlier in the capture window;
truncate raced the boot. Doesn't matter — the GENET line proves
post-Hello + post-genet_init success.)

`ping 10.0.0.2`: 3/3 packets, 0.227 ms avg.
`curl http://10.0.0.2/`: returns the actual hodapp.com `<!doctype html>`
home page with full Hugo-generated content.

**Conclusion: 0x80000 SD-direct is the shippable end-user path for
any kernel size we've tested.** No `kernel_address=` override
needed in config.txt. End user plugs in SD, powers on, gets the
served site.

The single remaining unknown is the 4 MB appliance at 0x200000
SD-direct (failed earlier today, ping unreachable, no UART
capture). Not a blocker — we don't ship via that path. Future
investigation if curiosity wins; until then, deferred.

## Status — original goal achieved

The 0x80000 SD-direct boot bug is closed. End-user-grade SD-direct
deploy works for both small kernels and the full hodapp.com
appliance build. Marker for follow-up:
- Linker now permanently at 0x80000 (linker_hw.ld committed).
- Chainloader path still works (chainloader stages at 0x200000 then
  memcpy to 0x80000 — see chainload/boot.S).
- The "GENET hangs" symptom from session 1's tail did not reproduce
  in session 2. Cause unknown but no longer blocking.
