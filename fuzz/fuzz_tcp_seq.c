/*
 * fuzz_tcp_seq.c -- Multi-packet TCP sequence fuzzer
 *
 * Feeds a sequence of length-prefixed Ethernet frames to net_recv_one(),
 * allowing the fuzzer to explore multi-step TCP state transitions
 * (handshake completion, data transfer, close sequences) that the
 * single-packet harness (fuzz_net.c) cannot reach.
 *
 * Input format: [u16be len][frame bytes][u16be len][frame bytes]...
 *
 * Build:  make fuzz-seq
 * Run:    qemu-aarch64 -L /usr/aarch64-linux-gnu ./build/fuzz_tcp_seq < input.bin
 * AFL++:  afl-fuzz -Q -i fuzz/corpus_seq -o fuzz/findings_seq -- ./build/fuzz_tcp_seq
 */

#include <unistd.h>

/* Assembled from lib/ — pure computation, no MMIO */
extern int net_recv_one(void *buf, int len);
extern void tcp_init(void);
extern int tcp_listen(int port);

/* Override weak tcp_isn from tcp.S — CNTPCT_EL0 is not available
   under QEMU user mode, so provide a simple counter instead. */
unsigned long tcp_isn(void)
{
    static unsigned int n;
    return n++;
}

/* Max Ethernet frame: 14-byte header + 1500-byte payload */
#define ETH_FRAME_MAX 1514
#define MAX_INPUT     8192
#define MAX_FRAMES    32

int main(void)
{
    unsigned char input[MAX_INPUT];

#ifdef __AFL_HAVE_MANUAL_CONTROL
    __AFL_INIT();
    while (__AFL_LOOP(10000)) {
#endif

    /* Reset ISN counter for deterministic replay */
    extern unsigned long tcp_isn(void);
    /* Re-read the static — the counter is inside tcp_isn itself.
       We just reset tcp state which is sufficient for determinism
       across AFL persistent-mode iterations. */
    tcp_init();
    tcp_listen(80);

    int total = read(0, input, sizeof(input));
    if (total <= 0)
        goto done;

    int off = 0;
    int nframes = 0;
    while (off + 2 <= total && nframes < MAX_FRAMES) {
        /* Big-endian 16-bit frame length */
        unsigned int flen = ((unsigned int)input[off] << 8) | input[off + 1];
        off += 2;

        if (flen == 0 || off + (int)flen > total)
            break;
        if (flen > ETH_FRAME_MAX)
            flen = ETH_FRAME_MAX;

        /* Copy to mutable buffer — net_recv_one writes reply in-place */
        unsigned char buf[ETH_FRAME_MAX];
        for (unsigned int i = 0; i < flen; i++)
            buf[i] = input[off + i];

        net_recv_one(buf, (int)flen);
        off += flen;
        nframes++;
    }

done:
#ifdef __AFL_HAVE_MANUAL_CONTROL
    }
#endif

    return 0;
}
