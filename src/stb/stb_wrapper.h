// Thin C wrapper for stb_truetype — exposes only the functions needed by Lightpanda.
// This avoids @cImport issues with the complex stb_truetype.h header.

#ifndef LP_STB_WRAPPER_H
#define LP_STB_WRAPPER_H

#ifdef __cplusplus
extern "C" {
#endif

// Opaque font info struct (matches stbtt_fontinfo size).
// We define a fixed-size buffer so Zig can allocate it on the stack/heap
// without needing to know the internal layout.
typedef struct {
    char opaque[256]; // stbtt_fontinfo is ~200 bytes; 256 gives margin
} lp_fontinfo;

// Initialize font from raw TTF data. Returns 1 on success, 0 on failure.
int lp_font_init(lp_fontinfo *info, const unsigned char *data);

// Get scale factor to produce glyphs of the given pixel height.
float lp_font_scale(const lp_fontinfo *info, float pixel_height);

// Get glyph bitmap for a codepoint. Caller must free with lp_font_free_bitmap().
// Returns NULL if glyph not found. Sets w, h, xoff, yoff.
unsigned char *lp_font_get_glyph_bitmap(const lp_fontinfo *info, float scale,
                                         int codepoint,
                                         int *w, int *h, int *xoff, int *yoff);

// Get horizontal metrics for a codepoint: advance width and left side bearing.
void lp_font_get_hmetrics(const lp_fontinfo *info, int codepoint,
                           int *advance_width, int *left_side_bearing);

// Get vertical metrics: ascent, descent, line gap (unscaled).
void lp_font_get_vmetrics(const lp_fontinfo *info,
                           int *ascent, int *descent, int *line_gap);

// Free a bitmap returned by lp_font_get_glyph_bitmap.
void lp_font_free_bitmap(unsigned char *bitmap);

// Get kern advance between two codepoints (unscaled).
int lp_font_get_kern(const lp_fontinfo *info, int cp1, int cp2);

#ifdef __cplusplus
}
#endif

#endif // LP_STB_WRAPPER_H
