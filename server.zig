
const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;

const MessageDispatcher = @import("engine/message-queue.zig").MessageDispatcher;
const MachinePool = @import("machine-pool.zig").MachinePool;
const Listener = @import("server-sm/listener.zig").Listener;
const Worker = @import("server-sm/worker.zig").Worker;
const RxPotBoy = @import("common-sm/rx.zig").RxPotBoy;
const TxPotBoy = @import("common-sm/tx.zig").TxPotBoy;

pub fn main() !void {

    const max_clients = 4;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //defer print("leakage?.. {}\n", .{gpa.deinit()});
    const allocator = gpa.allocator();
    var md = try MessageDispatcher.onStack(allocator, 5);

    var worker_pool = try MachinePool.init(allocator, max_clients);
    var rx_pool = try MachinePool.init(allocator, max_clients);
    var tx_pool = try MachinePool.init(allocator, max_clients);

    var i: u32 = 0;
    while (i < max_clients) : (i += 1) {
        var rx = try RxPotBoy.onHeap(allocator, &md, &rx_pool);
        try rx.run();
    }

    i = 0;
    while (i < max_clients) : (i += 1) {
        var tx = try TxPotBoy.onHeap(allocator, &md, &tx_pool);
        try tx.run();
    }

    i = 0;
    while (i < max_clients) : (i += 1) {
        var worker = try Worker.onHeap(allocator, &md, &worker_pool, &rx_pool, &tx_pool);
        try worker.run();
    }

    var reception = try Listener.onHeap(allocator, &md, 3333, &worker_pool);
    try reception.run();

    try md.loop();
    md.eq.fini();
}
