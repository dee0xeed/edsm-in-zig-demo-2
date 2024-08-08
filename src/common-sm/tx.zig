
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
const Context =  @import("../common-sm/context.zig").IoContext;
const utils = @import("../utils.zig");

pub const TxPotBoy = struct {

    const M0_IDLE = Message.M0;
    const M0_WORK = Message.M0;
    const M1_DONE = Message.M1;
    const M2_FAIL = Message.M2;
    var number: u16 = 0;

    const TxData = struct {
        my_pool: *MachinePool,
        io0: EventSource,
        ctx: *Context,
        customer: ?*StageMachine,
    };

    pub fn onHeap(a: Allocator, md: *MessageDispatcher, tx_pool: *MachinePool) !*StageMachine {

        number += 1;
        var me = try StageMachine.onHeap(a, md, "TX", number);
        try me.addStage(Stage{.name = "INIT", .enter = &initEnter, .leave = null});
        try me.addStage(Stage{.name = "IDLE", .enter = &idleEnter, .leave = null});
        try me.addStage(Stage{.name = "WORK", .enter = &workEnter, .leave = null});

        var init = &me.stages.items[0];
        var idle = &me.stages.items[1];
        var work = &me.stages.items[2];

        init.setReflex(.sm, Message.M0, Reflex{.transition = idle});

        idle.setReflex(.sm, Message.M1, Reflex{.action = &idleM1});
        idle.setReflex(.sm, Message.M0, Reflex{.transition = work});

        work.setReflex(.io, Message.D1, Reflex{.action = &workD1});
        work.setReflex(.io, Message.D2, Reflex{.action = &workD2});
        work.setReflex(.sm, Message.M0, Reflex{.transition = idle});

        me.data = me.allocator.create(TxData) catch unreachable;
        var pd = utils.opaqPtrTo(me.data, *TxData);
        pd.my_pool = tx_pool;
        return me;
    }

    fn initEnter(me: *StageMachine) void {
        var pd = utils.opaqPtrTo(me.data, *TxData);
        me.initIo(&pd.io0);
        me.msgTo(me, M0_IDLE, null);
    }

    fn idleEnter(me: *StageMachine) void {
        var pd = utils.opaqPtrTo(me.data, *TxData);
        pd.ctx = undefined;
        pd.customer = null;
        pd.my_pool.put(me) catch unreachable;
    }

    // message from 'customer' - 'transfer data'
    fn idleM1(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        var pd = utils.opaqPtrTo(me.data, *TxData);
        pd.customer = src;
        pd.ctx = utils.opaqPtrTo(dptr, *Context);
        pd.io0.id = pd.ctx.fd;
        me.msgTo(me, M0_WORK, null);
    }

    fn workEnter(me: *StageMachine) void {
        var pd = utils.opaqPtrTo(me.data, *TxData);
        pd.ctx.cnt = pd.ctx.buf.len;
        pd.io0.enableOut(&me.md.eq) catch unreachable;
    }

    fn workD1(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        const io = utils.opaqPtrTo(dptr, *EventSource);
        var pd = utils.opaqPtrTo(me.data, *TxData);

        if (0 == pd.ctx.cnt) {
            // it was request for asynchronous connect
            me.msgTo(me, M0_IDLE, null);
            me.msgTo(pd.customer, M1_DONE, null);
            return;
        } 

        const bw = std.posix.write(io.id, pd.ctx.buf[pd.ctx.buf.len - pd.ctx.cnt..pd.ctx.buf.len]) catch {
            me.msgTo(me, M0_IDLE, null);
            me.msgTo(pd.customer, M2_FAIL, null);
            return;
        };

        pd.ctx.cnt -= bw;
        if (pd.ctx.cnt > 0) {
            pd.io0.enableOut(&me.md.eq) catch unreachable;
            return;
        }

        me.msgTo(me, M0_IDLE, null);
        me.msgTo(pd.customer, M1_DONE, null);
    }

    fn workD2(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        const pd = utils.opaqPtrTo(me.data, *TxData);
        me.msgTo(me, M0_IDLE, null);
        me.msgTo(pd.customer, M2_FAIL, null);
    }
};
