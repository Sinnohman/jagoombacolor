.section .rodata
.align 4
.global font_lz77
.global font_lz77_end
.global font_lz77_size
font_lz77:
.incbin "font._lz77"
font_lz77_end:
.align 4
font_lz77_size = font_lz77_end - font_lz77

.global fontpal_bin
.global fontpal_bin_end
.global fontpal_bin_size
fontpal_bin:
.incbin "fontpal.bin"
fontpal_bin_end:
.align 4
fontpal_bin_size = fontpal_bin_end - fontpal_bin
