/* Link from repo root: riscv32-unknown-elf-gcc ... -T firmware/linker/scr1_shared_ddr.ld
 * TCM/DDR applications are entered by Boot BRAM firmware, not hardware reset.
 * Shared DDR is the reserved carveout, never ordinary Linux RAM.
 */
ENTRY(_start)
MEMORY { SCR1_RAM (rwx) : ORIGIN = 0x7F000000, LENGTH = 0x01000000 }
SECTIONS {
    . = ORIGIN(SCR1_RAM);
    .text : { *(.text.start*) *(.text*) *(.init) *(.fini) } > SCR1_RAM
    .rodata : { *(.rodata*) KEEP(*(.init_array*)) KEEP(*(.fini_array*)) } > SCR1_RAM
    .data : {
        . = ALIGN(16); __data_start = .;
        __global_pointer$ = . + 0x800;
        *(.sdata*) *(.data*) __data_end = .;
    } > SCR1_RAM
    .bss (NOLOAD) : {
        . = ALIGN(16); __bss_start = .;
        *(.sbss*) *(.bss*) *(COMMON)
        . = ALIGN(16); __bss_end = .;
    } > SCR1_RAM
    __heap_start = __bss_end;
    __heap_end = ORIGIN(SCR1_RAM) + LENGTH(SCR1_RAM) - 0x1000;
    .stack __heap_end (NOLOAD) : {
        __stack_bottom = .; . += 0x1000; __stack_top = .;
    } > SCR1_RAM
    ASSERT(__heap_start <= __heap_end, "Firmware overlaps reserved 4-KiB stack")
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
