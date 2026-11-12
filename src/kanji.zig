//! Kanji transform: fills `radical`, `kanji`, `kanji_reading`, `kanji_meaning`,
//! `kanji_component` and `kanji_example` from `raw_kanji_crawl_json`. The rules
//! are in docs/schema.md ("Transform rules"). Runs after words.transform, so
//! example words can be linked to entries.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("db.zig").Db;
const Stmt = @import("db.zig").Stmt;
const crawl = @import("crawl.zig");
const words = @import("words.zig");

const Kanji = crawl.KanjiBlob;
const trim = words.trim;
const nonEmpty = words.nonEmpty;

pub const Stats = struct {
    rows: usize = 0,
    with_jisho: usize = 0,
    with_mazii: usize = 0,
    examples: usize = 0,
    /// Examples whose word and reading match exactly one entry.
    examples_linked: usize = 0,
};

pub fn transform(gpa: Allocator, src: Db, out: Db) !Stats {
    var ctx: Context = .{
        .st = try Statements.init(out),
        .arena = .init(gpa),
        .unmapped = .init(gpa),
    };
    defer ctx.deinit();

    const rows = try src.prepare("SELECT textId, json FROM raw_kanji_crawl_json WHERE textId IS NOT NULL ORDER BY id");
    defer rows.deinit();

    while (try rows.step()) {
        defer _ = ctx.arena.reset(.retain_capacity);
        const literal = nonEmpty(rows.text(0)) orelse continue;
        try ctx.row(literal, rows.text(1) orelse continue);
        ctx.stats.rows += 1;
    }
    ctx.unmapped.report();
    return ctx.stats;
}

const Statements = struct {
    insert_radical: Stmt,
    insert_kanji: Stmt,
    insert_reading: Stmt,
    insert_meaning: Stmt,
    insert_component: Stmt,
    insert_example: Stmt,
    find_by_kanji_and_reading: Stmt,
    find_kana_only: Stmt,

    const sql = .{
        // The first meaning seen for a radical wins; Jisho gives the same one everywhere.
        .insert_radical = "INSERT OR IGNORE INTO radical (symbol, meaning_en) VALUES (?, ?)",
        .insert_kanji =
        \\INSERT OR IGNORE INTO kanji (literal, stroke_count, grade, jlpt, freq_rank, han_viet, radical, mnemonic_vi, mazii_id)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ,
        .insert_reading = "INSERT INTO kanji_reading (literal, type, position, text) VALUES (?, ?, ?, ?)",
        .insert_meaning = "INSERT INTO kanji_meaning (literal, lang, position, text) VALUES (?, ?, ?, ?)",
        .insert_component = "INSERT INTO kanji_component (literal, position, component, han_viet) VALUES (?, ?, ?, ?)",
        .insert_example =
        \\INSERT INTO kanji_example (literal, reading_type, word, reading, meaning, han_viet, lang, ent_seq)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ,
        // LIMIT 2 is enough to tell "exactly one entry" from "several".
        .find_by_kanji_and_reading =
        \\SELECT DISTINCT k.ent_seq FROM kanji_form k JOIN reading_form r ON r.ent_seq = k.ent_seq
        \\WHERE k.text = ? AND r.text = ? LIMIT 2
        ,
        .find_kana_only =
        \\SELECT DISTINCT r.ent_seq FROM reading_form r
        \\WHERE r.text = ? AND NOT EXISTS (SELECT 1 FROM kanji_form k WHERE k.ent_seq = r.ent_seq) LIMIT 2
        ,
    };

    fn init(db: Db) !Statements {
        var s: Statements = undefined;
        inline for (@typeInfo(Statements).@"struct".fields) |f| {
            @field(s, f.name) = try db.prepare(@field(sql, f.name));
        }
        return s;
    }

    fn deinit(s: Statements) void {
        inline for (@typeInfo(Statements).@"struct".fields) |f| @field(s, f.name).deinit();
    }
};

const Context = struct {
    st: Statements,
    /// Reset after every row.
    arena: std.heap.ArenaAllocator,
    unmapped: words.Unmapped,
    stats: Stats = .{},

    fn deinit(ctx: *Context) void {
        ctx.st.deinit();
        ctx.arena.deinit();
        ctx.unmapped.deinit();
    }

    fn row(ctx: *Context, literal: []const u8, json: []const u8) !void {
        const a = ctx.arena.allocator();
        const blob = try std.json.parseFromSliceLeaky(Kanji, a, json, crawl.parse_options);
        const mazii = pickMazii(blob.mazii, literal);
        const jisho: ?*const Kanji.Jisho = if (blob.jisho.found) &blob.jisho else null;
        if (mazii != null) ctx.stats.with_mazii += 1;
        if (jisho != null) ctx.stats.with_jisho += 1;

        // ---- kanji row (and its radical, which it references)
        var radical: ?[]const u8 = null;
        if (jisho) |j| if (j.radical) |r| {
            radical = nonEmpty(r.symbol);
            if (radical) |symbol| try ctx.st.insert_radical.run(.{ symbol, nonEmpty(r.meaning) });
        };

        const grade: ?i64 = if (jisho) |j| try ctx.parseGrade(j.taughtIn) else null;
        const jlpt = if (mazii) |m| parseMaziiLevel(m.level) else null;
        const stroke_count = if (jisho) |j| j.strokeCount else null;
        const freq_rank = if (jisho) |j| parseInt(j.newspaperFrequencyRank) else null;
        try ctx.st.insert_kanji.run(.{
            literal,
            stroke_count orelse if (mazii) |m| parseInt(m.stroke_count) else null,
            grade,
            jlpt orelse if (jisho) |j| parseJlpt(j.jlptLevel) else null,
            freq_rank orelse if (mazii) |m| m.freq else null,
            if (mazii) |m| nonEmpty(m.mean) else null,
            radical,
            if (mazii) |m| if (m.tips) |t| nonEmpty(try stripTags(a, t.vi)) else null else null,
            if (mazii) |m| m.mobileId else null,
        });

        // ---- readings: Jisho (KANJIDIC notation), else Mazii's space-separated lists
        inline for (.{ "on", "kun" }) |kind| {
            const jisho_list: []const []const u8 = if (jisho) |j| @field(j, kind ++ "yomi") else &.{};
            const readings = if (hasText(jisho_list))
                jisho_list
            else if (mazii) |m|
                try splitAny(a, @field(m, kind), " \t\u{3000}、,")
            else
                &.{};
            try ctx.addList(ctx.st.insert_reading, literal, kind, readings);
        }

        // ---- meanings
        if (mazii) |m| if (m.detail) |detail| {
            try ctx.addList(ctx.st.insert_meaning, literal, "vi", try splitSeq(a, try stripTags(a, detail), "##"));
        };
        if (jisho) |j| if (j.meaning) |meaning| {
            try ctx.addList(ctx.st.insert_meaning, literal, "en", try splitSeq(a, meaning, ", "));
        };

        // ---- components: Mazii's breakdown has Hán Việt names; Jisho parts otherwise
        var components: std.ArrayList(Kanji.Component) = .empty;
        if (mazii) |m| if (m.compDetail) |list| {
            for (list) |c| try components.append(a, .{ .w = c.w, .h = c.h });
        };
        if (components.items.len == 0) if (jisho) |j| {
            for (j.parts) |p| try components.append(a, .{ .w = p });
        };
        var next_component: i64 = 0;
        for (components.items, 0..) |c, i| {
            const text = nonEmpty(c.w) orelse continue;
            if (indexOfComponent(components.items[0..i], text) != null) continue;
            try ctx.st.insert_component.run(.{ literal, next_component, text, nonEmpty(c.h) });
            next_component += 1;
        }

        // ---- examples: Mazii general list, then Mazii by reading, then Jisho
        if (mazii) |m| {
            if (m.examples) |list| for (list) |e| {
                try ctx.addExample(literal, null, e.w, e.p, e.m, e.h, "vi");
            };
            inline for (.{ "on", "kun" }) |kind| {
                if (@field(m, "example_" ++ kind)) |by_reading| {
                    // {"vi": null} rows parse as a null list and are skipped.
                    for (by_reading.map.values()) |maybe_list| for (maybe_list orelse continue) |e| {
                        try ctx.addExample(literal, kind, e.w, e.p, e.m, null, "vi");
                    };
                }
            }
        }
        if (jisho) |j| {
            for (j.onyomiExamples) |e| try ctx.addExample(literal, "on", e.example, e.reading, e.meaning, null, "en");
            for (j.kunyomiExamples) |e| try ctx.addExample(literal, "kun", e.example, e.reading, e.meaning, null, "en");
        }
    }

    /// Inserts trimmed, non-empty, distinct texts with consecutive positions.
    fn addList(ctx: *Context, stmt: Stmt, literal: []const u8, kind: []const u8, list: []const []const u8) !void {
        _ = ctx;
        var position: i64 = 0;
        for (list, 0..) |raw, i| {
            const text = trim(raw);
            if (text.len == 0 or containsTrimmed(list[0..i], text)) continue;
            try stmt.run(.{ literal, kind, position, text });
            position += 1;
        }
    }

    fn addExample(
        ctx: *Context,
        literal: []const u8,
        reading_type: ?[]const u8,
        raw_word: []const u8,
        raw_reading: ?[]const u8,
        raw_meaning: ?[]const u8,
        han_viet: ?[]const u8,
        comptime lang: []const u8,
    ) !void {
        const word = nonEmpty(raw_word) orelse return;
        const meaning_trimmed = nonEmpty(raw_meaning) orelse return;
        // Mazii meanings often end in a stray period ("ngày ngày .").
        const meaning = if (comptime std.mem.eql(u8, lang, "vi")) words.dropFinalPeriod(meaning_trimmed) else meaning_trimmed;
        if (meaning.len == 0) return;
        const reading = nonEmpty(raw_reading);
        const ent_seq = if (reading) |r| try ctx.linkEntry(word, r) else null;
        try ctx.st.insert_example.run(.{ literal, reading_type, word, reading, meaning, nonEmpty(han_viet), lang, ent_seq });
        ctx.stats.examples += 1;
        if (ent_seq != null) ctx.stats.examples_linked += 1;
    }

    /// The one entry spelled `word` and read `reading`, else null. Jisho gives
    /// on'yomi example readings in katakana, so a katakana reading is retried
    /// in hiragana when it matches nothing as written.
    fn linkEntry(ctx: *Context, word: []const u8, reading: []const u8) !?i64 {
        const match = try ctx.findEntry(word, reading);
        if (match.count > 0) return match.unique();
        const hira = try toHiragana(ctx.arena.allocator(), reading);
        if (std.mem.eql(u8, hira, reading)) return null;
        return (try ctx.findEntry(if (std.mem.eql(u8, word, reading)) hira else word, hira)).unique();
    }

    fn findEntry(ctx: *Context, word: []const u8, reading: []const u8) !Match {
        if (std.mem.eql(u8, word, reading)) return Match.of(ctx.st.find_kana_only, .{reading});
        return Match.of(ctx.st.find_by_kanji_and_reading, .{ word, reading });
    }

    /// 'grade 4' -> 4, 'junior high' -> 8 (KANJIDIC's grades).
    fn parseGrade(ctx: *Context, taught_in: ?[]const u8) !?i64 {
        const text = nonEmpty(taught_in) orelse return null;
        if (std.mem.eql(u8, text, "junior high")) return 8;
        if (std.mem.startsWith(u8, text, "grade ")) {
            if (std.fmt.parseInt(i64, text["grade ".len..], 10)) |n| return n else |_| {}
        }
        try ctx.unmapped.add("kanji grade", text);
        return null;
    }
};

const Match = struct {
    count: usize,
    ent_seq: i64,

    fn of(stmt: Stmt, args: anytype) !Match {
        try stmt.bindAll(args);
        defer stmt.reset();
        var m: Match = .{ .count = 0, .ent_seq = 0 };
        while (try stmt.step()) {
            if (m.count == 0) m.ent_seq = stmt.int(0);
            m.count += 1;
        }
        return m;
    }

    fn unique(m: Match) ?i64 {
        return if (m.count == 1) m.ent_seq else null;
    }
};

/// The Mazii result for this character (rows hold zero or one).
fn pickMazii(list: []const Kanji.MaziiKanji, literal: []const u8) ?*const Kanji.MaziiKanji {
    for (list) |*m| {
        if (std.mem.eql(u8, trim(m.kanji), literal)) return m;
    }
    return null;
}

/// Mazii `level`: usually ["N2"], sometimes "" or null. Keeps the easiest level.
fn parseMaziiLevel(level: std.json.Value) ?i64 {
    switch (level) {
        .string => |s| return parseJlpt(s),
        .array => |list| {
            var best: ?i64 = null;
            for (list.items) |item| {
                if (item != .string) continue;
                const n = parseJlpt(item.string) orelse continue;
                if (best == null or n > best.?) best = n;
            }
            return best;
        },
        else => return null,
    }
}

/// 'N3' -> 3.
fn parseJlpt(level: ?[]const u8) ?i64 {
    const s = nonEmpty(level) orelse return null;
    if (s.len != 2 or (s[0] != 'N' and s[0] != 'n') or s[1] < '1' or s[1] > '5') return null;
    return s[1] - '0';
}

fn parseInt(s: ?[]const u8) ?i64 {
    const n = std.fmt.parseInt(i64, nonEmpty(s) orelse return null, 10) catch return null;
    return if (n > 0) n else null;
}

/// Mazii explanations and tips carry bits of HTML (`<b>`, `</ b>`); exporters
/// escape text, so tags are removed here.
fn stripTags(a: Allocator, s: ?[]const u8) ![]const u8 {
    const text = s orelse return "";
    if (std.mem.indexOfScalar(u8, text, '<') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '<') {
            if (std.mem.indexOfScalarPos(u8, text, i, '>')) |end| {
                i = end + 1;
                continue;
            }
        }
        try out.append(a, text[i]);
        i += 1;
    }
    return out.items;
}

fn splitSeq(a: Allocator, s: []const u8, sep: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitSequence(u8, s, sep);
    while (parts.next()) |p| try list.append(a, p);
    return list.items;
}

/// Splits on any of the UTF-8 separators in `seps` (which may be multi-byte).
fn splitAny(a: Allocator, s: ?[]const u8, comptime seps: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    const text = s orelse return list.items;
    var start: usize = 0;
    var i: usize = 0;
    outer: while (i < text.len) {
        inline for (comptime separatorList(seps)) |sep| {
            if (std.mem.startsWith(u8, text[i..], sep)) {
                if (i > start) try list.append(a, text[start..i]);
                i += sep.len;
                start = i;
                continue :outer;
            }
        }
        i += 1;
    }
    if (start < text.len) try list.append(a, text[start..]);
    return list.items;
}

fn separatorList(comptime seps: []const u8) []const []const u8 {
    comptime {
        var list: []const []const u8 = &.{};
        var view = std.unicode.Utf8View.initComptime(seps).iterator();
        while (view.nextCodepointSlice()) |cp| list = list ++ .{cp};
        return list;
    }
}

/// Katakana (U+30A1..U+30F6) to hiragana; everything else unchanged.
fn toHiragana(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var view = (std.unicode.Utf8View.init(s) catch return s).iterator();
    while (view.nextCodepoint()) |cp| {
        const mapped: u21 = if (cp >= 0x30A1 and cp <= 0x30F6) cp - 0x60 else cp;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(mapped, &buf) catch unreachable;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.items;
}

fn hasText(list: []const []const u8) bool {
    for (list) |s| {
        if (trim(s).len > 0) return true;
    }
    return false;
}

fn containsTrimmed(list: []const []const u8, text: []const u8) bool {
    for (list) |s| {
        if (std.mem.eql(u8, trim(s), text)) return true;
    }
    return false;
}

fn indexOfComponent(list: []const Kanji.Component, text: []const u8) ?usize {
    for (list, 0..) |c, i| {
        if (std.mem.eql(u8, trim(c.w), text)) return i;
    }
    return null;
}

// ---------------------------------------------------------------- tests

const queryInt = words.queryInt;

test "value parsers" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try t.expectEqual(3, parseJlpt("N3").?);
    try t.expectEqual(null, parseJlpt("N6"));
    try t.expectEqualStrings("Đây là mặt trời", try stripTags(a, "Đây là <b>mặt trời</ b>"));
    try t.expectEqualStrings("きょうがんそー", try toHiragana(a, "キョウガンソー"));
    const parts = try splitAny(a, " ひ  -び、-か\u{3000}x ", " \t\u{3000}、,");
    try t.expectEqual(4, parts.len);
    try t.expectEqualStrings("-び", parts[1]);
    try t.expectEqualStrings("x", parts[3]);
}

test "transforms kanji crawl rows" {
    const db = try Db.open(":memory:", .read_write_create);
    defer db.close();
    try db.exec("PRAGMA foreign_keys = ON");
    try db.exec(@embedFile("schema.sql"));
    try db.exec(
        \\INSERT INTO entry (ent_seq) VALUES (1), (2), (3), (4);
        \\INSERT INTO kanji_form (ent_seq, position, text) VALUES (1, 0, '響く'), (2, 0, '影響'), (3, 0, '交響'), (4, 0, '交響');
        \\INSERT INTO reading_form (ent_seq, position, text) VALUES (1, 0, 'ひびく'), (2, 0, 'えいきょう'), (3, 0, 'こうきょう'), (4, 0, 'こうきょう');
    );

    var ctx: Context = .{
        .st = try Statements.init(db),
        .arena = .init(std.testing.allocator),
        .unmapped = .init(std.testing.allocator),
    };
    defer ctx.deinit();

    try ctx.row("響",
        \\{"type":"kanji","mazii":[{"kanji":"響","mean":" HƯỞNG ","detail":"Tiếng.##Vang. <b>Ảnh hưởng</ b>.## ","kun":"ひび.く",
        \\  "on":"キョウ","level":["N1"],"stroke_count":"20","freq":502,"mobileId":597,"tips":{"vi":"<b>âm</b> thanh"},
        \\  "compDetail":[{"w":"音","h":"ÂM"},{"w":"郷","h":"HƯƠNG"},{"w":"音","h":"ÂM"}],
        \\  "examples":[{"w":"影響","m":"ảnh hưởng .","p":" えいきょう","h":"ẢNH HƯỞNG"},{"w":"響","p":"ひびき"}],
        \\  "example_on":{"キョウ":[{"w":"交響","m":"Sự dội lại","p":"こうきょう"}]},
        \\  "example_kun":{"vi":null}}],
        \\ "jisho":{"query":"響","found":true,"taughtIn":"junior high","jlptLevel":"N1","newspaperFrequencyRank":"502",
        \\  "strokeCount":20,"meaning":"echo, sound, resound","kunyomi":["ひび.く"],"onyomi":[" キョウ "],
        \\  "onyomiExamples":[{"example":"交響","reading":"コウキョウ","meaning":"reverberation"}],
        \\  "kunyomiExamples":[{"example":"響く","reading":"ひびく","meaning":"to resound"},{"example":"x","reading":"x","meaning":""}],
        \\  "radical":{"symbol":"音","meaning":"sound"},"parts":["日","立","音"]}}
    );
    // No Jisho data: readings fall back to Mazii, components to nothing, grade unknown.
    try ctx.row("頁",
        \\{"mazii":[{"kanji":"頁","mean":"HIỆT","detail":"Đầu.","kun":"ぺえじ おおがい","on":"ケツ","level":null,"stroke_count":"9"}],
        \\ "jisho":{"query":"頁","found":false}}
    );
    // No Mazii data: Jisho parts become components.
    try ctx.row("乙",
        \\{"mazii":[],"jisho":{"found":true,"taughtIn":"grade 9x","meaning":"the latter","onyomi":["オツ"],"parts":["乙"]}}
    );

    const t = std.testing;
    try t.expectEqual(3, try queryInt(db, "SELECT count(*) FROM kanji"));
    try t.expectEqual(1, try queryInt(db,
        \\SELECT count(*) FROM kanji WHERE literal = '響' AND stroke_count = 20 AND grade = 8 AND jlpt = 1
        \\  AND freq_rank = 502 AND han_viet = 'HƯỞNG' AND radical = '音' AND mnemonic_vi = 'âm thanh' AND mazii_id = 597
    ));
    try t.expectEqual(1, try queryInt(db, "SELECT count(*) FROM radical WHERE symbol = '音' AND meaning_en = 'sound'"));
    try t.expectEqual(1, try queryInt(db, "SELECT count(*) FROM kanji_reading WHERE literal = '響' AND type = 'on' AND text = 'キョウ'"));
    try t.expectEqual(2, try queryInt(db, "SELECT count(*) FROM kanji_meaning WHERE literal = '響' AND lang = 'vi'"));
    try t.expectEqual(1, try queryInt(db, "SELECT count(*) FROM kanji_meaning WHERE text = 'Vang. Ảnh hưởng.'"));
    try t.expectEqual(3, try queryInt(db, "SELECT count(*) FROM kanji_meaning WHERE literal = '響' AND lang = 'en'"));
    try t.expectEqual(2, try queryInt(db, "SELECT count(*) FROM kanji_component WHERE literal = '響'"));
    try t.expectEqual(1, try queryInt(db, "SELECT count(*) FROM kanji_component WHERE position = 1 AND component = '郷' AND han_viet = 'HƯƠNG'"));

    // Mazii: 影響 (linked), 響 skipped (no meaning), 交響 (two entries: not linked).
    // Jisho: 交響 (katakana reading, two entries), 響く (linked), x skipped (no meaning).
    try t.expectEqual(4, try queryInt(db, "SELECT count(*) FROM kanji_example WHERE literal = '響'"));
    try t.expectEqual(1, try queryInt(db, "SELECT count(*) FROM kanji_example WHERE word = '影響' AND reading = 'えいきょう' AND meaning = 'ảnh hưởng' AND ent_seq = 2 AND reading_type IS NULL"));
    try t.expectEqual(0, try queryInt(db, "SELECT count(*) FROM kanji_example WHERE word = '交響' AND ent_seq IS NOT NULL"));
    try t.expectEqual(1, try queryInt(db, "SELECT ent_seq FROM kanji_example WHERE word = '響く' AND lang = 'en' AND reading_type = 'kun'"));

    try t.expectEqual(2, try queryInt(db, "SELECT count(*) FROM kanji_reading WHERE literal = '頁' AND type = 'kun'"));
    try t.expectEqual(9, try queryInt(db, "SELECT stroke_count FROM kanji WHERE literal = '頁'"));
    try t.expectEqual(1, try queryInt(db, "SELECT count(*) FROM kanji WHERE literal = '頁' AND jlpt IS NULL AND grade IS NULL AND radical IS NULL"));
    try t.expectEqual(1, try queryInt(db, "SELECT count(*) FROM kanji_component WHERE literal = '乙'"));
    try t.expect(ctx.unmapped.counts.contains("kanji grade: grade 9x"));

    try t.expectEqual(2, ctx.stats.with_jisho);
    try t.expectEqual(2, ctx.stats.with_mazii);
    try t.expectEqual(2, ctx.stats.examples_linked);
}

test "Jisho on'yomi example readings link in hiragana" {
    const db = try Db.open(":memory:", .read_write_create);
    defer db.close();
    try db.exec(@embedFile("schema.sql"));
    try db.exec(
        \\INSERT INTO entry (ent_seq) VALUES (1), (2);
        \\INSERT INTO kanji_form (ent_seq, position, text) VALUES (1, 0, '響岩');
        \\INSERT INTO reading_form (ent_seq, position, text) VALUES (1, 0, 'きょうがん'), (2, 0, 'ソーダ');
    );
    var ctx: Context = .{
        .st = try Statements.init(db),
        .arena = .init(std.testing.allocator),
        .unmapped = .init(std.testing.allocator),
    };
    defer ctx.deinit();
    try std.testing.expectEqual(1, (try ctx.linkEntry("響岩", "キョウガン")).?);
    try std.testing.expectEqual(2, (try ctx.linkEntry("ソーダ", "ソーダ")).?);
    try std.testing.expectEqual(null, try ctx.linkEntry("響岩", "ひびきいわ"));
}
