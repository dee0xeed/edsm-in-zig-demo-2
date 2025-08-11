
const std = @import("std");
const os = std.os;
const mem = std.mem;
const net = std.net;

const timerFd = std.posix.timerfd_create;
const timerFdSetTime = std.posix.timerfd_settime;
const TimeSpec = os.linux.timespec;
const ITimerSpec = os.linux.itimerspec;

const signalFd  = std.posix.signalfd;
const sigProcMask = std.posix.sigprocmask;
const SigSet = std.posix.sigset_t;
const SIG = std.posix.SIG;
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
    kind: Kind,
    subkind: SubKind,
    id: i32 = -1, // fd in most cases, but not always
    owner: *StageMachine,
    seqn: u4 = 0,
    info: Info,

    pub const Kind = enum {
        sm, // state machine
        io, // socket, serial etc.
        sg, // signal
        tm, // timer
        fs, // file system
    };

    /// this is for i/o kind, for other kind must be set to 'none'
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
        const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
        errdefer std.posix.close(fd);
        const yes = mem.toBytes(@as(c_int, 1));
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &yes);
        const addr = net.Address.initIp4(.{0,0,0,0}, port);
        const socklen = addr.getOsSockLen();
        try std.posix.bind(fd, &addr.any, socklen);
        try std.posix.listen(fd, 128);
        return fd;
    }

    pub fn acceptClient(self: *Self) !i32 {
        if (self.kind != .io) unreachable;
        if (self.subkind != .ssock) unreachable;
        var addr: net.Address = undefined;
        var alen: std.posix.socklen_t = @sizeOf(net.Address);
        return try std.posix.accept(self.id, &addr.any, &alen, 0);
    }

    fn getClientSocketFd() !i32 {
        return try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
    }

    pub fn startConnect(self: *Self, addr: *net.Address) !void {
        const InProgress = std.posix.ConnectError.WouldBlock;

        if (self.kind != .io) unreachable;
        if (self.subkind != .csock) unreachable;

        var flags = std.posix.fcntl(self.id, std.posix.F.GETFL, 0) catch unreachable;
        flags |= std.posix.SOCK.NONBLOCK;
        _ = std.posix.fcntl(self.id, std.posix.F.SETFL, flags) catch unreachable;

        std.posix.connect(self.id, &addr.any, addr.getOsSockLen()) catch |err| {
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
        var sset: SigSet = std.posix.empty_sigset;
        // block the signal
        std.os.linux.sigaddset(&sset, signo);
        sigProcMask(SIG.BLOCK, &sset, null);
        return signalFd(-1, &sset, 0);
    }

    fn getTimerId() !i32 {
//        return try timerFd(std.os.linux.CLOCK.REALTIME, .{}); // 0.14.0
        return try timerFd(std.os.linux.TIMERFD_CLOCK.REALTIME, .{}); // 0.14.1
    }

    /// obtain fd from OS
    pub fn getId(self: *Self, args: anytype) !void {
        self.id = switch (self.kind) {
            .io => try getIoId(self.subkind, args),
            .sg => blk: {
                if (1 != args.len) unreachable;
                const signo: u6 = @intCast(args[0]);
                break :blk try getSignalId(signo);
            },
            .tm => if (0 == args.len) try getTimerId() else unreachable,
            else => unreachable,
        };
    }

    fn setTimer(id: i32, msec: u32) !void {
        const its = ITimerSpec {
            .it_interval = TimeSpec {
                .sec = 0,
                .nsec = 0,
            },
            .it_value = TimeSpec {
                .sec = msec / 1000,
                .nsec = (msec % 1000) * 1000 * 1000,
            },
        };
        try timerFdSetTime(id, .{}, &its, null);
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
        const p1 = switch (self.kind) {
            .tm => &self.info.tm.nexp,
            else => unreachable,
        };
        var p2: [*]u8 = @ptrCast(@alignCast(p1));
        var buf = p2[0..@sizeOf(AboutTimer)];
        _ = try std.posix.read(self.id, buf[0..]);
    }

    fn readSignalInfo(self: *Self) !void {
        const p1 = switch (self.kind) {
            .sg => &self.info.sg.sig_info,
            else => unreachable,
        };
        var p2: [*]u8 = @ptrCast(@alignCast(p1));
        var buf = p2[0..@sizeOf(SigInfo)];
        _ = try std.posix.read(self.id, buf[0..]);
    }

    pub fn readInfo(self: *Self) !void {
        switch (self.kind) {
            .sg => try readSignalInfo(self),
            .tm => try readTimerInfo(self),
            else => return,
        }
    }
};
