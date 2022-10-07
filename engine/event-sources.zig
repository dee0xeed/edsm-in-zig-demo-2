
const std = @import("std");
const os = std.os;
const mem = std.mem;
const net = std.net;

const timerFd = os.timerfd_create;
const timerFdSetTime = os.timerfd_settime;
const TimeSpec = os.linux.timespec;
const ITimerSpec = os.linux.itimerspec;

const signalFd  = os.signalfd;
const sigProcMask = os.sigprocmask;
const SigSet = os.sigset_t;
const SIG = os.SIG;
const SigInfo = os.linux.signalfd_siginfo;

const edsm = @import("edsm.zig");
const StageMachine = edsm.StageMachine;
const ecap = @import("event-capture.zig");

//pub const ClientSocket = struct {
//    fd: i32,
//    addr: net.Address,
//};

pub const EventSource = struct {

    const Self = @This();

    pub const Kind = enum {
        sm, // state machine
        io, // socket, serial etc.
        sg, // signal
        tm, // timer
        fs, // file system
    };

    /// this is for i/o kind, for other kinds must be set to 'none'
    pub const SubKind = enum {
        none,
        ssock,  // listening TCP socket
        csock,  // client TCP socket
        serdev, // '/dev/ttyS0' and alike
    };

    pub const AboutIo = struct {
        bytes_avail: u32 = 0,
    };

    pub const AboutTimer = struct {
        nexp: u64 = 0,
    };

    pub const AboutSignal = struct {
        sig_info: SigInfo = undefined,
    };

    pub const Info = union(Kind) {
        sm: void,
        io: AboutIo,
        sg: AboutSignal,
        tm: AboutTimer,
        fs: void,
    };

    kind: Kind,
    subkind: SubKind,
    id: i32 = -1, // fd in most cases, but not always
    owner: *StageMachine,
    seqn: u4 = 0,
    info: Info,

    pub fn init(
        owner: *StageMachine,
        esk: EventSource.Kind,
        essk: EventSource.SubKind,
        seqn: u4
    ) EventSource {
        if ((esk != .io) and (essk != .none)) unreachable;
        return EventSource {
            .kind = esk,
            .subkind = essk,
            .owner = owner,
            .seqn = seqn,
            .info = switch (esk) {
                .io => Info{.io = AboutIo{}},
                .sg => Info{.sg = AboutSignal{}},
                .tm => Info{.tm = AboutTimer{}},
                else => unreachable,
            }
        };
    }

    fn getServerSocketFd(port: u16) !i32 {
        const fd = try os.socket(os.AF.INET, os.SOCK.STREAM, os.IPPROTO.TCP);
        errdefer os.close(fd);
        const yes = mem.toBytes(@as(c_int, 1));
        try os.setsockopt(fd, os.SOL.SOCKET, os.SO.REUSEADDR, &yes);
        const addr = net.Address.initIp4(.{0,0,0,0}, port);
        var socklen = addr.getOsSockLen();
        try os.bind(fd, &addr.any, socklen);
        try os.listen(fd, 128);
        return fd;
    }

    pub fn acceptClient(self: *Self) !i32 {
        if (self.kind != .io) unreachable;
        if (self.subkind != .ssock) unreachable;
        var addr: net.Address = undefined;
        var alen: os.socklen_t = @sizeOf(net.Address);
        return try os.accept(self.id, &addr.any, &alen, 0);
    }

    fn getClientSocketFd() !i32 {
        return try os.socket(os.AF.INET, os.SOCK.STREAM, os.IPPROTO.TCP);
    }

    pub fn startConnect(self: *Self, addr: *net.Address) !void {
        const InProgress = os.ConnectError.WouldBlock;

        if (self.kind != .io) unreachable;
        if (self.subkind != .csock) unreachable;

        var flags = os.fcntl(self.id, os.F.GETFL, 0) catch unreachable;
        flags |= os.O.NONBLOCK;
        _ = os.fcntl(self.id, os.F.SETFL, flags) catch unreachable;

        os.connect(self.id, &addr.any, addr.getOsSockLen()) catch |err| {
            switch (err) {
                InProgress => return,
                else => return err,
            }
        };
    }

    fn getIoId(subkind: EventSource.SubKind, args: anytype) !i32 {
        return switch (subkind) {
            .ssock => if (1 == args.len) try getServerSocketFd(args[0]) else unreachable,
            .csock => if (0 == args.len) try getClientSocketFd() else unreachable,
            else => unreachable,
        };
    }

    fn getSignalId(signo: u6) !i32 {
        var sset: SigSet = os.empty_sigset;
        // block the signal
        os.linux.sigaddset(&sset, signo);
        sigProcMask(SIG.BLOCK, &sset, null);
        return signalFd(-1, &sset, 0);
    }

    fn getTimerId() !i32 {
        return try timerFd(os.CLOCK.REALTIME, 0);
    }

    /// obtain fd from OS
    pub fn getId(self: *Self, args: anytype) !void {
        self.id = switch (self.kind) {
            .io => try getIoId(self.subkind, args),
            .sg => blk: {
                if (1 != args.len) unreachable;
                const signo = @intCast(u6, args[0]);
                break :blk try getSignalId(signo);
            },
            .tm => if (0 == args.len) try getTimerId() else unreachable,
            else => unreachable,
        };
    }

    fn setTimer(id: i32, msec: u32) !void {
        const its = ITimerSpec {
            .it_interval = TimeSpec {
                .tv_sec = 0,
                .tv_nsec = 0,
            },
            .it_value = TimeSpec {
                .tv_sec = msec / 1000,
                .tv_nsec = (msec % 1000) * 1000 * 1000,
            },
        };
        try timerFdSetTime(id, 0, &its, null);
    }

    pub fn enable(self: *Self, eq: *ecap.EventQueue, args: anytype) !void {
        try eq.enableCanRead(self);
        if (self.kind == .tm) {
            if (1 == args.len)
                try setTimer(self.id, args[0])
            else
                unreachable;
        }
    }

    pub fn enableOut(self: *Self, eq: *ecap.EventQueue) !void {
        if (self.kind != .io) unreachable;
        try eq.enableCanWrite(self);
    }

    pub fn disable(self: *Self, eq: *ecap.EventQueue) !void {
        if (self.kind == .tm) try setTimer(self.id, 0);
        try eq.disableEventSource(self);
    }

    fn readTimerInfo(self: *Self) !void {
        var p1 = switch (self.kind) {
            .tm => &self.info.tm.nexp,
            else => unreachable,
        };
        var p2 = @ptrCast([*]u8, @alignCast(@alignOf([*]u8), p1));
        var buf = p2[0..@sizeOf(AboutTimer)];
        _ = try os.read(self.id, buf[0..]);
    }

    fn readSignalInfo(self: *Self) !void {
        var p1 = switch (self.kind) {
            .sg => &self.info.sg.sig_info,
            else => unreachable,
        };
        var p2 = @ptrCast([*]u8, @alignCast(@alignOf([*]u8), p1));
        var buf = p2[0..@sizeOf(SigInfo)];
        _ = try os.read(self.id, buf[0..]);
    }

    pub fn readInfo(self: *Self) !void {
        switch (self.kind) {
            .sg => try readSignalInfo(self),
            .tm => try readTimerInfo(self),
            else => return,
        }
    }
};
