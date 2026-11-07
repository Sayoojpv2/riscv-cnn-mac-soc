/* soc_top memory map, memory-mapped I/O helpers, UART and cycle counter. */
#ifndef SOC_H
#define SOC_H
#include <stdint.h>

#define ROM_BASE      0x00000000u
#define RAM_BASE      0x10000000u
#define MAC_BASE      0x20000000u
#define UART_BASE     0x30000000u
#define UNMAPPED_ADDR 0x40000000u   /* no slave: the decoder answers DECERR */

#define MMIO32(addr)  (*(volatile uint32_t *)(uintptr_t)(addr))

/* UART */
#define UART_TXDATA   MMIO32(UART_BASE + 0x0)  /* write stalls while the shifter is busy */
#define UART_STATUS   MMIO32(UART_BASE + 0x4)
#define UART_SCRATCH  MMIO32(UART_BASE + 0x8)

static inline void uart_putc(char c) { UART_TXDATA = (uint8_t)c; }

/* Testbench markers written to UART_SCRATCH: tag in [31:24], payload in [23:0]. */
#define TB_MARK(id)   (UART_SCRATCH = 0xA1000000u | (id))
#define TB_SW_CYC(n)  (UART_SCRATCH = 0xA2000000u | ((n) & 0xFFFFFFu))
#define TB_HW_CYC(n)  (UART_SCRATCH = 0xA3000000u | ((n) & 0xFFFFFFu))

/* PicoRV32 cycle counter (ENABLE_COUNTERS): CSR 0xC00 = cycle */
static inline uint32_t rdcycle(void)
{
  uint32_t c;
  __asm__ volatile("csrr %0, 0xc00" : "=r"(c));
  return c;
}

#endif
