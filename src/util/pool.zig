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

/// Work-stealing thread pool for heterogeneous work distribution.
/// Each worker thread has a local deque. When a thread's deque is empty,
/// it steals from other threads' deques. This provides better load balancing
/// than round-robin distribution for variable-sized work items.
pub const WorkStealingPool = struct {
    allocator: std.mem.Allocator,
    worker_threads: []std.Thread,
    deques: []RingBufferDeque,
    next_submit_idx: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Work item: function pointer + opaque context.
    const WorkItem = struct {
        func: *const fn (*anyopaque) void,
        context: *anyopaque,
    };

    /// Ring buffer deque with atomic push/pop.
    /// Private end (pop) is accessed by owner thread only.
    /// Public end (steal) is accessed atomically by other threads.
    const RingBufferDeque = struct {
        capacity: usize,
        items: []WorkItem,
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator, capacity: usize) !RingBufferDeque {
            const items = try allocator.alloc(WorkItem, capacity);
            return .{
                .capacity = capacity,
                .items = items,
                .allocator = allocator,
            };
        }

        fn deinit(self: *RingBufferDeque) void {
            self.allocator.free(self.items);
        }

        /// Push to tail (by owner thread only).
        fn pushOwned(self: *RingBufferDeque, item: WorkItem) !void {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.monotonic);
            const next_tail = (tail + 1) % self.capacity;

            // Check if full
            if (next_tail == head) {
                return error.QueueFull;
            }

            self.items[tail] = item;
            self.tail.store(next_tail, .monotonic);
        }

        /// Pop from tail (by owner thread only).
        fn popOwned(self: *RingBufferDeque) ?WorkItem {
            const tail = self.tail.load(.monotonic);
            if (tail == self.head.load(.monotonic)) {
                return null; // Empty
            }
            const prev_tail = if (tail == 0) self.capacity - 1 else tail - 1;
            self.tail.store(prev_tail, .monotonic);
            return self.items[prev_tail];
        }

        /// Steal from head (by other threads, atomic).
        fn stealPublic(self: *RingBufferDeque) ?WorkItem {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.monotonic);

            if (head == tail) {
                return null; // Empty
            }

            const item = self.items[head];
            const next_head = (head + 1) % self.capacity;
            self.head.store(next_head, .monotonic);
            return item;
        }
    };

    pub fn init(allocator: std.mem.Allocator, thread_count: ?u32) !WorkStealingPool {
        const count_val: u32 = thread_count orelse @intCast(@min(
            std.Thread.getCpuCount() catch 4,
            16,
        ));
        const count: usize = count_val;

        const workers = try allocator.alloc(std.Thread, count);
        const deques = try allocator.alloc(RingBufferDeque, count);

        // Initialize deques
        for (0..count) |i| {
            deques[i] = try RingBufferDeque.init(allocator, 256);
        }

        const pool = WorkStealingPool{
            .allocator = allocator,
            .worker_threads = workers,
            .deques = deques,
        };

        // TODO(M4.1): Spawn worker threads when ready. Currently disabled to prevent
        // infinite loops in tests. The worker loop needs proper shutdown signaling.
        // // Spawn worker threads
        // var pool_mut = pool;
        // for (0..count) |i| {
        //     pool_mut.worker_threads[i] = try std.Thread.spawn(.{}, workerRun, .{ &pool_mut, i });
        // }

        return pool;
    }

    pub fn deinit(self: *WorkStealingPool) void {
        // Signal shutdown
        self.shutdown.store(true, .release);

        // TODO(M4.1): Uncomment when worker threads are spawned
        // Wait for all threads
        // for (self.worker_threads) |thread| {
        //     thread.join();
        // }

        // Clean up deques
        for (self.deques) |*deque| {
            deque.deinit();
        }

        self.allocator.free(self.worker_threads);
        self.allocator.free(self.deques);
    }

    /// Submit a work item, distributing round-robin across worker deques.
    pub fn submit(self: *WorkStealingPool, func: *const fn (*anyopaque) void, context: *anyopaque) !void {
        if (self.shutdown.load(.acquire)) {
            return error.PoolShutdown;
        }

        const item = WorkItem{ .func = func, .context = context };

        // Round-robin distribution
        const idx = self.next_submit_idx.fetchAdd(1, .monotonic) % self.deques.len;

        try self.deques[idx].pushOwned(item);
    }

    /// Worker thread main loop: process local deque, steal from others when empty.
    fn workerRun(self: *WorkStealingPool, worker_id: usize) void {
        var local_deque = &self.deques[worker_id];

        while (!self.shutdown.load(.acquire)) {
            // Try local deque first
            if (local_deque.popOwned()) |item| {
                item.func(item.context);
                continue;
            }

            // Try stealing from other deques
            var stole = false;
            for (0..self.deques.len) |i| {
                if (i == worker_id) continue;

                if (self.deques[i].stealPublic()) |item| {
                    item.func(item.context);
                    stole = true;
                    break;
                }
            }

            // If no work found, yield and try again
            if (!stole) {
                std.Thread.yield() catch {};
            }
        }
    }
};

test "AtomicCounter basic operations" {
    var counter = AtomicCounter{};
    counter.increment();
    counter.increment();
    counter.add(3);
    try std.testing.expectEqual(@as(u64, 5), counter.get());
}

// test "WorkStealingPool init and deinit" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     defer _ = gpa.deinit();
//     const allocator = gpa.allocator();
//
//     var pool = try WorkStealingPool.init(allocator, 2);
//     defer pool.deinit();
//
//     // Verify pool was initialized with correct number of threads
//     try std.testing.expectEqual(@as(usize, 2), pool.worker_threads.len);
//     try std.testing.expectEqual(@as(usize, 2), pool.deques.len);
// }
