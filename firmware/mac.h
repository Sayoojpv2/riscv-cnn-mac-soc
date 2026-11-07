/* Driver for the CNN MAC accelerator (rtl/mac_axil.sv). */
#ifndef MAC_H
#define MAC_H
#include <stdint.h>
#include "soc.h"

#define MAC_CTRL    0x00u
#define MAC_SAMPLE  0x04u
#define MAC_STATUS  0x08u
#define MAC_RESULT  0x0Cu
#define MAC_ERR     0x10u
#define MAC_ID      0x14u
#define MAC_REG(off) MMIO32(MAC_BASE + (off))

#define MAC_ID_VALUE       0x4D414331u   /* "MAC1" */
#define MAC_CTRL_CLR       (1u << 0)
#define MAC_SAMPLE_CLR     (1u << 31)
#define MAC_STATUS_DONE    (1u << 0)
#define MAC_STATUS_ERR     (1u << 1)
#define MAC_ERR_ADDR       (1u << 0)
#define MAC_ERR_ACCESS     (1u << 1)
#define MAC_ERR_STRB       (1u << 2)
#define MAC_ERR_SAMPLE     (1u << 3)
#define MAC_ERR_ALL        0xFu

/* SAMPLE word fields: [11:0] activation, [19:12] weight (two's complement). */
static inline uint32_t mac_act_field(int32_t a) { return (uint32_t)a & 0xFFFu; }
static inline uint32_t mac_wgt_field(int32_t w) { return ((uint32_t)w & 0xFFu) << 12; }

static inline void     mac_clear(void)       { MAC_REG(MAC_CTRL) = MAC_CTRL_CLR; }
static inline void     mac_push_word(uint32_t s) { MAC_REG(MAC_SAMPLE) = s; }
static inline void     mac_push(int32_t act, int32_t wgt, int clr)
{
  mac_push_word(mac_act_field(act) | mac_wgt_field(wgt) | (clr ? MAC_SAMPLE_CLR : 0));
}
/* RESULT reads are held by the hardware until all issued samples are accumulated. */
static inline int32_t  mac_result(void)      { return (int32_t)MAC_REG(MAC_RESULT); }
static inline uint32_t mac_status(void)      { return MAC_REG(MAC_STATUS); }
static inline uint32_t mac_count(void)       { return mac_status() >> 16; }
static inline uint32_t mac_err(void)         { return MAC_REG(MAC_ERR); }
static inline void     mac_err_clear(uint32_t m) { MAC_REG(MAC_ERR) = m; }

/* Returns 0 when the peripheral identifies itself and comes up idle and error-free. */
static inline int mac_init(void)
{
  if (MAC_REG(MAC_ID) != MAC_ID_VALUE) return -1;
  mac_err_clear(MAC_ERR_ALL);
  mac_clear();
  return (mac_result() == 0 && mac_status() == MAC_STATUS_DONE) ? 0 : -2;
}

#endif
