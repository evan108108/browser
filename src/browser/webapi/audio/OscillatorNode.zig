const js = @import("../../js/js.zig");
const AudioParam = @import("AudioParam.zig");

const OscillatorNode = @This();

_type: []const u8 = "sine",
_frequency: AudioParam = .{ ._value = 440, ._default_value = 440 },
_detune: AudioParam = .{ ._value = 0, ._default_value = 0 },

pub fn getType(self: *const OscillatorNode) []const u8 {
    return self._type;
}

pub fn setType(self: *OscillatorNode, value: []const u8) void {
    self._type = value;
}

pub fn getFrequency(self: *OscillatorNode) *AudioParam {
    return &self._frequency;
}

pub fn getDetune(self: *OscillatorNode) *AudioParam {
    return &self._detune;
}

pub fn start(_: *OscillatorNode) void {} // noop
pub fn stop(_: *OscillatorNode) void {} // noop
pub fn connect(_: *OscillatorNode) void {} // noop — we don't track the graph
pub fn disconnect(_: *OscillatorNode) void {} // noop

pub const JsApi = struct {
    pub const bridge = js.Bridge(OscillatorNode);
    pub const Meta = struct {
        pub const name = "OscillatorNode";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const @"type" = bridge.accessor(OscillatorNode.getType, OscillatorNode.setType, .{});
    pub const frequency = bridge.accessor(OscillatorNode.getFrequency, null, .{});
    pub const detune = bridge.accessor(OscillatorNode.getDetune, null, .{});
    pub const start = bridge.function(OscillatorNode.start, .{ .noop = true });
    pub const stop = bridge.function(OscillatorNode.stop, .{ .noop = true });
    pub const connect = bridge.function(OscillatorNode.connect, .{ .noop = true });
    pub const disconnect = bridge.function(OscillatorNode.disconnect, .{ .noop = true });
};
