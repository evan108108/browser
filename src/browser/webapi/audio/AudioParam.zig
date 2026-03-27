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

const js = @import("../../js/js.zig");

const AudioParam = @This();

_value: f64 = 0,
_default_value: f64 = 0,
_min_value: f64 = -3.4028235e+38,
_max_value: f64 = 3.4028235e+38,

pub fn getValue(self: *const AudioParam) f64 {
    return self._value;
}

pub fn setValue(self: *AudioParam, value: f64) void {
    self._value = value;
}

pub fn getDefaultValue(self: *const AudioParam) f64 {
    return self._default_value;
}

pub fn getMinValue(self: *const AudioParam) f64 {
    return self._min_value;
}

pub fn getMaxValue(self: *const AudioParam) f64 {
    return self._max_value;
}

// Automation methods — all just store the value (ignore time)
pub fn setValueAtTime(self: *AudioParam, value: f64, _: f64) void {
    self._value = value;
}

pub fn linearRampToValueAtTime(self: *AudioParam, value: f64, _: f64) void {
    self._value = value;
}

pub fn exponentialRampToValueAtTime(self: *AudioParam, value: f64, _: f64) void {
    self._value = value;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioParam);
    pub const Meta = struct {
        pub const name = "AudioParam";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        // NOTE: Do NOT use empty_with_no_proto here — mutable _value state
        // must persist across JS accesses (Phase 7 PluginArray bug lesson).
    };

    pub const value = bridge.accessor(AudioParam.getValue, AudioParam.setValue, .{});
    pub const defaultValue = bridge.accessor(AudioParam.getDefaultValue, null, .{});
    pub const minValue = bridge.accessor(AudioParam.getMinValue, null, .{});
    pub const maxValue = bridge.accessor(AudioParam.getMaxValue, null, .{});
    pub const setValueAtTime = bridge.function(AudioParam.setValueAtTime, .{});
    pub const linearRampToValueAtTime = bridge.function(AudioParam.linearRampToValueAtTime, .{});
    pub const exponentialRampToValueAtTime = bridge.function(AudioParam.exponentialRampToValueAtTime, .{});
};
