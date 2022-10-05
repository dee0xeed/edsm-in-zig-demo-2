
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
const MachinePool = @import("../machine-pool.zig").MachinePool;

const Client = @import("client.zig").Client;

pub const Listener = struct {

    const M0_WORK = Message.M0;
    const M1_MEET = Message.M1;
    const M0_GONE = Message.M0;

    const ListenerData = struct {
        sg0: EventSource,
        sg1: EventSource,
        io0: EventSource, // listening socket
        port: u16,
        wpool: *MachinePool,
    };

    pub fn onHeap(
        a: Allocator,
        md: *MessageDispatcher,
        port: u16,
        wpool: *MachinePool
    ) !*StageMachine {

        var me = try StageMachine.onHeap(a, md, "LISTENER", 1);
        try me.addStage(Stage{.name = "INIT", .enter = &initEnter, .leave = null});
        try me.addStage(Stage{.name = "WORK", .enter = &workEnter, .leave = &workLeave});

        var init = &me.stages.items[0];
        var work = &me.stages.items[1];

        init.setReflex(.sm, Message.M0, Reflex{.transition = work});
        work.setReflex(.io, Message.D0, Reflex{.action = &workD0});
        work.setReflex(.sm, Message.M0, Reflex{.action = &workM0});
        work.setReflex(.sg, Message.S0, Reflex{.action = &workS0});
        work.setReflex(.sg, Message.S1, Reflex{.action = &workS0});

        me.data = me.allocator.create(ListenerData) catch unreachable;
        var pd = @ptrCast(*ListenerData, @alignCast(@alignOf(*ListenerData), me.data));
        pd.port = port;
        pd.wpool = wpool;
        return me;
    }

    fn initEnter(me: *StageMachine) void {
        var pd = @ptrCast(*ListenerData, @alignCast(@alignOf(*ListenerData), me.data));
        me.initSignal(&pd.sg0, std.os.SIG.INT, Message.S0) catch unreachable;
        me.initSignal(&pd.sg1, std.os.SIG.TERM, Message.S1) catch unreachable;
        me.initListener(&pd.io0, pd.port) catch unreachable;
        me.msgTo(me, M0_WORK, null);
    }

    fn workEnter(me: *StageMachine) void {
        var pd = @ptrCast(*ListenerData, @alignCast(@alignOf(*ListenerData), me.data));
        pd.io0.enable(&me.md.eq, .{}) catch unreachable;
        pd.sg0.enable(&me.md.eq, .{}) catch unreachable;
        pd.sg1.enable(&me.md.eq, .{}) catch unreachable;
        print("\nHello! I am '{s}' on port {}.\n", .{me.name, pd.port});
    }

    // incoming connection
    fn workD0(me: *StageMachine, src: ?*StageMachine, data: ?*anyopaque) void {
        _ = src;
        var pd = @ptrCast(*ListenerData, @alignCast(@alignOf(*ListenerData), me.data));
        var io = @ptrCast(*EventSource, @alignCast(@alignOf(*EventSource), data));
        io.enable(&me.md.eq, .{}) catch unreachable;
        const fd = io.acceptClient() catch unreachable;
        var ptr = me.allocator.create(Client) catch unreachable;
        var client = @ptrCast(*Client, @alignCast(@alignOf(*Client), ptr));
        client.fd = fd;
        // client.

        var sm = pd.wpool.get();
        if (sm) |worker| {
            me.msgTo(worker, M1_MEET, client);
        } else {
            me.msgTo(me, M0_GONE, client);
        }
    }

    // message from worker machine (client gone)
    // or from self (if no workers were available)
    fn workM0(me: *StageMachine, src: ?*StageMachine, data: ?*anyopaque) void {
        _ = src;
        var client = @ptrCast(*Client, @alignCast(@alignOf(*Client), data));
        os.close(client.fd);
        me.allocator.destroy(client);
    }

    fn workS0(me: *StageMachine, src: ?*StageMachine, data: ?*anyopaque) void {
//        var pd = @ptrCast(*ListenerData, @alignCast(@alignOf(*ListenerData), me.data));
        _ = src;
        var sg = @ptrCast(*EventSource, @alignCast(@alignOf(*EventSource), data));
        var si = sg.info.sg.sig_info;
        print("got signal #{} from PID {}\n", .{si.signo, si.pid});
        me.msgTo(null, Message.M0, null);
    }

    fn workLeave(me: *StageMachine) void {
        var pd = @ptrCast(*ListenerData, @alignCast(@alignOf(*ListenerData), me.data));
        pd.io0.disable(&me.md.eq) catch unreachable;
        print("Bye! It was '{s}'.\n", .{me.name});
    }
};
