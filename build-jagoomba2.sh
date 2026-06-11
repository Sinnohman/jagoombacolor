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

# Convert data files to object files
arm-none-eabi-objcopy -I binary -O elf32-littlearm -B armv4t \
    "$SRCDIR/font._lz77" "$BUILDDIR/font_lz77.o" 2>&1
arm-none-eabi-objcopy -I binary -O elf32-littlearm -B armv4t \
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

# Set ROM title and game code using python
python3 -c "
import struct
data = bytearray(open('$OUTDIR/jagoombacolor.gba', 'rb').read())
# Set title at 0xA0 (12 bytes)
title = b'JAGOOMBA CLR'
data[0xA0:0xA0+len(title)] = title.ljust(12, b' ')
# Set game code at 0xAC (4 bytes)
data[0xAC:0xAE] = b'GB'
# Set maker code at 0xB0 (2 bytes)
data[0xB0:0xB2] = b'01'
open('$OUTDIR/jagoombacolor_patched.gba', 'wb').write(data)
"

echo "Done!"
ls -la $OUTDIR/jagoombacolor.elf $OUTDIR/jagoombacolor.gba $OUTDIR/jagoombacolor_patched.gba 2>/dev/null
