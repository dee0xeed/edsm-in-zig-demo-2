
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

const esrc = @import("../engine/event-sources.zig");
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

pub const RxPotBoy = struct {

    const M0_IDLE = Message.M0;
    const M0_WORK = Message.M0;
    const M1_DONE = Message.M1;
    const M2_FAIL = Message.M2;
    var number: u16 = 0;

    const RxData = struct {
        my_pool: *MachinePool,
        io0: EventSource,
        tm0: EventSource,
        ctx: *Context,
        customer: ?*StageMachine,
    };

    pub fn onHeap(a: Allocator, md: *MessageDispatcher, rx_pool: *MachinePool) !*StageMachine {

        number += 1;
        var me = try StageMachine.onHeap(a, md, "RX", number);
        try me.addStage(Stage{.name = "INIT", .enter = &initEnter, .leave = null});
        try me.addStage(Stage{.name = "IDLE", .enter = &idleEnter, .leave = null});
        try me.addStage(Stage{.name = "WORK", .enter = &workEnter, .leave = &workLeave});

        var init = &me.stages.items[0];
        var idle = &me.stages.items[1];
        var work = &me.stages.items[2];

        init.setReflex(.sm, Message.M0, Reflex{.transition = idle});

        idle.setReflex(.sm, Message.M1, Reflex{.action = &idleM1});
        idle.setReflex(.sm, Message.M0, Reflex{.transition = work});

        work.setReflex(.io, Message.D0, Reflex{.action = &workD0});
        work.setReflex(.io, Message.D2, Reflex{.action = &workD2});
        work.setReflex(.tm, Message.T0, Reflex{.action = &workT0});
        work.setReflex(.sm, Message.M0, Reflex{.transition = idle});

        me.data = me.allocator.create(RxData) catch unreachable;
        var pd = utils.opaqPtrTo(me.data, *RxData);
        pd.my_pool = rx_pool;
        return me;
    }

    fn initEnter(me: *StageMachine) void {
        var pd = utils.opaqPtrTo(me.data, *RxData);
        me.initTimer(&pd.tm0, Message.T0) catch unreachable;
        me.initIo(&pd.io0);
        me.msgTo(me, M0_IDLE, null);
    }

    fn idleEnter(me: *StageMachine) void {
        var pd = utils.opaqPtrTo(me.data, *RxData);
        pd.ctx = undefined;
        pd.customer = null;
        pd.my_pool.put(me) catch unreachable;
    }

    // message from 'customer' - 'bring me data'
    fn idleM1(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        var pd = utils.opaqPtrTo(me.data, *RxData);
        pd.customer = src;
        pd.ctx = utils.opaqPtrTo(dptr, *Context);
        pd.io0.id = pd.ctx.fd;
        me.msgTo(me, M0_WORK, null);
    }

    fn workEnter(me: *StageMachine) void {
        var pd: *RxData = @ptrCast(@alignCast(me.data));
        pd.ctx.cnt = 0;
        const to = if (0 == pd.ctx.timeout) 1000 else pd.ctx.timeout;
        pd.tm0.enable(&me.md.eq, .{to}) catch unreachable;
        pd.io0.enable(&me.md.eq, .{}) catch unreachable;
    }

    fn workD0(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        var io = utils.opaqPtrTo(dptr, *EventSource);
        var pd = utils.opaqPtrTo(me.data, *RxData);

        const ba = io.info.io.bytes_avail;
        if (0 == ba) {
            me.msgTo(me, M0_IDLE, null);
            me.msgTo(pd.customer, M2_FAIL, null);
            return;
        }

        const br = std.posix.read(io.id, pd.ctx.buf[pd.ctx.cnt..]) catch {
            me.msgTo(me, M0_IDLE, null);
            me.msgTo(pd.customer, M2_FAIL, null);
            return;
        };

        pd.ctx.cnt += br;

        if (pd.ctx.needMore(pd.ctx.buf[0..pd.ctx.cnt])) {
            io.enable(&me.md.eq, .{}) catch unreachable;
            return;
        }

        me.msgTo(me, M0_IDLE, null);
        me.msgTo(pd.customer, M1_DONE, null);
    }

    fn workD2(me: *StageMachine, src: ?*StageMachine, data: ?*anyopaque) void {
        _ = src;
        _ = data;
        const pd = utils.opaqPtrTo(me.data, *RxData);
        me.msgTo(me, M0_IDLE, null);
        me.msgTo(pd.customer, M2_FAIL, null);
    }

    // timeout
    fn workT0(me: *StageMachine, src: ?*StageMachine, data: ?*anyopaque) void {
        _ = src;
        _ = data;
        const pd = utils.opaqPtrTo(me.data, *RxData);
        me.msgTo(me, M0_IDLE, null);
        me.msgTo(pd.customer, M2_FAIL, null);
    }

    fn workLeave(me: *StageMachine) void {
        var pd = utils.opaqPtrTo(me.data, *RxData);
        pd.tm0.disable(&me.md.eq) catch unreachable;
    }
};
