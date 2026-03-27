const js = @import("../../js/js.zig");

const AnalyserNode = @This();

_fft_size: u32 = 2048,

pub fn getFftSize(self: *const AnalyserNode) u32 {
    return self._fft_size;
}

pub fn setFftSize(self: *AnalyserNode, value: u32) void {
    self._fft_size = value;
}

pub fn getFrequencyBinCount(self: *const AnalyserNode) u32 {
    return self._fft_size / 2;
}

pub fn connect(_: *AnalyserNode) void {} // noop
pub fn disconnect(_: *AnalyserNode) void {} // noop

pub const JsApi = struct {
    pub const bridge = js.Bridge(AnalyserNode);
    pub const Meta = struct {
        pub const name = "AnalyserNode";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const fftSize = bridge.accessor(AnalyserNode.getFftSize, AnalyserNode.setFftSize, .{});
    pub const frequencyBinCount = bridge.accessor(AnalyserNode.getFrequencyBinCount, null, .{});
    pub const connect = bridge.function(AnalyserNode.connect, .{ .noop = true });
    pub const disconnect = bridge.function(AnalyserNode.disconnect, .{ .noop = true });
};
