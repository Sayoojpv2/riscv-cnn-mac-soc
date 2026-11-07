/* Reset entry: set up the C environment, run main(), report its return value, stop. */
    .section .text.start, "ax"
    .globl _start
_start:
    /* the register file is not reset: start from a known state */
    li    x1, 0
    li    x2, 0
    li    x3, 0
    li    x4, 0
    li    x5, 0
    li    x6, 0
    li    x7, 0
    li    x8, 0
    li    x9, 0
    li    x10, 0
    li    x11, 0
    li    x12, 0
    li    x13, 0
    li    x14, 0
    li    x15, 0
    li    x16, 0
    li    x17, 0
    li    x18, 0
    li    x19, 0
    li    x20, 0
    li    x21, 0
    li    x22, 0
    li    x23, 0
    li    x24, 0
    li    x25, 0
    li    x26, 0
    li    x27, 0
    li    x28, 0
    li    x29, 0
    li    x30, 0
    li    x31, 0
    la    sp, __stack_top

    la    a0, __data_load          /* copy .data initial values ROM -> RAM */
    la    a1, __data_start
    la    a2, __data_end
1:  bgeu  a1, a2, 2f
    lw    t0, 0(a0)
    sw    t0, 0(a1)
    addi  a0, a0, 4
    addi  a1, a1, 4
    j     1b

2:  la    a1, __bss_start          /* zero .bss */
    la    a2, __bss_end
3:  bgeu  a1, a2, 4f
    sw    zero, 0(a1)
    addi  a1, a1, 4
    j     3b

4:  call  main

    /* exit code -> UART SCRATCH as 0xC0xxxxxx (read by the testbench), then halt */
    li    t0, 0x30000008
    li    t1, 0x00FFFFFF
    and   a0, a0, t1
    li    t1, 0xC0000000
    or    a0, a0, t1
    sw    a0, 0(t0)
    ebreak                          /* PicoRV32 asserts trap and stops */
5:  j     5b
