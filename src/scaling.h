#ifndef __SCALING_H__
#define __SCALING_H__

// Scaling modes for the Display Settings menu
#define SCALE_1X        0   // Native 160x144 centered
#define SCALE_15X_WIDE  1   // 1.5x horizontal NN -> 240x144
#define SCALE_FULL      2   // 1.5x both axes -> 240x160 (cropped/stretched)
#define SCALE_MODES     3   // Total number of modes

// GBC screen dimensions
#define GBC_W 160
#define GBC_H 144

// GBA screen dimensions
#define GBA_W 240
#define GBA_H 160

// Scaled dimensions for the various modes
// 1x: 160x144 (GBA screen: 240x160)
// 1.5x Wide: 240x144  (fills width)
// Full: 240x160 (fills entire screen)

// Pixel buffer: 160x144, 1 byte per pixel (GBA palette index)
// Dimensions: 160 * 144 = 23040 bytes
extern u8 g_scaling_buffer[];

// Current scale mode
extern u8 g_scale_mode;

// Whether scaling is active (non-zero = skip tile display and use scaled output)
extern u8 g_scaling_active;

// Initialize scaling system (allocates buffer, sets up Mode 4 page pointers)
void scaling_init(void);

// Render a GBC frame to the pixel buffer from current GBC state
// Reads XGB_VRAM, gbc_palette, scroll regs, OAM, etc.
void scaling_render_frame(void);

// Nearest-neighbor scale the pixel buffer to the target dimensions
// and output to the current Mode 4 page in VRAM
void scaling_output(void);

// Set the GBA palette from the current GBC palette
void scaling_update_palette(void);

#endif
