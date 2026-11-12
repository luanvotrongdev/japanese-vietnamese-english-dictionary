//! JMdict import (`jmdict` command): downloads JMdict, or reads a local copy,
//! and fills the cache's `entry`, `k_ele` and `r_ele` tables. Creates the
//! cache, with every table the crawler and transform use, when it doesn't
//! exist. Port of the old Bun project's downloader.ts and jmdict_process.ts.
//!
//! Like the old importer it keeps only each entry's `ent_seq`, spellings
//! (`keb`) and readings (`reb`); meanings come from the crawl. It also stores
//! `re_nokanji` (readings that are not true readings of the kanji), which the
//! old importer dropped.
//!
//! Unlike the old importer, which deleted every entry and inserted them again,
//! entries are matched by `ent_seq`. An existing entry keeps its `entry.id`,
//! so its crawl rows (`raw_word_crawl_json.entry_id`) stay attached, and its
//! forms are rewritten only when they changed. Entries no longer in JMdict are
//! reported, and deleted with their crawl rows only when `prune` is set.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("db.zig").Db;

pub const default_url = "http://ftp.edrdg.org/pub/Nihongo/JMdict_e_examp.gz";

/// The cache schema, as the old project's Drizzle migration created it.
pub const cache_schema =
    \\CREATE TABLE IF NOT EXISTS `entry` (
    \\  `id` integer PRIMARY KEY NOT NULL,
    \\  `ent_seq` integer NOT NULL
    \\);
    \\CREATE UNIQUE INDEX IF NOT EXISTS `entry_ent_seq_unique` ON `entry` (`ent_seq`);
    \\CREATE TABLE IF NOT EXISTS `k_ele` (
    \\  `id` integer PRIMARY KEY NOT NULL,
    \\  `entry_id` integer NOT NULL,
    \\  `keb` text NOT NULL,
    \\  `position` integer NOT NULL,
    \\  FOREIGN KEY (`entry_id`) REFERENCES `entry`(`id`) ON UPDATE no action ON DELETE cascade
    \\);
    \\CREATE TABLE IF NOT EXISTS `r_ele` (
    \\  `id` integer PRIMARY KEY NOT NULL,
    \\  `entry_id` integer NOT NULL,
    \\  `reb` text NOT NULL,
    \\  `re_nokanji` text,
    \\  `position` integer NOT NULL,
    \\  FOREIGN KEY (`entry_id`) REFERENCES `entry`(`id`) ON UPDATE no action ON DELETE cascade
    \\);
    \\CREATE TABLE IF NOT EXISTS `raw_word_crawl_json` (
    \\  `id` integer PRIMARY KEY NOT NULL,
    \\  `entry_id` integer NOT NULL,
    \\  `json` text NOT NULL,
    \\  FOREIGN KEY (`entry_id`) REFERENCES `entry`(`id`) ON UPDATE no action ON DELETE cascade
    \\);
    \\CREATE TABLE IF NOT EXISTS `raw_kanji_crawl_json` (
    \\  `id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
    \\  `textId` text,
    \\  `json` text NOT NULL
    \\);
    \\CREATE UNIQUE INDEX IF NOT EXISTS `raw_kanji_crawl_json_textId_unique` ON `raw_kanji_crawl_json` (`textId`);
;

pub const Options = struct {
    /// Local JMdict file (.gz or .xml) instead of downloading.
    file: ?[]const u8 = null,
    url: []const u8 = default_url,
    /// Delete entries that are no longer in JMdict, with their crawl rows.
    prune: bool = false,
};

pub const Stats = struct {
    entries: usize = 0,
    added: usize = 0,
    changed: usize = 0,
    /// Entries in the cache but not in this JMdict.
    missing: usize = 0,
    pruned: usize = 0,
};

/// One JMdict entry: only the parts the cache stores. Slices point into the
/// XML buffer, or into `arena` when an entity had to be decoded.
pub const Entry = struct {
    ent_seq: i64,
    kanji: []const []const u8,
    readings: []const Reading,

    pub const Reading = struct {
        text: []const u8,
        no_kanji: bool,
    };
};

pub fn run(io: std.Io, gpa: Allocator, db: Db, options: Options) !Stats {
    const raw = if (options.file) |path|
        try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 31))
    else
        try download(io, gpa, options.url);
    defer gpa.free(raw);

    const xml = if (raw.len >= 2 and raw[0] == 0x1f and raw[1] == 0x8b) try gunzip(gpa, raw) else raw;
    defer if (xml.ptr != raw.ptr) gpa.free(xml);
    std.log.info("JMdict: {d} MB of XML", .{xml.len / (1 << 20)});

    try db.exec(cache_schema);
    try db.exec("BEGIN");
    errdefer db.exec("ROLLBACK") catch {};
    const stats = try importXml(gpa, db, xml, options.prune);
    try db.exec("COMMIT");
    return stats;
}

fn download(io: std.Io, gpa: Allocator, url: []const u8) ![]u8 {
    std.log.info("downloading {s}", .{url});
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(gpa);
    errdefer body.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    });
    if (result.status != .ok) {
        std.log.err("{s}: HTTP {d}", .{ url, @intFromEnum(result.status) });
        return error.HttpStatus;
    }
    return body.toOwnedSlice();
}

fn gunzip(gpa: Allocator, data: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(data);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var d: std.compress.flate.Decompress = .init(&in, .gzip, window);
    return d.reader.allocRemaining(gpa, .unlimited);
}

/// Imports every `<entry>` of a JMdict XML document. Runs inside the caller's
/// transaction.
///
/// `k_ele`, `r_ele` and `raw_word_crawl_json` have no index on `entry_id`, so
/// the existing entries and forms are read once up front, rows are deleted
/// by primary key, and pruning deletes through a temp table in one pass per
/// table. The cache's schema is left as it is.
pub fn importXml(gpa: Allocator, db: Db, xml: []const u8, prune: bool) !Stats {
    var existing = try Existing.load(gpa, db);
    defer existing.deinit();

    const insert_entry = try db.prepare("INSERT INTO entry (ent_seq) VALUES (?)");
    defer insert_entry.deinit();
    const delete_kanji = try db.prepare("DELETE FROM k_ele WHERE id = ?");
    defer delete_kanji.deinit();
    const delete_reading = try db.prepare("DELETE FROM r_ele WHERE id = ?");
    defer delete_reading.deinit();
    const insert_kanji = try db.prepare("INSERT INTO k_ele (entry_id, keb, position) VALUES (?, ?, ?)");
    defer insert_kanji.deinit();
    const insert_reading = try db.prepare("INSERT INTO r_ele (entry_id, reb, re_nokanji, position) VALUES (?, ?, ?, ?)");
    defer insert_reading.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var stats: Stats = .{};
    var seen: std.AutoHashMapUnmanaged(i64, void) = .empty;
    defer seen.deinit(gpa);

    var entries: EntryIterator = try .init(xml);
    while (true) {
        defer _ = arena.reset(.retain_capacity);
        const e = try entries.next(arena.allocator()) orelse break;
        stats.entries += 1;
        try seen.put(gpa, e.ent_seq, {});

        var entry_id: i64 = undefined;
        if (existing.entry_ids.get(e.ent_seq)) |id| {
            entry_id = id;
            const forms = existing.forms.get(id) orelse Forms{};
            if (forms.equals(e)) continue;
            for (forms.kanji.items) |row| try delete_kanji.run(.{row.id});
            for (forms.readings.items) |row| try delete_reading.run(.{row.id});
            stats.changed += 1;
        } else {
            try insert_entry.run(.{e.ent_seq});
            entry_id = db.lastInsertRowId();
            stats.added += 1;
        }
        for (e.kanji, 0..) |keb, i| try insert_kanji.run(.{ entry_id, keb, i });
        for (e.readings, 0..) |r, i| {
            try insert_reading.run(.{ entry_id, r.text, if (r.no_kanji) @as(?[]const u8, "1") else null, i });
        }
    }
    if (stats.entries == 0) return error.NoEntries;

    // Entries this JMdict no longer has.
    var missing: std.ArrayList(i64) = .empty;
    defer missing.deinit(gpa);
    var it = existing.entry_ids.iterator();
    while (it.next()) |kv| {
        if (!seen.contains(kv.key_ptr.*)) try missing.append(gpa, kv.value_ptr.*);
    }
    stats.missing = missing.items.len;
    if (prune and missing.items.len > 0) {
        try db.exec("CREATE TEMP TABLE prune (id INTEGER PRIMARY KEY)");
        defer db.exec("DROP TABLE temp.prune") catch {};
        const add = try db.prepare("INSERT INTO temp.prune (id) VALUES (?)");
        defer add.deinit();
        for (missing.items) |id| try add.run(.{id});
        try db.exec(
            \\DELETE FROM raw_word_crawl_json WHERE entry_id IN (SELECT id FROM temp.prune);
            \\DELETE FROM k_ele WHERE entry_id IN (SELECT id FROM temp.prune);
            \\DELETE FROM r_ele WHERE entry_id IN (SELECT id FROM temp.prune);
            \\DELETE FROM entry WHERE id IN (SELECT id FROM temp.prune);
        );
        stats.pruned = missing.items.len;
    }
    return stats;
}

const Row = struct {
    id: i64,
    text: []const u8,
    no_kanji: bool = false,
};

/// One cached entry's stored spellings and readings, in position order.
const Forms = struct {
    kanji: std.ArrayList(Row) = .empty,
    readings: std.ArrayList(Row) = .empty,

    fn equals(f: Forms, e: Entry) bool {
        if (f.kanji.items.len != e.kanji.len or f.readings.items.len != e.readings.len) return false;
        for (f.kanji.items, e.kanji) |row, keb| {
            if (!std.mem.eql(u8, row.text, keb)) return false;
        }
        for (f.readings.items, e.readings) |row, r| {
            if (!std.mem.eql(u8, row.text, r.text) or row.no_kanji != r.no_kanji) return false;
        }
        return true;
    }
};

/// The cache's entries and forms before the import.
const Existing = struct {
    arena: std.heap.ArenaAllocator,
    /// ent_seq -> entry.id
    entry_ids: std.AutoHashMapUnmanaged(i64, i64) = .empty,
    /// entry.id -> forms
    forms: std.AutoHashMapUnmanaged(i64, Forms) = .empty,

    fn load(gpa: Allocator, db: Db) !Existing {
        var ex: Existing = .{ .arena = .init(gpa) };
        errdefer ex.deinit();
        const a = ex.arena.allocator();

        const entries = try db.prepare("SELECT id, ent_seq FROM entry");
        defer entries.deinit();
        while (try entries.step()) try ex.entry_ids.put(a, entries.int(1), entries.int(0));

        const kanji = try db.prepare("SELECT id, entry_id, keb FROM k_ele ORDER BY entry_id, position");
        defer kanji.deinit();
        while (try kanji.step()) {
            const f = try ex.formsOf(kanji.int(1));
            try f.kanji.append(a, .{ .id = kanji.int(0), .text = try a.dupe(u8, kanji.text(2).?) });
        }

        const readings = try db.prepare("SELECT id, entry_id, reb, re_nokanji IS NOT NULL FROM r_ele ORDER BY entry_id, position");
        defer readings.deinit();
        while (try readings.step()) {
            const f = try ex.formsOf(readings.int(1));
            try f.readings.append(a, .{
                .id = readings.int(0),
                .text = try a.dupe(u8, readings.text(2).?),
                .no_kanji = readings.int(3) != 0,
            });
        }
        return ex;
    }

    fn formsOf(ex: *Existing, entry_id: i64) !*Forms {
        const slot = try ex.forms.getOrPut(ex.arena.allocator(), entry_id);
        if (!slot.found_existing) slot.value_ptr.* = .{};
        return slot.value_ptr;
    }

    fn deinit(ex: *Existing) void {
        ex.arena.deinit();
    }
};

// ---------------------------------------------------------------- XML

/// Walks the `<entry>` elements of a JMdict document. JMdict's layout is
/// regular (one element per line, no attributes on these elements, no
/// comments inside entries), so plain searching is enough; the DTD in the
/// DOCTYPE is skipped by starting at the `<JMdict>` root element.
pub const EntryIterator = struct {
    xml: []const u8,
    pos: usize,

    pub fn init(xml: []const u8) !EntryIterator {
        const root = std.mem.indexOf(u8, xml, "<JMdict>") orelse return error.NotJMdict;
        return .{ .xml = xml, .pos = root };
    }

    pub fn next(it: *EntryIterator, a: Allocator) !?Entry {
        const start = std.mem.indexOfPos(u8, it.xml, it.pos, "<entry>") orelse return null;
        const end = std.mem.indexOfPos(u8, it.xml, start, "</entry>") orelse return error.UnclosedEntry;
        it.pos = end + "</entry>".len;
        const body = it.xml[start..end];

        const seq_text = elementText(body, "ent_seq") orelse return error.MissingEntSeq;
        const ent_seq = std.fmt.parseInt(i64, std.mem.trim(u8, seq_text, " \t\r\n"), 10) catch return error.BadEntSeq;

        var kanji: std.ArrayList([]const u8) = .empty;
        var k_elements = Elements{ .body = body, .name = "k_ele" };
        while (k_elements.next()) |k| {
            const keb = elementText(k, "keb") orelse continue;
            try kanji.append(a, try decode(a, keb));
        }

        var readings: std.ArrayList(Entry.Reading) = .empty;
        var r_elements = Elements{ .body = body, .name = "r_ele" };
        while (r_elements.next()) |r| {
            const reb = elementText(r, "reb") orelse continue;
            try readings.append(a, .{
                .text = try decode(a, reb),
                .no_kanji = std.mem.indexOf(u8, r, "<re_nokanji") != null,
            });
        }
        return .{ .ent_seq = ent_seq, .kanji = kanji.items, .readings = readings.items };
    }
};

/// Iterates the contents of each `<name>…</name>` element in `body`.
const Elements = struct {
    body: []const u8,
    name: []const u8,
    pos: usize = 0,

    fn next(e: *Elements) ?[]const u8 {
        var open_buf: [32]u8 = undefined;
        var close_buf: [32]u8 = undefined;
        const open = std.fmt.bufPrint(&open_buf, "<{s}>", .{e.name}) catch return null;
        const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{e.name}) catch return null;
        const start = std.mem.indexOfPos(u8, e.body, e.pos, open) orelse return null;
        const end = std.mem.indexOfPos(u8, e.body, start, close) orelse return null;
        e.pos = end + close.len;
        return e.body[start + open.len .. end];
    }
};

/// Text of the first `<name>…</name>` in `body`.
fn elementText(body: []const u8, name: []const u8) ?[]const u8 {
    var it = Elements{ .body = body, .name = name };
    return it.next();
}

/// Decodes XML's predefined entities and character references.
fn decode(a: Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '&') == null) return text;
    var out: std.ArrayList(u8) = try .initCapacity(a, text.len);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            if (std.mem.indexOfScalarPos(u8, text, i, ';')) |semi| {
                const name = text[i + 1 .. semi];
                const named: ?[]const u8 = if (std.mem.eql(u8, name, "amp")) "&" else if (std.mem.eql(u8, name, "lt")) "<" else if (std.mem.eql(u8, name, "gt")) ">" else if (std.mem.eql(u8, name, "quot")) "\"" else if (std.mem.eql(u8, name, "apos")) "'" else null;
                if (named) |s| {
                    try out.appendSlice(a, s);
                    i = semi + 1;
                    continue;
                }
                if (name.len > 1 and name[0] == '#') {
                    const hex = name[1] == 'x';
                    if (std.fmt.parseInt(u21, name[if (hex) 2 else 1..], if (hex) 16 else 10)) |c| {
                        var buf: [4]u8 = undefined;
                        if (std.unicode.utf8Encode(c, &buf)) |n| {
                            try out.appendSlice(a, buf[0..n]);
                            i = semi + 1;
                            continue;
                        } else |_| {}
                    } else |_| {}
                }
            }
        }
        try out.append(a, text[i]);
        i += 1;
    }
    return out.items;
}

// ---------------------------------------------------------------- tests

const sample_xml =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE JMdict [
    \\<!ELEMENT JMdict (entry*)>
    \\<!-- an <entry> mentioned in a comment -->
    \\<!ENTITY n "noun (common) (futsuumeishi)">
    \\]>
    \\<JMdict>
    \\<entry>
    \\<ent_seq>1358280</ent_seq>
    \\<k_ele>
    \\<keb>食べる</keb>
    \\<ke_pri>ichi1</ke_pri>
    \\</k_ele>
    \\<k_ele>
    \\<keb>喰べる</keb>
    \\<ke_inf>&iK;</ke_inf>
    \\</k_ele>
    \\<r_ele>
    \\<reb>たべる</reb>
    \\</r_ele>
    \\<sense>
    \\<pos>&v1;</pos>
    \\<gloss>to eat</gloss>
    \\</sense>
    \\</entry>
    \\<entry>
    \\<ent_seq>1000000</ent_seq>
    \\<r_ele>
    \\<reb>ヽ</reb>
    \\</r_ele>
    \\<r_ele>
    \\<reb>くりかえし</reb>
    \\<re_nokanji/>
    \\</r_ele>
    \\</entry>
    \\<entry>
    \\<ent_seq>2000000</ent_seq>
    \\<k_ele>
    \\<keb>Ｒ＆Ｂ&amp;C</keb>
    \\</k_ele>
    \\<r_ele>
    \\<reb>アールアンドビー</reb>
    \\</r_ele>
    \\</entry>
    \\</JMdict>
;

test "parses JMdict entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = std.testing;
    var it: EntryIterator = try .init(sample_xml);

    const taberu = (try it.next(a)).?;
    try t.expectEqual(1358280, taberu.ent_seq);
    try t.expectEqual(2, taberu.kanji.len);
    try t.expectEqualStrings("喰べる", taberu.kanji[1]);
    try t.expectEqualStrings("たべる", taberu.readings[0].text);
    try t.expect(!taberu.readings[0].no_kanji);

    const kurikaeshi = (try it.next(a)).?;
    try t.expectEqual(0, kurikaeshi.kanji.len);
    try t.expect(kurikaeshi.readings[1].no_kanji);

    const rb = (try it.next(a)).?;
    try t.expectEqualStrings("Ｒ＆Ｂ&C", rb.kanji[0]);
    try t.expectEqual(null, try it.next(a));
}

fn count(db: Db, sql: []const u8) !i64 {
    const s = try db.prepare(sql);
    defer s.deinit();
    _ = try s.step();
    return s.int(0);
}

test "imports JMdict into the cache, keeping entry ids" {
    const gpa = std.testing.allocator;
    const t = std.testing;
    const db = try Db.open(":memory:", .read_write_create);
    defer db.close();
    try db.exec(cache_schema);

    // An existing cache: 食べる with a crawl row and an outdated reading, and an
    // entry JMdict has since dropped.
    try db.exec(
        \\INSERT INTO entry (id, ent_seq) VALUES (7, 1358280), (8, 3000000);
        \\INSERT INTO k_ele (entry_id, keb, position) VALUES (7, '食べる', 0);
        \\INSERT INTO r_ele (entry_id, reb, position) VALUES (7, 'たべるう', 0), (8, 'ふるい', 0);
        \\INSERT INTO raw_word_crawl_json (entry_id, json) VALUES (7, '{}'), (8, '{}');
    );

    var stats = try importXml(gpa, db, sample_xml, false);
    try t.expectEqual(3, stats.entries);
    try t.expectEqual(2, stats.added);
    try t.expectEqual(1, stats.changed);
    try t.expectEqual(1, stats.missing);
    try t.expectEqual(7, try count(db, "SELECT id FROM entry WHERE ent_seq = 1358280"));
    try t.expectEqual(2, try count(db, "SELECT count(*) FROM k_ele WHERE entry_id = 7"));
    try t.expectEqual(1, try count(db, "SELECT count(*) FROM r_ele WHERE entry_id = 7 AND reb = 'たべる'"));
    try t.expectEqual(1, try count(db, "SELECT count(*) FROM r_ele WHERE re_nokanji IS NOT NULL"));
    try t.expectEqual(2, try count(db, "SELECT count(*) FROM raw_word_crawl_json"));

    // A second run changes nothing; pruning drops the stale entry and its crawl row.
    stats = try importXml(gpa, db, sample_xml, true);
    try t.expectEqual(0, stats.added);
    try t.expectEqual(0, stats.changed);
    try t.expectEqual(1, stats.pruned);
    try t.expectEqual(3, try count(db, "SELECT count(*) FROM entry"));
    try t.expectEqual(1, try count(db, "SELECT count(*) FROM raw_word_crawl_json"));
    try t.expectEqual(0, try count(db, "SELECT count(*) FROM r_ele WHERE entry_id = 8"));
}

test "gunzip" {
    const gpa = std.testing.allocator;
    const zip = @import("zip.zig");
    const gz = try zip.compress(gpa, sample_xml, .gzip);
    defer gpa.free(gz);
    const back = try gunzip(gpa, gz);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(sample_xml, back);
}
