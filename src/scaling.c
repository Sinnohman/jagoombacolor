// scaling.c - GBC pixel buffer renderer + NN scaling for GBA Mode 4 output
//
// This provides a parallel rendering path to the existing tile-based renderer.
// The tile renderer still runs (needed for save states, etc.), but we also
// render the GBC frame to a pixel buffer and output in GBA Mode 4 with
// nearest-neighbor 1.5x scaling.
//
// Modes:
//   0 = SCALE_1X       - 160x144 centered on 240x160 GBA screen (native, same as tiles)
//   1 = SCALE_15X_WIDE - 240x144 (1.5x horizontal NN), fills width
//   2 = SCALE_FULL     - 240x160 (1.5x horizontal, 1.111x vertical NN)

#include "includes.h"
#include "asmcalls.h"
#include "scaling.h"

// Extern GBC state variables from lcd.s / gbz80.s
extern u8 scrollX;
extern u8 scrollY;
extern u8 windowX;
extern u8 windowY;
extern u8 lcdstate;  // first byte = lcdctrl (FF40)
extern u8 lcdyc;
extern u8 doublespeed;
extern u8 gbc_mode;
extern u8 sgb_mode;

// Extern the second VRAM bank pointer for CGB mode
extern u8 XGB_VRAM[0x4000];

// Frame buffer: 160x144 resolution, 8-bit per pixel (GBA palette index)
// Background palette indices: BG palette 0-7, 4 colors each = indices 0-31
// OBJ (sprite) palette indices: OBJ palette 0-7, 4 colors each = indices 32-63
// Color 0 of any palette = transparent (for sprites), mapped to palette index 0

// The buffer is allocated in EWRAM via the linker section
// Define it as a large array
#define PIXBUF_SIZE (GBC_W * GBC_H)

// We put the pixel buffer in EWRAM via section attribute
u8 __attribute__((section(".ewram"))) g_scaling_buffer[PIXBUF_SIZE];

// Current scale mode (initialized to 1x / off)
u8 g_scale_mode = 0;
u8 g_scaling_active = 0;

// Mode 4 page flipping
// Page 0 at 0x06000000, Page 1 at 0x0600A000 (each 240*160 = 38400 bytes)
#define MODE4_PAGE0 ((u16*)0x06000000)
#define MODE4_PAGE1 ((u16*)0x0600A000)
#define GBA_PALETTE ((u16*)0x05000000)

// Track which page we're displaying
static u8 current_page = 0;

// Track if we've initialized Mode 4 display
static u8 mode4_initialized = 0;

// Table for mapping GBC 2bpp tile row to pixel indices
// For each byte from bit plane 0 and byte from plane 1, produce 8 pixel indices
static void decode_tile_row(u8 plane0, u8 plane1, u8* pixels_out) {
    int i;
    for (i = 0; i < 8; i++) {
        u8 bit = 7 - i;  // GBC format: bit 7 = leftmost pixel
        u8 p0 = (plane0 >> bit) & 1;
        u8 p1 = (plane1 >> bit) & 1;
        pixels_out[i] = (p1 << 1) | p0;  // 2-bit color index (0-3)
    }
}

// Read tile data from GBC VRAM and return pixel row
// tile_number: GBC tile number (0-383 or signed depending on mode)
// row: pixel row within tile (0-7)
// pixels: output array of 8 pixel indices (0-3)
static void read_tile_row(u16 tile_number, u8 row, u8* pixels) {
    // GBC addressing mode handling:
    // LCDC bit 4 = 1 (0x8000 mode): tile_number is unsigned 0-255
    // LCDC bit 4 = 0 (0x8800 mode): tile_number is signed, offset by 128
    u8 lcdctrl_val = *(volatile u8*)&lcdstate;
    u32 addr;
    
    if (lcdctrl_val & 0x10) {
        // 0x8000 mode: unsigned, tile 0 at VRAM+0x0000
        addr = tile_number * 16;
    } else {
        // 0x8800 mode: signed
        // tile 0-127 at 0x9000-0x97FF
        // tile 128-255 at 0x8000-0x87FF
        if (tile_number >= 128) {
            addr = (tile_number - 128) * 16;
        } else {
            addr = 0x1000 + tile_number * 16;  // 0x1000 = 0x9000 - 0x8000
        }
    }
    
    addr &= 0x3FFF;  // Mask to VRAM size
    
    // In CGB mode, tile data bank is selected by bit 3 of the tile map attribute
    // For the BG renderer, we read from bank 0 (VRAM offset 0x0000-0x1FFF)
    // The caller will handle bank selection via the tile map attribute
    u8 plane0 = XGB_VRAM[addr + row];       // Plane 0 (low bit)
    u8 plane1 = XGB_VRAM[addr + row + 8];   // Plane 1 (high bit)
    
    decode_tile_row(plane0, plane1, pixels);
}

// Same as read_tile_row but reads from a specified VRAM bank
// vram_bank: 0 = XGB_VRAM[0x0000], 1 = XGB_VRAM[0x2000]
static void read_tile_row_bank(u16 tile_number, u8 row, u8* pixels, u8 vram_bank) {
    u8 lcdctrl_val = *(volatile u8*)&lcdstate;
    u32 addr;
    
    // Offset for CGB VRAM bank selection
    u32 bank_offset = vram_bank ? 0x2000 : 0;
    
    if (lcdctrl_val & 0x10) {
        addr = bank_offset + tile_number * 16;
    } else {
        if (tile_number >= 128) {
            addr = bank_offset + (tile_number - 128) * 16;
        } else {
            addr = bank_offset + 0x1000 + tile_number * 16;
        }
    }
    
    addr &= 0x1FFF;  // Mask to bank size
    if (!vram_bank) {
        addr &= 0x1FFF;  // Bank 0: 0x0000-0x1FFF
    }
    
    u8 plane0 = XGB_VRAM[bank_offset + (addr & 0x1FFF) + row];
    u8 plane1 = XGB_VRAM[bank_offset + (addr & 0x1FFF) + row + 8];
    
    decode_tile_row(plane0, plane1, pixels);
}

// Initialize the scaling system
void scaling_init(void) {
    g_scale_mode = 0;
    g_scaling_active = 0;
    current_page = 0;
    mode4_initialized = 0;
    
    // Clear pixel buffer
    int i;
    for (i = 0; i < PIXBUF_SIZE; i++) {
        g_scaling_buffer[i] = 0;
    }
}

// Copy the GBC palette to the GBA palette RAM for Mode 4
void scaling_update_palette(void) {
    int i;
    u16* gba_pal = GBA_PALETTE;
    
    // In GBC, the palette is stored in gbc_palette (128 bytes = 64 colors × 2 bytes)
    // Each color is 15-bit RGB: 0bbbbbgggggrrrrr (GBC format)
    // GBA format for Mode 4 is also 15-bit: 0bgr
    // Both are the same format (xBBBBBGGGGGRRRRR)
    // gbc_palette: bytes 0-63 = BG palettes (8 palettes × 4 colors × 2 bytes)
    // gbc_palette: bytes 64-127 = OBJ palettes (8 palettes × 4 colors × 2 bytes)
    
    for (i = 0; i < 64; i++) {
        u16 color;
        // Read 2 bytes
        color = gbc_palette[i * 2] | ((u16)gbc_palette[i * 2 + 1] << 8);
        // Store in GBA palette as-is (same 15-bit RGB format)
        gba_pal[i] = color;
    }
}

// Render GBC BG layer 0 (main background)
// This is the primary playfield for most games
static void render_bg_layer(void) {
    u8 lcdctrl_val = *(volatile u8*)&lcdstate;
    u8 scy = scrollY;
    u8 scx = scrollX;
    
    // Determine which tile map is active for BG
    // LCDC bit 3: BG tile map address (0=0x9800/VRAM+0x1800, 1=0x9C00/VRAM+0x1C00)
    u16 bg_map_offset = (lcdctrl_val & 0x08) ? 0x1C00 : 0x1800;
    
    // Check if BG display is enabled (LCDC bit 0)
    if (!(lcdctrl_val & 0x01)) {
        // BG disabled - fill with color 0
        int i;
        for (i = 0; i < PIXBUF_SIZE; i++) {
            g_scaling_buffer[i] = 0;
        }
        return;
    }
    
    int y;
    for (y = 0; y < GBC_H; y++) {
        u8 vy = (u8)(scy + y);  // Wrap at 256
        
        u16 tile_row = vy / 8;
        u8 tile_y = vy % 8;
        
        int x;
        for (x = 0; x < GBC_W; x++) {
            u8 vx = (u8)(scx + x);  // Wrap at 256
            
            u16 tile_col = vx / 8;
            u8 tile_x = vx % 8;
            
            // Read tile map entry (2 bytes in CGB mode, 1 byte in DMG mode)
            u16 map_addr = bg_map_offset + tile_row * 64 + tile_col * 2;
            u16 map_entry;
            
            if (gbc_mode) {
                // CGB mode: 2-byte tile map entry
                // Bank 0: tile number (low byte)
                // Bank 1: attributes (high byte)
                // But XGB_VRAM holds both banks: bank 0 = 0x0000, bank 1 = 0x2000
                u8 tile_low = XGB_VRAM[map_addr & 0x1FFF];
                u8 tile_high = XGB_VRAM[(map_addr & 0x1FFF) + 0x2000];
                map_entry = tile_low | ((u16)tile_high << 8);
            } else {
                // DMG mode: 1-byte tile map entry (no bank 1 attributes)
                map_entry = XGB_VRAM[map_addr & 0x1FFF];
            }
            
            u16 tile_number = map_entry & 0xFF;  // Low byte is tile number
            // For 0x8000 mode, tile_number is 0-255 as-is
            // For 0x8800 mode, tile_number is signed; bits 0-7 are already correct
            // Wait: in signed mode, tile numbers 128-255 map to tiles -128 to -1
            // The byte value 128-255 as-is represents tiles -128 to -1
            // And bytes 0-127 represent tiles 0-127
            // So we just use the byte value directly
            // The addressing mode handles the mapping in read_tile_row()
            
            // CGB extended tile number (bits 8-9 from... actually CGB has up to 384 tiles)
            // For simplicity, we use 8-bit tile number for now
            // The extra bits would come from attribute bits in some implementations
            
            // CGB attributes
            u8 vram_bank = 0;
            u8 x_flip = 0;
            u8 y_flip = 0;
            u8 palette_num = 0;
            
            if (gbc_mode) {
                // Upper byte: attributes
                u8 attr = (map_entry >> 8) & 0xFF;
                // For BG tile map entry attribute in CGB mode:
                // Bit 0: VRAM bank (0/1)
                // Bit 1: Horizontal flip
                // Bit 2: Vertical flip  
                // Bits 3-5: BG palette number (0-7)
                // Bit 6: Reserved
                // Bit 7: Priority (BG over OBJ)
                vram_bank = attr & 0x01;
                x_flip = (attr >> 1) & 0x01;
                y_flip = (attr >> 2) & 0x01;
                palette_num = (attr >> 3) & 0x07;
            } else {
                // DMG mode: palette is always BGP (FF47), palette 0
                palette_num = 0;
            }
            
            // Handle flips
            u8 pixel_row_in_tile = y_flip ? (7 - tile_y) : tile_y;
            u8 pixel_col_in_tile = x_flip ? (7 - tile_x) : tile_x;
            
            // Read pixel
            u8 pixels[8];
            if (vram_bank) {
                read_tile_row_bank(tile_number, pixel_row_in_tile, pixels, 1);
            } else {
                read_tile_row(tile_number, pixel_row_in_tile, pixels);
            }
            
            u8 pixel_idx = pixels[pixel_col_in_tile];
            
            // Map to GBA palette index
            // For CGB: BG palette 0-7, each has 4 colors
            // Pixel index 0-3, palette 0-7
            // GBA palette index = palette_num * 4 + pixel_idx
            // But pixel_idx 0 = transparent is actually color 0 in the palette
            // For GBA Mode 4, color 0 is the background/transparent color
            // We map directly: palette[palette_num][pixel_idx] = GBA palette index
            u8 gba_idx = palette_num * 4 + pixel_idx;
            
            g_scaling_buffer[y * GBC_W + x] = gba_idx;
        }
    }
}

// NN scale a line from 160 pixels to 240 pixels (1.5x horizontal)
// Using nearest-neighbor: each output pixel corresponds to input pixel (ox * 2 / 3)
// Pattern: input pixels 0,0,1,1,2,3,3,4,4,5,6,6,7,7,8,...
// i.e., for output pixel ox, input pixel = (ox * 160) / 240 = ox * 2 / 3
// But since 240/160 = 3/2, we have: 3 output pixels for every 2 input pixels
// Pattern: A A B C C D E E F G G H ... (each letter is one input pixel, 
//          repetitions indicate which pixels are doubled)
static void nn_scale_line_160_to_240(const u8* src_line, u8* dst_line) {
    int ox;
    for (ox = 0; ox < 240; ox++) {
        int ix = (ox * 160) / 240;  // = ox * 2 / 3
        dst_line[ox] = src_line[ix];
    }
}

// NN scale the entire buffer from 160x144 to 240x144
static void scale_to_240x144(const u8* src, u8* dst, int dst_stride) {
    int y;
    for (y = 0; y < 144; y++) {
        nn_scale_line_160_to_240(src + y * 160, dst + y * dst_stride);
    }
}

// NN scale from 160x144 to 240x160
// Vertical scaling: 144→160 requires selecting some scanlines to double
// Pattern: every 9th scanline gets doubled (144/16 = 9)
// Rows to double: 8, 17, 26, 35, 44, 53, 62, 71, 80, 89, 98, 107, 116, 125, 134, 143
static void scale_to_240x160(const u8* src, u8* dst, int dst_stride) {
    int dy;
    int double_count = 0;
    
    for (dy = 0; dy < 160; dy++) {
        // Calculate source scanline with proper distribution
        // 144 source lines → 160 destination lines
        // Use NN: dest_y = (src_y * 144) / 160 = src_y * 9 / 10
        // But we want to avoid the same source appearing too many times
        // Better: use Bresenham-like distribution
        // dest_y = (dest * 144 + 80) / 160  (centered mapping)
        int sy = (dy * 144 + 80) / 160;
        if (sy >= 144) sy = 143;
        
        // Scale the line horizontally
        nn_scale_line_160_to_240(src + sy * 160, dst + dy * dst_stride);
    }
}

// Output the scaled frame to a Mode 4 page in VRAM
// Mode 4 is 240x160 8-bit indexed color (1 byte per pixel)
// The page is 240 * 160 = 38400 bytes
void scaling_output(void) {
    u16* page;
    u8* page_bytes;
    int i;
    
    // Select the non-visible page for writing
    if (!mode4_initialized) {
        // First time: set up Mode 4 display
        mode4_initialized = 1;
        current_page = 0;
    }
    
    // Toggle page
    current_page = 1 - current_page;
    
    if (current_page == 0) {
        page = MODE4_PAGE0;
    } else {
        page = MODE4_PAGE1;
    }
    page_bytes = (u8*)page;
    
    switch (g_scale_mode) {
        case SCALE_1X: {
            // 1x mode: center the 160x144 image on the 240x160 screen
            // Position: (40, 8) - 40px left margin, 8px top margin
            int margin_x = (GBA_W - GBC_W) / 2;  // 40
            int margin_y = (GBA_H - GBC_H) / 2;  // 8
            
            // Clear the page first (set to color 0)
            // We need to fill 38400 bytes. 240*160 = 38400
            // memset32 is available
            memset32(page, 0, 38400);
            
            // Copy centered
            int y;
            for (y = 0; y < GBC_H; y++) {
                u8* src_line = &g_scaling_buffer[y * GBC_W];
                u8* dst_line = &page_bytes[(y + margin_y) * GBA_W + margin_x];
                for (i = 0; i < GBC_W; i++) {
                    dst_line[i] = src_line[i];
                }
            }
            break;
        }
        
        case SCALE_15X_WIDE: {
            // 1.5x wide: scale to 240x144, center vertically (8px top margin)
            int margin_y = (GBA_H - 144) / 2;  // 8
            
            // Clear
            memset32(page, 0, 38400);
            
            // Scale horizontal, write centered vertically
            int y;
            for (y = 0; y < 144; y++) {
                nn_scale_line_160_to_240(
                    &g_scaling_buffer[y * GBC_W],
                    &page_bytes[(y + margin_y) * GBA_W]
                );
            }
            break;
        }
        
        case SCALE_FULL: {
            // Fullscreen: scale to 240x160
            // No clearing needed (we fill every pixel)
            scale_to_240x160(g_scaling_buffer, page_bytes, GBA_W);
            break;
        }
    }
    
    // Set the display to show the newly written page
    // We do this by modifying DISPCNT
    // Mode 4: bitmap mode, 8-bit color, page select by bit 4
    // DISPCNT = 0x0004 (Mode 4) | BG2_EN | (page_bit << 4)
    u16 dispcnt = 0x0004 | 0x0400;  // Mode 4, BG2 enable
    if (current_page == 0) {
        dispcnt |= 0x0010;  // Display page 0
    }
    // Note: actually in Mode 4, bit 4 selects the display page:
    // 0 = page 0 at 0x06000000, 1 = page 1 at 0x0600A000
    // The LCK writes to the non-visible page, then flips the bit
    
    *(volatile u16*)0x04000000 = dispcnt;
}

// Main render function: reads GBC state and renders to pixel buffer
void scaling_render_frame(void) {
    // Render BG layer
    render_bg_layer();
    
    // Update palette
    scaling_update_palette();
    
    // Output the scaled result
    scaling_output();
}
