// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

/// Minimal PNG encoder for Canvas toDataURL().
///
/// Produces valid PNG files with RGBA pixel data. Uses zlib stored blocks
/// (uncompressed DEFLATE) for simplicity — output is slightly larger but
/// every PNG decoder supports this. For canvas bot detection, compression
/// ratio doesn't matter; validity does.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Crc32 = std.hash.crc.Crc32;
const Adler32 = std.hash.Adler32;

/// PNG file signature (8 bytes).
const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

/// Encode RGBA pixel data as raw PNG bytes.
///
/// `pixels` may be null (no draws yet), in which case an all-transparent PNG is generated.
/// The returned slice is allocated on `allocator`.
pub fn encodePngRaw(pixels: ?[]const u8, width: u32, height: u32, allocator: Allocator) ![]const u8 {
    const scanline_size = @as(usize, width) * 4 + 1; // filter byte + RGBA
    const raw_size = scanline_size * @as(usize, height);

    var png: std.ArrayList(u8) = try std.ArrayList(u8).initCapacity(allocator, raw_size + 256);
    defer png.deinit(allocator);

    // --- PNG signature ---
    try png.appendSlice(allocator, &png_signature);

    // --- IHDR chunk ---
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type: RGBA
    ihdr[10] = 0; // compression method: deflate
    ihdr[11] = 0; // filter method: adaptive
    ihdr[12] = 0; // interlace method: none
    try writeChunk(allocator, &png, "IHDR", &ihdr);

    // --- IDAT chunk (zlib-compressed filtered scanlines) ---
    var idat: std.ArrayList(u8) = .{};
    defer idat.deinit(allocator);
    try zlibStoredScanlines(allocator, &idat, pixels, width, height);
    try writeChunk(allocator, &png, "IDAT", idat.items);

    // --- IEND chunk ---
    try writeChunk(allocator, &png, "IEND", &[_]u8{});

    return allocator.dupe(u8, png.items);
}

/// Encode RGBA pixel data as a PNG and return a base64 data URI string.
///
/// `pixels` may be null (no draws yet), in which case an all-transparent PNG is generated.
/// The returned string is allocated on `allocator` and looks like:
///   "data:image/png;base64,iVBORw0KGgo..."
pub fn encodePngBase64(pixels: ?[]const u8, width: u32, height: u32, allocator: Allocator) ![]const u8 {
    const png_bytes = try encodePngRaw(pixels, width, height, allocator);
    defer allocator.free(png_bytes);

    const prefix = "data:image/png;base64,";
    const encoder = std.base64.standard.Encoder;
    const b64_len = encoder.calcSize(png_bytes.len);
    const result = try allocator.alloc(u8, prefix.len + b64_len);
    @memcpy(result[0..prefix.len], prefix);
    _ = encoder.encode(result[prefix.len..], png_bytes);

    return result;
}

/// Write a PNG chunk: length (4 bytes BE) + type (4 bytes) + data + CRC32 (4 bytes BE).
/// CRC32 covers the type + data bytes.
fn writeChunk(allocator: Allocator, png: *std.ArrayList(u8), chunk_type: *const [4]u8, data: []const u8) !void {
    // Length (of data only, not including type or CRC).
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try png.appendSlice(allocator, &len_buf);

    // Type.
    try png.appendSlice(allocator, chunk_type);

    // Data.
    try png.appendSlice(allocator, data);

    // CRC32 over type + data.
    var crc = Crc32.init();
    crc.update(chunk_type);
    crc.update(data);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .big);
    try png.appendSlice(allocator, &crc_buf);
}

/// Produce a zlib stream (RFC 1950) containing filtered PNG scanlines using
/// stored (uncompressed) DEFLATE blocks.
///
/// Format: zlib header (2 bytes) + stored blocks + Adler32 footer (4 bytes).
/// Each stored block: BFINAL|BTYPE (1 byte) + LEN (2 bytes LE) + ~LEN (2 bytes LE) + data.
/// Max block size is 65535 bytes.
fn zlibStoredScanlines(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    pixels: ?[]const u8,
    width: u32,
    height: u32,
) !void {
    const scanline_size = @as(usize, width) * 4 + 1; // filter_byte + width * RGBA
    const total_size = scanline_size * @as(usize, height);

    // Pre-allocate for the worst case: header + block overhead + data + footer.
    const num_blocks = if (total_size == 0) 1 else (total_size + 65534) / 65535;
    try out.ensureTotalCapacity(allocator, 2 + num_blocks * 5 + total_size + 4);

    // Zlib header: CMF=0x78 (deflate, window=32K), FLG=0x01 (level=fastest, check ok).
    // FLG check: (0x78 * 256 + 0x01) % 31 == 0  => 30721 % 31 == 0 ✓
    try out.appendSlice(allocator, &[_]u8{ 0x78, 0x01 });

    // Build the raw filtered scanline data and compress into stored blocks.
    // We accumulate an Adler32 checksum over all raw data.
    var adler: Adler32 = .{};

    if (height == 0 or width == 0) {
        // Empty image — emit one empty final stored block.
        try out.appendSlice(allocator, &[_]u8{ 0x01, 0x00, 0x00, 0xff, 0xff });
    } else {
        // Process scanlines, packing them into stored blocks (max 65535 bytes each).
        // We build the full raw filtered data first, then split into blocks.
        // Each scanline: 0x00 (filter=None) + width*4 RGBA bytes.
        var raw = try std.ArrayList(u8).initCapacity(allocator, total_size);
        defer raw.deinit(allocator);

        var y: u32 = 0;
        while (y < height) : (y += 1) {
            // Filter byte: 0 = None (no filtering).
            try raw.append(allocator, 0);
            // Pixel row data.
            if (pixels) |px| {
                const row_start = @as(usize, y) * @as(usize, width) * 4;
                const row_end = row_start + @as(usize, width) * 4;
                try raw.appendSlice(allocator, px[row_start..row_end]);
            } else {
                // No pixel buffer — all transparent (zeros).
                try raw.appendNTimes(allocator, 0, @as(usize, width) * 4);
            }
        }

        // Update Adler32 checksum over all raw data.
        adler.update(raw.items);

        // Emit stored DEFLATE blocks.
        var offset: usize = 0;
        while (offset < raw.items.len) {
            const remaining = raw.items.len - offset;
            const block_len: u16 = @intCast(@min(remaining, 65535));
            const is_final = (offset + block_len >= raw.items.len);

            // Block header byte: bit 0 = BFINAL, bits 1-2 = BTYPE (00 = stored).
            try out.append(allocator, if (is_final) @as(u8, 0x01) else @as(u8, 0x00));

            // LEN and NLEN (one's complement).
            var len_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &len_buf, block_len, .little);
            try out.appendSlice(allocator, &len_buf);
            std.mem.writeInt(u16, &len_buf, ~block_len, .little);
            try out.appendSlice(allocator, &len_buf);

            // Block data.
            try out.appendSlice(allocator, raw.items[offset..][0..block_len]);
            offset += block_len;
        }
    }

    // Zlib footer: Adler32 checksum (big-endian).
    var adler_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_buf, adler.adler, .big);
    try out.appendSlice(allocator, &adler_buf);
}

// --- Tests ---

test "PNG encoder: produces valid data URI prefix" {
    const allocator = std.testing.allocator;

    // 1x1 transparent PNG (null pixels).
    const result = try encodePngBase64(null, 1, 1, allocator);
    defer allocator.free(result);

    try std.testing.expect(std.mem.startsWith(u8, result, "data:image/png;base64,"));
}

test "PNG encoder: zero-dimension canvas" {
    const allocator = std.testing.allocator;

    // 0x0 should still produce a valid PNG.
    const result = try encodePngBase64(null, 0, 0, allocator);
    defer allocator.free(result);

    try std.testing.expect(std.mem.startsWith(u8, result, "data:image/png;base64,"));
}

test "PNG encoder: 2x2 red square" {
    const allocator = std.testing.allocator;

    // 2x2 fully opaque red pixels (RGBA).
    var pixels: [2 * 2 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        pixels[i * 4] = 255; // R
        pixels[i * 4 + 1] = 0; // G
        pixels[i * 4 + 2] = 0; // B
        pixels[i * 4 + 3] = 255; // A
    }

    const result = try encodePngBase64(&pixels, 2, 2, allocator);
    defer allocator.free(result);

    try std.testing.expect(std.mem.startsWith(u8, result, "data:image/png;base64,"));
    // Verify it's longer than just the prefix (actual data was encoded).
    try std.testing.expect(result.len > 30);
}
