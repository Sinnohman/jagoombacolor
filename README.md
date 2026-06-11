# Jagoomba Color - Sinnohman's Fork

A fork of [Jaga's Goomba Color fork](https://github.com/EvilJagaGenius/jagoombacolor), which itself is a fork of Goomba Color with bug fixes and compatibility improvements. Based on the 2019-05-04 source.

Primary goal of this fork: **Proper EZ Flash Omega Definitive Edition support** with working config persistence for GBC GBA enhancement features.

## What's Fixed in This Fork

### GBA Enhanced Mode Default ON
The "Identify as GBA" setting (`request_gba_mode`) now defaults to **ON**. This means GBC games that support GBA hardware detection (like **Shantae**, **Pokémon Pinball**) will automatically show their enhanced content — better colors, extra game modes, new transformations — without needing to toggle anything in the menu.

Most GBC games don't check for GBA hardware at all, so this change is harmless for the vast majority of titles. The setting can still be toggled off in the menu for any game that has issues (Language Settings → Identify as GBA).

### EZ Flash Omega DE Config Persistence
The original Jagoomba Color has a `using_flashcart()` function that checks whether SRAM save/load is safe by testing if the binary's `textstart` is in ROM address space (`0x08000000+`). When running as a plugin under SimpleDE/PogoShell, the binary is in EWRAM (`0x02000000+`), so this check fails and config read/write silently returns without doing anything. Settings like "Identify as GBA" would never persist across boots.

**Fix:** `using_flashcart()` unconditionally returns 1.

### Font Data Restored
The `font._lz77` file in the source tree was a different (wrong) version from what the original ezode binary was compiled with. The original uses a 2752-byte decompressed font; the source had a 3072-byte version. This caused garbled UI text on boot. Restored from the working original ezode binary.

### Fixed IWRAM Overflow
The font and palette data was placed in `.data` (loaded into IWRAM) alongside the emulator core. Combined they exceeded the GBA's 32K IWRAM limit by ~80 bytes, causing linker errors. Moved font data to `.rodata` so it stays in ROM.

### Updated Build System
- `build-jagoomba2.sh` — complete build pipeline using system devkitARM toolchain (Linux)
- `install-devkitpro` — install devkitARM toolchain from GitHub mirror (bypasses Cloudflare)
- Fixed `data.s` assembly to use `gcc -x assembler-with-cpp` for C preprocessor support
- Removed redundant `font_lz77.o` / `fontpal_bin.o` objects (data.s already includes font data)

### Notable Hacks and Games Fixed (from upstream)
- Donkey Kong Land: New Colors Mode (file select menu accessible)
- Faceball 2000 (menu accessible)
- Kirby's Dream Land DX Service Repair (level 2 palette issues fixed)
- Konami GB Collections 2 and 4 (boots)
- Metal Gear Solid: Ghost Babel (elevator crash fixed)
- Pokemon Crystal (graphical corruption fixed)
- Wario Land DX (boots)

## Building

### Prerequisites (Linux)
```bash
# Install devkitARM toolchain (run as root):
chmod +x install-devkitpro
./install-devkitpro
```

### Build
```bash
chmod +x build-jagoomba2.sh
./build-jagoomba2.sh
```

Output: `jagoombacolor.gba` — the compiled emulator binary.

### EZ Flash Omega DE Installation
1. Copy the built `.gba` to `SYSTEM/PLUG/gbc.gba` (and optionally `SYSTEM/PLUG/gb.gba` for Game Boy)
2. The SimpleDE kernel will use it as the GBC plugin automatically

### Standalone GBA ROM Compilation
To build a standalone `.gba` with GBC games baked in, use [Goomba Front](https://www.dwedit.org/gba/goombacolor.php) and replace the included `goomba.gba` with the built `jagoombacolor.gba`.

## Config Persistence on EZ Flash Omega DE

With `request_gba_mode` defaulting to **ON**, most users won't need to change this setting at all — Shantae GBA enhanced mode works immediately.

If you do toggle the setting in the menu, the value is stored at a fixed SRAM offset (`0x0E0000F0`) using byte writes matching the Omega DE kernel's `WriteSram` pattern. The Omega DE kernel intercepts writes to `0x0E000000` and flushes them to the `.sav` file when the user returns to the kernel menu (via L+R menu, soft reset, or the boot-time save prompt).

**Note:** Direct power-off without soft-resetting or using the L+R save menu will lose any uncommitted setting changes. This is a kernel limitation, not a Goomba bug.

## Thanks To
- Dwedit for the Goomba Color emulator
- FluBBa for the Goomba emulator
- Jaga for the Jagoomba Color fork and ongoing fixes
- Sterophonick for Simple kernel integration
- EZ-Flash for releasing the Omega DE kernel source
- Minucce, Nuvie, Radimerry, Therealteamplayer for various fixes
