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
extern void timer_pool_init(void *pool, int capacity);
extern void tcp_set_timer_pool(void *pool);
extern void ip_reasm_init(void);
extern void ip_reasm_set_timer_pool(void *pool);

/* Override weak tcp_isn from tcp.S — CNTPCT_EL0 is not available
   under QEMU user mode, so provide a simple counter instead. */
unsigned long tcp_isn(unsigned int lport, unsigned int rport,
                      unsigned int lip, unsigned int rip)
{
    (void)lport; (void)rport; (void)lip; (void)rip;
    static unsigned int n;
    return n++;
}

/* Override weak tcp_init_secret — no CNTPCT_EL0 under user mode */
void tcp_init_secret(void) { }

/* Override weak timer_now/timer_freq — no system counter under user mode */
unsigned long timer_now(void)  { return 0; }
unsigned long timer_freq(void) { return 1; }

/* Max Ethernet frame: 14-byte header + 1500-byte payload */
#define ETH_FRAME_MAX 1514

static char timer_pool[520] __attribute__((aligned(8)));

int main(void)
{
    unsigned char buf[ETH_FRAME_MAX];

#ifdef __AFL_HAVE_MANUAL_CONTROL
    __AFL_INIT();
    while (__AFL_LOOP(10000)) {
#endif

    tcp_init();
    tcp_listen(80);
    timer_pool_init(timer_pool, 16);
    tcp_set_timer_pool(timer_pool);
    ip_reasm_init();
    ip_reasm_set_timer_pool(timer_pool);

    int n = read(0, buf, sizeof(buf));
    if (n > 0)
        net_recv_one(buf, n);

#ifdef __AFL_HAVE_MANUAL_CONTROL
    }
#endif

    return 0;
}
