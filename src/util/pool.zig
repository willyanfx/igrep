const std = @import("std");

/// Thread pool for parallel file processing.
/// Wraps std.Thread.Pool with a simpler interface for our use case.
pub const ThreadPool = struct {
    pool: std.Thread.Pool,

    pub fn init(allocator: std.mem.Allocator, thread_count: ?u32) !ThreadPool {
        var pool: std.Thread.Pool = undefined;
        try pool.init(.{
            .allocator = allocator,
            .n_jobs = if (thread_count) |tc| @as(usize, tc) else null,
        });

        return .{ .pool = pool };
    }

    pub fn deinit(self: *ThreadPool) void {
        self.pool.deinit();
    }

    /// Spawn a task on the thread pool.
    pub fn spawn(self: *ThreadPool, comptime func: anytype, args: anytype) void {
        self.pool.spawn(func, args);
    }
};

/// A thread-safe counter for aggregating results across worker threads.
pub const AtomicCounter = struct {
    value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn increment(self: *AtomicCounter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    pub fn add(self: *AtomicCounter, n: u64) void {
        _ = self.value.fetchAdd(n, .monotonic);
    }

    pub fn get(self: *const AtomicCounter) u64 {
        return self.value.load(.monotonic);
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "AtomicCounter basic operations" {
    var counter = AtomicCounter{};
    counter.increment();
    counter.increment();
    counter.add(3);
    try std.testing.expectEqual(@as(u64, 5), counter.get());
}
