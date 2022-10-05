
const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;

const msgq = @import("message-queue.zig");
const Message = msgq.Message;
const MessageQueue = msgq.MessageQueue;
const MessageDispatcher = msgq.MessageDispatcher;

const esrc = @import("event-sources.zig");
const EventSourceKind = esrc.EventSourceKind;
const EventSourceSubKind = esrc.EventSourceSubKind;
const EventSource = esrc.EventSource;
const EventSourceInfo = esrc.EventSourceInfo;
const SignalInfo = esrc.SignalInfo;
const IoInfo = esrc.IoInfo;
const TimerInfo = esrc.TimerInfo;

const reactFnPtr = *const fn (me: *StageMachine, src: ?*StageMachine, data: ?*anyopaque) void;
const enterFnPtr = *const fn (me: *StageMachine) void;
const leaveFnPtr = enterFnPtr;

const ReflexKind = enum {
    action,
    transition
};

pub const Reflex = union(ReflexKind) {
    action: reactFnPtr,
    transition: *Stage,
};

pub const Stage = struct {

    /// number of rows in reflex matrix
    const nrows = @typeInfo(EventSourceKind).Enum.fields.len;
    const esk_tags = "MDSTF";
    /// number of columns in reflex matrix
    const ncols = 16;
    /// name of a stage
    name: []const u8,
    /// called when machine enters a stage
    enter: ?enterFnPtr = null,
    /// called when machine leaves a stage
    leave: ?leaveFnPtr = null,

    /// reflex matrix
    /// row 0: M0 M1 M2 ... M15 : internal messages
    /// row 1: D0 D1 D2         : i/o (POLLIN, POLLOUT, POLLERR)
    /// row 2: S0 S1 S2 ... S15 : signals
    /// row 3: T0 T1 T2 ... T15 : timers
    /// row 4: F0.............. : file system events
    reflexes: [nrows][ncols]?Reflex = [nrows][ncols]?Reflex {
        [_]?Reflex{null} ** ncols,
        [_]?Reflex{null} ** ncols,
        [_]?Reflex{null} ** ncols,
        [_]?Reflex{null} ** ncols,
        [_]?Reflex{null} ** ncols,
    },

    pub fn setReflex(self: *Stage, esk: EventSourceKind, seqn: u4, refl: Reflex) void {
        const row: u8 = @enumToInt(esk);
        const col: u8 = seqn;
        self.reflexes[row][col] = refl;
    }
};

pub const StageList = std.ArrayList(Stage);

const StageMachineError = error {
    IsAlreadyRunning,
    HasNoStates,
};

pub const StageMachine = struct {

    const Self = @This();

    name: []const u8 = undefined,
    namebuf: [32]u8 = undefined,
    is_running: bool = false,
    stages: StageList,
    current_stage: *Stage = undefined,
    md: *msgq.MessageDispatcher,
    allocator: Allocator,
    data: ?*anyopaque = null,

    pub fn init(a: Allocator, md: *MessageDispatcher) StageMachine {
        return StageMachine {
//            .name = name,
            .md = md,
            .stages = StageList.init(a),
            .allocator = a,
        };
    }

    pub fn onHeap(a: Allocator, md: *MessageDispatcher, name: []const u8, numb: u16) !*StageMachine {
        var sm = try a.create(StageMachine);
        sm.* = init(a, md);
        sm.name = try std.fmt.bufPrint(&sm.namebuf, "{s}-{}", .{name, numb});
        return sm;
    }

    pub fn addStage(self: *Self, st: Stage) !void {
        var ptr = try self.stages.addOne();
        ptr.* = st;
    }

    pub fn initTimer(self: *Self, tm: *EventSource, seqn: u4) !void {
        tm.* = EventSource.init(self, .tm, .none, seqn);
        try tm.getId(.{});
    }

    pub fn initSignal(self: *Self, sg: *EventSource, signo: u6, seqn: u4) !void {
        sg.* = EventSource.init(self, .sg, .none, seqn);
        try sg.getId(.{signo});
    }

    pub fn initListener(self: *Self, io: *EventSource, port: u16) !void {
        io.* = EventSource.init(self, .io, .ssock, Message.D0);
        try io.getId(.{port});
    }

    pub fn initIo(self: *Self, io: *EventSource) void {
        io.id = -1;
        io.kind = .io;
        io.info = EventSourceInfo{.io = IoInfo{}};
        io.owner = self;
        io.seqn = 0; // undefined;
    }

    /// state machine engine
    pub fn reactTo(self: *Self, msg: Message) void {
        const row = @enumToInt(msg.esk);
        const col = msg.sqn;
        const current_stage = self.current_stage;

        var sender = if (msg.src) |s| s.name else "OS";
        if (msg.src == self) sender = "SELF";
        print(
            "{s} @ {s} got '{c}{}' from {s}\n",
            .{self.name, current_stage.name, Stage.esk_tags[row], col, sender}
        );

        if (current_stage.reflexes[row][col]) |refl| {
            switch (refl) {
                .action => |func| func(self, msg.src, msg.ptr),
                .transition => |next_stage| {
                    if (current_stage.leave) |func| {
                        func(self); // func(self, next_stage)?.. might be useful
                    }
                    self.current_stage = next_stage;
                    if (next_stage.enter) |func| {
                        func(self);
                    }
                },
            }
        } else {
            print(
                "\n{s} @ {s} : no reflex for '{c}{}'\n",
                .{self.name, current_stage.name, Stage.esk_tags[row], col}
            );
            unreachable;
        }
    }

    pub fn msgTo(self: *Self, dst: ?*Self, sqn: u4, data: ?*anyopaque) void {
        const msg = Message {
            .src = self,
            .dst = dst,
            .esk = .sm,
            .sqn = sqn,
            .ptr = data,
        };
        // message buffer is not growable so this will panic
        // when there is no more space left in the buffer
        self.md.mq.put(msg) catch unreachable;
    }

    pub fn run(self: *Self) !void {

        if (0 == self.stages.items.len)
            return error.HasNoStates;
        if (self.is_running)
            return error.IsAlreadyRunning;

        self.current_stage = &self.stages.items[0];
        if (self.current_stage.enter) |hello| {
            hello(self);
        }
        self.is_running = true;
    }
};
