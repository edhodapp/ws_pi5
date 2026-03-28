#!/bin/sh
# GENET dump v2 — skip bad TBUF offsets, DMA first
# Run: sudo sh dump_genet2.sh
B=0xFD580000
d(){ printf "%s=%s\n" "$1" "$(busybox devmem $2)"; }
d UMAC_CMD    $((B+0x808))
d TDMA_CTRL   $((B+0x5044))
d TDMA_STAT   $((B+0x5048))
d TDMA_BURST  $((B+0x504C))
d TDMA_RCFG   $((B+0x5040))
d TDMA_CONS   $((B+0x5008))
d TDMA_PROD   $((B+0x500C))
d TDMA_BFSZ   $((B+0x5010))
d TDMA_START  $((B+0x5014))
d TDMA_END    $((B+0x501C))
d TDMA_RDPTR  $((B+0x5000))
d TDMA_WRPTR  $((B+0x502C))
d TDMA_ARB    $((B+0x506C))
d TDMA_PRI2   $((B+0x5078))
d RDMA_CTRL   $((B+0x3044))
d RDMA_STAT   $((B+0x3048))
d UMAC_MAXFR  $((B+0x814))
d UMAC_MIB    $((B+0xD80))
d TBUF_CTRL   $((B+0x600))
d RBUF_CTRL   $((B+0x300))
d RBUF_TBSZ   $((B+0x3B4))
d EXT_OOB     $((B+0x08C))
d EXT_PWR     $((B+0x080))
