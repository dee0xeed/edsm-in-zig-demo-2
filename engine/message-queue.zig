
const std = @import("std");
const Allocator = std.mem.Allocator;

const edsm = @import("edsm.zig");
const ecap = @import("event-capture.zig");
const esrc = @import("event-sources.zig");

pub const MessageDispatcher = struct {

    const Self = @This();

    /// Ring buffer (non-growable) that holds messages
    pub const MessageQueue = struct {

        const MQ = @This();

        pub const Error = error {
            IsFull,
        };

        /// This structure decribes a message being sent to stage machines
        pub const Message = struct {

            /// internal messages
            pub const M0: u4 = 0;
            pub const M1: u4 = 1;
            pub const M2: u4 = 2;
            pub const M3: u4 = 3;
            pub const M4: u4 = 4;
            pub const M5: u4 = 5;
            pub const M6: u4 = 6;
            pub const M7: u4 = 7;

            /// read()/accept() will not block (POLLIN)
            pub const D0: u4 = 0;
            /// write() will not block/connection established (POLLOUT)
            pub const D1: u4 = 1;
            /// error happened (POLLERR, POLLHUP, POLLRDHUP)
            pub const D2: u4 = 2;

            /// timers
            pub const T0: u4 = 0;
            pub const T1: u4 = 1;
            pub const T2: u4 = 2;

            /// signals
            pub const S0: u4 = 0;
            pub const S1: u4 = 1;
            pub const S2: u4 = 2;

            /// file system events (TODO)
            pub const F0: u4 = 0;
            pub const F1: u4 = 1;
            pub const F2: u4 = 2;

            /// message sender (null for messages from OS)
            src: ?*edsm.StageMachine,
            /// message recipient (null will stop event loop)
            dst: ?*edsm.StageMachine,
            /// row number for stage reflex matrix
            esk: esrc.EventSource.Kind,
            /// column number for stage reflex matrix
            sqn: u4,
            /// *EventSource for messages from OS (Tx, Sx, Dx, Fx),
            /// otherwise (Mx) pointer to some arbitrary data if needed
            ptr: ?*anyopaque,
        };

        cap: u32,
        storage: []Message,
        index_mask: u32,
        r_index: u32,
        w_index: u32,
        n_items: u32,

        pub fn onHeap(a: Allocator, order: u5) !*MessageQueue {
            var mq = try a.create(MessageQueue);
            mq.cap = @intCast(u32, 1) << order;
            mq.storage = try a.alloc(Message, mq.cap);
            mq.index_mask = mq.cap - 1;
            mq.r_index = 0;
            mq.w_index = mq.cap - 1;
            mq.n_items = 0;
            return mq;
        }

        pub fn onStack(a: Allocator, order: u5) !MessageQueue {
            const cap = @intCast(u32, 1) << order;
            const buf = try a.alloc(Message, cap);
            return MessageQueue {
                .cap = cap,
                .storage = buf,
                .index_mask = cap - 1,
                .r_index = 0,
                .w_index = cap - 1,
                .n_items = 0,
            };
        }

        pub fn put(self: *MQ, item: Message) !void {
            if (self.n_items == self.cap) return error.IsFull;
            self.w_index += 1;
            self.w_index &= self.index_mask;
            self.storage[self.w_index] = item;
            self.n_items += 1;
        }

        pub fn get(self: *MQ) ?Message {
            if (0 == self.n_items) return null;
            var item = self.storage[self.r_index];
            self.n_items -= 1;
            self.r_index += 1;
            self.r_index &= self.index_mask;
            return item;
        }
    };

    mq: *MessageQueue,
    eq: ecap.EventQueue,

    pub fn onStack(a: Allocator, mq_cap_order: u5) !MessageDispatcher {
        var mq = try MessageQueue.onHeap(a, mq_cap_order);
        var eq = try ecap.EventQueue.onStack(mq);
        return MessageDispatcher {
            .mq = mq,
            .eq = eq,
        };
    }

    /// message processing loop
    pub fn loop(self: *Self) !void {
        outer: while (true) {
            while (true) {
                const msg = self.mq.get() orelse break;
                if (msg.dst) |sm| {
                    sm.reactTo(msg);
                } else {
                    if (msg.src) |sm| {
                        if (sm.current_stage.leave) |bye| {
                            bye(sm);
                        }
                    }
                    break :outer;
                }
            }
            try self.eq.wait();
        }
    }
};
