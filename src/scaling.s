@----------------------------------------------------------------------------
@ scaling.s - 1.5x nearest-neighbor tile expansion for Jagoomba Color
@
@ When scaling is active, instead of converting 1 GBC tile -> 1 GBA tile,
@ we convert 2 GBC tiles -> 3 GBA tiles with horizontal 1.5x NN expansion.
@
@ GBC tile data: 2bpp planar, 16 bytes/tile
@   bytes 0-7: plane 0 (low bit), byte n = 8 pixels of row n
@   bytes 8-15: plane 1 (high bit), byte n = 8 pixels of row n
@   pixel value = (plane1_bit << 1) | plane0_bit -> 0-3 (2-bit color index)
@
@ GBA tile data: 4bpp, 32 bytes/tile
@   4 bits per pixel, 8 pixels per row, 8 rows
@   each row = 4 bytes = one 32-bit word
@   pixel 0 in low nibble (bits 0-3), pixel 1 in bits 4-7, etc.
@
@ 1.5x NN expansion pattern for ONE row of 8 pixels:
@   Input:  p0 p1 p2 p3 p4 p5 p6 p7  (8 GBC pixels, 2-bit each)
@   Output: p0 p0 p1 p2 p2 p3 p4 p4 p5 p6 p6 p7 (12 GBA pixels, 4-bit each)
@   Because NN: output ox = input floor(ox * 2/3)
@   ox:  0  1  2  3  4  5  6  7  8  9 10 11
@   ix:  0  0  1  2  2  3  4  4  5  6  6  7
@
@ For TWO GBC tiles (16 input pixels):
@   Tile A: A0 A1 A2 A3 A4 A5 A6 A7
@   Tile B: B0 B1 B2 B3 B4 B5 B6 B7
@   Combined: A0 A1 A2 A3 A4 A5 A6 A7 B0 B1 B2 B3 B4 B5 B6 B7
@   Expanded to 24 output pixels, split into 3 GBA tiles:
@   Tile X (px 0-7):  A0 A0 A1 A2 A2 A3 A4 A4
@   Tile Y (px 8-15): A5 A6 A6 A7 B0 B0 B1 B2
@   Tile Z (px 16-23):B2 B3 B4 B4 B5 B6 B6 B7
@
@ Each GBA row output is a 32-bit word with 8 nibbles.
@
@ Implementation strategy:
@   1. Read 2 GBC tiles (32 bytes) from XGB_VRAM
@   2. For each of 8 row pairs:
@      - Decode plane0 bytes from both tiles (2 bytes)
@      - Decode plane1 bytes from both tiles (2 bytes)
@      - Generate 3 output row words using a precomputed expansion table
@   3. Write 3 GBA tiles (96 bytes) to VRAM
@
@ We use the existing CHR_DECODE table as much as possible.
@----------------------------------------------------------------------------

	.pushsection .text, "ax", %progbits
	.arm

	.global render_tiles_vram_15x
	.global g_scaling_active
	.global g_scale_mode

@----------------------------------------------------------------------------
@ NN expansion table for 1.5x horizontal
@ Maps 16 GBC 2-bit pixels (packed as (plane0<<8)|plane1 bytes) to 24
@ GBA 4-bit pixels packed as 3 words.
@
@ But this table would be huge (256^2 entries). Instead we compute on-the-fly.
@
@ A faster approach: use the CHR_DECODE table to get GBA 4-bit nibbles from
@ the 2-bit input, then expand using a lookup on the 8-pixel row values.
@
@ CHR_DECODE maps an 8-bit byte (8 pixels of one bit-plane) to a 32-bit
@ value where each nibble = bit value repeated across the nibble.
@ So CHR_DECODE[byte] gives pixels0/pixels1 where each nibble is 0 or 0x1.
@
@ From pixels0 (plane0 expanded) and pixels1 (plane1 expanded):
@   dest = pixels1 << 1 | pixels0 -> each nibble = 2-bit color index 0-3
@
@ For 1.5x expansion, we need to rearrange the 8 nibbles from the CHR_DECODE
@ output into 12 nibbles across 3 output words.
@
@ Since CHR_DECODE returns 0x11111111 patterns per bit, we can do:
@   word0 = (pixels0_byte & mask0) | ((pixels1_byte & mask0) << 1) ...
@
@ Actually, the output words are already in GBA 4bpp format from CHR_DECODE.
@ Let me think about this differently.
@
@ We have 8 pixels from one GBC row:
@   planes packed as 2 bytes (plane0 byte, plane1 byte)
@
@ CHR_DECODE converts each plane byte to a 32-bit word with 8 repeated-bit nibbles.
@ Then: gbaWord = plane1_decode << 1 | plane0_decode
@ Result: each nibble = 2-bit color index
@
@ For 1.5x expansion of one row:
@   Read plane0 byte A and plane1 byte A from GBC tile 0
@   Let p0 = CHR_DECODE[plane0_A], p1 = CHR_DECODE[plane1_A]
@   gba0 = p1 << 1 | p0  (GBA pixels 0-7 in the word)
@   (Same for tile B's row -> gba1)
@
@ Now we have two 32-bit words: gba0 (tile A row) and gba1 (tile B row)
@ Each word contains 8 nibbles of 4-bit color data.
@
@ We need to expand 16 pixels (from gba0 and gba1) to 24 pixels.
@ The NN mapping (ox->ix):
@   ox: 0  1  2  3  4  5  6  7  8  9 10 11 |12 13 14 15 16 17 18 19 20 21 22 23
@   ix: 0  0  1  2  2  3  4  4  5  6  6  7 | 8  8  9 10 10 11 12 12 13 14 14 15
@      A0 A0 A1 A2 A2 A3 A4 A4 A5 A6 A6 A7 | B0 B0 B1 B2 B2 B3 B4 B4 B5 B6 B6 B7
@   Source: 0=A0, 1=A1, 7=A7, 8=B0, 15=B7
@
@ For each of 3 output words (8 pixels each):
@   Word 0 (pixels 0-7):  ix: 0 0 1 2 2 3 4 4
@   Word 1 (pixels 8-15): ix: 5 6 6 7 8 8 9 10
@   Word 2 (pixels 16-23):ix:10 11 12 12 13 14 14 15
@
@ To extract/rearrange nibbles from the source words, we can use bit
@ manipulation:
@   word0_nibbles = source word 0, bits corresponding to pixels 0,0,1,2,2,3,4,4
@   = (nibble0, nibble0, nibble1, nibble2, nibble2, nibble3, nibble4, nibble4)
@
@ This is equivalent to taking source word 0, replicating nibbles 0,2,4, and
@ duplicating the nibble sequence pattern through a precomputed mask + shift.
@
@ A simpler approach: use a byte-level lookup table.
@ 256^4 would be huge. But we can process in 4-pixel chunks.
@
@ **Simplest approach: byte-by-byte expansion**
@   For each source byte (2 pixels in 4bpp GBA format), expand to 3 output bytes
@   (3 pixels, but stored one per byte? No, GBA packs 2 pixels per byte)
@
@ Actually, thinking about this more carefully, the simplest practical approach:
@ We unpack from GBA 4bpp to separate bytes, expand, then repack.
@
@ But for ARM assembly, bit manipulation is fast. Let me calculate the expansion
@ using shifts and masks directly on the 32-bit source words.
@
@ Source word W0 (from GBC tile A row):
@   bits 31-0: p7' p6' p5' p4' p3' p2' p1' p0'
@   where pn' = 4-bit nibble for pixel n
@
@ We want output words:
@   Out0: p4' p4' p3' p2' p2' p1' p0' p0'  (but in reversed bit order?)
@
@ Actually GBA nibble order: pixel 0 in bits 0-3, pixel 1 in bits 4-7, ...
@ So W0 = {p7:4, p6:4, p5:4, p4:4, p3:4, p2:4, p1:4, p0:4}
@
@ Desired output:
@   Out0 = {p4:4, p4:4, p3:4, p2:4, p2:4, p1:4, p0:4, p0:4}
@   Out1 = {p10:4 (B2), p9:4 (B2 bit?), ...}
@
@ This requires significant bit rearrangement. Let me use a lookup table approach.
@----------------------------------------------------------------------------

@ Precomputed expansion table
@ For each possible 8-nibble input (tile row), produce 12-nibble output
@ 256^4 would be way too big. 
@
@ Instead: process 4 input pixels at a time, producing 6 output pixels.
@ For each 4-pixel chunk (one half of a source word), we look up the 6-pixel
@ expansion in a small table. 256^2 entries = 65536 entry table, each entry
@ is 1 word... actually each entry needs 1.5 words = 6 bytes for 6 nibbles.
@
@ Or: process 2 input pixels at a time -> 3 output pixels
@ 4-bit * 2 = byte -> 4-bit * 3 = 12 bits, stored in halfword with padding
@ Table: 256 entries (one byte of 2 pixels) -> one 16-bit value (3 pixels)
@ Size: 256 * 2 = 512 bytes. Very manageable!
@
@ Steps per pair of source words (tile A row + tile B row = 16 pixels):
@   1. Split W0 into 4 bytes (each byte = 2 GBA pixels): B3, B2, B1, B0
@   2. Split W1 into 4 bytes: B7, B6, B5, B4
@   3. For each byte string: {B0,B1,B2,B3,B4,B5,B6,B7}, expand each byte
@      to 3 nibbles (12 bits = 1.5 bytes) using the lookup table
@   4. Pack the 8*3=24 nibbles into 3 output words
@
@ The lookup table: exp_table[256] = 12-bit value (3 nibbles packed as uint16)
@   Input byte (2 GBA pixels): {p1:4, p0:4}
@   Output: NN expands (p0 p0 p1) for 6 bits, or (p0 p0 p1 p2 p2 p3) for chunk of 4
@   For 2->3: p0 p0 p1 -> packed as 12 bits: 0x000 | (p1<<8) | (p0<<4) | p0
@   Actually the NN pattern for 2->3 is:
@     ox 0 1 2 = ix 0 0 1 = pixel0 pixel0 pixel1
@   So: out_nibbles = [p0, p0, p1]
@   Packed as bits 11-0: nibble2:nibble1:nibble0 = p1:p0:p0
@   Stored as 16-bit uint16 with top 4 bits zero.
@
@ For 4->6 expansion using 2->3 on each half:
@   Input bytes B0 (pixels 1,0), B1 (pixels 3,2)
@   exp(B0) = 3 nibbles p0 p0 p1 = 12 bits
@   exp(B1) = 3 nibbles p2 p2 p3 = 12 bits
@   Output = exp(B0) | (exp(B1) << 12) = 24 bits (3 bytes = 6 nibbles)
@
@ For 8->12 (full tile row expansion of 8 pixels to 12):
@   4 input bytes: B0 B1 B2 B3
@   3 output words: 
@     Out0 = {exp(B0)[11:0], exp(B1)[11:8]} = low 12 bits of exp(B0) + high 4 bits of exp(B1)
@     Actually the full 12 nibble output is: exp(B0)[11:0], exp(B1)[11:0]
@     Packed as 3 words:
@       word0 = output nibbles 0-7  = exp(B0)[11:0] with exp(B1)[11:8] in high nibbles
@       word1 = output nibbles 8-15 = exp(B1)[7:0], exp(B2)[11:0]... 
@
@ This is getting complex with bit packing. Let me simplify.
@
@ The absolute simplest approach: do the expansion with byte-level lookups
@ and pack into words manually.
@----------------------------------------------------------------------------

@ Build the 2->3 pixel expansion table
@ exp_table[byte] -> 12-bit value: {p1, p0, p0} packed as nibbles
@ where byte = {p1:4, p0:4}
@ output nibbles: p0 p0 p1 = bits 11:8=p1, bits 7:4=p0, bits 3:0=p0
	.global build_exp_table
build_exp_table:
	stmfd sp!,{r4-r6,lr}
	ldr r4,=exp_table
	mov r5,#0
1:
	@ r5 = input byte
	@ extract p0 (low nibble) and p1 (high nibble)
	mov r0,r5
	and r1,r5,#0xF0		@p1 in low nibble after shift
	and r0,r5,#0x0F		@p0
	
	@ Build 12-bit: (p1<<8) | (p0<<4) | p0
	orr r2,r0,r0,lsl#4		@p0 in bits 3:0, p0 in bits 7:4
	orr r2,r1,lsl#4			@p1 in bits 11:8
	@ Actually: p0 in low nibble (bits 3:0), p0 in next (bits 7:4), p1 in next (bits 11:8)
	@ r2 = (p1 << 8) | (p0 << 4) | p0
	mov r6,r5,lsl#1
	strh r2,[r4,r6]
	add r5,r5,#1
	cmp r5,#0x100
	blt 1b
	
	ldmfd sp!,{r4-r6,pc}

	.popsection

@----------------------------------------------------------------------------
@ The exp_table: maps 2 GBA 4bpp pixels to 3 NN-expanded pixels
@ Table size: 256 * 2 = 512 bytes
@----------------------------------------------------------------------------
	.section .data
	.align 4
exp_table:
	.space 512, 0
