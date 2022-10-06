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
and then delivered to destination state machine (owner of a channel, see below).
Besides messages triggered by 'external world', there are internal messages - 
machines can send them to each other directly (see `engine/architecture.txt` in the sources).

### Event sources (channels)

Event source is anything representable by file descriptor and thus can be used with `epoll` facility:

* signals (`EPOLLIN` only)
* timers (`EPOLLIN` only)
* sockets, terminals, serial devices, fifoes etc.
* file system (via `inotify` facility)

Each event source has an owner (it is some state machine).

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
    * `M0`: goto `WORK` state
    * leave: nothing
* WORK
    * enter: enable channels
    * `D0`: accept connection, take WORKER from the pool, send it `M1` with ptr to client as payload
    * `M0`: close connection, free memory
    * `S0` (SIGINT): stop event loop
    * `S1` (SIGTERM): stop event loop
    * leave: say goodbye

### WORKER

Worker is a machine which implements message flow pattern. Has 5 states:

* INIT
    * enter: send `M0` to self
    * `M0`: goto `IDLE` state
    * leave: nothing
* IDLE
    * enter: put self into the pool
    * `M1`: store information about client
    * `M0`: goto `RECV` state
    * leave: nothing
* RECV
    * enter: get `RX` machine from pool, send it `M1` with ptr to context
    * `M0`: goto `SEND` state
    * `M1`: send `M0` to self
    * `M2`: goto `FAIL` state
    * leave: nothing
* SEND
    * enter: get `TX` machine from pool, send it `M1` with ptr to context
    * `M0`: goto `RECV` state
    * `M1`: send `M0` to self
    * `M2`: goto `FAIL` state
    * leave: nothing
* FAIL
    * enter: send `M0` to self, `M0` to `LISTENER` with ptr to client
    * `M0`: goto `IDLE` state
    * leave: nothing

### RX

Rx is a machine which knows how to read data. Has 3 states:

* INIT
    * enter: init timer and i/o channels, send `M0` to self
    * `M0`: goto `IDLE` state
    * leave: nothing
* IDLE
    * enter: put self into the pool
    * `M0`: goto `WORK` state
    * `M1`: store context given by `WORKER`
    * leave: nothing
* WORK
    * enter: enable i/o and timer
    * `D0`: read data
    * `D2`: send `M0` to self, `M2` to `WORKER`
    * `T0` (timeout): send `M0` to self, `M2` to `WORKER`
    * `M0`: goto `IDLE` state
    * leave: stop timer

### TX

Tx is a machine which knows how to write data. Also has 3 states:

* INIT
    * enter: init i/o channel
    * `M0`: goto `IDLE` state
    * leave: nothing
* IDLE
    * enter: put self into the pool
    * `M0`: goto `WORK` state
    * `M1`: store context given by `WORKER`
    * leave: nothing
* WORK
    * enter: enable i/o
    * `D1`: write data
    * `D2`: send `M0` to self, `M2` to `WORKER`
    * `M0`: goto `IDLE` state
    * leave: nothing

### Examples of workflow

* client connected (note `D0`)

```
LISTENER-1 @ WORK got 'D0' from OS
WORKER-4 @ IDLE got 'M1' from LISTENER-1
WORKER-4 @ IDLE got 'M0' from SELF
RX-4 @ IDLE got 'M1' from WORKER-4
RX-4 @ IDLE got 'M0' from SELF
```

* client suddenly disconnected (note `D2`)

```
RX-4 @ IDLE got 'M0' from SELF
RX-4 @ WORK got 'D2' from OS
RX-4 @ WORK got 'M0' from SELF
WORKER-4 @ RECV got 'M2' from RX-4
WORKER-4 @ FAIL got 'M0' from SELF
LISTENER-1 @ WORK got 'M0' from WORKER-4
```

* normal request-reply (note `D0` and `D1`)

```
RX-4 @ IDLE got 'M0' from SELF
RX-4 @ WORK got 'D0' from OS
<<< 4 bytes: { 49, 50, 51, 10 }
RX-4 @ WORK got 'M0' from SELF
WORKER-4 @ RECV got 'M1' from RX-4
WORKER-4 @ RECV got 'M0' from SELF
TX-4 @ IDLE got 'M1' from WORKER-4
TX-4 @ IDLE got 'M0' from SELF
TX-4 @ WORK got 'D1' from OS
TX-4 @ WORK got 'M0' from SELF
WORKER-4 @ SEND got 'M1' from TX-4
WORKER-4 @ SEND got 'M0' from SELF
```

* request timeout (note `T0`)

```
RX-4 @ IDLE got 'M0' from SELF
RX-4 @ WORK got 'T0' from OS
RX-4 @ WORK got 'M0' from SELF
WORKER-4 @ RECV got 'M2' from RX-4
WORKER-4 @ FAIL got 'M0' from SELF
LISTENER-1 @ WORK got 'M0' from WORKER-4
```

## Links
* [Event driven state machine](https://en.wikipedia.org/wiki/Event-driven_finite-state_machine)
* [Reactor pattern](https://en.wikipedia.org/wiki/Reactor_pattern)
* [Modeling Software with Finite State Machines](http://www.stateworks.com/book/book/)
