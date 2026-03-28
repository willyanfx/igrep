const std = @import("std");

/// Convenience wrapper around std.heap.ArenaAllocator for per-search-job
/// allocation. All memory allocated during a search job is freed in one shot
/// when the arena is reset or deinitialized.
pub const SearchArena = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(backing: std.mem.Allocator) SearchArena {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
        };
    }

    pub fn allocator(self: *SearchArena) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Free all allocations made through this arena.
    pub fn reset(self: *SearchArena) void {
        _ = self.arena.reset(.free_all);
    }

    pub fn deinit(self: *SearchArena) void {
        self.arena.deinit();
    }
};

test "SearchArena allocate and reset" {
    var arena = SearchArena.init(std.testing.allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    const buf = try alloc.alloc(u8, 1024);
    _ = buf;

    arena.reset();

    // Should be able to allocate again after reset
    const buf2 = try alloc.alloc(u8, 2048);
    _ = buf2;
}
