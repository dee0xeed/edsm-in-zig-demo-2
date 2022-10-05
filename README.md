# edsm-in-zig-demo-2 (simple echo server)

## Preliminary notes

First of all - this is **NOT** so called hierarchical state machines (nested states and whatnots)
implementation. It is much more convenient to deal with *hierarchy of* (relatively simple)
*interacting state machines* rather than with a single huge machine having *hierarchy of states*.

### Events

This is epoll based implementation, so in essence events are:

* `EPOLLIN` (`read()`/`accept()` will not block)
* `EPOLLOUT` (`write()` will not block)
* `EPOLLERR/EPOLLHUP/EPOLLRDHUP`

Upon returning from `epoll_wait()` these events are transformed into messages
and then delivered to destination state machine. Besides messages triggered
by 'external world', there are internal messages - machines can send them to each other directly
(see `engine/architecture.txt` in the sources).

### Event sources (channels)

Event source is anything representable by file descriptor and thus can be used with `epoll` facility:

* signals (`EPOLLIN` only)
* timers (`EPOLLIN` only)
* sockets, terminals, serial devices, fifoes etc.
* file system (via `inotify` facility)

### Event/messages notation

* M0, M1, M2 ... - internal messages
* S0, S1, S2 ... - signals
* T0, T1, T2 ... - timers
* DO, D1, D2     - i/o ('can read', 'can write', 'error')
* F0, F1, F2 ... - file system ('writable file was closed' and alike)

These 'tags' are used in the names of state machines 'methods', for example:

```zig
    fn workD2(me: *StageMachine, src: ?*StageMachine, data: ?*anyopaque) void {
        _ = src;
        _ = data;
        var pd = @ptrCast(*TxData, @alignCast(@alignOf(*TxData), me.data));
        me.msgTo(me, M0_IDLE, null);
        me.msgTo(pd.customer, M2_FAIL, null);
    }
```

### Enter/Leave functions

Each state can have enter/leave functions, which can be used to perform some action
in addition to 'regular' actions. For example, `RX` machine stops timeout timer
when leaving `WORK` state:

```zig
    fn workLeave(me: *StageMachine) void {
        var pd = @ptrCast(*RxData, @alignCast(@alignOf(*RxData), me.data));
        pd.tm0.disable(&me.md.eq) catch unreachable;
    }
```

## Server architecture

The server consists of 4 kinds of state machines:

* LISTENER (one instance)
* WORKER (many instances, kept in a pool when idle)
* RX/TX (many instances, also kept in pools)

Thus we have 3-level hierarchy here.

### LISTENER

Listener is responsible for accepting incoming connections and also for managing
resources, associated with connected client (memory and file descriptor). Has 2 states:

* INIT
    * enter: prepare channels
    * `M0` => goto `WORK` state
    * leave: nothing
* WORK
    * enter: enable channels
    * `D0` => accept connection, take WORKER from the pool, send it `M1` with ptr to client as payload
    * `M0` => close connection, free memory
    * `S0` (SIGINT) => stop event loop
    * `S1` (SIGTERM) => stop event loop
    * leave: say goodbye

### WORKER

Worker is a machine which implements message flow pattern. Has 5 states:

* INIT
    * enter: 
    * `M0` => goto `IDLE` state
    * leave: 
* IDLE
    * enter: 
    * `M1` => store information about client
    * `M0` => goto `RECV` state
    * leave: 
* RECV
    * enter: 
    * `M0` => goto `SEND` state
    * `M1` => send `M0` to self
    * `M2` => goto `FAIL` state
    * leave: 
* SEND
    * enter: 
    * `M0` => goto `RECV` state
    * `M1` => send `M0` to self
    * `M2` => goto `FAIL` state
    * leave: 
* FAIL
    * enter: 
    * `M0` => goto `IDLE` state
    * leave: 

### RX

Rx is a machine which knows how to read data. Has 3 states:

* INIT
* IDLE
* WORK

### TX

Tx is a machine which knows how to write data. Also has 3 states:

* INIT
* IDLE
* WORK
