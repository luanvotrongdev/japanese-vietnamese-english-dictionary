const std = @import("std");
const Db = @import("db.zig").Db;
const crawl = @import("crawl.zig");
const forms = @import("forms.zig");
const tags = @import("tags.zig");
const words = @import("words.zig");

const usage =
    \\Usage:
    \\  javi-transform build <input.sqlite> <output.sqlite>   build the standardized database
    \\  javi-transform check <input.sqlite>                    parse every crawl JSON blob, report failures
    \\
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const cmd = if (args.len > 1) args[1] else "";

    if (std.mem.eql(u8, cmd, "build") and args.len == 4) {
        try build(init.io, init.gpa, args[2], args[3]);
    } else if (std.mem.eql(u8, cmd, "check") and args.len == 3) {
        try check(init.gpa, args[2]);
    } else {
        std.debug.print(usage, .{});
        std.process.exit(2);
    }
}

fn build(io: std.Io, gpa: std.mem.Allocator, input_path: [:0]const u8, output_path: [:0]const u8) !void {
    // The output is rebuilt from scratch on every run.
    std.Io.Dir.cwd().deleteFile(io, output_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const src = try Db.open(input_path, .read_only);
    defer src.close();
    const out = try Db.open(output_path, .read_write_create);
    defer out.close();

    // Safe to skip durability: a failed run is simply rerun.
    try out.exec("PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF; PRAGMA foreign_keys = ON;");
    try out.exec(@embedFile("schema.sql"));

    try out.exec("BEGIN");
    try tags.seed(out);
    const counts = try forms.copy(src, out);
    std.log.info("entries: {d}, kanji forms: {d}, reading forms: {d}", .{
        counts.entries, counts.kanji_forms, counts.reading_forms,
    });
    const word_stats = try words.transform(gpa, src, out);
    std.log.info("word rows: {d}, matched Jisho: {d}, matched Mazii: {d}, Mazii skipped as homograph: {d}", .{
        word_stats.rows, word_stats.jisho_matched, word_stats.mazii_matched, word_stats.mazii_homographs_skipped,
    });
    // TODO: kanji tables from raw_kanji_crawl_json.
    try out.exec("COMMIT");
}

fn check(gpa: std.mem.Allocator, input_path: [:0]const u8) !void {
    const src = try Db.open(input_path, .read_only);
    defer src.close();

    const failed =
        try checkTable(crawl.WordBlob, gpa, src, "SELECT entry_id, json FROM raw_word_crawl_json") +
        try checkTable(crawl.KanjiBlob, gpa, src, "SELECT id, json FROM raw_kanji_crawl_json");
    if (failed > 0) return error.ParseFailures;
}

/// Parses column 1 of every row as `T`. Logs the first few failures with the
/// row id from column 0 and the byte offset, and returns the failure count.
fn checkTable(comptime T: type, gpa: std.mem.Allocator, src: Db, sql: []const u8) !usize {
    const stmt = try src.prepare(sql);
    defer stmt.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var ok: usize = 0;
    var failed: usize = 0;
    while (try stmt.step()) {
        defer _ = arena.reset(.retain_capacity);
        const json = stmt.text(1) orelse continue;

        var scanner = std.json.Scanner.initCompleteInput(arena.allocator(), json);
        var diag: std.json.Diagnostics = .{};
        scanner.enableDiagnostics(&diag);
        if (std.json.parseFromTokenSourceLeaky(T, arena.allocator(), &scanner, crawl.parse_options)) |_| {
            ok += 1;
        } else |err| {
            failed += 1;
            if (failed <= 10) std.log.err("{s} row {d}: {s} at byte {d}", .{
                @typeName(T), stmt.int(0), @errorName(err), diag.getByteOffset(),
            });
        }
    }
    std.log.info("{s}: {d} parsed, {d} failed", .{ @typeName(T), ok, failed });
    return failed;
}

test {
    _ = @import("db.zig");
    _ = @import("crawl.zig");
    _ = @import("tags.zig");
    _ = @import("lang.zig");
    _ = @import("words.zig");
}
