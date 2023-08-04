
const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const page_allocator = std.heap.page_allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const MessageDispatcher = @import("engine/message-queue.zig").MessageDispatcher;
const MachinePool = @import("machine-pool.zig").MachinePool;
const Terminator = @import("client-sm/terminator.zig").Terminator;
const Worker = @import("client-sm/worker.zig").Worker;
const RxPotBoy = @import("common-sm/rx.zig").RxPotBoy;
const TxPotBoy = @import("common-sm/tx.zig").TxPotBoy;

pub fn main() !void {

    const nconnections = 4;
    var arena = ArenaAllocator.init(page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var md = try MessageDispatcher.onStack(allocator, 5);

    var rx_pool = try MachinePool.init(allocator, nconnections);
    var tx_pool = try MachinePool.init(allocator, nconnections);

    var i: u32 = 0;
    while (i < nconnections) : (i += 1) {
        var rx = try RxPotBoy.onHeap(allocator, &md, &rx_pool);
        try rx.run();
    }

    i = 0;
    while (i < nconnections) : (i += 1) {
        var tx = try TxPotBoy.onHeap(allocator, &md, &tx_pool);
        try tx.run();
    }

    i = 0;
    while (i < nconnections) : (i += 1) {
        var w = try Worker.onHeap(allocator, &md, &rx_pool, &tx_pool, "127.0.0.1", 3333);
        try w.run();
    }

    var t = try Terminator.onHeap(allocator, &md);
    try t.run();

    try md.loop();
    md.eq.fini();
}
