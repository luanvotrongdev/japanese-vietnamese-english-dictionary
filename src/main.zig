const std = @import("std");
const Db = @import("db.zig").Db;
const crawl = @import("crawl.zig");
const crawler = @import("crawler.zig");
const forms = @import("forms.zig");
const jmdict = @import("jmdict.zig");
const kanji = @import("kanji.zig");
const kobo = @import("kobo.zig");
const tags = @import("tags.zig");
const words = @import("words.zig");
const yomitan = @import("yomitan.zig");

const usage =
    \\Usage:
    \\  javi-transform jmdict <cache.sqlite> [options]         import JMdict headwords into the cache (creates it if missing)
    \\  javi-transform build <input.sqlite> <output.sqlite>   build the standardized database
    \\  javi-transform check <input.sqlite>                    parse every crawl JSON blob, report failures
    \\  javi-transform crawl <cache.sqlite> [options]          fetch Mazii/Jisho data for uncrawled entries and kanji
    \\  javi-transform kobo <javi.sqlite> <dicthtml-ja.zip>     export a Kobo dictionary from the built database
    \\  javi-transform yomitan <javi.sqlite> <lulujv.zip>       export a Yomitan dictionary from the built database
    \\
    \\jmdict options:
    \\  --file PATH        import a local JMdict file (.gz or .xml) instead of downloading
    \\  --url URL          download from URL (default: JMdict_e_examp.gz from ftp.edrdg.org)
    \\  --prune            delete entries no longer in JMdict, with their crawl rows
    \\
    \\crawl options:
    \\  --dry-run          only count what is uncrawled
    \\  --limit N          stop after N new rows
    \\  --min-sleep MS     shortest pause before each item (default 500)
    \\  --max-sleep MS     longest pause before each item (default 1500)
    \\
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const cmd = if (args.len > 1) args[1] else "";

    if (std.mem.eql(u8, cmd, "build") and args.len == 4) {
        try build(init.io, init.gpa, args[2], args[3]);
    } else if (std.mem.eql(u8, cmd, "check") and args.len == 3) {
        try check(init.gpa, args[2]);
    } else if (std.mem.eql(u8, cmd, "crawl") and args.len >= 3) {
        const options = parseCrawlOptions(args[3..]) orelse usageExit();
        try crawlCache(init.io, init.gpa, args[2], options);
    } else if (std.mem.eql(u8, cmd, "jmdict") and args.len >= 3) {
        const options = parseJmdictOptions(args[3..]) orelse usageExit();
        const db = try Db.open(args[2], .read_write_create);
        defer db.close();
        const stats = try jmdict.run(init.io, init.gpa, db, options);
        std.log.info("jmdict: {d} entries, {d} added, {d} changed, {d} no longer in JMdict ({d} deleted)", .{
            stats.entries, stats.added, stats.changed, stats.missing, stats.pruned,
        });
        if (stats.missing > stats.pruned) std.log.info("rerun with --prune to delete the entries no longer in JMdict", .{});
    } else if (std.mem.eql(u8, cmd, "kobo") and args.len == 4) {
        const stats = try exportZip(kobo, init.io, init.gpa, args[2], args[3]);
        std.log.info("kobo: {d} words, {d} kanji, {d} lookup keys in {d} shards", .{
            stats.words, stats.kanji, stats.keys, stats.shards,
        });
    } else if (std.mem.eql(u8, cmd, "yomitan") and args.len == 4) {
        const stats = try exportZip(yomitan, init.io, init.gpa, args[2], args[3]);
        std.log.info("yomitan: {d} words as {d} terms, {d} pitch accents, {d} kanji", .{
            stats.words, stats.terms, stats.pitches, stats.kanji,
        });
    } else usageExit();
}

fn usageExit() noreturn {
    std.debug.print(usage, .{});
    std.process.exit(2);
}

fn parseJmdictOptions(args: []const [:0]const u8) ?jmdict.Options {
    var options: jmdict.Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--prune")) {
            options.prune = true;
            continue;
        }
        i += 1;
        if (i == args.len) return null;
        if (std.mem.eql(u8, arg, "--file")) {
            options.file = args[i];
        } else if (std.mem.eql(u8, arg, "--url")) {
            options.url = args[i];
        } else return null;
    }
    return options;
}

fn parseCrawlOptions(args: []const [:0]const u8) ?crawler.Options {
    var options: crawler.Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            options.dry_run = true;
            continue;
        }
        i += 1;
        if (i == args.len) return null;
        const value = std.fmt.parseInt(u32, args[i], 10) catch return null;
        if (std.mem.eql(u8, arg, "--limit")) {
            options.limit = value;
        } else if (std.mem.eql(u8, arg, "--min-sleep")) {
            options.min_sleep_ms = value;
        } else if (std.mem.eql(u8, arg, "--max-sleep")) {
            options.max_sleep_ms = value;
        } else return null;
    }
    if (options.max_sleep_ms < options.min_sleep_ms) options.max_sleep_ms = options.min_sleep_ms;
    return options;
}

/// The one command that writes to the cache: it only inserts rows for entries
/// and kanji that have none.
fn crawlCache(io: std.Io, gpa: std.mem.Allocator, cache_path: [:0]const u8, options: crawler.Options) !void {
    const db = try Db.open(cache_path, if (options.dry_run) .read_only else .read_write);
    defer db.close();
    const stats = try crawler.run(io, gpa, db, options);
    if (!options.dry_run) std.log.info("crawled {d} of {d} kanji, {d} of {d} entries", .{
        stats.kanji_crawled, stats.kanji_missing, stats.words_crawled, stats.words_missing,
    });
}

/// Runs an exporter (kobo.zig or yomitan.zig) on the built database and
/// writes its ZIP to `output_path`.
fn exportZip(comptime exporter: type, io: std.Io, gpa: std.mem.Allocator, input_path: [:0]const u8, output_path: []const u8) !exporter.Stats {
    const db = try Db.open(input_path, .read_only);
    defer db.close();
    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    // Leave no partial dictionary behind when the export fails.
    errdefer std.Io.Dir.cwd().deleteFile(io, output_path) catch {};
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const stats = exporter.write(gpa, db, &file_writer.interface) catch |err| {
        if (err == error.NoWords) std.log.err("{s} has no words with meanings: crawl the cache (`crawl`), then rerun `build`", .{input_path});
        return err;
    };
    try file_writer.interface.flush();
    return stats;
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
    const kanji_stats = try kanji.transform(gpa, src, out);
    std.log.info("kanji rows: {d}, with Jisho: {d}, with Mazii: {d}, examples: {d} ({d} linked to an entry)", .{
        kanji_stats.rows, kanji_stats.with_jisho, kanji_stats.with_mazii, kanji_stats.examples, kanji_stats.examples_linked,
    });
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
    _ = @import("crawler.zig");
    _ = @import("tags.zig");
    _ = @import("lang.zig");
    _ = @import("words.zig");
    _ = @import("kanji.zig");
    _ = @import("jmdict.zig");
    _ = @import("marisa.zig");
    _ = @import("zip.zig");
    _ = @import("entries.zig");
    _ = @import("kobo.zig");
    _ = @import("yomitan.zig");
    _ = @import("text.zig");
}
