// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const Allocator = std.mem.Allocator;

const js = @import("../../js/js.zig");

const color = @import("../../color.zig");
const Page = @import("../../Page.zig");

const Canvas = @import("../element/html/Canvas.zig");
const ImageData = @import("../ImageData.zig");
const TextMetrics = @import("TextMetrics.zig");

// stb_truetype C wrapper for font rasterization.
const stb = @cImport(@cInclude("stb_wrapper.h"));

// Embedded Liberation Sans Regular font (Apache 2.0 license).
// Metrically compatible with Arial — matches what fingerprint scripts expect.
const embedded_font_data = @embedFile("resources/LiberationSans-Regular.ttf");

/// This class doesn't implement a `constructor`.
/// It can be obtained with a call to `HTMLCanvasElement#getContext`.
/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D
const CanvasRenderingContext2D = @This();

/// Maximum canvas dimension to prevent excessive memory allocation.
/// Matches common headless Chrome limits (4096x4096 = 64MB max pixel buffer).
const MAX_CANVAS_DIM: u32 = 4096;

/// Maximum depth of the save()/restore() state stack.
/// Per spec, browsers typically allow at least 150; we use 32 to avoid excessive memory.
const MAX_STATE_STACK: u32 = 32;

/// Saved drawing state for save()/restore().
/// Per spec: includes fillStyle, strokeStyle, lineWidth, font, globalAlpha, and more.
/// We save the properties that our implementation actually uses.
const SavedState = struct {
    fill_style: color.RGBA,
    stroke_style: color.RGBA,
    line_width: f64,
    global_alpha: f64,
    font_size: f64,
    font_str: []const u8,
};

// --- Fields ---

/// Reference to the parent canvas element.
/// https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D/canvas
_canvas: *Canvas,
/// Fill color.
/// TODO: Add support for `CanvasGradient` and `CanvasPattern`.
_fill_style: color.RGBA = color.RGBA.Named.black,
/// Stroke color.
_stroke_style: color.RGBA = color.RGBA.Named.black,
/// RGBA pixel buffer, lazily allocated on first draw call.
_pixels: ?[]u8 = null,
/// Canvas width in pixels.
_width: u32 = 300,
/// Canvas height in pixels.
_height: u32 = 150,
/// Arena allocator for pixel buffer (persists across JS calls).
/// Set at creation time via Session.getArena(); null if context was created without arena.
_arena: ?Allocator = null,
/// Line width for stroke operations.
_line_width: f64 = 1.0,
/// Global alpha transparency (0.0-1.0).
_global_alpha: f64 = 1.0,
/// Font size parsed from font property.
_font_size: f64 = 10.0,
/// Raw CSS font string for getter (e.g., "bold 48px serif").
_font_str: []const u8 = "10px sans-serif",
/// Per-instance seed for fingerprint variation.
_noise_seed: u32 = 0,
/// State stack for save()/restore().
_state_stack: [MAX_STATE_STACK]SavedState = undefined,
/// Number of states currently saved on the stack.
_state_stack_len: u32 = 0,
/// Path commands for the current path.
_path_cmds: std.ArrayList(PathCmd) = .empty,
/// Current point x-coordinate.
_current_x: f64 = 0,
/// Current point y-coordinate.
_current_y: f64 = 0,
/// Start of the current sub-path (x).
_sub_path_start_x: f64 = 0,
/// Start of the current sub-path (y).
_sub_path_start_y: f64 = 0,
/// Whether a current point has been established.
_has_current_point: bool = false,

// --- Internal helpers ---

/// Check if a float coordinate is finite (not NaN or Infinity).
/// Per Canvas 2D spec, draw operations silently abort for non-finite coords.
fn isFiniteCoord(v: f64) bool {
    return !std.math.isNan(v) and !std.math.isInf(v);
}

/// Ensure the pixel buffer is allocated. Returns true if buffer is available.
/// Lazy allocation: buffer is only created on first draw call, not on context creation.
fn ensurePixelBuffer(self: *CanvasRenderingContext2D) bool {
    if (self._pixels != null) return true;
    const arena = self._arena orelse return false;
    if (self._width == 0 or self._height == 0) return false;
    if (self._width > MAX_CANVAS_DIM or self._height > MAX_CANVAS_DIM) return false;
    const size = @as(usize, self._width) * @as(usize, self._height) * 4;
    self._pixels = arena.alloc(u8, size) catch return false;
    @memset(self._pixels.?, 0);
    return true;
}

/// Clamped rectangle bounds (pixel coordinates, exclusive end).
const ClampedRect = struct { x0: u32, y0: u32, x1: u32, y1: u32 };

/// A 2D point used in path commands.
const PathPoint = struct { x: f64, y: f64 };

/// Path command — only moveTo and lineTo are stored.
/// Curves and arcs are flattened to line segments at add-time.
const PathCmd = union(enum) {
    move_to: PathPoint,
    line_to: PathPoint,
};

/// An edge for scanline fill processing.
const Edge = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

/// Clamp a float rectangle to canvas bounds. Returns null if the result is empty.
fn clampRect(self: *const CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64) ?ClampedRect {
    if (w <= 0.0 or h <= 0.0) return null;

    const canvas_w: f64 = @floatFromInt(self._width);
    const canvas_h: f64 = @floatFromInt(self._height);

    const fx0 = @floor(@max(0.0, x));
    const fy0 = @floor(@max(0.0, y));
    const fx1 = @floor(@min(canvas_w, x + w));
    const fy1 = @floor(@min(canvas_h, y + h));

    if (fx0 >= fx1 or fy0 >= fy1) return null;

    return .{
        .x0 = @intFromFloat(fx0),
        .y0 = @intFromFloat(fy0),
        .x1 = @intFromFloat(fx1),
        .y1 = @intFromFloat(fy1),
    };
}

/// Write a single pixel with source-over alpha blending.
fn blendPixel(self: *CanvasRenderingContext2D, px: u32, py: u32, src_r: u8, src_g: u8, src_b: u8, src_alpha: f64) void {
    const pixels = self._pixels orelse return;
    const idx = (@as(usize, py) * @as(usize, self._width) + @as(usize, px)) * 4;
    if (idx + 3 >= pixels.len) return;

    if (src_alpha >= 1.0) {
        // Fully opaque — just overwrite.
        pixels[idx] = src_r;
        pixels[idx + 1] = src_g;
        pixels[idx + 2] = src_b;
        pixels[idx + 3] = 255;
    } else if (src_alpha > 0.0) {
        // Source-over alpha compositing.
        const sa = src_alpha;
        const da = @as(f64, @floatFromInt(pixels[idx + 3])) / 255.0;
        const out_a = sa + da * (1.0 - sa);
        if (out_a > 0.0) {
            const inv_sa = 1.0 - sa;
            pixels[idx] = clampU8((@as(f64, @floatFromInt(src_r)) * sa + @as(f64, @floatFromInt(pixels[idx])) * da * inv_sa) / out_a);
            pixels[idx + 1] = clampU8((@as(f64, @floatFromInt(src_g)) * sa + @as(f64, @floatFromInt(pixels[idx + 1])) * da * inv_sa) / out_a);
            pixels[idx + 2] = clampU8((@as(f64, @floatFromInt(src_b)) * sa + @as(f64, @floatFromInt(pixels[idx + 2])) * da * inv_sa) / out_a);
            pixels[idx + 3] = clampU8(out_a * 255.0);
        }
    }
    // src_alpha <= 0: fully transparent source, no change to destination.
}

/// Clamp a float to [0, 255] and convert to u8.
fn clampU8(v: f64) u8 {
    if (v <= 0.0) return 0;
    if (v >= 255.0) return 255;
    return @intFromFloat(@round(v));
}

/// Fill a rectangle region with a color, applying globalAlpha.
fn fillRectWithColor(self: *CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64, col: color.RGBA) void {
    const r = self.clampRect(x, y, w, h) orelse return;
    const alpha = self._global_alpha * (@as(f64, @floatFromInt(col.a)) / 255.0);

    var py = r.y0;
    while (py < r.y1) : (py += 1) {
        var px = r.x0;
        while (px < r.x1) : (px += 1) {
            self.blendPixel(px, py, col.r, col.g, col.b, alpha);
        }
    }
}

/// Apply subtle fingerprint noise to a pixel region.
/// Makes toDataURL() output unique per session (prevents identical fingerprint detection).
/// Deterministic: same seed + same region → same noise pattern within a session.
fn applyFingerprintNoise(self: *CanvasRenderingContext2D, x: u32, y: u32, w: u32, h: u32) void {
    const pixels = self._pixels orelse return;
    var prng = std.Random.DefaultPrng.init(self._noise_seed);
    var random = prng.random();

    const x1 = @min(x + w, self._width);
    const y1 = @min(y + h, self._height);

    var py = y;
    while (py < y1) : (py += 1) {
        var px = x;
        while (px < x1) : (px += 1) {
            // Apply to ~10% of pixels.
            if (random.int(u8) < 26) { // 26/256 ≈ 10%
                const idx = (@as(usize, py) * @as(usize, self._width) + @as(usize, px)) * 4;
                if (idx + 3 >= pixels.len) continue;

                // Pick random channel (0=R, 1=G, 2=B — skip alpha).
                const channel = random.intRangeLessThan(usize, 0, 3);
                const current = pixels[idx + channel];

                // Apply ±1.
                if (random.boolean()) {
                    pixels[idx + channel] = if (current < 255) current + 1 else current - 1;
                } else {
                    pixels[idx + channel] = if (current > 0) current - 1 else current + 1;
                }
            }
        }
    }
}

/// Helper to extract backing store data pointer from an ImageData's V8 typed array.
/// Returns null if the data cannot be accessed.
fn getImageDataPtr(image_data: *ImageData, local: *const js.Local) ?[*]u8 {
    const local_ref = image_data._data.local(local);
    const buffer_view: *const js.v8.ArrayBufferView = @ptrCast(local_ref.handle);
    const array_buffer = js.v8.v8__ArrayBufferView__Buffer(buffer_view) orelse return null;
    var backing_store_ptr = js.v8.v8__ArrayBuffer__GetBackingStore(array_buffer);
    const backing_store = js.v8.std__shared_ptr__v8__BackingStore__get(&backing_store_ptr) orelse return null;
    const data_raw = js.v8.v8__BackingStore__Data(backing_store);
    return @ptrCast(@alignCast(data_raw));
}

// --- UTF-8 decoder (self-contained, no std.unicode dependency) ---

/// Decode one UTF-8 codepoint from the given position.
/// Returns the codepoint and advances pos. Returns null for invalid sequences.
fn decodeUtf8(text: []const u8, pos: *usize) ?u21 {
    if (pos.* >= text.len) return null;
    const b0 = text[pos.*];
    if (b0 < 0x80) {
        pos.* += 1;
        return @intCast(b0);
    } else if (b0 < 0xC0) {
        // Invalid continuation byte — skip.
        pos.* += 1;
        return null;
    } else if (b0 < 0xE0) {
        if (pos.* + 1 >= text.len) {
            pos.* += 1;
            return null;
        }
        const cp = (@as(u21, b0 & 0x1F) << 6) | @as(u21, text[pos.* + 1] & 0x3F);
        pos.* += 2;
        return cp;
    } else if (b0 < 0xF0) {
        if (pos.* + 2 >= text.len) {
            pos.* += 1;
            return null;
        }
        const cp = (@as(u21, b0 & 0x0F) << 12) | (@as(u21, text[pos.* + 1] & 0x3F) << 6) | @as(u21, text[pos.* + 2] & 0x3F);
        pos.* += 3;
        return cp;
    } else {
        if (pos.* + 3 >= text.len) {
            pos.* += 1;
            return null;
        }
        const cp = (@as(u21, b0 & 0x07) << 18) | (@as(u21, text[pos.* + 1] & 0x3F) << 12) | (@as(u21, text[pos.* + 2] & 0x3F) << 6) | @as(u21, text[pos.* + 3] & 0x3F);
        pos.* += 4;
        return cp;
    }
}

// --- Font singleton ---

/// Global font info, initialized lazily on first text operation.
var font_info: stb.lp_fontinfo = undefined;
var font_initialized: bool = false;

/// Initialize the embedded font. Returns true on success.
fn ensureFont() bool {
    if (font_initialized) return true;
    if (stb.lp_font_init(&font_info, embedded_font_data.ptr) != 0) {
        font_initialized = true;
        return true;
    }
    return false;
}

/// Compute the total advance width of a text string at the given font size.
/// Returns the width in pixels (CSS pixels).
fn computeTextWidth(text: []const u8, font_size: f64) f64 {
    if (!ensureFont()) return 0.0;
    const font_scale: f64 = @floatCast(stb.lp_font_scale(&font_info, @floatCast(font_size)));
    var total_width: f64 = 0.0;
    var prev_cp: u21 = 0;
    var pos: usize = 0;
    while (pos < text.len) {
        const cp = decodeUtf8(text, &pos) orelse continue;
        // Kerning between previous and current codepoint.
        if (prev_cp != 0) {
            const kern = stb.lp_font_get_kern(&font_info, @intCast(prev_cp), @intCast(cp));
            total_width += @as(f64, @floatFromInt(kern)) * font_scale;
        }
        var advance: c_int = 0;
        var lsb: c_int = 0;
        stb.lp_font_get_hmetrics(&font_info, @intCast(cp), &advance, &lsb);
        total_width += @as(f64, @floatFromInt(advance)) * font_scale;
        prev_cp = cp;
    }
    return total_width;
}

/// Render text glyphs into the pixel buffer at the given position.
/// Uses the current fillStyle color and globalAlpha for compositing.
fn renderText(self: *CanvasRenderingContext2D, text: []const u8, x: f64, y: f64, col: color.RGBA) void {
    if (!ensureFont()) return;
    const font_scale_f: f32 = stb.lp_font_scale(&font_info, @floatCast(self._font_size));
    const font_scale: f64 = @floatCast(font_scale_f);

    // Canvas textBaseline default is "alphabetic" — y is the baseline.
    // stb_truetype's GetCodepointBitmap yoff is relative to the baseline
    // (negative values mean above baseline), so we use y directly.
    var cursor_x: f64 = x;
    const baseline_y: f64 = y;

    var prev_cp: u21 = 0;
    var pos: usize = 0;
    while (pos < text.len) {
        const cp = decodeUtf8(text, &pos) orelse continue;

        // Apply kerning.
        if (prev_cp != 0) {
            const kern = stb.lp_font_get_kern(&font_info, @intCast(prev_cp), @intCast(cp));
            cursor_x += @as(f64, @floatFromInt(kern)) * font_scale;
        }

        // Get glyph bitmap.
        var bw: c_int = 0;
        var bh: c_int = 0;
        var xoff: c_int = 0;
        var yoff: c_int = 0;
        const bitmap = stb.lp_font_get_glyph_bitmap(&font_info, font_scale_f, @intCast(cp), &bw, &bh, &xoff, &yoff);
        if (bitmap != null and bw > 0 and bh > 0) {
            // Composite glyph bitmap into pixel buffer.
            // xoff/yoff are relative to cursor position at baseline.
            const glyph_x: f64 = cursor_x + @as(f64, @floatFromInt(xoff));
            const glyph_y: f64 = baseline_y + @as(f64, @floatFromInt(yoff));

            const glyph_alpha_base = self._global_alpha * (@as(f64, @floatFromInt(col.a)) / 255.0);
            const canvas_w: f64 = @floatFromInt(self._width);
            const canvas_h: f64 = @floatFromInt(self._height);

            var by: c_int = 0;
            while (by < bh) : (by += 1) {
                const py_f = glyph_y + @as(f64, @floatFromInt(by));
                if (py_f < 0.0 or py_f >= canvas_h) continue;
                const py: u32 = @intFromFloat(py_f);

                var bx: c_int = 0;
                while (bx < bw) : (bx += 1) {
                    const px_f = glyph_x + @as(f64, @floatFromInt(bx));
                    if (px_f < 0.0 or px_f >= canvas_w) continue;
                    const px: u32 = @intFromFloat(px_f);

                    // Grayscale coverage from stb (0-255).
                    const bitmap_idx = @as(usize, @intCast(by)) * @as(usize, @intCast(bw)) + @as(usize, @intCast(bx));
                    const coverage: f64 = @as(f64, @floatFromInt(bitmap[bitmap_idx])) / 255.0;
                    const pixel_alpha = glyph_alpha_base * coverage;

                    if (pixel_alpha > 0.0) {
                        self.blendPixel(px, py, col.r, col.g, col.b, pixel_alpha);
                    }
                }
            }

            stb.lp_font_free_bitmap(bitmap);
        }

        // Advance cursor.
        var advance: c_int = 0;
        var lsb: c_int = 0;
        stb.lp_font_get_hmetrics(&font_info, @intCast(cp), &advance, &lsb);
        cursor_x += @as(f64, @floatFromInt(advance)) * font_scale;

        prev_cp = cp;
    }
}

// --- Path rendering helpers ---

/// Insertion sort for a small array of f64 values.
/// Used for sorting scanline intersection x-coordinates.
fn sortF64(items: []f64) void {
    if (items.len <= 1) return;
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j: usize = i;
        while (j > 0 and items[j - 1] > key) {
            items[j] = items[j - 1];
            j -= 1;
        }
        items[j] = key;
    }
}

/// Scanline fill using even-odd rule.
/// Implicitly closes each sub-path.
fn fillPath(self: *CanvasRenderingContext2D) void {
    if (!self.ensurePixelBuffer()) return;
    const arena = self._arena orelse return;
    const cmds = self._path_cmds.items;
    if (cmds.len == 0) return;

    // Phase 1: Build edge list with implicit sub-path closing.
    var edges: std.ArrayList(Edge) = .empty;

    var cur_x: f64 = 0;
    var cur_y: f64 = 0;
    var sp_x: f64 = 0;
    var sp_y: f64 = 0;
    var in_sub_path = false;

    for (cmds) |cmd| {
        switch (cmd) {
            .move_to => |p| {
                // Implicitly close previous sub-path for fill.
                if (in_sub_path and (cur_x != sp_x or cur_y != sp_y)) {
                    edges.append(arena, .{ .x0 = cur_x, .y0 = cur_y, .x1 = sp_x, .y1 = sp_y }) catch return;
                }
                sp_x = p.x;
                sp_y = p.y;
                cur_x = p.x;
                cur_y = p.y;
                in_sub_path = true;
            },
            .line_to => |p| {
                if (!in_sub_path) {
                    sp_x = cur_x;
                    sp_y = cur_y;
                    in_sub_path = true;
                }
                edges.append(arena, .{ .x0 = cur_x, .y0 = cur_y, .x1 = p.x, .y1 = p.y }) catch return;
                cur_x = p.x;
                cur_y = p.y;
            },
        }
    }
    // Close last sub-path.
    if (in_sub_path and (cur_x != sp_x or cur_y != sp_y)) {
        edges.append(arena, .{ .x0 = cur_x, .y0 = cur_y, .x1 = sp_x, .y1 = sp_y }) catch return;
    }

    if (edges.items.len == 0) return;

    // Phase 2: Find vertical bounding box.
    var min_y = @min(edges.items[0].y0, edges.items[0].y1);
    var max_y = @max(edges.items[0].y0, edges.items[0].y1);
    for (edges.items[1..]) |e| {
        min_y = @min(min_y, @min(e.y0, e.y1));
        max_y = @max(max_y, @max(e.y0, e.y1));
    }

    // Clamp to canvas bounds.
    const canvas_h: f64 = @floatFromInt(self._height);
    const y_start_f = @max(0.0, @floor(min_y));
    const y_end_f = @min(canvas_h, @ceil(max_y));
    if (y_start_f >= y_end_f) return;
    const y_start: u32 = @intFromFloat(y_start_f);
    const y_end: u32 = @intFromFloat(y_end_f);

    // Phase 3: Allocate intersection buffer (reused per scanline).
    const intersections = arena.alloc(f64, edges.items.len) catch return;

    // Phase 4: Fill color and alpha.
    const col = self._fill_style;
    const alpha = self._global_alpha * (@as(f64, @floatFromInt(col.a)) / 255.0);

    // Phase 5: Scanline fill.
    var y = y_start;
    while (y < y_end) : (y += 1) {
        const scanline_y: f64 = @as(f64, @floatFromInt(y)) + 0.5;
        var n_ix: usize = 0;

        for (edges.items) |e| {
            // Skip horizontal edges.
            if (e.y0 == e.y1) continue;
            const ey_min = @min(e.y0, e.y1);
            const ey_max = @max(e.y0, e.y1);
            // Edge must span the scanline (inclusive bottom, exclusive top).
            if (scanline_y < ey_min or scanline_y >= ey_max) continue;

            const t = (scanline_y - e.y0) / (e.y1 - e.y0);
            const ix = e.x0 + t * (e.x1 - e.x0);
            if (n_ix < intersections.len) {
                intersections[n_ix] = ix;
                n_ix += 1;
            }
        }

        // Sort intersections by x-coordinate.
        sortF64(intersections[0..n_ix]);

        // Fill between pairs (even-odd rule).
        var i: usize = 0;
        while (i + 1 < n_ix) : (i += 2) {
            const raw_x0 = @max(0.0, intersections[i]);
            const raw_x1 = @min(@as(f64, @floatFromInt(self._width)), intersections[i + 1]);
            if (raw_x0 >= raw_x1) continue;

            var px: u32 = @intFromFloat(@floor(raw_x0));
            const px_end: u32 = @intFromFloat(@min(@as(f64, @floatFromInt(self._width)), @ceil(raw_x1)));
            while (px < px_end) : (px += 1) {
                self.blendPixel(px, y, col.r, col.g, col.b, alpha);
            }
        }
    }
}

/// Stroke the current path by drawing thick lines along each segment.
fn strokePath(self: *CanvasRenderingContext2D) void {
    if (!self.ensurePixelBuffer()) return;
    const cmds = self._path_cmds.items;
    if (cmds.len == 0) return;

    const col = self._stroke_style;
    const lw = @max(1.0, self._line_width);

    var cur_x: f64 = 0;
    var cur_y: f64 = 0;

    for (cmds) |cmd| {
        switch (cmd) {
            .move_to => |p| {
                cur_x = p.x;
                cur_y = p.y;
            },
            .line_to => |p| {
                self.drawThickLine(cur_x, cur_y, p.x, p.y, lw, col);
                cur_x = p.x;
                cur_y = p.y;
            },
        }
    }
}

/// Draw a thick line segment from (x0,y0) to (x1,y1).
/// Uses distance-to-segment test for each pixel in the bounding box.
fn drawThickLine(self: *CanvasRenderingContext2D, x0: f64, y0: f64, x1: f64, y1: f64, width: f64, col: color.RGBA) void {
    const half_w = width / 2.0;
    const canvas_w: f64 = @floatFromInt(self._width);
    const canvas_h: f64 = @floatFromInt(self._height);

    // Bounding box expanded by half line width.
    const bb_x0 = @max(0.0, @min(x0, x1) - half_w);
    const bb_y0 = @max(0.0, @min(y0, y1) - half_w);
    const bb_x1 = @min(canvas_w, @max(x0, x1) + half_w + 1.0);
    const bb_y1 = @min(canvas_h, @max(y0, y1) + half_w + 1.0);

    if (bb_x0 >= bb_x1 or bb_y0 >= bb_y1) return;

    const px_x0: u32 = @intFromFloat(@floor(bb_x0));
    const px_y0: u32 = @intFromFloat(@floor(bb_y0));
    const px_x1: u32 = @intFromFloat(@ceil(bb_x1));
    const px_y1: u32 = @intFromFloat(@ceil(bb_y1));

    const dx = x1 - x0;
    const dy = y1 - y0;
    const len_sq = dx * dx + dy * dy;
    const alpha = self._global_alpha * (@as(f64, @floatFromInt(col.a)) / 255.0);

    var py = px_y0;
    while (py < px_y1) : (py += 1) {
        var px = px_x0;
        while (px < px_x1) : (px += 1) {
            const pcx = @as(f64, @floatFromInt(px)) + 0.5;
            const pcy = @as(f64, @floatFromInt(py)) + 0.5;

            // Distance from pixel center to line segment.
            var dist: f64 = undefined;
            if (len_sq < 0.0001) {
                // Degenerate line (point).
                const ddx = pcx - x0;
                const ddy = pcy - y0;
                dist = @sqrt(ddx * ddx + ddy * ddy);
            } else {
                const t_raw = ((pcx - x0) * dx + (pcy - y0) * dy) / len_sq;
                const t = @max(0.0, @min(1.0, t_raw));
                const proj_x = x0 + t * dx;
                const proj_y = y0 + t * dy;
                const ddx = pcx - proj_x;
                const ddy = pcy - proj_y;
                dist = @sqrt(ddx * ddx + ddy * ddy);
            }

            if (dist <= half_w) {
                self.blendPixel(px, py, col.r, col.g, col.b, alpha);
            }
        }
    }
}

/// Flatten a quadratic Bezier curve into line segments.
/// Uses fixed subdivision with ~8 segments.
fn flattenQuadraticBezier(self: *CanvasRenderingContext2D, arena: Allocator, x0: f64, y0: f64, cpx: f64, cpy: f64, x1: f64, y1: f64) void {
    const n_segments: u32 = 8;
    var i: u32 = 1;
    while (i <= n_segments) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n_segments));
        const inv_t = 1.0 - t;
        // B(t) = (1-t)^2 * P0 + 2(1-t)t * CP + t^2 * P1
        const px = inv_t * inv_t * x0 + 2.0 * inv_t * t * cpx + t * t * x1;
        const py = inv_t * inv_t * y0 + 2.0 * inv_t * t * cpy + t * t * y1;
        self._path_cmds.append(arena, .{ .line_to = .{ .x = px, .y = py } }) catch return;
        self._current_x = px;
        self._current_y = py;
    }
}

/// Flatten a cubic Bezier curve into line segments.
/// Uses fixed subdivision with ~16 segments.
fn flattenCubicBezier(self: *CanvasRenderingContext2D, arena: Allocator, x0: f64, y0: f64, cp1x: f64, cp1y: f64, cp2x: f64, cp2y: f64, x1: f64, y1: f64) void {
    const n_segments: u32 = 16;
    var i: u32 = 1;
    while (i <= n_segments) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n_segments));
        const inv_t = 1.0 - t;
        // B(t) = (1-t)^3*P0 + 3(1-t)^2*t*CP1 + 3(1-t)*t^2*CP2 + t^3*P1
        const px = inv_t * inv_t * inv_t * x0 + 3.0 * inv_t * inv_t * t * cp1x + 3.0 * inv_t * t * t * cp2x + t * t * t * x1;
        const py = inv_t * inv_t * inv_t * y0 + 3.0 * inv_t * inv_t * t * cp1y + 3.0 * inv_t * t * t * cp2y + t * t * t * y1;
        self._path_cmds.append(arena, .{ .line_to = .{ .x = px, .y = py } }) catch return;
        self._current_x = px;
        self._current_y = py;
    }
}

// --- Public methods: property accessors ---

pub fn getCanvas(self: *const CanvasRenderingContext2D) *Canvas {
    return self._canvas;
}

pub fn getFillStyle(self: *const CanvasRenderingContext2D, page: *Page) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(page.call_arena);
    try self._fill_style.format(&w.writer);
    return w.written();
}

pub fn setFillStyle(
    self: *CanvasRenderingContext2D,
    value: []const u8,
) !void {
    // Prefer the same fill_style if parsing fails.
    self._fill_style = color.RGBA.parse(value) catch self._fill_style;
}

pub fn getStrokeStyle(self: *const CanvasRenderingContext2D, page: *Page) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(page.call_arena);
    try self._stroke_style.format(&w.writer);
    return w.written();
}

pub fn setStrokeStyle(
    self: *CanvasRenderingContext2D,
    value: []const u8,
) !void {
    // Prefer the same stroke_style if parsing fails.
    self._stroke_style = color.RGBA.parse(value) catch self._stroke_style;
}

pub fn getGlobalAlpha(self: *const CanvasRenderingContext2D) f64 {
    return self._global_alpha;
}

pub fn setGlobalAlpha(self: *CanvasRenderingContext2D, value: f64) void {
    // Per spec: ignore if value is NaN, Infinity, or outside [0, 1].
    if (!isFiniteCoord(value) or value < 0.0 or value > 1.0) return;
    self._global_alpha = value;
}

pub fn getLineWidth(self: *const CanvasRenderingContext2D) f64 {
    return self._line_width;
}

pub fn setLineWidth(self: *CanvasRenderingContext2D, value: f64) void {
    // Per spec: ignore if value is not finite or <= 0.
    if (!isFiniteCoord(value) or value <= 0.0) return;
    self._line_width = value;
}

// --- Public methods: drawing operations ---

pub fn fillRect(self: *CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64) void {
    // Per spec: silently abort for non-finite coordinates.
    if (!isFiniteCoord(x) or !isFiniteCoord(y) or !isFiniteCoord(w) or !isFiniteCoord(h)) return;
    if (!self.ensurePixelBuffer()) return;
    self.fillRectWithColor(x, y, w, h, self._fill_style);
}

pub fn clearRect(self: *CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64) void {
    if (!isFiniteCoord(x) or !isFiniteCoord(y) or !isFiniteCoord(w) or !isFiniteCoord(h)) return;
    // clearRect doesn't need ensurePixelBuffer — if no buffer exists, there's nothing to clear.
    const pixels = self._pixels orelse return;
    const r = self.clampRect(x, y, w, h) orelse return;

    var py = r.y0;
    while (py < r.y1) : (py += 1) {
        const row_start = (@as(usize, py) * @as(usize, self._width) + @as(usize, r.x0)) * 4;
        const row_end = (@as(usize, py) * @as(usize, self._width) + @as(usize, r.x1)) * 4;
        @memset(pixels[row_start..row_end], 0);
    }
}

pub fn strokeRect(self: *CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64) void {
    if (!isFiniteCoord(x) or !isFiniteCoord(y) or !isFiniteCoord(w) or !isFiniteCoord(h)) return;
    // Per spec: if w and h are both 0, nothing is drawn.
    if (w == 0.0 and h == 0.0) return;
    if (!self.ensurePixelBuffer()) return;

    const lw = @max(1.0, self._line_width);

    // Draw rectangle outline as 4 non-overlapping filled rectangles.
    // Top edge (full width)
    self.fillRectWithColor(x, y, w, lw, self._stroke_style);
    // Bottom edge (full width)
    self.fillRectWithColor(x, y + h - lw, w, lw, self._stroke_style);
    // Left edge (excluding corners already drawn by top/bottom)
    self.fillRectWithColor(x, y + lw, lw, h - 2.0 * lw, self._stroke_style);
    // Right edge (excluding corners)
    self.fillRectWithColor(x + w - lw, y + lw, lw, h - 2.0 * lw, self._stroke_style);
}

// --- Public methods: context state ---

/// Reset the context state. Called when canvas width/height changes.
/// Per spec: frees pixel buffer and resets all drawing state to defaults.
pub fn reset(self: *CanvasRenderingContext2D, new_width: u32, new_height: u32) void {
    // Pixel buffer is arena-allocated — no explicit free needed.
    // Setting to null means next draw call will lazy-allocate a new buffer.
    self._pixels = null;
    self._width = new_width;
    self._height = new_height;
    // Reset drawing state per spec.
    self._fill_style = color.RGBA.Named.black;
    self._stroke_style = color.RGBA.Named.black;
    self._line_width = 1.0;
    self._global_alpha = 1.0;
    self._font_size = 10.0;
    // Reset state stack.
    self._state_stack_len = 0;
    // Reset path state.
    self._path_cmds.clearRetainingCapacity();
    self._has_current_point = false;
    self._current_x = 0;
    self._current_y = 0;
    self._sub_path_start_x = 0;
    self._sub_path_start_y = 0;
}

// --- Public methods: ImageData ---

const WidthOrImageData = union(enum) {
    width: u32,
    image_data: *ImageData,
};

pub fn createImageData(
    _: *const CanvasRenderingContext2D,
    width_or_image_data: WidthOrImageData,
    /// If `ImageData` variant preferred, this is null.
    maybe_height: ?u32,
    /// Can be used if width and height provided.
    maybe_settings: ?ImageData.ConstructorSettings,
    page: *Page,
) !*ImageData {
    switch (width_or_image_data) {
        .width => |width| {
            const height = maybe_height orelse return error.TypeError;
            return ImageData.init(width, height, maybe_settings, page);
        },
        .image_data => |image_data| {
            return ImageData.init(image_data._width, image_data._height, null, page);
        },
    }
}

pub fn putImageData(self: *CanvasRenderingContext2D, image_data: *ImageData, dx_f: f64, dy_f: f64, _: ?f64, _: ?f64, _: ?f64, _: ?f64, page: *Page) void {
    // Per spec: abort if coords are not finite.
    if (!isFiniteCoord(dx_f) or !isFiniteCoord(dy_f)) return;
    // Ensure pixel buffer exists (allocate if needed — putImageData is a draw op).
    if (!self.ensurePixelBuffer()) return;
    const pixels = self._pixels orelse return;

    const dest_x: i32 = @intFromFloat(@floor(dx_f));
    const dest_y: i32 = @intFromFloat(@floor(dy_f));
    const src_w = image_data._width;
    const src_h = image_data._height;

    // Access the ImageData's V8 typed array backing store to read from it.
    const local = page.js.local orelse return;
    const src = getImageDataPtr(image_data, local) orelse return;
    const src_len: usize = @as(usize, src_w) * @as(usize, src_h) * 4;

    // putImageData is a direct pixel copy — NO alpha blending, NO globalAlpha (per spec).
    const canvas_w: i32 = @intCast(self._width);
    const canvas_h: i32 = @intCast(self._height);
    var sy: u32 = 0;
    while (sy < src_h) : (sy += 1) {
        const py = dest_y + @as(i32, @intCast(sy));
        if (py < 0 or py >= canvas_h) continue;
        var sx: u32 = 0;
        while (sx < src_w) : (sx += 1) {
            const px = dest_x + @as(i32, @intCast(sx));
            if (px < 0 or px >= canvas_w) continue;
            const src_idx = (@as(usize, sy) * @as(usize, src_w) + @as(usize, sx)) * 4;
            if (src_idx + 3 >= src_len) continue;
            const dest_idx = (@as(usize, @intCast(py)) * @as(usize, self._width) + @as(usize, @intCast(px))) * 4;
            if (dest_idx + 3 >= pixels.len) continue;
            // Direct copy — no compositing per spec.
            pixels[dest_idx] = src[src_idx];
            pixels[dest_idx + 1] = src[src_idx + 1];
            pixels[dest_idx + 2] = src[src_idx + 2];
            pixels[dest_idx + 3] = src[src_idx + 3];
        }
    }
}

pub fn getImageData(
    self: *const CanvasRenderingContext2D,
    sx: i32,
    sy: i32,
    sw: i32,
    sh: i32,
    page: *Page,
) !*ImageData {
    if (sw <= 0 or sh <= 0) {
        return error.IndexSizeError;
    }
    const uw: u32 = @intCast(sw);
    const uh: u32 = @intCast(sh);

    // Create new ImageData (zero-initialized Uint8ClampedArray).
    const image_data = try ImageData.init(uw, uh, null, page);

    // If no pixel buffer exists, return all-transparent ImageData (correct per spec).
    const pixels = self._pixels orelse return image_data;

    // Access the ImageData's V8 typed array backing store to write into it.
    const local = page.js.local orelse return image_data;
    const dest = getImageDataPtr(image_data, local) orelse return image_data;
    const dest_len: usize = @as(usize, uw) * @as(usize, uh) * 4;

    // Copy pixels from canvas buffer into ImageData, clamping to canvas bounds.
    // Out-of-bounds regions remain transparent black (zero-initialized by ImageData.init).
    const canvas_w: i32 = @intCast(self._width);
    const canvas_h: i32 = @intCast(self._height);
    var dy: u32 = 0;
    while (dy < uh) : (dy += 1) {
        const src_y = sy + @as(i32, @intCast(dy));
        if (src_y < 0 or src_y >= canvas_h) continue;
        var dx: u32 = 0;
        while (dx < uw) : (dx += 1) {
            const src_x = sx + @as(i32, @intCast(dx));
            if (src_x < 0 or src_x >= canvas_w) continue;
            const dest_idx = (@as(usize, dy) * @as(usize, uw) + @as(usize, dx)) * 4;
            if (dest_idx + 3 >= dest_len) continue;
            const src_idx = (@as(usize, @intCast(src_y)) * @as(usize, self._width) + @as(usize, @intCast(src_x))) * 4;
            if (src_idx + 3 >= pixels.len) continue;
            dest[dest_idx] = pixels[src_idx];
            dest[dest_idx + 1] = pixels[src_idx + 1];
            dest[dest_idx + 2] = pixels[src_idx + 2];
            dest[dest_idx + 3] = pixels[src_idx + 3];
        }
    }

    return image_data;
}

// --- Public methods: stubs (noops until implemented in later tasks) ---

pub fn save(self: *CanvasRenderingContext2D) void {
    // Per spec: if stack is full, silently ignore.
    if (self._state_stack_len >= MAX_STATE_STACK) return;
    self._state_stack[self._state_stack_len] = .{
        .fill_style = self._fill_style,
        .stroke_style = self._stroke_style,
        .line_width = self._line_width,
        .global_alpha = self._global_alpha,
        .font_size = self._font_size,
        .font_str = self._font_str,
    };
    self._state_stack_len += 1;
}

pub fn restore(self: *CanvasRenderingContext2D) void {
    // Per spec: if stack is empty, silently ignore.
    if (self._state_stack_len == 0) return;
    self._state_stack_len -= 1;
    const state = self._state_stack[self._state_stack_len];
    self._fill_style = state.fill_style;
    self._stroke_style = state.stroke_style;
    self._line_width = state.line_width;
    self._global_alpha = state.global_alpha;
    self._font_size = state.font_size;
    self._font_str = state.font_str;
}
pub fn scale(_: *CanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn rotate(_: *CanvasRenderingContext2D, _: f64) void {}
pub fn translate(_: *CanvasRenderingContext2D, _: f64, _: f64) void {}
pub fn transform(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn setTransform(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64, _: f64) void {}
pub fn resetTransform(_: *CanvasRenderingContext2D) void {}
pub fn beginPath(self: *CanvasRenderingContext2D) void {
    self._path_cmds.clearRetainingCapacity();
    self._has_current_point = false;
}

pub fn closePath(self: *CanvasRenderingContext2D) void {
    if (!self._has_current_point) return;
    const arena = self._arena orelse return;
    // Add line back to sub-path start.
    if (self._current_x != self._sub_path_start_x or self._current_y != self._sub_path_start_y) {
        self._path_cmds.append(arena, .{ .line_to = .{ .x = self._sub_path_start_x, .y = self._sub_path_start_y } }) catch return;
    }
    self._current_x = self._sub_path_start_x;
    self._current_y = self._sub_path_start_y;
}

pub fn moveTo(self: *CanvasRenderingContext2D, x: f64, y: f64) void {
    if (!isFiniteCoord(x) or !isFiniteCoord(y)) return;
    const arena = self._arena orelse return;
    self._path_cmds.append(arena, .{ .move_to = .{ .x = x, .y = y } }) catch return;
    self._current_x = x;
    self._current_y = y;
    self._sub_path_start_x = x;
    self._sub_path_start_y = y;
    self._has_current_point = true;
}

pub fn lineTo(self: *CanvasRenderingContext2D, x: f64, y: f64) void {
    if (!isFiniteCoord(x) or !isFiniteCoord(y)) return;
    const arena = self._arena orelse return;
    if (!self._has_current_point) {
        // Per spec: if no current point, lineTo behaves like moveTo.
        self._path_cmds.append(arena, .{ .move_to = .{ .x = x, .y = y } }) catch return;
        self._sub_path_start_x = x;
        self._sub_path_start_y = y;
        self._has_current_point = true;
    } else {
        self._path_cmds.append(arena, .{ .line_to = .{ .x = x, .y = y } }) catch return;
    }
    self._current_x = x;
    self._current_y = y;
}

pub fn quadraticCurveTo(self: *CanvasRenderingContext2D, cpx: f64, cpy: f64, x: f64, y: f64) void {
    if (!isFiniteCoord(cpx) or !isFiniteCoord(cpy) or !isFiniteCoord(x) or !isFiniteCoord(y)) return;
    if (!self._has_current_point) return;
    const arena = self._arena orelse return;
    self.flattenQuadraticBezier(arena, self._current_x, self._current_y, cpx, cpy, x, y);
}

pub fn bezierCurveTo(self: *CanvasRenderingContext2D, cp1x: f64, cp1y: f64, cp2x: f64, cp2y: f64, x: f64, y: f64) void {
    if (!isFiniteCoord(cp1x) or !isFiniteCoord(cp1y) or !isFiniteCoord(cp2x) or !isFiniteCoord(cp2y) or !isFiniteCoord(x) or !isFiniteCoord(y)) return;
    if (!self._has_current_point) return;
    const arena = self._arena orelse return;
    self.flattenCubicBezier(arena, self._current_x, self._current_y, cp1x, cp1y, cp2x, cp2y, x, y);
}

pub fn arc(self: *CanvasRenderingContext2D, x: f64, y: f64, radius: f64, start_angle: f64, end_angle: f64, ccw_opt: ?bool) void {
    if (!isFiniteCoord(x) or !isFiniteCoord(y) or !isFiniteCoord(radius)) return;
    if (!isFiniteCoord(start_angle) or !isFiniteCoord(end_angle)) return;
    if (radius < 0.0) return; // Per spec: should throw RangeError, silent skip for stealth.
    const arena = self._arena orelse return;
    const counterclockwise = ccw_opt orelse false;
    const tau = 2.0 * std.math.pi;

    if (radius == 0.0) {
        // Zero-radius arc is just a point.
        self.lineTo(x, y);
        return;
    }

    // Compute angle span normalized to the correct direction.
    var span = end_angle - start_angle;
    if (counterclockwise) {
        if (span > 0.0) span -= tau * @ceil(span / tau);
        if (span == 0.0 and start_angle != end_angle) span = -tau;
    } else {
        if (span < 0.0) span += tau * @ceil(-span / tau);
        if (span == 0.0 and start_angle != end_angle) span = tau;
    }

    // If span is zero (identical angles), nothing to draw.
    if (span == 0.0) return;

    // ~32 segments per full circle.
    const abs_span = @abs(span);
    const n_seg_f = @max(1.0, @ceil(abs_span / tau * 32.0));
    const n_segments: u32 = @intFromFloat(@min(256.0, n_seg_f));
    const step = span / @as(f64, @floatFromInt(n_segments));

    var i: u32 = 0;
    while (i <= n_segments) : (i += 1) {
        const angle = start_angle + @as(f64, @floatFromInt(i)) * step;
        const px = x + radius * @cos(angle);
        const py = y + radius * @sin(angle);

        if (i == 0) {
            if (self._has_current_point) {
                // Per spec: draw a straight line from current point to arc start.
                self._path_cmds.append(arena, .{ .line_to = .{ .x = px, .y = py } }) catch return;
            } else {
                self._path_cmds.append(arena, .{ .move_to = .{ .x = px, .y = py } }) catch return;
                self._sub_path_start_x = px;
                self._sub_path_start_y = py;
                self._has_current_point = true;
            }
        } else {
            self._path_cmds.append(arena, .{ .line_to = .{ .x = px, .y = py } }) catch return;
        }

        self._current_x = px;
        self._current_y = py;
    }
}

pub fn arcTo(_: *CanvasRenderingContext2D, _: f64, _: f64, _: f64, _: f64, _: f64) void {
    // arcTo is rarely used by bot detectors — keep as noop.
}

pub fn rect(self: *CanvasRenderingContext2D, x: f64, y: f64, w: f64, h: f64) void {
    if (!isFiniteCoord(x) or !isFiniteCoord(y) or !isFiniteCoord(w) or !isFiniteCoord(h)) return;
    // rect() is shorthand for moveTo + 3×lineTo + closePath.
    self.moveTo(x, y);
    self.lineTo(x + w, y);
    self.lineTo(x + w, y + h);
    self.lineTo(x, y + h);
    self.closePath();
}

pub fn fill(self: *CanvasRenderingContext2D) void {
    self.fillPath();
}

pub fn stroke(self: *CanvasRenderingContext2D) void {
    self.strokePath();
}

pub fn clip(_: *CanvasRenderingContext2D) void {
    // clip() is complex to implement — keep as noop for stealth.
}
pub fn fillText(self: *CanvasRenderingContext2D, text: []const u8, x: f64, y: f64, _: ?f64) void {
    if (!isFiniteCoord(x) or !isFiniteCoord(y)) return;
    if (text.len == 0) return;
    if (!self.ensurePixelBuffer()) return;
    self.renderText(text, x, y, self._fill_style);

    // Apply fingerprint noise to the text bounding region.
    // Text baseline is "alphabetic" (default), so text extends above and below y.
    const text_w = computeTextWidth(text, self._font_size);
    const region_h = self._font_size * 1.5; // approximate ascent + descent
    const rx = @max(0.0, x);
    const ry = @max(0.0, y - self._font_size);
    const canvas_w: f64 = @floatFromInt(self._width);
    const canvas_h: f64 = @floatFromInt(self._height);
    if (rx >= canvas_w or ry >= canvas_h) return;
    const rw = @min(text_w + 1.0, canvas_w - rx);
    const rh = @min(region_h, canvas_h - ry);
    if (rw <= 0.0 or rh <= 0.0) return;
    self.applyFingerprintNoise(
        @intFromFloat(rx),
        @intFromFloat(ry),
        @intFromFloat(@ceil(rw)),
        @intFromFloat(@ceil(rh)),
    );
}

pub fn strokeText(self: *CanvasRenderingContext2D, text: []const u8, x: f64, y: f64, _: ?f64) void {
    // Approximate strokeText as filled text — acceptable for stealth purposes.
    // Real browsers render outlined glyphs, but the visual difference is minimal
    // and bot detectors check for non-blank output, not exact rendering.
    if (!isFiniteCoord(x) or !isFiniteCoord(y)) return;
    if (text.len == 0) return;
    if (!self.ensurePixelBuffer()) return;
    self.renderText(text, x, y, self._stroke_style);
}

pub fn measureText(self: *CanvasRenderingContext2D, text: []const u8, page: *Page) !*TextMetrics {
    const width = computeTextWidth(text, self._font_size);

    // Compute additional metrics from font vertical metrics.
    var font_ascent: f64 = 0;
    var font_descent: f64 = 0;
    if (ensureFont()) {
        var asc: c_int = 0;
        var desc: c_int = 0;
        var lg: c_int = 0;
        stb.lp_font_get_vmetrics(&font_info, &asc, &desc, &lg);
        const sc: f64 = @floatCast(stb.lp_font_scale(&font_info, @floatCast(self._font_size)));
        font_ascent = @as(f64, @floatFromInt(asc)) * sc;
        font_descent = @abs(@as(f64, @floatFromInt(desc)) * sc);
    }

    return page._factory.create(TextMetrics{
        ._width = width,
        ._actual_bounding_box_right = width,
        ._font_bounding_box_ascent = font_ascent,
        ._font_bounding_box_descent = font_descent,
        ._actual_bounding_box_ascent = font_ascent,
        ._actual_bounding_box_descent = font_descent,
        ._em_height_ascent = font_ascent,
        ._em_height_descent = font_descent,
    });
}

pub fn getFont(self: *const CanvasRenderingContext2D) []const u8 {
    return self._font_str;
}

pub fn setFont(self: *CanvasRenderingContext2D, value: []const u8) void {
    // Parse font size from CSS font shorthand (e.g., "14px Arial", "bold 12pt serif").
    // We only extract the numeric size; font family is always Liberation Sans.
    self._font_size = parseFontSize(value);
    // Store the raw string for the getter (per spec, font getter returns what was set).
    self._font_str = value;
}

/// Parse a CSS font size value from a font shorthand string.
/// Looks for a pattern like "NNpx" or "NNpt" in the string.
/// Returns the parsed size in pixels, or 10.0 as default.
fn parseFontSize(font_str: []const u8) f64 {
    // Find "px" or "pt" suffix and parse the number before it.
    var i: usize = 0;
    while (i + 1 < font_str.len) : (i += 1) {
        if ((font_str[i] == 'p' and (font_str[i + 1] == 'x' or font_str[i + 1] == 't'))) {
            const is_pt = font_str[i + 1] == 't';
            // Scan backwards to find the start of the number.
            const num_end = i;
            var j = i;
            while (j > 0) {
                j -= 1;
                const c = font_str[j];
                if ((c >= '0' and c <= '9') or c == '.') {
                    continue;
                }
                break;
            }
            const num_start = if (j == 0 and ((font_str[0] >= '0' and font_str[0] <= '9') or font_str[0] == '.')) 0 else j + 1;
            if (num_start < num_end) {
                const size = std.fmt.parseFloat(f64, font_str[num_start..num_end]) catch return 10.0;
                return if (is_pt) size * 4.0 / 3.0 else size; // 1pt = 4/3 px
            }
        }
    }
    return 10.0;
}

// --- JS API bridge ---

pub const JsApi = struct {
    pub const bridge = js.Bridge(CanvasRenderingContext2D);

    pub const Meta = struct {
        pub const name = "CanvasRenderingContext2D";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const canvas = bridge.accessor(CanvasRenderingContext2D.getCanvas, null, .{});
    pub const font = bridge.accessor(CanvasRenderingContext2D.getFont, CanvasRenderingContext2D.setFont, .{});
    pub const globalCompositeOperation = bridge.property("source-over", .{ .template = false, .readonly = false });
    pub const lineCap = bridge.property("butt", .{ .template = false, .readonly = false });
    pub const lineJoin = bridge.property("miter", .{ .template = false, .readonly = false });
    pub const miterLimit = bridge.property(10.0, .{ .template = false, .readonly = false });
    pub const textAlign = bridge.property("start", .{ .template = false, .readonly = false });
    pub const textBaseline = bridge.property("alphabetic", .{ .template = false, .readonly = false });

    // Properties backed by Zig struct fields (needed for drawing operations).
    pub const fillStyle = bridge.accessor(CanvasRenderingContext2D.getFillStyle, CanvasRenderingContext2D.setFillStyle, .{});
    pub const strokeStyle = bridge.accessor(CanvasRenderingContext2D.getStrokeStyle, CanvasRenderingContext2D.setStrokeStyle, .{});
    pub const globalAlpha = bridge.accessor(CanvasRenderingContext2D.getGlobalAlpha, CanvasRenderingContext2D.setGlobalAlpha, .{});
    pub const lineWidth = bridge.accessor(CanvasRenderingContext2D.getLineWidth, CanvasRenderingContext2D.setLineWidth, .{});

    pub const createImageData = bridge.function(CanvasRenderingContext2D.createImageData, .{ .dom_exception = true });
    pub const putImageData = bridge.function(CanvasRenderingContext2D.putImageData, .{});
    pub const getImageData = bridge.function(CanvasRenderingContext2D.getImageData, .{ .dom_exception = true });
    pub const save = bridge.function(CanvasRenderingContext2D.save, .{});
    pub const restore = bridge.function(CanvasRenderingContext2D.restore, .{});
    pub const scale = bridge.function(CanvasRenderingContext2D.scale, .{ .noop = true });
    pub const rotate = bridge.function(CanvasRenderingContext2D.rotate, .{ .noop = true });
    pub const translate = bridge.function(CanvasRenderingContext2D.translate, .{ .noop = true });
    pub const transform = bridge.function(CanvasRenderingContext2D.transform, .{ .noop = true });
    pub const setTransform = bridge.function(CanvasRenderingContext2D.setTransform, .{ .noop = true });
    pub const resetTransform = bridge.function(CanvasRenderingContext2D.resetTransform, .{ .noop = true });
    // Drawing operations — no longer noops.
    pub const clearRect = bridge.function(CanvasRenderingContext2D.clearRect, .{});
    pub const fillRect = bridge.function(CanvasRenderingContext2D.fillRect, .{});
    pub const strokeRect = bridge.function(CanvasRenderingContext2D.strokeRect, .{});
    // Path methods — no longer noops (Phase 8 Task 4).
    pub const beginPath = bridge.function(CanvasRenderingContext2D.beginPath, .{});
    pub const closePath = bridge.function(CanvasRenderingContext2D.closePath, .{});
    pub const moveTo = bridge.function(CanvasRenderingContext2D.moveTo, .{});
    pub const lineTo = bridge.function(CanvasRenderingContext2D.lineTo, .{});
    pub const quadraticCurveTo = bridge.function(CanvasRenderingContext2D.quadraticCurveTo, .{});
    pub const bezierCurveTo = bridge.function(CanvasRenderingContext2D.bezierCurveTo, .{});
    pub const arc = bridge.function(CanvasRenderingContext2D.arc, .{});
    pub const arcTo = bridge.function(CanvasRenderingContext2D.arcTo, .{ .noop = true });
    pub const rect = bridge.function(CanvasRenderingContext2D.rect, .{});
    pub const fill = bridge.function(CanvasRenderingContext2D.fill, .{});
    pub const stroke = bridge.function(CanvasRenderingContext2D.stroke, .{});
    pub const clip = bridge.function(CanvasRenderingContext2D.clip, .{ .noop = true });
    pub const fillText = bridge.function(CanvasRenderingContext2D.fillText, .{});
    pub const strokeText = bridge.function(CanvasRenderingContext2D.strokeText, .{});
    pub const measureText = bridge.function(CanvasRenderingContext2D.measureText, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: CanvasRenderingContext2D" {
    try testing.htmlRunner("canvas/canvas_rendering_context_2d.html", .{});
}
