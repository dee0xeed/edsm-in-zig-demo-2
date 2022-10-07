
const std = @import("std");
const os = std.os;
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

const utils = @import("../utils.zig");

pub const Terminator = struct {

    const M0_IDLE = Message.M0;

    const TerminatorData = struct {
        sg0: EventSource,
        sg1: EventSource,
    };

    pub fn onHeap(a: Allocator, md: *MessageDispatcher) !*StageMachine {

        var me = try StageMachine.onHeap(a, md, "TERMINATOR", 1);
        try me.addStage(Stage{.name = "INIT", .enter = &initEnter, .leave = null});
        try me.addStage(Stage{.name = "IDLE", .enter = &idleEnter, .leave = null});

        var init = &me.stages.items[0];
        var idle = &me.stages.items[1];

        init.setReflex(.sm, Message.M0, Reflex{.transition = idle});
        idle.setReflex(.sg, Message.S0, Reflex{.action = &idleS0});
        idle.setReflex(.sg, Message.S1, Reflex{.action = &idleS0});

        me.data = me.allocator.create(TerminatorData) catch unreachable;
        return me;
    }

    fn initEnter(me: *StageMachine) void {
        var pd = utils.opaqPtrTo(me.data, *TerminatorData);
        me.initSignal(&pd.sg0, os.SIG.INT, Message.S0) catch unreachable;
        me.initSignal(&pd.sg1, os.SIG.TERM, Message.S1) catch unreachable;
        me.msgTo(me, M0_IDLE, null);
    }

    fn idleEnter(me: *StageMachine) void {
        var pd = utils.opaqPtrTo(me.data, *TerminatorData);
        pd.sg0.enable(&me.md.eq, .{}) catch unreachable;
        pd.sg1.enable(&me.md.eq, .{}) catch unreachable;
    }

    fn idleS0(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        var sg = utils.opaqPtrTo(dptr, *EventSource);
        var si = sg.info.sg.sig_info;
        print("got signal #{} from PID {}\n", .{si.signo, si.pid});
        me.msgTo(null, Message.M0, null);
    }
};
