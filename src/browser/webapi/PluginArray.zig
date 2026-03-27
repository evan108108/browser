// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

pub fn registerTypes() []const type {
    return &.{ PluginArray, Plugin, MimeType };
}

const PluginArray = @This();

// Fields — fully comptime-initialized, no mutation needed.
// The struct may reside in read-only memory (__TEXT segment on macOS),
// so all fields must be set at comptime to avoid SIGBUS on write.
_pad: bool = false,
_plugins: [5]Plugin = .{
    makePlugin("PDF Viewer"),
    makePlugin("Chrome PDF Viewer"),
    makePlugin("Chromium PDF Viewer"),
    makePlugin("Microsoft Edge PDF Viewer"),
    makePlugin("WebKit built-in PDF"),
},

fn makePlugin(comptime name: []const u8) Plugin {
    return .{
        .name = name,
        .description = "Portable Document Format",
        .filename = "internal-pdf-viewer",
    };
}

pub fn refresh(_: *const PluginArray) void {}

pub fn getLength(_: *const PluginArray, page: *Page) u32 {
    if (page._session.browser.app.config.isStealth()) return 5;
    return 0;
}

pub fn getAtIndex(self: *PluginArray, index: usize, page: *Page) ?*Plugin {
    if (!page._session.browser.app.config.isStealth()) return null;
    if (index < 5) return &self._plugins[index];
    return null;
}

pub fn getByName(self: *PluginArray, name: []const u8, page: *Page) ?*Plugin {
    if (!page._session.browser.app.config.isStealth()) return null;
    for (&self._plugins) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

// --- Plugin struct ---

const Plugin = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    filename: []const u8 = "",
    _mime_type: MimeType = .{},

    pub fn getName(self: *const Plugin) []const u8 {
        return self.name;
    }

    pub fn getDescription(self: *const Plugin) []const u8 {
        return self.description;
    }

    pub fn getFilename(self: *const Plugin) []const u8 {
        return self.filename;
    }

    pub fn getItem(self: *Plugin, index: i32) ?*MimeType {
        if (index == 0) return &self._mime_type;
        return null;
    }

    pub fn getAtIndex(self: *Plugin, index: usize) ?*MimeType {
        if (index == 0) return &self._mime_type;
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Plugin);
        pub const Meta = struct {
            pub const name = "Plugin";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const name = bridge.accessor(Plugin.getName, null, .{});
        pub const description = bridge.accessor(Plugin.getDescription, null, .{});
        pub const filename = bridge.accessor(Plugin.getFilename, null, .{});
        pub const length = bridge.property(1, .{ .template = false });
        pub const item = bridge.function(Plugin.getItem, .{});
        pub const @"[int]" = bridge.indexed(Plugin.getAtIndex, null, .{ .null_as_undefined = true });
    };
};

// --- MimeType struct ---

const MimeType = struct {
    _type: []const u8 = "application/pdf",
    _description: []const u8 = "Portable Document Format",
    _suffixes: []const u8 = "pdf",

    pub fn getType(self: *const MimeType) []const u8 {
        return self._type;
    }

    pub fn getDescription(self: *const MimeType) []const u8 {
        return self._description;
    }

    pub fn getSuffixes(self: *const MimeType) []const u8 {
        return self._suffixes;
    }

    /// Navigate from MimeType back to the parent Plugin via @fieldParentPtr.
    /// This avoids storing a mutable pointer (which would require runtime init
    /// and cause SIGBUS when the struct is in read-only memory).
    pub fn getEnabledPlugin(self: *const MimeType) *Plugin {
        return @constCast(@fieldParentPtr("_mime_type", self));
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MimeType);
        pub const Meta = struct {
            pub const name = "MimeType";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const @"type" = bridge.accessor(MimeType.getType, null, .{});
        pub const description = bridge.accessor(MimeType.getDescription, null, .{});
        pub const suffixes = bridge.accessor(MimeType.getSuffixes, null, .{});
        pub const enabledPlugin = bridge.accessor(MimeType.getEnabledPlugin, null, .{});
    };
};

// --- PluginArray JsApi ---

pub const JsApi = struct {
    pub const bridge = js.Bridge(PluginArray);

    pub const Meta = struct {
        pub const name = "PluginArray";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const length = bridge.accessor(PluginArray.getLength, null, .{});
    pub const refresh = bridge.function(PluginArray.refresh, .{});
    pub const @"[int]" = bridge.indexed(PluginArray.getAtIndex, null, .{ .null_as_undefined = true });
    pub const @"[str]" = bridge.namedIndexed(PluginArray.getByName, null, null, .{ .null_as_undefined = true });
    pub const item = bridge.function(_item, .{});
    fn _item(self: *PluginArray, index: i32, page: *Page) ?*Plugin {
        if (index < 0) return null;
        return self.getAtIndex(@intCast(index), page);
    }
    pub const namedItem = bridge.function(PluginArray.getByName, .{});
};
