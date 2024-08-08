
const std = @import("std");
const os = std.os;
const mem = std.mem;
const math = std.math;
const print = std.debug.print;
const Allocator = std.mem.Allocator;

const mq = @import("../engine/message-queue.zig");
const MessageDispatcher = mq.MessageDispatcher;
const MessageQueue = MessageDispatcher.MessageQueue;
const Message = MessageQueue.Message;

const esrc = @import("../engine//event-sources.zig");
const EventSourceKind = esrc.EventSourceKind;
const EventSourceSubKind = esrc.EventSourceSubKind;
const EventSource = esrc.EventSource;

const edsm = @import("../engine/edsm.zig");
const StageMachine = edsm.StageMachine;
const Stage = StageMachine.Stage;
const Reflex = Stage.Reflex;
const StageList = edsm.StageList;

const MachinePool = @import("../machine-pool.zig").MachinePool;
const Client = @import("client.zig").Client;
const Context =  @import("../common-sm/context.zig").IoContext;
const utils = @import("../utils.zig");

pub const Worker = struct {

    const M0_IDLE = Message.M0;
    const M0_RECV = Message.M0;
    const M1_WORK = Message.M1;
    const M0_SEND = Message.M0;
    const M0_GONE = Message.M0;
    const M2_FAIL = Message.M2;
    const max_bytes = 64;
    var number: u16 = 0;

    const WorkerData = struct {
        my_pool: *MachinePool,
        rx_pool: *MachinePool,
        tx_pool: *MachinePool,
        listener: ?*StageMachine,
        client: ?*Client,
        request: [max_bytes]u8,
//        reply: [max_bytes]u8,
        ctx: Context,
    };

    pub fn onHeap (
        a: Allocator,
        md: *MessageDispatcher,
        my_pool: *MachinePool,
        rx_pool: *MachinePool,
        tx_pool: *MachinePool,
    ) !*StageMachine {

        number += 1;
        var me = try StageMachine.onHeap(a, md, "WORKER", number);
        try me.addStage(Stage{.name = "INIT", .enter = &initEnter, .leave = null});
        try me.addStage(Stage{.name = "IDLE", .enter = &idleEnter, .leave = null});
        try me.addStage(Stage{.name = "RECV", .enter = &recvEnter, .leave = null});
        try me.addStage(Stage{.name = "SEND", .enter = &sendEnter, .leave = null});
        try me.addStage(Stage{.name = "FAIL", .enter = &failEnter, .leave = null});

        var init = &me.stages.items[0];
        var idle = &me.stages.items[1];
        var recv = &me.stages.items[2];
        var send = &me.stages.items[3];
        var fail = &me.stages.items[4];

        init.setReflex(.sm, Message.M0, Reflex{.transition = idle});

        idle.setReflex(.sm, Message.M1, Reflex{.action = &idleM1});
        idle.setReflex(.sm, Message.M0, Reflex{.transition = recv});

        recv.setReflex(.sm, Message.M0, Reflex{.transition = send});
        recv.setReflex(.sm, Message.M1, Reflex{.action = &recvM1});
        recv.setReflex(.sm, Message.M2, Reflex{.transition = fail});

        send.setReflex(.sm, Message.M0, Reflex{.transition = recv});
        send.setReflex(.sm, Message.M1, Reflex{.action = &sendM1});
        send.setReflex(.sm, Message.M2, Reflex{.transition = fail});

        fail.setReflex(.sm, Message.M0, Reflex{.transition = idle});

        me.data = me.allocator.create(WorkerData) catch unreachable;
        var pd = utils.opaqPtrTo(me.data, *WorkerData);
        pd.my_pool = my_pool;
        pd.rx_pool = rx_pool;
        pd.tx_pool = tx_pool;
        return me;
    }

    fn initEnter(me: *StageMachine) void {
        me.msgTo(me, M0_IDLE, null);
    }

    fn idleEnter(me: *StageMachine) void {
        var pd = utils.opaqPtrTo(me.data, *WorkerData);
        pd.listener = null;
        pd.client = null;
        pd.my_pool.put(me) catch unreachable;
    }

    // message from LISTENER (new client)
    fn idleM1(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        var pd = utils.opaqPtrTo(me.data, *WorkerData);
        const client = utils.opaqPtrTo(dptr, *Client);
        pd.listener = src;
        pd.client = client;
        pd.ctx.fd = client.fd;
        me.msgTo(me, M0_RECV, null);
    }

    fn myNeedMore(buf: []u8) bool {
        print("<<< {} bytes: {any}\n", .{buf.len, buf});
        if (0x0A == buf[buf.len - 1])
            return false;
        return true;
    }

    fn recvEnter(me: *StageMachine) void {
        var pd = utils.opaqPtrTo(me.data, *WorkerData);
        const rx = pd.rx_pool.get() orelse {
            me.msgTo(me, M2_FAIL, null);
            return;
        };
        pd.ctx.fd = if (pd.client) |c| c.fd else unreachable;
        pd.ctx.needMore = &myNeedMore;
        pd.ctx.timeout = 10000; // msec
        pd.ctx.buf = pd.request[0..];
        me.msgTo(rx, M1_WORK, &pd.ctx);
    }

    // message from RX machine (success)
    fn recvM1(me: *StageMachine, src: ?*StageMachine, data: ?*anyopaque) void {
        const pd = utils.opaqPtrTo(me.data, *WorkerData);
        _ = pd;
        _ = data;
        _ = src;
        me.msgTo(me, M0_SEND, null);
    }

    fn sendEnter(me: *StageMachine) void {
        var pd = utils.opaqPtrTo(me.data, *WorkerData);
        const tx = pd.tx_pool.get() orelse {
            me.msgTo(me, M2_FAIL, null);
            return;
        };
        pd.ctx.buf = pd.request[0..pd.ctx.cnt];
        me.msgTo(tx, M1_WORK, &pd.ctx);
    }

    // message from TX machine (success)
    fn sendM1(me: *StageMachine, src: ?*StageMachine, data: ?*anyopaque) void {
        _ = src;
        _ = data;
        me.msgTo(me, M0_RECV, null);
    }

    fn failEnter(me: *StageMachine) void {
        const pd = utils.opaqPtrTo(me.data, *WorkerData);
        me.msgTo(me, M0_IDLE, null);
        me.msgTo(pd.listener, M0_GONE, pd.client);
    }
};
