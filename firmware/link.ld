/* Memory layout of soc_top: code and constants in the boot ROM, data/bss/stack in RAM. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
  RAM (rwx) : ORIGIN = 0x10000000, LENGTH = 16K
}

SECTIONS
{
  .text : {
    KEEP(*(.text.start))                 /* reset vector: PROGADDR_RESET = 0 */
    *(.text .text.*)
    *(.rodata .rodata.* .srodata .srodata.*)
    . = ALIGN(4);
  } > ROM

  .data : {                              /* initial values stored in ROM, copied by start.S */
    __data_start = .;
    *(.data .data.* .sdata .sdata.*)
    . = ALIGN(4);
    __data_end = .;
  } > RAM AT > ROM
  __data_load = LOADADDR(.data);

  .bss (NOLOAD) : {
    __bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > RAM

  __stack_top = ORIGIN(RAM) + LENGTH(RAM);
  ASSERT(__bss_end + 1024 <= __stack_top, "less than 1 KiB left for the stack")

  /DISCARD/ : { *(.eh_frame*) *(.note*) }
}
