/*
 * fuzz_tcp_seq.c -- Multi-packet TCP sequence fuzzer
 *
 * Feeds a sequence of length-prefixed Ethernet frames to net_recv_one(),
 * allowing the fuzzer to explore multi-step TCP state transitions
 * (handshake completion, data transfer, close sequences) that the
 * single-packet harness (fuzz_net.c) cannot reach.
 *
 * Input format: [u16be len][frame bytes][u16be len][frame bytes]...
 * Close sentinel: flen==0 triggers tcp_close on first ESTABLISHED/CLOSE_WAIT conn.
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
extern int tcp_close(void *conn, void *frame);
extern char tcp_conn_table[];
extern void timer_pool_init(void *pool, int capacity);
extern void tcp_set_timer_pool(void *pool);

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
#define MAX_INPUT     8192
#define MAX_FRAMES    32

/* Connection state constants (must match tcp.inc) */
#define TCPS_ESTABLISHED 3
#define TCPS_CLOSE_WAIT  4
#define TCONN_SIZE       128

static char timer_pool[520] __attribute__((aligned(8)));

int main(void)
{
    unsigned char input[MAX_INPUT];

#ifdef __AFL_HAVE_MANUAL_CONTROL
    __AFL_INIT();
    while (__AFL_LOOP(10000)) {
#endif

    /* Reset TCP state for deterministic replay across AFL
       persistent-mode iterations. */
    tcp_init();
    tcp_listen(80);
    timer_pool_init(timer_pool, 16);
    tcp_set_timer_pool(timer_pool);

    int total = read(0, input, sizeof(input));
    if (total <= 0)
        goto done;

    int off = 0;
    int nframes = 0;
    while (off + 2 <= total && nframes < MAX_FRAMES) {
        /* Big-endian 16-bit frame length */
        unsigned int flen = ((unsigned int)input[off] << 8) | input[off + 1];
        off += 2;

        if (flen == 0) {
            /* Close sentinel: trigger tcp_close on first eligible conn */
            unsigned char fin_buf[ETH_FRAME_MAX];
            for (int i = 0; i < 16; i++) {
                unsigned char state = tcp_conn_table[i * TCONN_SIZE];
                if (state == TCPS_ESTABLISHED || state == TCPS_CLOSE_WAIT) {
                    tcp_close(&tcp_conn_table[i * TCONN_SIZE], fin_buf);
                    break;
                }
            }
            nframes++;
            continue;
        }

        if (off + (int)flen > total)
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
