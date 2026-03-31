# PL011 UART Technical Reference

ARM PrimeCell UART (PL011), as implemented in BCM2711 (Raspberry Pi 4).
Based on ARM DDI 0183G and BCM2711 ARM Peripherals documentation.

## Register Map

| Offset | Name      | R/W | Description                        |
|--------|-----------|-----|------------------------------------|
| 0x000  | UARTDR    | R/W | Data Register (TX write, RX read)  |
| 0x004  | UARTRSR   | R   | Receive Status Register            |
| 0x004  | UARTECR   | W   | Error Clear Register               |
| 0x018  | UARTFR    | R   | Flag Register                      |
| 0x020  | UARTILPR  | R/W | IrDA Low Power Counter             |
| 0x024  | UARTIBRD  | R/W | Integer Baud Rate Divisor          |
| 0x028  | UARTFBRD  | R/W | Fractional Baud Rate Divisor       |
| 0x02C  | UARTLCR_H | R/W | Line Control Register              |
| 0x030  | UARTCR    | R/W | Control Register                   |
| 0x034  | UARTIFLS  | R/W | Interrupt FIFO Level Select        |
| 0x038  | UARTIMSC  | R/W | Interrupt Mask Set/Clear           |
| 0x03C  | UARTRIS   | R   | Raw Interrupt Status               |
| 0x040  | UARTMIS   | R   | Masked Interrupt Status            |
| 0x044  | UARTICR   | W   | Interrupt Clear Register           |
| 0x048  | UARTDMACR | R/W | DMA Control Register               |

Pi 4 UART0 base: `0xFE201000`

---

## UARTDR — Data Register (offset 0x000)

Dual-purpose: writes go to the TX path, reads come from the RX path.
Same address, physically separate hardware paths.

### On WRITE (transmit)

| Bits   | Name | Description                                    |
|--------|------|------------------------------------------------|
| [31:8] | —    | Reserved, ignored                              |
| [7:0]  | DATA | Transmit data. Pushed into TX FIFO/holding reg |

### On READ (receive)

| Bits    | Name | Description                                          |
|---------|------|------------------------------------------------------|
| [31:12] | —    | Reserved, read as zero                               |
| [11]    | OE   | Overrun Error — RX FIFO was full, new char discarded |
| [10]    | BE   | Break Error — line held LOW for full character time   |
| [9]     | PE   | Parity Error — parity mismatch                       |
| [8]     | FE   | Framing Error — stop bit was 0 instead of 1          |
| [7:0]   | DATA | Received data character                              |

**Key behaviors:**
- Error flags [11:8] are **per-character** — stored alongside each byte in the RX FIFO
- **Reading DR pops one entry from the RX FIFO** (destructive read)
- Reading DR when FIFO is empty returns stale/undefined data — always check FR.RXFE first
- Writing DR when FIFO is full silently drops the character — always check FR.TXFF first

---

## UARTRSR / UARTECR — Receive Status / Error Clear (offset 0x004)

### On READ (UARTRSR) — latched/sticky error flags

| Bits   | Name | Description           |
|--------|------|-----------------------|
| [31:4] | —    | Reserved              |
| [3]    | OE   | Overrun Error (sticky) |
| [2]    | BE   | Break Error (sticky)   |
| [1]    | PE   | Parity Error (sticky)  |
| [0]    | FE   | Framing Error (sticky) |

### On WRITE (UARTECR)

Writing **any value** clears all four error flags simultaneously.

RSR flags accumulate (OR) across reads. They stay set until you write to ECR.
Use for "did any error happen since I last checked?" polling.

---

## UARTFR — Flag Register (offset 0x018)

**Read-only.** Live hardware status. No side effects from reading.

| Bits   | Name | Description                          |
|--------|------|--------------------------------------|
| [31:9] | —    | Reserved                             |
| [8]    | RI   | Ring Indicator                       |
| [7]    | TXFE | TX FIFO Empty                        |
| [6]    | RXFF | RX FIFO Full                         |
| [5]    | TXFF | TX FIFO Full (don't write DR)        |
| [4]    | RXFE | RX FIFO Empty (don't read DR)        |
| [3]    | BUSY | UART transmit shift register active  |
| [2]    | DCD  | Data Carrier Detect                  |
| [1]    | DSR  | Data Set Ready                       |
| [0]    | CTS  | Clear To Send                        |

**BUSY behavior:**
- Sets when data is loaded from TX FIFO into shift register
- Remains set while shift register clocks out bits on TXD
- Clears when shift register finishes AND TX FIFO is empty
- TXFE=1 + BUSY=1 means FIFO empty but last byte still on the wire

**With FIFOs disabled (FEN=0):** TXFF and RXFE reflect the 1-byte holding register.
TXFF=1 immediately after writing DR. Clears when byte moves to shift register.

---

## UARTIBRD — Integer Baud Rate Divisor (offset 0x024)

| Bits    | Name     | Description                      |
|---------|----------|----------------------------------|
| [31:16] | —        | Reserved                         |
| [15:0]  | BAUD_INT | Integer part of baud rate divisor |

## UARTFBRD — Fractional Baud Rate Divisor (offset 0x028)

| Bits   | Name      | Description                                |
|--------|-----------|--------------------------------------------|
| [31:6] | —         | Reserved                                   |
| [5:0]  | BAUD_FRAC | Fractional part (0-63), represents N/64    |

### Baud Rate Calculation

```
BAUDDIV = UARTCLK / (16 x baud_rate)
IBRD = floor(BAUDDIV)
FBRD = round((BAUDDIV - IBRD) x 64)
```

**For 115200 baud at 48 MHz:**
```
BAUDDIV = 48000000 / (16 x 115200) = 26.042
IBRD = 26
FBRD = round(0.042 x 64) = 3
```

**Critical:** IBRD/FBRD values are NOT applied until LCRH is written.
The LCRH write latches both divisor registers into the baud rate generator.

---

## UARTLCR_H — Line Control Register (offset 0x02C)

| Bits   | Name | Description                                        |
|--------|------|----------------------------------------------------|
| [31:8] | —    | Reserved                                           |
| [7]    | SPS  | Stick Parity Select                                |
| [6:5]  | WLEN | Word length: 00=5, 01=6, 10=7, **11=8**           |
| [4]    | FEN  | FIFO Enable: 0=1-byte holding regs, **1=16-deep** |
| [3]    | STP2 | Two Stop Bits: 0=1 stop, 1=2 stop                 |
| [2]    | EPS  | Even Parity Select                                 |
| [1]    | PEN  | Parity Enable                                      |
| [0]    | BRK  | Send Break: 1=force TXD LOW continuously           |

**Critical behavior:** Writing LCRH **flushes both FIFOs** and latches IBRD/FBRD.

Common configurations:
- `0x70` = 8N1, FIFOs enabled (WLEN=11, FEN=1)
- `0x60` = 8N1, FIFOs disabled (WLEN=11, FEN=0)

---

## UARTCR — Control Register (offset 0x030)

| Bits    | Name   | Description                              |
|---------|--------|------------------------------------------|
| [31:16] | —      | Reserved                                 |
| [15]    | CTSEn  | CTS hardware flow control enable         |
| [14]    | RTSEn  | RTS hardware flow control enable         |
| [13]    | Out2   | Complement of nUARTOut2                  |
| [12]    | Out1   | Complement of nUARTOut1                  |
| [11]    | RTS    | Request To Send (manual, when RTSEn=0)   |
| [10]    | DTR    | Data Transmit Ready                      |
| [9]     | RXE    | **Receive Enable**                       |
| [8]     | TXE    | **Transmit Enable**                      |
| [7]     | LBE    | **Loopback Enable** (TX feeds back to RX)|
| [6:3]   | —      | Reserved                                 |
| [2]     | SIRLP  | SIR Low-Power mode                       |
| [1]     | SIREN  | SIR Enable                               |
| [0]     | UARTEN | **UART Enable** (master enable)          |

Common configurations:
- `0x0301` = UART enabled, TX+RX enabled
- `0x0000` = everything disabled (for reconfiguration)

**Reconfiguration sequence:**
1. Wait for FR.BUSY = 0
2. Write CR = 0 (disable)
3. Write IBRD, FBRD
4. Write LCRH (latches baud, flushes FIFOs)
5. Write CR = 0x0301 (re-enable)

---

## UARTIFLS — Interrupt FIFO Level Select (offset 0x034)

| Bits   | Name     | Description                                |
|--------|----------|--------------------------------------------|
| [31:6] | —        | Reserved                                   |
| [5:3]  | RXIFLSEL | RX trigger: 000=1/8, 001=1/4, **010=1/2**, 011=3/4, 100=7/8 |
| [2:0]  | TXIFLSEL | TX trigger: 000=1/8, 001=1/4, **010=1/2**, 011=3/4, 100=7/8 |

RX fires when FIFO fills **to or above** level. TX fires when FIFO drains **to or below** level.

---

## UARTIMSC — Interrupt Mask Set/Clear (offset 0x038)

| Bit  | Name   | Description               |
|------|--------|---------------------------|
| [10] | OEIM   | Overrun Error             |
| [9]  | BEIM   | Break Error               |
| [8]  | PEIM   | Parity Error              |
| [7]  | FEIM   | Framing Error             |
| [6]  | RTIM   | Receive Timeout (32 bit-times idle with data in FIFO) |
| [5]  | TXIM   | Transmit (FIFO at/below level) |
| [4]  | RXIM   | Receive (FIFO at/above level)  |
| [3]  | DSRMIM | DSR modem                 |
| [2]  | DCDMIM | DCD modem                 |
| [1]  | CTSMIM | CTS modem                 |
| [0]  | RIMIM  | RI modem                  |

1 = enabled (unmasked), 0 = disabled (masked).

---

## UARTRIS / UARTMIS — Interrupt Status (offsets 0x03C, 0x040)

Same bit layout as IMSC. RIS = raw (hardware condition). MIS = RIS AND IMSC.

## UARTICR — Interrupt Clear (offset 0x044)

Write-only. Same bit layout. Write 1 to clear the corresponding interrupt.
TX/RX interrupts are level-sensitive — clearing only helps if the condition is resolved.
Receive timeout (bit 6) is edge-triggered — clear it and it won't reassert until a new timeout.

---

## UARTDMACR — DMA Control (offset 0x048)

| Bits   | Name     | Description                    |
|--------|----------|--------------------------------|
| [31:3] | —        | Reserved                       |
| [2]    | DMAONERR | Disable DMA on UART error      |
| [1]    | TXDMAE   | TX DMA enable                  |
| [0]    | RXDMAE   | RX DMA enable                  |

---

## Theory of Operation

### TX Path

1. Software checks FR.TXFF = 0 (room available)
2. Writes character to DR[7:0] → enters TX FIFO
3. UART loads byte from FIFO into transmit shift register
4. Shift register serializes: start(0) → data(LSB first) → parity → stop(1)
5. Bits clocked out on TXD at baud rate
6. BUSY remains set until shift register finishes AND FIFO empty

### RX Path

1. UART samples RXD at 16x baud rate (majority voting, 3 samples per bit)
2. Assembles start + data + parity + stop into byte + 4 error flags
3. Pushes into RX FIFO (byte + flags travel together)
4. Software checks FR.RXFE = 0 (data available)
5. Reads DR → pops front entry: data in [7:0], errors in [11:8]

### FIFO vs No-FIFO Mode

| Aspect        | FEN=1 (FIFO)              | FEN=0 (No FIFO)            |
|---------------|---------------------------|-----------------------------|
| TX depth      | 16 entries                | 1-byte holding register     |
| RX depth      | 16 entries                | 1-byte holding register     |
| TX interrupt  | At configurable level     | After each byte             |
| RX interrupt  | At configurable level     | After each byte             |
| Overrun risk  | Low (16-byte buffer)      | High (must read every byte) |
| Throughput    | Burst read/write          | One byte at a time          |

**No-FIFO mode key concern:** At 115200 baud, bytes arrive every ~87us.
If the CPU doesn't read DR within 87us, the next byte causes an overrun.
Any TX work (cl_putc blocking on BUSY) during which RX bytes arrive will
cause overruns unless the TX completes within one byte time.

### Polling Patterns

**TX (one byte, blocking):**
```
1:  ldr  w1, [x19, #FR]       // read flags
    tst  w1, #TXFF             // TX full?
    b.ne 1b                    // yes → wait
    str  w0, [x19, #DR]       // write byte
2:  ldr  w1, [x19, #FR]       // read flags
    tst  w1, #BUSY             // still transmitting?
    b.ne 2b                    // yes → wait
```

**RX (one byte, blocking):**
```
1:  ldr  w0, [x19, #FR]       // read flags
    tst  w0, #RXFE             // RX empty?
    b.ne 1b                    // yes → wait
    ldr  w0, [x19, #DR]       // read byte (pops FIFO)
    and  w0, w0, #0xFF         // mask to data only
```
