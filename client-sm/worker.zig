
const std = @import("std");
const os = std.os;
const mem = std.mem;
const net = std.net;
const print = std.debug.print;
const Allocator = std.mem.Allocator;

const msgq = @import("../engine/message-queue.zig");
const Message = msgq.Message;
const MessageDispatcher = msgq.MessageDispatcher;

const esrc = @import("../engine//event-sources.zig");
const EventSourceKind = esrc.EventSourceKind;
const EventSourceSubKind = esrc.EventSourceSubKind;
const EventSource = esrc.EventSource;

const edsm = @import("../engine/edsm.zig");
const Reflex = edsm.Reflex;
const Stage = edsm.Stage;
const StageList = edsm.StageList;
const StageMachine = edsm.StageMachine;
const MachinePool = @import("../machine-pool.zig").MachinePool;
const Context = @import("../common-sm/context.zig").IoContext;

const utils = @import("../utils.zig");

pub const Worker = struct {

    const M0_CONN = Message.M0;
    const M0_SEND = Message.M0;
    const M0_RECV = Message.M0;
    const M0_TWIX = Message.M0;
    const M1_WORK = Message.M1;
    const M3_WAIT = Message.M3;
    const max_bytes = 64;
    var number: u16 = 0;

    const WorkerData = struct {
        rxp: *MachinePool,
        txp: *MachinePool,
        request: [max_bytes]u8,
        request_seqn: u32,
        reply: [max_bytes]u8,
        ctx: Context,
        tm: EventSource,
        io: EventSource,
        host: []const u8,
        port: u16,
        addr: net.Address,
    };

    pub fn onHeap (
        a: Allocator,
        md: *MessageDispatcher,
        rx_pool: *MachinePool,
        tx_pool: *MachinePool,
        host: []const u8,
        port: u16,
    ) !*StageMachine {

        number += 1;
        var me = try StageMachine.onHeap(a, md, "WORKER", number);
        try me.addStage(Stage{.name = "INIT", .enter = &initEnter, .leave = null});
        try me.addStage(Stage{.name = "CONN", .enter = &connEnter, .leave = null});
        try me.addStage(Stage{.name = "SEND", .enter = &sendEnter, .leave = null});
        try me.addStage(Stage{.name = "RECV", .enter = &recvEnter, .leave = null});
        try me.addStage(Stage{.name = "TWIX", .enter = &twixEnter, .leave = null});
        try me.addStage(Stage{.name = "WAIT", .enter = &waitEnter, .leave = null});

        var init = &me.stages.items[0];
        var conn = &me.stages.items[1];
        var send = &me.stages.items[2];
        var recv = &me.stages.items[3];
        var twix = &me.stages.items[4];
        var wait = &me.stages.items[5];

        init.setReflex(.sm, Message.M0, Reflex{.transition = conn});

        conn.setReflex(.sm, Message.M1, Reflex{.action = &connM1});
        conn.setReflex(.sm, Message.M2, Reflex{.action = &connM2});
        conn.setReflex(.sm, Message.M0, Reflex{.transition = send});
        conn.setReflex(.sm, Message.M3, Reflex{.transition = wait});

        send.setReflex(.sm, Message.M1, Reflex{.action = &sendM1});
        send.setReflex(.sm, Message.M2, Reflex{.action = &sendM2});
        send.setReflex(.sm, Message.M0, Reflex{.transition = recv});
        send.setReflex(.sm, Message.M3, Reflex{.transition = wait});

        recv.setReflex(.sm, Message.M1, Reflex{.action = &recvM1});
        recv.setReflex(.sm, Message.M2, Reflex{.action = &recvM2});
        recv.setReflex(.sm, Message.M0, Reflex{.transition = twix});
        recv.setReflex(.sm, Message.M3, Reflex{.transition = wait});

        twix.setReflex(.tm, Message.T0, Reflex{.transition = send});
        wait.setReflex(.tm, Message.T0, Reflex{.transition = conn});

        me.data = me.allocator.create(WorkerData) catch unreachable;
        var pd = utils.opaqPtrTo(me.data, *WorkerData);
        pd.host = host;
        pd.port = port;
        pd.rxp = rx_pool;
        pd.txp = tx_pool;
        pd.request_seqn = 0;
        return me;
    }

    fn initEnter(me: *StageMachine) void {
        var pd = utils.opaqPtrTo(me.data, *WorkerData);
        pd.io = EventSource.init(me, .io, .csock, Message.D0);
        me.initTimer(&pd.tm, Message.T0) catch unreachable;
        pd.addr = net.Address.resolveIp(pd.host, pd.port) catch unreachable;
        me.msgTo(me, M0_CONN, null);
    }

    fn connEnter(me: *StageMachine) void {
        var pd = utils.opaqPtrTo(me.data, *WorkerData);
        pd.io.getId(.{}) catch unreachable;

        var tx = pd.txp.get() orelse {
            me.msgTo(me, M3_WAIT, null);
            return;
        };

        pd.ctx.fd = pd.io.id;
        pd.ctx.buf = pd.request[0..0];
        pd.io.startConnect(&pd.addr) catch unreachable;
        me.msgTo(tx, M1_WORK, &pd.ctx);
    }

    // message from TX machine, connection established
    fn connM1(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        var pd = utils.opaqPtrTo(me.data, *WorkerData);
        print("{s} : connected to '{s}:{}'\n", .{me.name, pd.host, pd.port});
        me.msgTo(me, M0_SEND, null);
    }

    // message from TX machine, can't connect
    fn connM2(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        var pd = utils.opaqPtrTo(me.data, *WorkerData);
        print("{s} : can not connect to '{s}:{}'\n", .{me.name, pd.host, pd.port});
        me.msgTo(me, M3_WAIT, null);
    }

    fn sendEnter(me: *StageMachine) void {
        var pd = utils.opaqPtrTo(me.data, *WorkerData);
        var tx = pd.txp.get() orelse {
            me.msgTo(me, M3_WAIT, null);
            return;
        };
        pd.request_seqn += 1;
        pd.ctx.buf = std.fmt.bufPrint(&pd.request, "{s}-{}\n", .{me.name, pd.request_seqn}) catch unreachable;
        me.msgTo(tx, M1_WORK, &pd.ctx);
    }

    // message from TX machine (success)
    fn sendM1(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        me.msgTo(me, M0_RECV, null);
    }

    // message from TX machine (failure)
    fn sendM2(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        me.msgTo(me, M3_WAIT, null);
    }

    fn myNeedMore(buf: []u8) bool {
        if (0x0A == buf[buf.len - 1])
            return false;
        return true;
    }

    fn recvEnter(me: *StageMachine) void {
        var pd = utils.opaqPtrTo(me.data, *WorkerData);
        var rx = pd.rxp.get() orelse {
            me.msgTo(me, M3_WAIT, null);
            return;
        };
        pd.ctx.needMore = &myNeedMore;
        pd.ctx.timeout = 10000; // msec
        pd.ctx.buf = pd.reply[0..];
        me.msgTo(rx, M1_WORK, &pd.ctx);
    }

    // message from RX machine (success)
    fn recvM1(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        var pd = utils.opaqPtrTo(me.data, *WorkerData);
        _ = dptr;
        _ = src;
        print("reply: {s}", .{pd.reply[0..pd.ctx.cnt]});
        me.msgTo(me, M0_TWIX, null);
    }

    // message from RX machine (failure)
    fn recvM2(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        var pd = utils.opaqPtrTo(me.data, *WorkerData);
        _ = pd;
        _ = dptr;
        _ = src;
        me.msgTo(me, M3_WAIT, null);
    }

    fn twixEnter(me: *StageMachine) void {
        var pd = utils.opaqPtrTo(me.data, *WorkerData);
        pd.tm.enable(&me.md.eq, .{500}) catch unreachable;
    }

    fn waitEnter(me: *StageMachine) void {
        var pd = utils.opaqPtrTo(me.data, *WorkerData);
        os.close(pd.io.id);
        pd.tm.enable(&me.md.eq, .{5000}) catch unreachable;
    }
};
