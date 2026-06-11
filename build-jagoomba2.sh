#!/bin/bash
# Build jagoombacolor with system arm-none-eabi toolchain
set -e

DEVKITARM=/opt/devkitarm
export PATH=$DEVKITARM/bin:$PATH
export LIBGBA=$DEVKITARM

SRCDIR=/tmp/jagoombacolor/src
BUILDDIR=/tmp/jagoombacolor/build
OUTDIR=/tmp/jagoombacolor

mkdir -p $BUILDDIR

ARCH="-mthumb -mthumb-interwork -mcpu=arm7tdmi -mtune=arm7tdmi"
CFLAGS="$ARCH -g -Wall -Os -fomit-frame-pointer -ffast-math -std=c99"
INCLUDES="-I$SRCDIR -I$DEVKITARM/include"
ASFLAGS="-mcpu=arm7tdmi"

# Compile .c files
echo "Compiling C sources..."
for src in $SRCDIR/*.c; do
    name=$(basename $src .c)
    echo "  $name.c"
    arm-none-eabi-gcc $CFLAGS $INCLUDES -c "$src" -o "$BUILDDIR/$name.o" 2>&1
done

# Assemble (use gcc to handle C preprocessor #include directives)
echo "Assembling sources..."
arm-none-eabi-gcc -x assembler-with-cpp $ASFLAGS -I$SRCDIR -c "$SRCDIR/all.s" -o "$BUILDDIR/all.o" 2>&1

arm-none-eabi-gcc -x assembler-with-cpp $ASFLAGS -I$SRCDIR -c "$SRCDIR/gba_crt0_my.s" -o "$BUILDDIR/gba_crt0_my.o" 2>&1

# Assemble data files
arm-none-eabi-gcc -x assembler-with-cpp $ASFLAGS -I$SRCDIR -c "$SRCDIR/data.s" -o "$BUILDDIR/data.o" 2>&1

# Compile stub
arm-none-eabi-gcc $CFLAGS $INCLUDES -c "$SRCDIR/stub.c" -o "$BUILDDIR/stub.o" 2>&1

# Link - use gcc to handle library paths correctly
echo "Linking..."

# Convert data files to object files (put in .rodata so they stay in ROM, not IWRAM)
arm-none-eabi-objcopy -I binary -O elf32-littlearm -B armv4t \
    --rename-section .data=.rodata,alloc,load,readonly,data,contents \
    "$SRCDIR/font._lz77" "$BUILDDIR/font_lz77.o" 2>&1
arm-none-eabi-objcopy -I binary -O elf32-littlearm -B armv4t \
    --rename-section .data=.rodata,alloc,load,readonly,data,contents \
    "$SRCDIR/fontpal.bin" "$BUILDDIR/fontpal_bin.o" 2>&1

OFILES="-Wl,$BUILDDIR/gba_crt0_my.o \
        -Wl,$BUILDDIR/cache.o -Wl,$BUILDDIR/dma.o -Wl,$BUILDDIR/gbcgamedetect.o \
        -Wl,$BUILDDIR/main.o -Wl,$BUILDDIR/mbclient.o -Wl,$BUILDDIR/minilzo.o \
        -Wl,$BUILDDIR/pocketnes_text.o -Wl,$BUILDDIR/rumble.o -Wl,$BUILDDIR/savestate.o \
        -Wl,$BUILDDIR/speedhack.o -Wl,$BUILDDIR/sram.o -Wl,$BUILDDIR/ui.o \
        -Wl,$BUILDDIR/all.o \
        -Wl,$BUILDDIR/data.o \
        -Wl,$BUILDDIR/stub.o \
        -Wl,$BUILDDIR/font_lz77.o -Wl,$BUILDDIR/fontpal_bin.o"

arm-none-eabi-gcc -nostartfiles $ARCH -g \
    -Wl,-T,$SRCDIR/gba_cart_my.ld \
    -Wl,-Map,$OUTDIR/jagoombacolor.map \
    $OFILES \
    -L$DEVKITARM/lib/gba -lgba \
    -L/usr/lib/arm-none-eabi/newlib/thumb/nofp -lc_nano \
    -lnosys \
    -o "$OUTDIR/jagoombacolor.elf" 2>&1

# Convert to .gba
echo "Generating .gba..."
arm-none-eabi-objcopy -O binary "$OUTDIR/jagoombacolor.elf" "$OUTDIR/jagoombacolor.gba" 2>&1

# Set ROM title and game code, fix Nintendo logo and header checksum
python3 << PYEOF
import struct
nintendo_logo = bytes([
    0x24,0xFF,0xAE,0x51,0x69,0x9A,0xA2,0x21,0x3D,0x84,0x82,0x0A,
    0x84,0xE4,0x09,0xAD,0x11,0x24,0x8B,0x98,0xC0,0x81,0x7F,0x21,
    0xA3,0x52,0xBE,0x19,0x93,0x09,0xCE,0x20,0x10,0x46,0x4A,0x4A,
    0xF8,0x27,0x31,0xEC,0x58,0xC7,0xE8,0x33,0x82,0xE3,0xCE,0xBF,
    0x85,0xF4,0xDF,0x94,0xCE,0x4B,0x09,0xC1,0x94,0x56,0x8A,0xC0,
    0x13,0x72,0xA7,0xFC,0x9F,0x84,0x4D,0x73,0xA3,0xCA,0x9A,0x61,
    0x58,0x97,0xA3,0x27,0xFC,0x03,0x98,0x76,0x23,0x1D,0xC7,0x61,
    0x03,0x04,0xAE,0x56,0xBF,0x38,0x84,0x00,0x40,0xA7,0x0E,0xFD,
    0xFF,0x52,0xFE,0x03,0x6F,0x95,0x30,0xF1,0x97,0xFB,0xC0,0x85,
    0x60,0xD6,0x80,0x25,0xA9,0x63,0xBE,0x03,0x01,0x4E,0x38,0xE2,
    0xF9,0xA2,0x34,0xFF,0xBB,0x3E,0x03,0x44,0x78,0x00,0x90,0xCB,
    0x88,0x11,0x3A,0x94,0x65,0xC0,0x7C,0x63,0x87,0xF0,0x3C,0xAF,
    0xD6,0x25,0xE4,0x8B,0x38,0x0A,0xAC,0x72,0x21,0xD4,0xF8,0x07
])
data = bytearray(open('$OUTDIR/jagoombacolor.gba', 'rb').read())
# Fix Nintendo logo
data[0x04:0xA0] = nintendo_logo
# Set title at 0xA0 (12 bytes)
title = b'JAGOOMBACLR'
data[0xA0:0xAC] = title.ljust(12, b'\x00')
# Set game code at 0xAC (4 bytes)
data[0xAC:0xAE] = b'GB'
data[0xAE:0xB0] = b'\x00\x00'
# Set maker code at 0xB0 (2 bytes)
data[0xB0:0xB2] = b'01'
# Zero reserved bytes
for i in range(0xB2, 0xBD):
    data[i] = 0
# Fix header checksum at 0xBD (sum 0xA0-0xBD must be 0 mod 256)
s = sum(data[0xA0:0xBD]) & 0xFF
data[0xBD] = (-s) & 0xFF
open('$OUTDIR/jagoombacolor.gba', 'wb').write(data)
print('Header fixed: logo + checksum OK')
PYEOF

echo "Done!"
ls -la $OUTDIR/jagoombacolor.elf $OUTDIR/jagoombacolor.gba $OUTDIR/jagoombacolor_patched.gba 2>/dev/null
