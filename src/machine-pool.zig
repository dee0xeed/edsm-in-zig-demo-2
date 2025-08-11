
const std = @import("std");
const edsm = @import("engine/edsm.zig");
const StageMachine = edsm.StageMachine;
const Allocator = std.mem.Allocator;

pub const MachinePool = struct {

    const Self = @This();
    const MachinePtrList = std.ArrayList(*StageMachine);

    allocator: Allocator,
    list: MachinePtrList,

    pub fn init(a: Allocator, cap: usize) !Self {
        return Self {
            .allocator = a,
            .list = try MachinePtrList.initCapacity(a, cap),
        };
    }

    pub fn put(self: *Self, sm: *StageMachine) !void {
        const p = try self.list.addOne();
        p.* = sm;
    }

    pub fn get(self: *Self) ?*StageMachine {
        //return self.list.popOrNull();
        //return self.list.getLastOrNull(); // crash
        return self.list.pop();
    }
};
