
const std = @import("std");
const edsm = @import("engine/edsm.zig");
const StageMachine = edsm.StageMachine;
const Allocator = std.mem.Allocator;

const MachinePtrList = std.ArrayList(*StageMachine);

pub const MachinePool = struct {
    const Self = @This();
    allocator: Allocator,
    list: MachinePtrList,

    pub fn init(a: Allocator, cap: usize) !Self {
        return Self {
            .allocator = a,
            .list = try MachinePtrList.initCapacity(a, cap),
        };
    }

    pub fn put(self: *Self, sm: *StageMachine) !void {
        var p = try self.list.addOne();
        p.* = sm;
    }

    pub fn get(self: *Self) ?*StageMachine {
        return self.list.popOrNull();
    }
};
