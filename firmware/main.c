/*
 * Bare-metal test firmware for soc_top (PicoRV32 RV32IM + CNN MAC accelerator).
 *
 * 1. memory and bus self-test, 2. MAC driver self-test (arithmetic, wrap, errors),
 * 3. 5x5 valid convolution of a 28x28 feature map in pure software and on the
 *    accelerator, timed with the cycle counter, 4. comparison of both results with
 *    each other and with the golden reference from scripts/gen_conv_data.py,
 * 5. "RESULT: PASS" / "RESULT: FAIL" on the UART; main() returns the error count.
 *
 * Arithmetic (identical in software and hardware): 12-bit signed activation x
 * 8-bit signed weight -> 20-bit product, 20-bit two's-complement wrap-around sum.
 */
#include <stdint.h>
#include "soc.h"
#include "mac.h"
#include "conv_data.h"   /* generated: CONV_IN_H/W, conv_in[], conv_w[], conv_ref[] */

#define K      5
#define OUT_H  (CONV_IN_H - K + 1)
#define OUT_W  (CONV_IN_W - K + 1)
#define N_OUT  (OUT_H * OUT_W)

static int32_t out_sw[N_OUT];
static int32_t out_hw[N_OUT];

/* ---------------- console ---------------- */
static void put_str(const char *s) { while (*s) uart_putc(*s++); }

static void put_dec(int32_t v)
{
  char buf[11];
  int n = 0;
  uint32_t u = (v < 0) ? 0u - (uint32_t)v : (uint32_t)v;
  if (v < 0) uart_putc('-');
  do { buf[n++] = (char)('0' + u % 10u); u /= 10u; } while (u);
  while (n) uart_putc(buf[--n]);
}

static void put_hex(uint32_t v)
{
  put_str("0x");
  for (int s = 28; s >= 0; s -= 4) uart_putc("0123456789abcdef"[(v >> s) & 0xFu]);
}

static int check(const char *what, int fails)
{
  put_str("  ");
  put_str(what);
  put_str(fails ? ": error(s) " : ": ok\n");
  if (fails) { put_dec(fails); uart_putc('\n'); }
  return fails;
}

/* ---------------- self-tests ---------------- */
static volatile uint32_t ram_word;

static int memory_test(void)
{
  int f = 0;
  volatile uint8_t  *b = (volatile uint8_t *)&ram_word;
  volatile uint16_t *h = (volatile uint16_t *)&ram_word;
  volatile uint32_t *rom = (volatile uint32_t *)ROM_BASE;

  ram_word = 0x11223344u;                 /* word write */
  b[1] = 0xABu;                           /* byte strobe 0010 */
  h[1] = 0xCDEFu;                         /* halfword strobe 1100 */
  f += ram_word != 0xCDEFAB44u;
  f += b[0] != 0x44u || (int8_t)b[1] != (int8_t)0xAB || h[1] != 0xCDEFu;

  uint32_t first = rom[0];                /* ROM is read-only: store gets SLVERR, no change */
  rom[0] = ~first;
  f += rom[0] != first;

  f += MMIO32(UNMAPPED_ADDR) != 0u;       /* decoder: DECERR, read data 0 */
  return check("memory/bus", f);
}

static int mac_selftest(void)
{
  int f = 0;

  f += mac_init() != 0;
  mac_push(-2048, -128, 1);               /* largest product: +262144 */
  f += mac_result() != 262144;
  mac_push(0, 77, 0);                     /* zero activation: counted, adds 0 */
  f += mac_result() != 262144 || mac_count() != 2;
  mac_push(-2048, -128, 0);               /* 524288 wraps to -524288 */
  f += mac_result() != -524288;
  mac_push(2047, 127, 0);                 /* -524288 + 259969 */
  f += mac_result() != -264319 || mac_count() != 4;
  mac_push(-3, 5, 1);                     /* CLR bit: new sum starts with this sample */
  f += mac_result() != -15 || mac_count() != 1;
  mac_clear();
  f += mac_result() != 0 || mac_count() != 0;
  f += check("mac arithmetic", f);

  /* Error reporting: each access below is rejected with SLVERR and flagged in ERR. */
  int e = 0;
  e += mac_err() != 0;
  (void)MAC_REG(0x100);                                  /* unmapped offset */
  e += mac_err() != MAC_ERR_ADDR;
  MAC_REG(MAC_RESULT) = 1;                               /* read-only register */
  e += mac_err() != (MAC_ERR_ADDR | MAC_ERR_ACCESS);
  *(volatile uint8_t *)(MAC_BASE + MAC_SAMPLE) = 5;      /* byte write */
  e += mac_err() != (MAC_ERR_ADDR | MAC_ERR_ACCESS | MAC_ERR_STRB);
  mac_push_word((uint32_t)-5);                           /* unmasked negative: reserved bits */
  e += mac_err() != MAC_ERR_ALL;
  e += mac_count() != 0 || mac_result() != 0;            /* nothing reached the core */
  e += (mac_status() & MAC_STATUS_ERR) == 0;
  mac_err_clear(MAC_ERR_ADDR | MAC_ERR_ACCESS);          /* W1C, partial */
  e += mac_err() != (MAC_ERR_STRB | MAC_ERR_SAMPLE);
  mac_err_clear(MAC_ERR_ALL);
  e += mac_err() != 0 || mac_status() != MAC_STATUS_DONE;
  return f + check("mac error handling", e);
}

/* ---------------- convolution ---------------- */
static inline int32_t wrap20(int32_t x) { return (int32_t)((uint32_t)x << 12) >> 12; }

/* Software reference. The 32-bit sum of 25 products cannot overflow (|sum| < 2^23),
 * so wrapping once at the end equals the hardware's 20-bit wrap after every add. */
__attribute__((noinline))
static void conv_sw(const int16_t *in, const int8_t *w, int32_t *out)
{
  for (int oy = 0; oy < OUT_H; oy++)
    for (int ox = 0; ox < OUT_W; ox++) {
      const int16_t *p = in + oy * CONV_IN_W + ox;
      int32_t acc = 0;
      for (int ky = 0; ky < K; ky++)
        for (int kx = 0; kx < K; kx++)
          acc += p[ky * CONV_IN_W + kx] * w[ky * K + kx];
      *out++ = wrap20(acc);
    }
}

/* Accelerated version: one SAMPLE write per MAC, one RESULT read per output. */
__attribute__((noinline))
static void conv_hw(const int16_t *in, const int8_t *w, int32_t *out)
{
  uint32_t wf[K * K];                     /* weight fields, packed once per kernel */
  for (int k = 0; k < K * K; k++) wf[k] = mac_wgt_field(w[k]);
  wf[0] |= MAC_SAMPLE_CLR;                /* first tap of each window restarts the sum */

  for (int oy = 0; oy < OUT_H; oy++)
    for (int ox = 0; ox < OUT_W; ox++) {
      const int16_t *p = in + oy * CONV_IN_W + ox;
      const uint32_t *q = wf;
      for (int ky = 0; ky < K; ky++)
        for (int kx = 0; kx < K; kx++)
          mac_push_word(mac_act_field(p[ky * CONV_IN_W + kx]) | *q++);
      *out++ = mac_result();
    }
}

static int compare(const char *what, const int32_t *a, const int32_t *b)
{
  int bad = 0;
  for (int i = 0; i < N_OUT; i++)
    if (a[i] != b[i]) {
      if (!bad) {
        put_str("  first mismatch at "); put_dec(i);
        put_str(": "); put_dec(a[i]); put_str(" vs "); put_dec(b[i]); uart_putc('\n');
      }
      bad++;
    }
  put_str("  "); put_str(what); put_str(" mismatches: "); put_dec(bad); uart_putc('\n');
  return bad;
}

int main(void)
{
  int fails = 0;

  put_str("\nriscv-cnn-mac-soc: PicoRV32 RV32IM + operand-isolated CNN MAC\n");
  put_str("self-test\n");
  fails += memory_test();
  fails += mac_selftest();

  put_str("5x5 convolution, "); put_dec(CONV_IN_H); uart_putc('x'); put_dec(CONV_IN_W);
  put_str(" input -> "); put_dec(OUT_H); uart_putc('x'); put_dec(OUT_W);
  put_str(" outputs, "); put_dec(N_OUT * K * K); put_str(" MACs\n");

  TB_MARK(1);
  uint32_t t0 = rdcycle();
  conv_sw(conv_in, conv_w, out_sw);
  uint32_t t1 = rdcycle();
  TB_MARK(2);

  TB_MARK(3);
  uint32_t t2 = rdcycle();
  conv_hw(conv_in, conv_w, out_hw);
  uint32_t t3 = rdcycle();
  TB_MARK(4);

  uint32_t sw = t1 - t0, hw = t3 - t2;
  TB_SW_CYC(sw);
  TB_HW_CYC(hw);

  /* accelerator integrity after the run: last window had 25 samples, no errors */
  int integ = (mac_count() != K * K) + (mac_err() != 0);
  fails += check("accelerator status after run", integ);

  fails += compare("sw vs reference", out_sw, conv_ref);
  fails += compare("hw vs reference", out_hw, conv_ref);
  fails += compare("sw vs hw", out_sw, out_hw);

  put_str("  out[0], out[mid], out[last]: ");
  put_dec(out_hw[0]); put_str(", "); put_dec(out_hw[N_OUT / 2]); put_str(", ");
  put_dec(out_hw[N_OUT - 1]); uart_putc('\n');
  put_str("  checksum: "); {
    uint32_t c = 0;
    for (int i = 0; i < N_OUT; i++) c = (c << 5 | c >> 27) ^ (uint32_t)out_hw[i];
    put_hex(c);
  }
  uart_putc('\n');

  put_str("cycles (rdcycle)\n");
  put_str("  software conv : "); put_dec((int32_t)sw); put_str("  ("); put_dec((int32_t)(sw / N_OUT));
  put_str(" per output)\n");
  put_str("  hardware conv : "); put_dec((int32_t)hw); put_str("  ("); put_dec((int32_t)(hw / N_OUT));
  put_str(" per output)\n");
  put_str("  sw/hw x100    : "); put_dec((int32_t)(100u * sw / hw)); uart_putc('\n');

  put_str(fails ? "RESULT: FAIL\n" : "RESULT: PASS\n");
  return fails;
}
