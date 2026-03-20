/*
 * fuzz_net.c -- Fuzzing harness for net_recv_one
 *
 * Reads a packet from stdin, passes it to the AArch64
 * net_recv_one() parser.  Works standalone under qemu-aarch64
 * and under AFL++ with QEMU mode (-Q) for coverage-guided
 * mutation.
 *
 * Build:  make fuzz
 * Run:    qemu-aarch64 -L /usr/aarch64-linux-gnu ./build/fuzz_net < input.bin
 * AFL++:  afl-fuzz -Q -i fuzz/corpus -o fuzz/findings -- ./build/fuzz_net
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
    static unsigned int n = 0x12345678;
    return n++;
}

/* Max Ethernet frame: 14-byte header + 1500-byte payload */
#define ETH_FRAME_MAX 1514

int main(void)
{
    unsigned char buf[ETH_FRAME_MAX];

#ifdef __AFL_HAVE_MANUAL_CONTROL
    __AFL_INIT();
    while (__AFL_LOOP(10000)) {
#endif

    tcp_init();
    tcp_listen(80);
    int n = read(0, buf, sizeof(buf));
    if (n > 0)
        net_recv_one(buf, n);

#ifdef __AFL_HAVE_MANUAL_CONTROL
    }
#endif

    return 0;
}
