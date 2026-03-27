const js = @import("../../js/js.zig");
const AudioParam = @import("AudioParam.zig");

const DynamicsCompressorNode = @This();

_threshold: AudioParam = .{ ._value = -24, ._default_value = -24, ._min_value = -100, ._max_value = 0 },
_knee: AudioParam = .{ ._value = 30, ._default_value = 30, ._min_value = 0, ._max_value = 40 },
_ratio: AudioParam = .{ ._value = 12, ._default_value = 12, ._min_value = 1, ._max_value = 20 },
_attack: AudioParam = .{ ._value = 0.003, ._default_value = 0.003, ._min_value = 0, ._max_value = 1 },
_release: AudioParam = .{ ._value = 0.25, ._default_value = 0.25, ._min_value = 0, ._max_value = 1 },
_reduction: f64 = -20.538288116455078, // Chrome's DynamicsCompressorNode.reduction value (CreepJS checks this)

pub fn getThreshold(self: *DynamicsCompressorNode) *AudioParam {
    return &self._threshold;
}

pub fn getKnee(self: *DynamicsCompressorNode) *AudioParam {
    return &self._knee;
}

pub fn getRatio(self: *DynamicsCompressorNode) *AudioParam {
    return &self._ratio;
}

pub fn getAttack(self: *DynamicsCompressorNode) *AudioParam {
    return &self._attack;
}

pub fn getRelease(self: *DynamicsCompressorNode) *AudioParam {
    return &self._release;
}

pub fn getReduction(self: *const DynamicsCompressorNode) f64 {
    return self._reduction;
}

pub fn connect(_: *DynamicsCompressorNode) void {} // noop
pub fn disconnect(_: *DynamicsCompressorNode) void {} // noop

pub const JsApi = struct {
    pub const bridge = js.Bridge(DynamicsCompressorNode);
    pub const Meta = struct {
        pub const name = "DynamicsCompressorNode";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const threshold = bridge.accessor(DynamicsCompressorNode.getThreshold, null, .{});
    pub const knee = bridge.accessor(DynamicsCompressorNode.getKnee, null, .{});
    pub const ratio = bridge.accessor(DynamicsCompressorNode.getRatio, null, .{});
    pub const attack = bridge.accessor(DynamicsCompressorNode.getAttack, null, .{});
    pub const release = bridge.accessor(DynamicsCompressorNode.getRelease, null, .{});
    pub const reduction = bridge.accessor(DynamicsCompressorNode.getReduction, null, .{});
    pub const connect = bridge.function(DynamicsCompressorNode.connect, .{ .noop = true });
    pub const disconnect = bridge.function(DynamicsCompressorNode.disconnect, .{ .noop = true });
};
