# edsm-in-zig-demo-2 (simple echo server)

## Preliminary notes

First of all - this is **NOT** so called hierarchical state machines (nested states and whatnots)
implementation.

### Events

This is epoll based implementation, so in essence events are:

* `EPOLLIN` (`read()`/`accept()` will not block)
* `EPOLLOUT` (`write()` will not block)
* `EPOLLERR/EPOLLHUP/EPOLLRDHUP`

### Event sources (channels)

Event source is anything representable by file descriptor and thus can be used with `epoll` facility:

* signals (`EPOLLIN` only)
* timers (`EPOLLIN` only)
* sockets, terminals, serial devices, fifoes etc.
* file system (via `inotify` facility)

## Server architecture

The server consists of 4 kinds of state machines:

* LISTENER (one instance)
* WORKER (many instances, kept in a pool when idle)
* RX/TX (many instances, also kept in pools)

### LISTENER

Listener is responsible for accepting incoming connections and also for managing
resources, assotiated with connected client (memory and file descriptor). Has 2 states:

* INIT
* WORK

### WORKER

Worker is a machine which implements message flow pattern. Has 5 states:

* INIT
* IDLE
* RECV
* SEND
* FAIL

### RX

Rx is a machine which knows how to read data. Has 3 states:

* INIT
* IDLE
* WORK

### TX

Rx is a machine which knows how to write data. Also has 3 states:

* INIT
* IDLE
* WORK
