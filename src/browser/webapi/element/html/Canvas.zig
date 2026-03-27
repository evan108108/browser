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
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Session = @import("../../../Session.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Blob = @import("../../Blob.zig");
const CanvasRenderingContext2D = @import("../../canvas/CanvasRenderingContext2D.zig");
const WebGLRenderingContext = @import("../../canvas/WebGLRenderingContext.zig");
const OffscreenCanvas = @import("../../canvas/OffscreenCanvas.zig");
const png_encoder = @import("../../canvas/png_encoder.zig");

const log = @import("../../../../log.zig");

const Canvas = @This();
_proto: *HtmlElement,

/// Cached context type. Once set, requesting a different type returns null (per spec).
_context_type: ContextType = .none,
/// Cached 2D rendering context (same object returned on repeated getContext("2d") calls).
_ctx_2d: ?*CanvasRenderingContext2D = null,

const ContextType = enum { none, @"2d", webgl };

pub fn asElement(self: *Canvas) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Canvas) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Canvas) *Node {
    return self.asElement().asNode();
}

pub fn getWidth(self: *const Canvas) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("width")) orelse return 300;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 300;
}

pub fn setWidth(self: *Canvas, value: u32, page: *Page) !void {
    const str = try std.fmt.allocPrint(page.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("width"), .wrap(str), page);
    // Per spec: setting width/height resets the context state and clears the pixel buffer.
    if (self._ctx_2d) |ctx| {
        ctx.reset(value, self.getHeight());
    }
}

pub fn getHeight(self: *const Canvas) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("height")) orelse return 150;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 150;
}

pub fn setHeight(self: *Canvas, value: u32, page: *Page) !void {
    const str = try std.fmt.allocPrint(page.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("height"), .wrap(str), page);
    // Per spec: setting width/height resets the context state and clears the pixel buffer.
    if (self._ctx_2d) |ctx| {
        ctx.reset(self.getWidth(), value);
    }
}

/// Since there's no base class rendering contextes inherit from,
/// we're using tagged union.
const DrawingContext = union(enum) {
    @"2d": *CanvasRenderingContext2D,
    webgl: *WebGLRenderingContext,
};

pub fn getContext(self: *Canvas, context_type: []const u8, page: *Page) !?DrawingContext {
    if (std.mem.eql(u8, context_type, "2d")) {
        // Return cached context if available.
        if (self._ctx_2d) |cached| return .{ .@"2d" = cached };
        // Per spec: return null if a different context type was already requested.
        if (self._context_type != .none) return null;

        // Only allocate a pixel-buffer arena in stealth mode (needed for
        // software rendering). In non-stealth mode, draw ops are effectively
        // no-ops and no pixel buffer is ever used — avoiding arena leaks.
        const arena: ?std.mem.Allocator = if (page._session.browser.app.config.isStealth())
            try page.getArena(.{ .debug = "CanvasRenderingContext2D" })
        else
            null;
        const ctx = try page._factory.create(CanvasRenderingContext2D{
            ._arena = arena,
            ._width = self.getWidth(),
            ._height = self.getHeight(),
            ._noise_seed = @truncate(@as(u64, @bitCast(std.time.milliTimestamp()))),
        });
        self._ctx_2d = ctx;
        self._context_type = .@"2d";
        return .{ .@"2d" = ctx };
    }

    if (std.mem.eql(u8, context_type, "webgl") or std.mem.eql(u8, context_type, "experimental-webgl")) {
        // Per spec: return null if a different context type was already requested.
        if (self._context_type != .none and self._context_type != .webgl) return null;

        // WebGL context is not cached yet (no pixel buffer to manage).
        const ctx = try page._factory.create(WebGLRenderingContext{});
        self._context_type = .webgl;
        return .{ .webgl = ctx };
    }

    return null;
}

/// Transfers control of the canvas to an OffscreenCanvas.
/// Returns an OffscreenCanvas with the same dimensions.
pub fn transferControlToOffscreen(self: *Canvas, page: *Page) !*OffscreenCanvas {
    const width = self.getWidth();
    const height = self.getHeight();
    return OffscreenCanvas.constructor(width, height, page);
}

/// Asynchronously creates a Blob object representing the image contained in the canvas.
/// Per spec: callback is invoked asynchronously (via scheduler with 0ms delay).
/// https://developer.mozilla.org/en-US/docs/Web/API/HTMLCanvasElement/toBlob
pub fn toBlob(self: *Canvas, maybe_callback: ?js.Function.Temp, maybe_type: ?[]const u8, _: ?f64, page: *Page) !void {
    _ = maybe_type; // Only PNG supported; type parameter is ignored.

    const callback = maybe_callback orelse return;

    const arena = try page.getArena(.{ .debug = "Canvas.toBlob" });
    errdefer page.releaseArena(arena);

    const cb_ctx = try arena.create(ToBlobCallback);
    cb_ctx.* = .{
        .cb = callback,
        .canvas = self,
        .page = page,
        .arena = arena,
    };

    try page.js.scheduler.add(cb_ctx, ToBlobCallback.run, 0, .{
        .name = "canvas.toBlob",
        .finalizer = ToBlobCallback.cancelled,
    });
}

const ToBlobCallback = struct {
    cb: js.Function.Temp,
    canvas: *Canvas,
    page: *Page,
    arena: Allocator,

    fn cancelled(ctx: *anyopaque) void {
        const self: *ToBlobCallback = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn deinit(self: *ToBlobCallback) void {
        self.cb.release();
        self.page.releaseArena(self.arena);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ToBlobCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        const page = self.page;
        const canvas = self.canvas;
        const w = canvas.getWidth();
        const h = canvas.getHeight();

        // Encode canvas pixels to raw PNG bytes.
        const pixels: ?[]const u8 = if (canvas._ctx_2d) |c| c._pixels else null;
        const png_bytes = png_encoder.encodePngRaw(pixels, w, h, page.call_arena) catch |err| {
            log.warn(.js, "toBlob PNG encode fail", .{ .err = err });
            // Per spec: call callback with null on failure.
            var ls: js.Local.Scope = undefined;
            page.js.localScope(&ls);
            defer ls.deinit();
            ls.toLocal(self.cb).call(void, .{@as(?*Blob, null)}) catch {};
            return null;
        };

        // Create a Blob from the PNG data.
        const blob = Blob.init(
            &.{png_bytes},
            .{ .type = "image/png" },
            page,
        ) catch |err| {
            log.warn(.js, "toBlob Blob create fail", .{ .err = err });
            var ls: js.Local.Scope = undefined;
            page.js.localScope(&ls);
            defer ls.deinit();
            ls.toLocal(self.cb).call(void, .{@as(?*Blob, null)}) catch {};
            return null;
        };

        // Invoke the callback with the Blob.
        var ls: js.Local.Scope = undefined;
        page.js.localScope(&ls);
        defer ls.deinit();
        ls.toLocal(self.cb).call(void, .{blob}) catch |err| {
            log.warn(.js, "toBlob callback fail", .{ .err = err });
        };
        ls.local.runMicrotasks();

        return null;
    }
};

/// Returns a data URI containing a representation of the image in PNG format.
/// Per spec: only PNG is required; JPEG/WebP support is optional.
/// https://developer.mozilla.org/en-US/docs/Web/API/HTMLCanvasElement/toDataURL
pub fn toDataURL(self: *Canvas, maybe_type: ?[]const u8, _: ?f64, page: *Page) ![]const u8 {
    _ = maybe_type; // Only PNG supported; type parameter is ignored.

    const w = self.getWidth();
    const h = self.getHeight();

    // Per spec: zero-dimension canvas returns "data:,".
    if (w == 0 or h == 0) {
        return "data:,";
    }

    // Read pixel buffer from the 2D context (if one exists and has been drawn to).
    const pixels: ?[]const u8 = if (self._ctx_2d) |ctx| ctx._pixels else null;

    // Encode to PNG and base64. Allocate on call_arena (freed after JS call returns).
    return png_encoder.encodePngBase64(pixels, w, h, page.call_arena);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Canvas);

    pub const Meta = struct {
        pub const name = "HTMLCanvasElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const width = bridge.accessor(Canvas.getWidth, Canvas.setWidth, .{});
    pub const height = bridge.accessor(Canvas.getHeight, Canvas.setHeight, .{});
    pub const getContext = bridge.function(Canvas.getContext, .{});
    pub const toDataURL = bridge.function(Canvas.toDataURL, .{});
    pub const toBlob = bridge.function(Canvas.toBlob, .{});
    pub const transferControlToOffscreen = bridge.function(Canvas.transferControlToOffscreen, .{});
};
