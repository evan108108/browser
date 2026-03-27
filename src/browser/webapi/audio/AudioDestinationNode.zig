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

const AudioDestinationNode = @This();

_pad: bool = false,

pub fn getChannelCount(_: *const AudioDestinationNode) u32 {
    return 2;
}

pub fn getMaxChannelCount(_: *const AudioDestinationNode) u32 {
    return 2;
}

pub fn getNumberOfInputs(_: *const AudioDestinationNode) u32 {
    return 1;
}

pub fn getNumberOfOutputs(_: *const AudioDestinationNode) u32 {
    return 0;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(AudioDestinationNode);
    pub const Meta = struct {
        pub const name = "AudioDestinationNode";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const channelCount = bridge.accessor(AudioDestinationNode.getChannelCount, null, .{});
    pub const maxChannelCount = bridge.accessor(AudioDestinationNode.getMaxChannelCount, null, .{});
    pub const numberOfInputs = bridge.accessor(AudioDestinationNode.getNumberOfInputs, null, .{});
    pub const numberOfOutputs = bridge.accessor(AudioDestinationNode.getNumberOfOutputs, null, .{});
};
