
const std = @import("std");
const os = std.os;
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

pub const Terminator = struct {

    const M0_IDLE = Message.M0;

    const TerminatorData = struct {
        sg0: EventSource,
        sg1: EventSource,
    };

    pub fn onHeap(
        a: Allocator,
        md: *MessageDispatcher,
    ) !*StageMachine {

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
        var pd = @ptrCast(*TerminatorData, @alignCast(@alignOf(*TerminatorData), me.data));
        me.initSignal(&pd.sg0, std.os.SIG.INT, Message.S0) catch unreachable;
        me.initSignal(&pd.sg1, std.os.SIG.TERM, Message.S1) catch unreachable;
        me.msgTo(me, M0_IDLE, null);
    }

    fn idleEnter(me: *StageMachine) void {
        var pd = @ptrCast(*TerminatorData, @alignCast(@alignOf(*TerminatorData), me.data));
        pd.sg0.enable(&me.md.eq, .{}) catch unreachable;
        pd.sg1.enable(&me.md.eq, .{}) catch unreachable;
    }

    fn idleS0(me: *StageMachine, src: ?*StageMachine, data: ?*anyopaque) void {
        _ = src;
        var sg = @ptrCast(*EventSource, @alignCast(@alignOf(*EventSource), data));
        var si = sg.info.sg.sig_info;
        print("got signal #{} from PID {}\n", .{si.signo, si.pid});
        me.msgTo(null, Message.M0, null);
    }
};
