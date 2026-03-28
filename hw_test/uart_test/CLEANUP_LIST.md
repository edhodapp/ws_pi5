# test_kern.S Cleanup List

Baseline: clean GENET init + standard TX test + diagnostic register dumps.

## 1. REMOVE: Firmware clock enable via mailbox (lines 207-230)

Lines 207-230: The `SET_CLOCK_STATE` mailbox call for "clock ID 5 (GENET?)"
was proven irrelevant -- the GENET clock is already enabled by the time we
run. Remove the entire block including the comment, buffer setup, cache
flush, mbox_call, and post-call invalidate.

## 2. REMOVE: EXT_GPHY_CTRL writes (lines 377-401)

Lines 377-401: The three-step EXT_GPHY_CTRL sequence at GENET+0x09C
(CK25_DIS clear, power-down clear + GPHY_RESET assert, GPHY_RESET deassert).
This register controls the internal GPHY which is irrelevant for the Pi 4's
external Broadcom PHY. The PHY is already powered and clocked by the board.
Remove the entire "GPHY power-up" block (Steps 1-3).

## 3. KEEP: EXT_EXT_PWR_MGMT power-down clear (lines 403-413)

Lines 403-413: The EXT_EXT_PWR_MGMT (+0x080) read-modify-write that clears
PHY power-down bits (mask 0x001F1087) and does the PHY_RESET assert/deassert
cycle. This IS the PHY power-up sequence and must stay.

## 4. REMOVE: FAKE_CONS diagnostic test (lines 852-872)

Lines 852-872: The "DIAGNOSTIC: bump PROD without writing a descriptor" block
that increments PROD_INDEX, waits, reads CONS_INDEX to check for fake-consuming,
prints "FAKE_CONS=", then restores PROD_INDEX. This was a one-off diagnostic
to understand TDMA behavior; not a production test.

Also remove `msg_fake` string at line 1213.

## 5. REMOVE: Loopback check after TX (lines 919-934)

Lines 919-934: The "LOOPBACK CHECK" block that prints 'L', waits 1M cycles,
then reads RX PROD_INDEX to see if the TX frame looped back. This was a
diagnostic experiment. The MIB counter reads and register dumps that follow
are the real verification.

## 6. REMOVE: TX descriptor dump (lines 981-993)

Lines 981-993: The "TX descriptor" dump that reads back desc words at
GENET+0x4000. This was debugging the descriptor format during TX bringup,
not a standard diagnostic.

Also remove `msg_txdesc` string at line 1212.

## 7. REMOVE: TDMA CONS/PROD dump after TX (lines 970-979)

Lines 970-979: The CONS/PROD index dump after TX. These are transient DMA
state, not meaningful diagnostics. The MIB counters (TX_GD_PKTS, RX_GD_PKTS)
are the real verification.

Also remove `msg_cons` (line 1210) and `msg_prod` (line 1211).

## 8. REMOVE: TDMA DMA_STATUS dump (lines 964-968)

Lines 964-968: The TDMA DMA_STATUS register dump. This was debugging DMA
init during bringup.

Also remove `msg_dma_stat` string at line 1209.

## 9. REMOVE: UMAC_TX_FIFO_STATUS dump (lines 1009-1013)

Lines 1009-1013: The TXFIFO status register (+0xB3C) dump. This was a
debugging diagnostic for the TX path, not a standard register.

Also remove `msg_txfifo` string at line 1216.

## 10. REMOVE: Pre-init TDMA DMA_CTRL save + dump (lines 372-375, 997-1002)

Lines 372-375: Saving the pre-init TDMA DMA_CTRL value to w28 before any
DMA configuration. This was diagnostic to see what firmware left in the
register.

Lines 997-1002 (labeled "Pre-init TDMA DMA_CTRL value"): The corresponding
dump that prints "PRE_CTRL=" with the saved w28 value.

Also remove `msg_prectrl` string at line 1214.

## 11. REMOVE: Unused `tx_frame` buffer (lines 1225-1227)

Lines 1225-1227: The `tx_frame:` buffer in .data is never used -- the TX
test builds the ARP frame at 0x200000 (RX pool area). Remove it.

## 12. KEEP: These diagnostic dumps (clean set)

The following should remain as the clean diagnostic output after TX:

- **UMAC_CMD** (lines 959-962): Verifies MAC TX/RX enable state and speed bits.
- **TX_GD_PKTS** (lines 938-945): MIB counter confirming MAC transmitted a frame.
- **RX_GD_PKTS** (lines 947-954): MIB counter confirming MAC received frames.
- **PWR / EXT_EXT_PWR_MGMT** (lines 1004-1007): Confirms PHY power-down bits are clear.
- **TBSZ / RBUF_TBUF_SIZE_CTRL** (lines 1015-1019): Confirms TBUF allocation is set.

## Summary of string constants to remove from .rodata

| Line | Label | Reason |
|------|-------|--------|
| 1209 | `msg_dma_stat` | TDMA DMA_STATUS dump removed |
| 1210 | `msg_cons` | TDMA CONS index dump removed |
| 1211 | `msg_prod` | TDMA PROD index dump removed |
| 1212 | `msg_txdesc` | TX descriptor dump removed |
| 1213 | `msg_fake` | FAKE_CONS test removed |
| 1214 | `msg_prectrl` | Pre-init CTRL dump removed |
| 1216 | `msg_txfifo` | TXFIFO dump removed |
