//! Background thread that reads terminal replies during a run. The writer
//! appends `CSI 5 n` after every frame; this thread timestamps each `CSI 0 n`
//! reply (replies arrive in order), so the writer never waits for a round trip.

const std = @import("std");
const c = std.c;
const term = @import("term.zig");
const replies = @import("replies.zig");

/// Ring of ack timestamps; index = ack number mod len.
pub const ring_len = 1 << 20;

pub const Reader = struct {
    ack_ns: []u64,
    /// Total DSR acks seen. Written only by the reader thread.
    acks: std.atomic.Value(u64) = .init(0),
    /// Total DA1 replies seen (resync sentinel between cells).
    da1s: std.atomic.Value(u64) = .init(0),
    /// Watchdog: a main-thread write with no progress for this long is
    /// interrupted and flagged as stalled. 0 = off.
    stall_ns: u64 = 0,
    kitty_errors: std.atomic.Value(u32) = .init(0),
    /// First bytes of the most recent kitty error reply (for logs/results).
    last_kitty_error: [96]u8 = undefined,
    last_kitty_error_len: std.atomic.Value(usize) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    mutex: c.pthread_mutex_t = c.PTHREAD_MUTEX_INITIALIZER,
    cond: c.pthread_cond_t = c.PTHREAD_COND_INITIALIZER,
    thread: ?std.Thread = null,

    pub fn init(gpa: std.mem.Allocator) !Reader {
        return .{ .ack_ns = try gpa.alloc(u64, ring_len) };
    }

    pub fn deinit(r: *Reader, gpa: std.mem.Allocator) void {
        r.join();
        gpa.free(r.ack_ns);
    }

    pub fn start(r: *Reader) !void {
        r.stop.store(false, .release);
        r.thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, run, .{r});
    }

    pub fn join(r: *Reader) void {
        r.stop.store(true, .release);
        if (r.thread) |t| t.join();
        r.thread = null;
    }

    pub fn ackTime(r: *const Reader, n: u64) u64 {
        return r.ack_ns[n % ring_len];
    }

    pub fn lastKittyError(r: *const Reader) []const u8 {
        return r.last_kitty_error[0..r.last_kitty_error_len.load(.acquire)];
    }

    /// Blocks until `acks >= target`, the deadline (monotonic ns) passes, or
    /// the run is interrupted. Returns the ack count.
    pub fn waitAcks(r: *Reader, target: u64, deadline_ns: u64) u64 {
        return r.waitFor(&r.acks, target, deadline_ns);
    }

    /// Like `waitAcks`, for DA1 replies.
    pub fn waitDa1(r: *Reader, target: u64, deadline_ns: u64) u64 {
        return r.waitFor(&r.da1s, target, deadline_ns);
    }

    fn waitFor(r: *Reader, counter: *const std.atomic.Value(u64), target: u64, deadline_ns: u64) u64 {
        var n = counter.load(.acquire);
        if (n >= target) return n;
        _ = c.pthread_mutex_lock(&r.mutex);
        defer _ = c.pthread_mutex_unlock(&r.mutex);
        while (true) {
            n = counter.load(.acquire);
            if (n >= target or term.interrupted.load(.acquire)) return n;
            const now = term.nowNs();
            if (now >= deadline_ns) return n;
            // Wake at least every 50 ms to notice interrupts.
            const wait_ns = @min(deadline_ns - now, 50 * std.time.ns_per_ms);
            var abs = realtimeIn(wait_ns);
            _ = c.pthread_cond_timedwait(&r.cond, &r.mutex, &abs);
        }
    }

    fn watchdog(r: *const Reader) void {
        watchdogCheck(r.stall_ns);
    }

    fn run(r: *Reader) void {
        var parser: replies.Parser = .{};
        var buf: [4096]u8 = undefined;
        var fds = [_]c.pollfd{.{ .fd = term.stdin_fd, .events = c.POLL.IN, .revents = 0 }};
        while (!r.stop.load(.acquire)) {
            const ready = c.poll(&fds, 1, 100);
            r.watchdog();
            if (ready <= 0) continue;
            const n = c.read(term.stdin_fd, &buf, buf.len);
            if (n <= 0) {
                if (n == 0) return; // EOF: terminal gone
                continue;
            }
            const now = term.nowNs();
            var new_acks: u64 = 0;
            var new_da1s: u64 = 0;
            const base = r.acks.load(.monotonic);
            for (buf[0..@intCast(n)]) |b| {
                const e = parser.feed(b) orelse continue;
                switch (e.kind) {
                    .dsr_ok => {
                        r.ack_ns[(base + new_acks) % ring_len] = now;
                        new_acks += 1;
                    },
                    .kitty_graphics => if (!e.kittyOk()) {
                        const len = @min(e.body.len, r.last_kitty_error.len);
                        @memcpy(r.last_kitty_error[0..len], e.body[0..len]);
                        r.last_kitty_error_len.store(len, .release);
                        _ = r.kitty_errors.fetchAdd(1, .acq_rel);
                    },
                    .da1 => new_da1s += 1,
                    .ctrl_c => {
                        // A second Ctrl-C means the main thread is stuck.
                        if (term.interrupted.swap(true, .acq_rel)) {
                            term.restore();
                            c._exit(130);
                        }
                        term.wakeMain();
                    },
                    else => {},
                }
            }
            if (new_da1s > 0) _ = r.da1s.fetchAdd(new_da1s, .acq_rel);
            if (new_acks > 0 or new_da1s > 0) {
                if (new_acks > 0) r.acks.store(base + new_acks, .release);
                _ = c.pthread_mutex_lock(&r.mutex);
                _ = c.pthread_cond_signal(&r.cond);
                _ = c.pthread_mutex_unlock(&r.mutex);
            }
        }
    }
};

// Reader-thread half of `term.writeWatched`.
fn watchdogCheck(stall_ns: u64) void {
    if (stall_ns == 0) return;
    const since = term.write_since.load(.acquire);
    if (since == 0 or term.nowNs() -| since < stall_ns) return;
    if (term.write_stalled.swap(true, .acq_rel)) return;
    term.wakeMain();
}

fn realtimeIn(ns: u64) c.timespec {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.REALTIME, &ts);
    const total = @as(u64, @intCast(ts.nsec)) + ns;
    ts.sec += @intCast(total / std.time.ns_per_s);
    ts.nsec = @intCast(total % std.time.ns_per_s);
    return ts;
}
