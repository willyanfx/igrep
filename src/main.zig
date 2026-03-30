const std = @import("std");
const searcher = @import("searcher.zig");
const cli = @import("cli.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = cli.parseArgs(allocator) catch |err| {
        switch (err) {
            error.ShowHelp => {
                cli.printUsage();
                return;
            },
            error.ShowVersion => {
                const stdout = std.fs.File.stdout().deprecatedWriter();
                try stdout.print("instantGrep {s}\n", .{version});
                return;
            },
            else => {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                try stderr.print("igrep: error parsing arguments\n", .{});
                std.process.exit(1);
            },
        }
    };
    defer config.deinit(allocator);

    // Create buffered stdout writer — owned by main, outlives Searcher
    var out_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&out_buf);

    var search_engine = searcher.Searcher.init(allocator, config, &stdout_writer.interface) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print("igrep: error compiling pattern: {}\n", .{err}) catch {};
        std.process.exit(2);
    };
    defer search_engine.deinit();

    // Index build mode: build index and exit
    if (config.build_index) {
        search_engine.buildIndex() catch |err| {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            stderr.print("igrep: index build failed: {}\n", .{err}) catch {};
            std.process.exit(2);
        };
        return;
    }

    const match_count = search_engine.run() catch |err| {
        // If indexed search fails, fall back to full scan
        if (err == error.InvalidIndex) {
            var fallback = search_engine;
            fallback.config.use_index = false;
            const count = try fallback.run();
            if (count == 0) std.process.exit(1);
            return;
        }
        return err;
    };

    // Exit code follows grep convention: 0 = matches found, 1 = no matches
    if (match_count == 0) {
        std.process.exit(1);
    }
}

pub const version = "0.1.0";

// Pull in all modules for testing
test {
    _ = @import("cli.zig");
    _ = @import("searcher.zig");
    _ = @import("engine/literal.zig");
    _ = @import("engine/regex.zig");
    _ = @import("engine/lazy_dfa.zig");
    _ = @import("io/mmap.zig");
    _ = @import("io/walker.zig");
    _ = @import("io/gitignore.zig");
    _ = @import("output/printer.zig");
    _ = @import("output/buffer.zig");
    _ = @import("index/builder.zig");
    _ = @import("index/store.zig");
    _ = @import("index/query.zig");
    _ = @import("index/query_decompose.zig");
    _ = @import("index/cache.zig");
    _ = @import("util/pool.zig");
    _ = @import("util/simd.zig");
    _ = @import("engine/aho_corasick.zig");
    _ = @import("engine/prefilter.zig");
    _ = @import("io/reader.zig");
}
