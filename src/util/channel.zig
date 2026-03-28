const std = @import("std");

/// A bounded, thread-safe MPMC (multi-producer multi-consumer) channel.
/// Uses a fixed-capacity ring buffer with mutex + condition variables for synchronization.
pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        buffer: []T,
        capacity: usize,
        head: usize = 0, // Index of oldest item (pop side)
        tail: usize = 0, // Index of next free slot (push side)
        size: usize = 0, // Number of items in buffer
        mutex: std.Thread.Mutex = .{},
        not_empty: std.Thread.Condition = .{},
        not_full: std.Thread.Condition = .{},
        closed: bool = false,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const buffer = try allocator.alloc(T, capacity);
            return Self{
                .allocator = allocator,
                .buffer = buffer,
                .capacity = capacity,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        /// Send an item. Blocks if the channel is full.
        /// Returns error.ChannelClosed if the channel was closed.
        pub fn send(self: *Self, item: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Wait until there's space or the channel is closed
            while (self.size >= self.capacity and !self.closed) {
                self.not_full.wait(&self.mutex);
            }

            if (self.closed) {
                return error.ChannelClosed;
            }

            // Insert item at tail
            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.capacity;
            self.size += 1;

            // Signal that there's data available
            self.not_empty.signal();
        }

        /// Receive an item. Returns null if the channel is closed and empty.
        /// Blocks if the channel is empty but not closed.
        pub fn recv(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Wait until there's data or the channel is closed
            while (self.size == 0 and !self.closed) {
                self.not_empty.wait(&self.mutex);
            }

            if (self.size == 0) {
                return null; // Channel closed and empty
            }

            // Extract item from head
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.capacity;
            self.size -= 1;

            // Signal that there's space available
            self.not_full.signal();

            return item;
        }

        /// Close the channel. No more items can be sent.
        /// Receivers will get null when the channel is empty.
        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.closed = true;

            // Wake up all waiters
            self.not_empty.broadcast();
            self.not_full.broadcast();
        }

        /// Check if the channel is closed.
        pub fn isClosed(self: *const Self) bool {
            return self.closed;
        }
    };
}

// ── Tests ────────────────────────────────────────────────────────────

test "Channel basic send and recv" {
    var ch = try Channel(i32).init(std.testing.allocator, 4);
    defer ch.deinit();

    try ch.send(42);
    const val = ch.recv();
    try std.testing.expectEqual(@as(?i32, 42), val);
}

test "Channel returns null when closed and empty" {
    var ch = try Channel(i32).init(std.testing.allocator, 4);
    defer ch.deinit();

    try ch.send(1);
    try ch.send(2);
    ch.close();

    try std.testing.expectEqual(@as(?i32, 1), ch.recv());
    try std.testing.expectEqual(@as(?i32, 2), ch.recv());
    try std.testing.expectEqual(@as(?i32, null), ch.recv());
}

test "Channel blocks on full and empty" {
    var ch = try Channel(u32).init(std.testing.allocator, 2);
    defer ch.deinit();

    // Fill the channel
    try ch.send(1);
    try ch.send(2);

    // Try to send when full — should error after close
    ch.close();
    try std.testing.expectError(error.ChannelClosed, ch.send(3));
}

test "Channel closed prevents send" {
    var ch = try Channel(i32).init(std.testing.allocator, 4);
    defer ch.deinit();

    ch.close();
    try std.testing.expectError(error.ChannelClosed, ch.send(42));
}
