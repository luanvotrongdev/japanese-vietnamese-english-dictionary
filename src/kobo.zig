//! Kobo dictionary export: writes a dictzip (`dicthtml-ja.zip`) that Kobo's
//! Japanese lookup can read. Port of the old Bun exporter's dictfile.ts
//! (HTML) and kobo.ts (sharding), without the dictgen step: the `words`
//! index is built here with src/marisa.zig.
//!
//! A dictzip holds `words`, a marisa trie of every lookup key, and gzipped
//! HTML shards named after a key prefix. Kobo picks shards for Japanese
//! dictionaries with its own rules, not dictgen's (see `shardPrefix`):
//! https://github.com/cessen/kobo_jp_dict. Format notes:
//! https://pgaskin.net/dictutil/dictgen/

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Db = @import("db.zig").Db;
const entries = @import("entries.zig");
const marisa = @import("marisa.zig");
const zip = @import("zip.zig");

pub const Stats = struct {
    words: usize = 0,
    kanji: usize = 0,
    keys: usize = 0,
    shards: usize = 0,
};

/// Kobo shows dictionary text in its built-in Georgia, which lacks most
/// Vietnamese letters (ư ơ ạ ả ấ ự …). Kobo Nickel has them; on-device
/// testing confirmed Kobo honours this inline font. Japanese still falls
/// back to Kobo's CJK font.
const font_style = "font-family: 'Kobo Nickel', 'Noto Serif', Georgia, serif";

/// When several entries share a key, Kobo often shows only one, so they are
/// merged into one entry in this order.
const Rank = enum(u8) { common_word, word, kanji };

const Body = struct {
    html: []const u8,
    rank: Rank,
};

/// Writes the dictzip to `out`. The caller flushes it.
pub fn write(gpa: Allocator, db: Db, out: *Writer) !Stats {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stats: Stats = .{};
    var bodies: std.ArrayList(Body) = .empty;
    // key -> indexes into `bodies`
    var by_key: std.StringArrayHashMapUnmanaged(std.ArrayList(u32)) = .empty;

    var reader = try entries.Reader.init(gpa, db);
    defer reader.deinit();
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    while (true) {
        defer _ = scratch.reset(.retain_capacity);
        const w = try reader.nextWord(scratch.allocator()) orelse break;
        const index: u32 = @intCast(bodies.items.len);
        try bodies.append(arena, .{
            .html = try renderWord(arena, w),
            .rank = if (w.is_common) .common_word else .word,
        });
        var keys: std.ArrayList([]const u8) = .empty;
        try keys.append(scratch.allocator(), w.headword());
        for (w.kanji) |k| try keys.append(scratch.allocator(), k);
        for (w.readings) |r| try keys.append(scratch.allocator(), r.text);
        try addKeys(arena, scratch.allocator(), &by_key, keys.items, index);
        stats.words += 1;
    }
    while (true) {
        defer _ = scratch.reset(.retain_capacity);
        const k = try reader.nextKanji(scratch.allocator()) orelse break;
        const index: u32 = @intCast(bodies.items.len);
        try bodies.append(arena, .{ .html = try renderKanji(arena, k), .rank = .kanji });
        try addKeys(arena, scratch.allocator(), &by_key, &.{k.literal}, index);
        stats.kanji += 1;
    }
    stats.keys = by_key.count();

    // prefix -> keys
    var shards: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    for (by_key.keys()) |key| {
        const prefix = try shardPrefix(arena, key);
        const shard = try shards.getOrPut(arena, prefix);
        if (!shard.found_existing) shard.value_ptr.* = .empty;
        try shard.value_ptr.append(arena, key);
    }
    stats.shards = shards.count();

    var archive: zip.Writer = .init(gpa, out);
    defer archive.deinit();

    const words = try marisa.build(gpa, by_key.keys());
    defer gpa.free(words);
    try archive.addFile("words", words, .store);

    var html: Writer.Allocating = .init(gpa);
    defer html.deinit();
    for (shards.keys(), shards.values()) |prefix, keys| {
        html.clearRetainingCapacity();
        try writeShard(&html.writer, keys.items, by_key, bodies.items);
        const gz = try zip.compress(gpa, html.written(), .gzip);
        defer gpa.free(gz);
        const name = try std.fmt.allocPrint(arena, "{s}.html", .{prefix});
        // The shards are already gzipped, so the ZIP stores them as is.
        try archive.addFile(name, gz, .store);
    }
    try archive.finish();
    return stats;
}

/// Registers `keys` (normalized, plus katakana forms of all-kana keys,
/// which Kobo uses to look hiragana words up) for body `index`.
fn addKeys(
    arena: Allocator,
    scratch: Allocator,
    by_key: *std.StringArrayHashMapUnmanaged(std.ArrayList(u32)),
    keys: []const []const u8,
    index: u32,
) !void {
    var all: std.ArrayList([]const u8) = .empty;
    for (keys) |raw| {
        const key = try normalizeKey(scratch, raw);
        if (key.len == 0) continue;
        try all.append(scratch, key);
        if (isAllKana(key)) try all.append(scratch, try hiraganaToKatakana(scratch, key));
    }
    for (all.items) |key| {
        const slot = try by_key.getOrPut(arena, key);
        if (!slot.found_existing) {
            slot.key_ptr.* = try arena.dupe(u8, key);
            slot.value_ptr.* = .empty;
        }
        const list = slot.value_ptr;
        if (std.mem.indexOfScalar(u32, list.items, index) == null) try list.append(arena, index);
    }
}

/// One shard: every key's entries merged into one `<w>` element. Shorter keys
/// come first, so Kobo's fallback prefix match picks the closest word.
fn writeShard(w: *Writer, keys: [][]const u8, by_key: std.StringArrayHashMapUnmanaged(std.ArrayList(u32)), bodies: []const Body) !void {
    std.mem.sort([]const u8, keys, {}, shorterFirst);
    try w.writeAll("<?xml version=\"1.0\" encoding=\"utf-8\"?><html>");
    for (keys) |key| {
        const indexes = by_key.get(key).?.items;
        std.mem.sort(u32, indexes, bodies, byRank); // stable: same rank keeps ent_seq order
        try w.writeAll("<w><a name=\"");
        try writeEscaped(w, key);
        try w.writeAll("\" />");
        for (indexes, 0..) |i, n| {
            if (n > 0) try w.writeAll("<hr/>");
            try w.writeAll(bodies[i].html);
        }
        try w.writeAll("</w>");
    }
    try w.writeAll("</html>");
}

fn shorterFirst(_: void, a: []const u8, b: []const u8) bool {
    const la = codepointCount(a);
    const lb = codepointCount(b);
    if (la != lb) return la < lb;
    return std.mem.lessThan(u8, a, b);
}

fn byRank(bodies: []const Body, a: u32, b: u32) bool {
    return @intFromEnum(bodies[a].rank) < @intFromEnum(bodies[b].rank);
}

// ---------------------------------------------------------------- keys and shards

fn isKana(c: u21) bool {
    return (c >= 0x3041 and c <= 0x3096) or // hiragana
        (c >= 0x3099 and c <= 0x309e) or // combining marks, iteration marks
        (c >= 0x30a1 and c <= 0x30f6) or // katakana
        (c >= 0x30fc and c <= 0x30fe); // prolonged sound mark, iteration marks
}

pub fn isAllKana(text: []const u8) bool {
    if (text.len == 0) return false;
    var it = (std.unicode.Utf8View.init(text) catch return false).iterator();
    while (it.nextCodepoint()) |c| if (!isKana(c)) return false;
    return true;
}

pub fn hiraganaToKatakana(a: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(a, text.len);
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepoint()) |c| {
        const k = if ((c >= 0x3041 and c <= 0x3096) or (c >= 0x309d and c <= 0x309e)) c + 0x60 else c;
        var buf: [4]u8 = undefined;
        try out.appendSlice(a, buf[0..try std.unicode.utf8Encode(k, &buf)]);
    }
    return out.items;
}

/// Trims and lowercases a key, as dictgen does (Latin, fullwidth Latin,
/// Greek and Cyrillic capitals; JMdict has keys like ＣＤ and Ｘ線).
pub fn normalizeKey(a: Allocator, raw: []const u8) ![]u8 {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    var out: std.ArrayList(u8) = try .initCapacity(a, text.len);
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepoint()) |c| {
        const lower: u21 = switch (c) {
            'A'...'Z', 0xff21...0xff3a, 0x0410...0x042f => c + 0x20,
            0x0391...0x03a1, 0x03a3...0x03a9 => c + 0x20,
            0x0400...0x040f => c + 0x50,
            else => c,
        };
        var buf: [4]u8 = undefined;
        try out.appendSlice(a, buf[0..try std.unicode.utf8Encode(lower, &buf)]);
    }
    return out.items;
}

/// Shard name Kobo looks a word up in, for a Japanese dictionary: one
/// character for words starting with a kanji, up to two characters (no
/// padding) for kana and Cyrillic, two letters ("a"-padded) for other
/// letters, and "11" for everything else.
pub fn shardPrefix(a: Allocator, key: []const u8) ![]const u8 {
    var it = (try std.unicode.Utf8View.init(key)).iterator();
    const first_start = it.i;
    const c1 = it.nextCodepoint() orelse return "11";
    const first = key[first_start..it.i];
    const c2 = it.nextCodepoint();
    const two = key[first_start..it.i];

    if ((c1 >= 0x0400 and c1 <= 0x052f) or (c1 >= 0x2de0 and c1 <= 0x2dff) or
        (c1 >= 0xa640 and c1 <= 0xa69f) or (c1 >= 0x3040 and c1 <= 0x30ff)) return two;
    if ((c1 >= 0x3400 and c1 <= 0x4dbf) or (c1 >= 0x4e00 and c1 <= 0x9fff)) return first;
    if (isLetter(c1)) {
        const c = c2 orelse return std.fmt.allocPrint(a, "{s}a", .{first});
        if (isLetter(c)) return two;
    }
    return "11";
}

/// Rough \p{L}: ASCII and Latin-1/Latin Extended letters, Greek, Cyrillic,
/// fullwidth Latin, kana and CJK ideographs.
fn isLetter(c: u21) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z' => true,
        0xc0...0x24f => c != 0xd7 and c != 0xf7,
        0x370...0x3ff, 0x400...0x52f => true,
        0x3041...0x3096, 0x30a1...0x30fa, 0x3400...0x4dbf, 0x4e00...0x9fff => true,
        0xff21...0xff3a, 0xff41...0xff5a => true,
        else => false,
    };
}

fn codepointCount(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

// ---------------------------------------------------------------- HTML

/// 食べる 【たべる】 [2]  N5 · thông dụng, then other spellings, the Vietnamese
/// senses with examples, and the English senses.
pub fn renderWord(a: Allocator, e: entries.Word) ![]const u8 {
    var out: Writer.Allocating = .init(a);
    const w = &out.writer;

    try w.print("<div class=\"word{s}\" style=\"{s}\"><p><b>", .{ if (e.is_common) " common" else "", font_style });
    try writeEscaped(w, e.headword());
    try w.writeAll("</b>");
    const readings = e.shownReadings();
    if (readings.len > 0) {
        try w.writeAll(" 【");
        for (readings[0..@min(readings.len, 3)], 0..) |r, i| {
            if (i > 0) try w.writeAll("・");
            try writeEscaped(w, r.text);
        }
        try w.writeAll("】");
    }
    if (e.pitch()) |p| try w.print(" <font color=\"gray\">[{d}]</font>", .{p});
    if (e.jlpt != null or e.is_common) {
        try w.writeAll(" <small><font color=\"gray\">");
        if (e.jlpt) |n| try w.print("N{d}", .{n});
        if (e.jlpt != null and e.is_common) try w.writeAll(" · ");
        if (e.is_common) try w.writeAll("thông dụng");
        try w.writeAll("</font></small>");
    }
    try w.writeAll("</p>");

    if (e.kanji.len > 1) {
        try w.writeAll("<p><small><font color=\"gray\">Cách viết khác: ");
        try writeJoined(w, e.kanji[1..], "、");
        try w.writeAll("</font></small></p>");
    }

    if (e.vietnamese.len > 0) {
        if (e.word_types.len > 0) {
            try w.writeAll("<p><i>");
            for (e.word_types, 0..) |t, i| {
                if (i > 0) try w.writeAll(" · ");
                try writeEscaped(w, if (i == 0) try capitalize(a, t) else t);
            }
            try w.writeAll("</i></p>");
        }
        try w.writeAll("<ol>");
        for (e.vietnamese) |sense| {
            try w.writeAll("<li>");
            try writeJoined(w, sense.glosses, "; ");
            for (sense.examples) |ex| {
                try w.writeAll("<br/><small>");
                try writeEscaped(w, ex.japanese);
                try w.writeAll("<br/><i>");
                try writeEscaped(w, ex.vietnamese);
                try w.writeAll("</i></small>");
            }
            try w.writeAll("</li>");
        }
        try w.writeAll("</ol>");
    }

    if (e.english.len > 0) {
        try w.writeAll("<p><font color=\"gray\">English</font></p><ol>");
        var previous_pos: []const []const u8 = &.{};
        for (e.english) |sense| {
            try w.writeAll("<li>");
            // Repeat the parts of speech only when they change.
            if (sense.parts_of_speech.len > 0 and !sameStrings(sense.parts_of_speech, previous_pos)) {
                try w.writeAll("<small><font color=\"gray\"><i>");
                try writeJoined(w, sense.parts_of_speech, ", ");
                try w.writeAll("</i></font></small><br/>");
            }
            previous_pos = sense.parts_of_speech;
            try writeJoined(w, sense.glosses, "; ");
            if (sense.notes.len > 0) {
                try w.writeAll(" <small><font color=\"gray\">(");
                try writeJoined(w, sense.notes, "; ");
                try w.writeAll(")</font></small>");
            }
            try w.writeAll("</li>");
        }
        try w.writeAll("</ol>");
    }
    try w.writeAll("</div>");
    return out.written();
}

/// 食  THỰC  N5 · 9 nét, then the Vietnamese and English meanings, readings,
/// radical, components, mnemonic and example words.
pub fn renderKanji(a: Allocator, k: entries.Kanji) ![]const u8 {
    var out: Writer.Allocating = .init(a);
    const w = &out.writer;

    try w.print("<div class=\"kanji\" style=\"{s}\"><p><span style=\"font-size:1.8em\"><b>", .{font_style});
    try writeEscaped(w, k.literal);
    try w.writeAll("</b></span>");
    if (k.han_viet) |hv| {
        try w.writeAll(" <b>");
        try writeEscaped(w, hv);
        try w.writeAll("</b>");
    }
    if (k.jlpt != null or k.strokes != null) {
        try w.writeAll(" <small><font color=\"gray\">");
        if (k.jlpt) |n| try w.print("N{d}", .{n});
        if (k.jlpt != null and k.strokes != null) try w.writeAll(" · ");
        if (k.strokes) |n| try w.print("{d} nét", .{n});
        try w.writeAll("</font></small>");
    }
    try w.writeAll("</p>");

    if (k.vietnamese.len > 0) {
        try w.writeAll("<p>");
        try writeJoined(w, k.vietnamese, "<br/>");
        try w.writeAll("</p>");
    }
    if (k.english.len > 0) {
        try w.writeAll("<p><font color=\"gray\">English:</font> ");
        try writeJoined(w, k.english, ", ");
        try w.writeAll("</p>");
    }

    var rows: usize = 0;
    if (k.onyomi.len > 0) {
        try row(w, &rows, "Âm On");
        try writeJoined(w, k.onyomi, "、");
    }
    if (k.kunyomi.len > 0) {
        try row(w, &rows, "Âm Kun");
        try writeJoined(w, k.kunyomi, "、");
    }
    if (k.radical) |r| {
        try row(w, &rows, "Bộ");
        try writeEscaped(w, r);
        if (k.radical_meaning) |m| {
            try w.writeByte(' ');
            try writeEscaped(w, m);
        }
    }
    if (k.components.len > 0) {
        try row(w, &rows, "Thành phần");
        for (k.components, 0..) |c, i| {
            if (i > 0) try w.writeAll(" · ");
            try writeEscaped(w, c.kanji);
            if (c.han_viet) |hv| {
                try w.writeByte(' ');
                try writeEscaped(w, hv);
            }
        }
    }
    if (k.mnemonic) |m| {
        try row(w, &rows, "Mẹo nhớ");
        try writeEscaped(w, m);
    }
    if (rows > 0) try w.writeAll("</p>");

    if (k.examples.len > 0) {
        try w.writeAll("<p><font color=\"gray\">Ví dụ:</font>");
        for (k.examples) |ex| {
            try w.writeAll("<br/>");
            try writeEscaped(w, ex.word);
            if (ex.reading) |r| {
                try w.writeAll(" (");
                try writeEscaped(w, r);
                try w.writeByte(')');
            }
            if (ex.han_viet) |hv| {
                try w.writeAll(" <small><font color=\"gray\">");
                try writeEscaped(w, hv);
                try w.writeAll("</font></small>");
            }
            try w.writeAll(": ");
            try writeEscaped(w, ex.meaning);
        }
        try w.writeAll("</p>");
    }
    try w.writeAll("</div>");
    return out.written();
}

/// Starts a "Label: value" line in the kanji info paragraph.
fn row(w: *Writer, rows: *usize, label: []const u8) !void {
    try w.writeAll(if (rows.* == 0) "<p>" else "<br/>");
    try w.print("<font color=\"gray\">{s}:</font> ", .{label});
    rows.* += 1;
}

fn writeJoined(w: *Writer, items: []const []const u8, separator: []const u8) !void {
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeAll(separator);
        try writeEscaped(w, item);
    }
}

pub fn writeEscaped(w: *Writer, text: []const u8) !void {
    var start: usize = 0;
    for (text, 0..) |c, i| {
        const entity: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            else => continue,
        };
        try w.writeAll(text[start..i]);
        try w.writeAll(entity);
        start = i + 1;
    }
    try w.writeAll(text[start..]);
}

/// Uppercases the first letter of a word-type label. The labels are ours and
/// start with an ASCII letter or đ.
fn capitalize(a: Allocator, text: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, text, "đ")) return std.fmt.allocPrint(a, "Đ{s}", .{text["đ".len..]});
    if (text.len > 0 and std.ascii.isLower(text[0])) {
        const out = try a.dupe(u8, text);
        out[0] = std.ascii.toUpper(out[0]);
        return out;
    }
    return text;
}

fn sameStrings(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

// ---------------------------------------------------------------- tests

test "Kobo shard prefixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = std.testing;
    try t.expectEqualStrings("食", try shardPrefix(a, "食べる"));
    try t.expectEqualStrings("たべ", try shardPrefix(a, "たべる"));
    try t.expectEqualStrings("タ", try shardPrefix(a, "タ"));
    try t.expectEqualStrings("cd", try shardPrefix(a, "cd"));
    try t.expectEqualStrings("xa", try shardPrefix(a, "x"));
    try t.expectEqualStrings("11", try shardPrefix(a, "1つ"));
    try t.expectEqualStrings("11", try shardPrefix(a, ""));
}

test "Kobo keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = std.testing;
    try t.expect(isAllKana("たべる"));
    try t.expect(isAllKana("コーヒー"));
    try t.expect(!isAllKana("食べる"));
    try t.expectEqualStrings("タベル", try hiraganaToKatakana(a, "たべる"));
    try t.expectEqualStrings("ヽヾー", try hiraganaToKatakana(a, "ゝゞー"));
    try t.expectEqualStrings("ｃｄ プレーヤー", try normalizeKey(a, " ＣＤ プレーヤー "));
    try t.expectEqualStrings("ｘ線", try normalizeKey(a, "Ｘ線"));
}

test "writes the Kobo dictzip" {
    const db = try entries.testDatabase();
    defer db.close();
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const stats = try write(std.testing.allocator, db, &out.writer);
    const t = std.testing;
    try t.expectEqual(3, stats.words);
    try t.expectEqual(1, stats.kanji);
    // 食べる 喰べる たべる タベル ああ アア 甲 乙 こう コウ おつ オツ 食
    try t.expectEqual(13, stats.keys);
    const bytes = out.written();
    try t.expect(std.mem.startsWith(u8, bytes[30..], "wordsWe love Marisa."));
    for ([_][]const u8{ "食.html", "たべ.html", "タベ.html", "甲.html", "乙.html", "ああ.html", "アア.html" }) |name| {
        try t.expect(std.mem.indexOf(u8, bytes, name) != null);
    }
    try t.expect(std.mem.indexOf(u8, bytes, "喰.html") != null);
}

test "renders Kobo entries" {
    const db = try entries.testDatabase();
    defer db.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = std.testing;

    var r = try entries.Reader.init(std.testing.allocator, db);
    defer r.deinit();
    _ = try r.nextWord(a);
    const kou = (try r.nextWord(a)).?;
    const kou_html = try renderWord(a, kou);
    try t.expect(std.mem.indexOf(u8, kou_html, "A &lt;B&gt; &amp; C") != null);

    const taberu = (try r.nextWord(a)).?;
    const html = try renderWord(a, taberu);
    try t.expect(std.mem.startsWith(u8, html, "<div class=\"word common\" style=\"font-family: 'Kobo Nickel'"));
    try t.expect(std.mem.indexOf(u8, html, "<b>食べる</b> 【たべる】 <font color=\"gray\">[2]</font> <small><font color=\"gray\">N5 · thông dụng</font></small>") != null);
    try t.expect(std.mem.indexOf(u8, html, "Cách viết khác: 喰べる") != null);
    try t.expect(std.mem.indexOf(u8, html, "<p><i>Động từ nhóm 2 · tha động từ</i></p>") != null);
    try t.expect(std.mem.indexOf(u8, html, "<li>ăn; xơi nhé.<br/><small>食べるな。<br/><i>Cấm ăn.</i></small>") != null);
    // Parts of speech show again when they change; notes follow the glosses.
    try t.expect(std.mem.indexOf(u8, html, "<i>Ichidan verb, Transitive verb</i></font></small><br/>to eat</li>") != null);
    try t.expect(std.mem.indexOf(u8, html, "<i>Ichidan verb</i></font></small><br/>to live on; to subsist on <small><font color=\"gray\">(Colloquial; colloquial)</font></small></li>") != null);

    const shoku = (try r.nextKanji(a)).?;
    const kanji_html = try renderKanji(a, shoku);
    try t.expect(std.mem.indexOf(u8, kanji_html, "<b>THỰC</b> <small><font color=\"gray\">N5 · 9 nét</font></small>") != null);
    try t.expect(std.mem.indexOf(u8, kanji_html, "<font color=\"gray\">Âm Kun:</font> く.う、た.べる") != null);
    try t.expect(std.mem.indexOf(u8, kanji_html, "<font color=\"gray\">Bộ:</font> 食 eat, food") != null);
}
