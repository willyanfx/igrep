const std = @import("std");
const literal = @import("engine/literal.zig");
const walker_mod = @import("io/walker.zig");
const mmap_mod = @import("io/mmap.zig");

const CORPUS_DIR = "tests/corpus";

/// Read a file fully into memory for testing.
fn readTestFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

// ── Walker Integration Tests ─────────────────────────────────────────

test "walker discovers all non-ignored files in corpus" {
    const allocator = std.testing.allocator;
    var w = walker_mod.DirWalker.init(allocator, CORPUS_DIR, null);
    defer w.deinit();

    var file_count: usize = 0;
    var found_server_go = false;
    var found_connection_py = false;
    var found_search_bar = false;
    var found_edge_cases = false;
    var found_vendor = false;
    var found_hidden = false;

    while (try w.next()) |path| {
        defer allocator.free(path);
        file_count += 1;

        if (std.mem.endsWith(u8, path, "server.go")) found_server_go = true;
        if (std.mem.endsWith(u8, path, "connection.py")) found_connection_py = true;
        if (std.mem.endsWith(u8, path, "SearchBar.tsx")) found_search_bar = true;
        if (std.mem.endsWith(u8, path, "edge_cases.txt")) found_edge_cases = true;

        // These should be skipped
        if (std.mem.indexOf(u8, path, "vendor/") != null) found_vendor = true;
        if (std.mem.indexOf(u8, path, ".hidden/") != null) found_hidden = true;
    }

    try std.testing.expect(found_server_go);
    try std.testing.expect(found_connection_py);
    try std.testing.expect(found_search_bar);
    try std.testing.expect(found_edge_cases);
    try std.testing.expect(!found_vendor);
    try std.testing.expect(!found_hidden);
    try std.testing.expect(file_count >= 20);
    try std.testing.expect(file_count <= 35);
}

test "walker respects max depth" {
    const allocator = std.testing.allocator;
    var w = walker_mod.DirWalker.init(allocator, CORPUS_DIR, 1);
    defer w.deinit();

    var found_deep_file = false;
    while (try w.next()) |path| {
        defer allocator.free(path);
        // Files in src/api/ are at depth 2+
        if (std.mem.indexOf(u8, path, "src/api/") != null) found_deep_file = true;
    }

    try std.testing.expect(!found_deep_file);
}

// ── Literal Search Integration Tests ─────────────────────────────────

test "literal search finds TODO in Go source" {
    const allocator = std.testing.allocator;
    const data = try readTestFile(allocator, "tests/corpus/src/api/server.go");
    defer allocator.free(data);

    try std.testing.expect(literal.contains(data, "TODO"));
    try std.testing.expect(literal.contains(data, "FIXME"));
    try std.testing.expect(literal.contains(data, "handleHealth"));
    try std.testing.expect(!literal.contains(data, "NONEXISTENT_PATTERN_XYZ"));
}

test "case-insensitive search across languages" {
    const allocator = std.testing.allocator;
    const go_data = try readTestFile(allocator, "tests/corpus/src/api/server.go");
    defer allocator.free(go_data);
    const py_data = try readTestFile(allocator, "tests/corpus/src/db/connection.py");
    defer allocator.free(py_data);
    const ts_data = try readTestFile(allocator, "tests/corpus/src/auth/jwt.ts");
    defer allocator.free(ts_data);

    try std.testing.expect(literal.containsCaseInsensitive(go_data, "todo"));
    try std.testing.expect(literal.containsCaseInsensitive(py_data, "todo"));
    try std.testing.expect(literal.containsCaseInsensitive(ts_data, "todo"));

    try std.testing.expect(literal.containsCaseInsensitive(go_data, "server"));
    try std.testing.expect(literal.containsCaseInsensitive(go_data, "SERVER"));
    try std.testing.expect(literal.containsCaseInsensitive(go_data, "Server"));
}

test "SIMD path exercised on realistic file sizes" {
    const allocator = std.testing.allocator;
    const data = try readTestFile(allocator, "tests/corpus/src/utils/edge_cases.txt");
    defer allocator.free(data);

    try std.testing.expect(data.len > 16);
    try std.testing.expect(literal.contains(data, "TODO"));
    try std.testing.expect(literal.contains(data, "FIXME"));
    try std.testing.expect(literal.contains(data, "HACK"));
    try std.testing.expect(literal.contains(data, "SIMD vector width"));
    try std.testing.expect(literal.contains(data, "buffer boundaries"));
    try std.testing.expect(literal.contains(data, "0123456789abcdef"));
}

test "edge cases in search patterns" {
    const allocator = std.testing.allocator;
    const data = try readTestFile(allocator, "tests/corpus/src/utils/edge_cases.txt");
    defer allocator.free(data);

    try std.testing.expect(literal.contains(data, "(TODO)"));
    try std.testing.expect(literal.contains(data, "[TODO]"));
    try std.testing.expect(literal.contains(data, "{TODO}"));
    try std.testing.expect(literal.contains(data, "TODO and another TODO"));
    try std.testing.expect(literal.contains(data, "foo.*bar"));
    try std.testing.expect(literal.contains(data, "[a-z]+"));
    try std.testing.expect(literal.contains(data, "\\d{3}"));
}

test "case-insensitive search on edge cases" {
    const allocator = std.testing.allocator;
    const data = try readTestFile(allocator, "tests/corpus/src/utils/edge_cases.txt");
    defer allocator.free(data);

    try std.testing.expect(literal.containsCaseInsensitive(data, "todo"));
    try std.testing.expect(literal.containsCaseInsensitive(data, "TODO"));
    try std.testing.expect(literal.containsCaseInsensitive(data, "Todo"));
    try std.testing.expect(literal.containsCaseInsensitive(data, "unicode"));
}

// ── Memory-mapped I/O Integration Tests ──────────────────────────────

test "mmap reads corpus files correctly" {
    var mapped = try mmap_mod.MappedFile.open("tests/corpus/config/app.json");
    defer mapped.close();

    const data = mapped.data();
    try std.testing.expect(data.len > 0);
    try std.testing.expect(literal.contains(data, "CodeSearch"));
    try std.testing.expect(literal.contains(data, "trigram_index"));
    try std.testing.expect(literal.contains(data, "bloom_filter_bits"));
}

// ── Full Pipeline Smoke Tests ────────────────────────────────────────

test "findFirst returns correct offsets in multi-language files" {
    const allocator = std.testing.allocator;
    const go_data = try readTestFile(allocator, "tests/corpus/src/api/server.go");
    defer allocator.free(go_data);

    const pkg_pos = literal.findFirst(go_data, "package");
    try std.testing.expect(pkg_pos != null);
    try std.testing.expectEqual(@as(usize, 0), pkg_pos.?);

    const health_pos = literal.findFirst(go_data, "handleHealth");
    try std.testing.expect(health_pos != null);
    try std.testing.expect(health_pos.? > 100);
}

test "search across all file types in corpus" {
    const allocator = std.testing.allocator;

    const paths = [_][]const u8{
        "tests/corpus/src/api/server.go",
        "tests/corpus/src/db/connection.py",
        "tests/corpus/src/auth/jwt.ts",
        "tests/corpus/src/db/migrations.sql",
        "tests/corpus/src/utils/helpers.rs",
        "tests/corpus/src/utils/trigram.zig",
        "tests/corpus/frontend/styles/search.css",
        "tests/corpus/docs/architecture.md",
        "tests/corpus/scripts/benchmark.sh",
        "tests/corpus/theme/layout/theme.liquid",
        "tests/corpus/theme/templates/product.liquid",
        "tests/corpus/theme/sections/header.liquid",
        "tests/corpus/theme/snippets/product-card.liquid",
        "tests/corpus/theme/assets/theme.js",
    };

    for (paths) |path| {
        const data = try readTestFile(allocator, path);
        defer allocator.free(data);
        try std.testing.expect(
            literal.contains(data, "TODO") or literal.contains(data, "FIXME"),
        );
    }
}

// ── Shopify Liquid Integration Tests ─────────────────────────────────

test "search Liquid template tags and objects" {
    const allocator = std.testing.allocator;
    const data = try readTestFile(allocator, "tests/corpus/theme/templates/product.liquid");
    defer allocator.free(data);

    // Liquid object syntax {{ }}
    try std.testing.expect(literal.contains(data, "{{ product.title"));
    try std.testing.expect(literal.contains(data, "{{ product.vendor"));
    try std.testing.expect(literal.contains(data, "{{ current_variant.price | money }}"));

    // Liquid tag syntax {% %}
    try std.testing.expect(literal.contains(data, "{%- if product."));
    try std.testing.expect(literal.contains(data, "{%- endfor -%}"));
    try std.testing.expect(literal.contains(data, "{%- render '"));
    try std.testing.expect(literal.contains(data, "{%- form 'product'"));

    // Schema / JSON-LD
    try std.testing.expect(literal.contains(data, "@context"));
    try std.testing.expect(literal.contains(data, "schema.org"));
}

test "search Liquid filters and pipes" {
    const allocator = std.testing.allocator;
    const data = try readTestFile(allocator, "tests/corpus/theme/layout/theme.liquid");
    defer allocator.free(data);

    // Liquid filters with pipe syntax
    try std.testing.expect(literal.contains(data, "| asset_url | stylesheet_tag"));
    try std.testing.expect(literal.contains(data, "| escape"));
    try std.testing.expect(literal.contains(data, "| font_modify:"));
    try std.testing.expect(literal.contains(data, "| join: ', '"));

    // Liquid comment blocks
    try std.testing.expect(literal.contains(data, "{%- comment -%}"));
    try std.testing.expect(literal.contains(data, "{%- endcomment -%}"));

    // Liquid liquid tag (multi-line)
    try std.testing.expect(literal.contains(data, "{%- liquid"));
}

test "search Liquid section schema JSON" {
    const allocator = std.testing.allocator;
    const data = try readTestFile(allocator, "tests/corpus/theme/sections/header.liquid");
    defer allocator.free(data);

    // Schema block inside Liquid template
    try std.testing.expect(literal.contains(data, "{% schema %}"));
    try std.testing.expect(literal.contains(data, "{% endschema %}"));
    try std.testing.expect(literal.contains(data, "\"image_picker\""));
    try std.testing.expect(literal.contains(data, "\"link_list\""));
    try std.testing.expect(literal.contains(data, "main-menu"));
}

test "search Liquid snippet render calls" {
    const allocator = std.testing.allocator;
    const data = try readTestFile(allocator, "tests/corpus/theme/snippets/product-card.liquid");
    defer allocator.free(data);

    // Snippet parameters
    try std.testing.expect(literal.contains(data, "product: product"));
    try std.testing.expect(literal.contains(data, "show_vendor: true"));
    try std.testing.expect(literal.contains(data, "| image_url: width: 600"));

    // Shopify-specific objects
    try std.testing.expect(literal.contains(data, "product.featured_image"));
    try std.testing.expect(literal.contains(data, "product.metafields.reviews"));
    try std.testing.expect(literal.contains(data, "forloop.index"));
    try std.testing.expect(literal.contains(data, "product.options_by_name"));
}

test "case-insensitive search in Liquid files" {
    const allocator = std.testing.allocator;
    const data = try readTestFile(allocator, "tests/corpus/theme/templates/product.liquid");
    defer allocator.free(data);

    // Case-insensitive Liquid keywords
    try std.testing.expect(literal.containsCaseInsensitive(data, "fitfoods"));
    try std.testing.expect(literal.containsCaseInsensitive(data, "PRODUCT"));
    try std.testing.expect(literal.containsCaseInsensitive(data, "json-ld"));
    try std.testing.expect(literal.containsCaseInsensitive(data, "NUTRITION"));
}

test "walker discovers Liquid theme files" {
    const allocator = std.testing.allocator;
    var w = walker_mod.DirWalker.init(allocator, "tests/corpus/theme", null);
    defer w.deinit();

    var liquid_count: usize = 0;
    var json_count: usize = 0;
    var js_count: usize = 0;

    while (try w.next()) |path| {
        defer allocator.free(path);
        if (std.mem.endsWith(u8, path, ".liquid")) liquid_count += 1;
        if (std.mem.endsWith(u8, path, ".json")) json_count += 1;
        if (std.mem.endsWith(u8, path, ".js")) js_count += 1;
    }

    // 6 Liquid files: theme.liquid, product.liquid, collection.liquid,
    // header.liquid, featured-collection.liquid, product-card.liquid, price.liquid
    try std.testing.expect(liquid_count >= 6);
    try std.testing.expect(json_count >= 2); // settings_schema.json, en.default.json
    try std.testing.expect(js_count >= 1); // theme.js
}
