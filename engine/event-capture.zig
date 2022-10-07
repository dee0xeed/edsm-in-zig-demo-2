
const std = @import("std");
const os = std.os;
const print = std.debug.print;
const EpollEvent = os.linux.epoll_event;
const EpollData = os.linux.epoll_data;
const epollCreate = os.epoll_create1;
const epollCtl = os.epoll_ctl;
const epollWait = os.epoll_wait;
const EPOLL = os.linux.EPOLL;
const ioctl = os.linux.ioctl;

const msgq = @import("message-queue.zig");
const MD = msgq.MessageDispatcher;
const MessageQueue = MD.MessageQueue;
const Message = MessageQueue.Message;

const esrc = @import("event-sources.zig");
const EventSourceKind = esrc.EventSourceKind;
const EventSource = esrc.EventSource;
const EventSourceInfo = esrc.EventSourceInfo;
const IoInfo = esrc.IoInfo;
const edsm = @import("edsm.zig");
const StageMachine = edsm.StageMachine;

pub const EventQueue = struct {

    fd: i32 = -1,
    mq: *MessageQueue,

    pub fn onStack(mq: *MessageQueue) !EventQueue {
        return EventQueue {
            .fd = try epollCreate(0),
            .mq = mq,
        };
    }

    pub fn fini(self: *EventQueue) void {
        os.close(self.fd);
    }

    fn getIoEventInfo(es: *EventSource, events: u32) !u4 {

        const FIONREAD = os.linux.T.FIONREAD;
        if (0 != events & (EPOLL.ERR | EPOLL.HUP | EPOLL.RDHUP)) {
            return Message.D2;
        }

        if (0 != events & EPOLL.OUT)
            return Message.D1;

        if (0 != events & EPOLL.IN) {
            var ba: u32 = 0;
            _ = ioctl(es.id, FIONREAD, @ptrToInt(&ba)); // IOCINQ
            // see https://github.com/ziglang/zig/issues/12961
            es.info.io.bytes_avail = ba;
            return Message.D0;
        }

        unreachable;
    }

    fn getEventInfo(es: *EventSource, events: u32) !u4 {

        try es.readInfo();

        return switch (es.kind) {
            .sm => unreachable,
            .tm => es.seqn,
            .sg => es.seqn,
            .io => getIoEventInfo(es, events),
            .fs => 0, // TODO
        };
    }

    pub fn wait(self: *EventQueue) !void {

        const max_events = 1;
        var events: [max_events]EpollEvent = undefined;
        const wait_forever = -1;

        const n = epollWait(self.fd, events[0..], wait_forever);

        for (events[0..n]) |ev| {
            const es = @intToPtr(*EventSource, ev.data.ptr);
            const seqn = try getEventInfo(es, ev.events);
            const msg = Message {
                .src = null,
                .dst = es.owner,
                .esk = es.kind,
                .sqn = seqn,
                .ptr = es,
            };
            try self.mq.put(msg);
        }
    }

    const EventKind = enum {
        can_read,
        can_write,
    };

    fn enableEventSource(self: *EventQueue, es: *EventSource, ek: EventKind) !void {

        const FdAlreadyInSet = os.EpollCtlError.FileDescriptorAlreadyPresentInSet;
        var em: u32 = if (.can_read == ek) (EPOLL.IN | EPOLL.RDHUP) else EPOLL.OUT;
        em |= EPOLL.ONESHOT;

        var ee = EpollEvent {
            .events = em,
            .data = EpollData{.ptr = @ptrToInt(es)},
        };

        // emulate FreeBSD kqueue behavior
        epollCtl(self.fd, EPOLL.CTL_ADD, es.id, &ee) catch |err| {
            return switch (err) {
                FdAlreadyInSet => try epollCtl(self.fd, EPOLL.CTL_MOD, es.id, &ee),
                else => err,
            };
        };
    }

    pub fn disableEventSource(self: *EventQueue, es: *EventSource) !void {
        var ee = EpollEvent {
            .events = 0,
            .data = EpollData{.ptr = @ptrToInt(es)},
        };
        try epollCtl(self.fd, EPOLL.CTL_MOD, es.id, &ee);
    }

    pub fn enableCanRead(self: *EventQueue, es: *EventSource) !void {
        return try enableEventSource(self, es, .can_read);
    }

    pub fn enableCanWrite(self: *EventQueue, es: *EventSource) !void {
        return try enableEventSource(self, es, .can_write);
    }
};
