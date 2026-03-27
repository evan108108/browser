const js = @import("../../js/js.zig");
const AudioParam = @import("AudioParam.zig");

const GainNode = @This();

_gain: AudioParam = .{ ._value = 1, ._default_value = 1 },

pub fn getGain(self: *GainNode) *AudioParam {
    return &self._gain;
}

pub fn connect(_: *GainNode) void {} // noop
pub fn disconnect(_: *GainNode) void {} // noop

pub const JsApi = struct {
    pub const bridge = js.Bridge(GainNode);
    pub const Meta = struct {
        pub const name = "GainNode";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const gain = bridge.accessor(GainNode.getGain, null, .{});
    pub const connect = bridge.function(GainNode.connect, .{ .noop = true });
    pub const disconnect = bridge.function(GainNode.disconnect, .{ .noop = true });
};
