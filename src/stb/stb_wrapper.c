// Thin C wrapper for stb_truetype.
// Compiled as a regular C file; #includes stb_truetype.h with implementation.

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
#include "stb_wrapper.h"

#include <string.h> // memcpy

// Compile-time check that our opaque buffer is large enough.
_Static_assert(sizeof(lp_fontinfo) >= sizeof(stbtt_fontinfo),
               "lp_fontinfo opaque buffer too small for stbtt_fontinfo");

int lp_font_init(lp_fontinfo *info, const unsigned char *data) {
    return stbtt_InitFont((stbtt_fontinfo *)info, data, 0);
}

float lp_font_scale(const lp_fontinfo *info, float pixel_height) {
    return stbtt_ScaleForPixelHeight((const stbtt_fontinfo *)info, pixel_height);
}

unsigned char *lp_font_get_glyph_bitmap(const lp_fontinfo *info, float scale,
                                         int codepoint,
                                         int *w, int *h, int *xoff, int *yoff) {
    return stbtt_GetCodepointBitmap((const stbtt_fontinfo *)info, 0, scale,
                                    codepoint, w, h, xoff, yoff);
}

void lp_font_get_hmetrics(const lp_fontinfo *info, int codepoint,
                           int *advance_width, int *left_side_bearing) {
    stbtt_GetCodepointHMetrics((const stbtt_fontinfo *)info, codepoint,
                                advance_width, left_side_bearing);
}

void lp_font_get_vmetrics(const lp_fontinfo *info,
                           int *ascent, int *descent, int *line_gap) {
    stbtt_GetFontVMetrics((const stbtt_fontinfo *)info, ascent, descent, line_gap);
}

void lp_font_free_bitmap(unsigned char *bitmap) {
    stbtt_FreeBitmap(bitmap, NULL);
}

int lp_font_get_kern(const lp_fontinfo *info, int cp1, int cp2) {
    return stbtt_GetCodepointKernAdvance((const stbtt_fontinfo *)info, cp1, cp2);
}
