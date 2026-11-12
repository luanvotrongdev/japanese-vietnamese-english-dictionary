//! Yomitan dictionary export (format 3). Port of the old Bun exporter's
//! yomitan.ts, without the yomichan-dict-builder package: the banks are
//! written as JSON straight into the ZIP.
//! Format: https://github.com/yomidevs/yomitan/tree/master/ext/data/schemas
//!
//! Definitions are structured content (styled spans and lists). Each part has
//! a `data: {content: …}` hook (data-sc-content in Yomitan), so users can
//! restyle it with custom CSS: vietnamese, english, example, word-types,
//! section-label.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Stringify = std.json.Stringify;
const Db = @import("db.zig").Db;
const entries = @import("entries.zig");
const zip = @import("zip.zig");

pub const revision = "2.0.0";

pub const index_json =
    \\{"title":"Lulu J-V Dictionary","revision":"
++ revision ++
    \\","format":3,"author":"Vo Trong Luan",
++
    \\"description":"A Japanese → Vietnamese / English dictionary built from JMdict, Mazii and Jisho.",
++
    \\"attribution":"JMdict (EDRDG, CC BY-SA 4.0); Vietnamese from Mazii.net; English from Jisho.org",
++
    \\"url":"https://github.com/luanvotrongdev/ja-vi-jmdict","sequenced":true,"sourceLanguage":"ja","targetLanguage":"vi"}
;

/// Entries per term, term-meta and kanji bank file.
const bank_size = 10_000;

pub const Stats = struct {
    words: usize = 0,
    terms: usize = 0,
    pitches: usize = 0,
    kanji: usize = 0,
};

/// Writes the dictionary ZIP to `out`. The caller flushes it.
pub fn write(gpa: Allocator, db: Db, out: *Writer) !Stats {
    var archive: zip.Writer = .init(gpa, out);
    defer archive.deinit();
    try archive.addFile("index.json", index_json, .deflate);
    try archive.addFile("tag_bank_1.json", tag_bank, .deflate);

    var reader = try entries.Reader.init(gpa, db);
    defer reader.deinit();
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    var stats: Stats = .{};
    var terms: Bank = try .init(gpa, &archive, "term_bank");
    defer terms.deinit();
    var pitches: Bank = try .init(gpa, &archive, "term_meta_bank");
    defer pitches.deinit();
    // "term\x00reading" pairs that already have pitch data.
    var seen_pitch: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen_pitch.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        seen_pitch.deinit(gpa);
    }

    while (true) {
        defer _ = scratch.reset(.retain_capacity);
        const a = scratch.allocator();
        const w = try reader.nextWord(a) orelse break;
        stats.words += 1;

        const content = try renderWordContent(a, w);
        const rules = inflectionRules(w);
        const base_score: i64 = @as(i64, if (w.is_common) 10 else 0) + @as(i64, if (w.jlpt != null) 5 else 0);
        var term_tags: Writer.Allocating = .init(a);
        if (w.jlpt) |n| try term_tags.writer.print("N{d}", .{n});
        if (w.is_common) try term_tags.writer.writeAll(if (w.jlpt != null) " ★" else "★");

        // One term per (spelling, reading) pair; the shared sequence number
        // lets Yomitan merge them into one result.
        for (w.readings, 0..) |r, j| {
            if (w.kanji.len == 0) {
                try addTerm(&terms, r.text, "", rules, base_score - @as(i64, @intCast(j)), content, w.ent_seq, term_tags.written());
                stats.terms += 1;
                continue;
            }
            for (w.kanji, 0..) |k, i| {
                if (!r.appliesTo(i)) continue;
                try addTerm(&terms, k, r.text, rules, base_score - @as(i64, @intCast(i + j)), content, w.ent_seq, term_tags.written());
                stats.terms += 1;
            }
        }

        for (w.readings) |r| {
            const position = r.pitch orelse continue;
            for (0..@max(w.kanji.len, 1)) |i| {
                const term = if (w.kanji.len == 0) r.text else w.kanji[i];
                if (w.kanji.len > 0 and !r.appliesTo(i)) continue;
                const key = try std.fmt.allocPrint(gpa, "{s}\x00{s}", .{ term, r.text });
                const slot = try seen_pitch.getOrPut(gpa, key);
                if (slot.found_existing) {
                    gpa.free(key);
                    continue;
                }
                const jw = try pitches.next();
                try jw.beginArray();
                try jw.write(term);
                try jw.write("pitch");
                try jw.beginObject();
                try jw.objectField("reading");
                try jw.write(r.text);
                try jw.objectField("pitches");
                try jw.beginArray();
                try jw.beginObject();
                try jw.objectField("position");
                try jw.write(position);
                try jw.endObject();
                try jw.endArray();
                try jw.endObject();
                try jw.endArray();
                stats.pitches += 1;
            }
        }
    }
    if (stats.words == 0) return error.NoWords;
    try terms.finish();
    try pitches.finish();

    var kanji: Bank = try .init(gpa, &archive, "kanji_bank");
    defer kanji.deinit();
    while (true) {
        defer _ = scratch.reset(.retain_capacity);
        const k = try reader.nextKanji(scratch.allocator()) orelse break;
        try addKanji(scratch.allocator(), try kanji.next(), k);
        stats.kanji += 1;
    }
    try kanji.finish();

    try archive.finish();
    return stats;
}

/// A series of `<name>_N.json` files holding at most `bank_size` items each.
const Bank = struct {
    gpa: Allocator,
    archive: *zip.Writer,
    name: []const u8,
    buffer: Writer.Allocating,
    jw: Stringify,
    count: usize = 0,
    files: usize = 0,

    fn init(gpa: Allocator, archive: *zip.Writer, name: []const u8) !Bank {
        return .{ .gpa = gpa, .archive = archive, .name = name, .buffer = .init(gpa), .jw = undefined };
    }

    fn deinit(b: *Bank) void {
        b.buffer.deinit();
    }

    /// Returns the writer for the next item, starting a new file if needed.
    fn next(b: *Bank) !*Stringify {
        if (b.count == bank_size) try b.flush();
        if (b.count == 0) {
            b.buffer.clearRetainingCapacity();
            b.jw = .{ .writer = &b.buffer.writer };
            try b.jw.beginArray();
        }
        b.count += 1;
        return &b.jw;
    }

    fn flush(b: *Bank) !void {
        if (b.count == 0) return;
        try b.jw.endArray();
        b.files += 1;
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{s}_{d}.json", .{ b.name, b.files });
        try b.archive.addFile(name, b.buffer.written(), .deflate);
        b.count = 0;
    }

    fn finish(b: *Bank) !void {
        try b.flush();
    }
};

fn addTerm(bank: *Bank, term: []const u8, reading: []const u8, rules: Rules, score: i64, content: []const u8, sequence: i64, term_tags: []const u8) !void {
    const jw = try bank.next();
    try jw.beginArray();
    try jw.write(term);
    try jw.write(if (std.mem.eql(u8, reading, term)) "" else reading);
    try jw.write("");
    try writeRules(jw, rules, term);
    try jw.write(score);
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("structured-content");
    try jw.objectField("content");
    try jw.beginWriteRaw();
    try jw.writer.writeAll(content);
    jw.endWriteRaw();
    try jw.endObject();
    try jw.endArray();
    try jw.write(sequence);
    try jw.write(term_tags);
    try jw.endArray();
}

// ---------------------------------------------------------------- inflection rules

/// Yomitan only deinflects (食べた → 食べる) when the term names its rule.
const Rules = packed struct {
    v1: bool = false,
    v5: bool = false,
    vs: bool = false,
    vk: bool = false,
    vz: bool = false,
    adj_i: bool = false,
};

fn inflectionRules(w: entries.Word) Rules {
    var r: Rules = .{};
    for (w.tag_codes) |code| {
        if (std.mem.eql(u8, code, "v1") or std.mem.eql(u8, code, "v1-s")) r.v1 = true;
        if (std.mem.startsWith(u8, code, "v5")) r.v5 = true;
        if (std.mem.eql(u8, code, "vs") or std.mem.eql(u8, code, "vs-i") or std.mem.eql(u8, code, "vs-s")) r.vs = true;
        if (std.mem.eql(u8, code, "vk")) r.vk = true;
        if (std.mem.eql(u8, code, "vz")) r.vz = true;
        if (std.mem.eql(u8, code, "adj-i") or std.mem.eql(u8, code, "adj-ix")) r.adj_i = true;
    }
    return r;
}

/// Yomitan's する/来る/ずる rules only apply to terms ending that way; JMdict
/// also marks nouns like 勉強 as "vs" (takes する), which Yomitan can't use.
fn writeRules(jw: *Stringify, r: Rules, term: []const u8) !void {
    var buf: [32]u8 = undefined;
    var list: std.ArrayList(u8) = .initBuffer(&buf);
    const ends = std.mem.endsWith;
    const candidates = [_]struct { on: bool, name: []const u8 }{
        .{ .on = r.v1, .name = "v1" },
        .{ .on = r.v5, .name = "v5" },
        .{ .on = r.vs and ends(u8, term, "する"), .name = "vs" },
        .{ .on = r.vk and (ends(u8, term, "くる") or ends(u8, term, "来る")), .name = "vk" },
        .{ .on = r.vz and ends(u8, term, "ずる"), .name = "vz" },
        .{ .on = r.adj_i, .name = "adj-i" },
    };
    for (candidates) |c| {
        if (!c.on) continue;
        if (list.items.len > 0) list.appendAssumeCapacity(' ');
        list.appendSliceAssumeCapacity(c.name);
    }
    try jw.write(list.items);
}

// ---------------------------------------------------------------- structured content

/// Colors are semi-transparent so they work in light and dark themes.
const muted = "rgba(128, 128, 128, 1)";
const rule_color = "rgba(128, 128, 128, 0.45)";

const Style = []const [2][]const u8;

const pill_style: Style = &.{
    .{ "fontSize", "0.75em" },     .{ "backgroundColor", "rgba(86, 130, 201, 0.18)" },
    .{ "borderRadius", "0.35em" }, .{ "padding", "0.05em 0.45em" },
    .{ "marginRight", "0.3em" },   .{ "whiteSpace", "nowrap" },
};
const example_style: Style = &.{
    .{ "fontSize", "0.88em" },      .{ "borderStyle", "solid" },  .{ "borderWidth", "0 0 0 2px" },
    .{ "borderColor", rule_color }, .{ "paddingLeft", "0.55em" }, .{ "marginTop", "0.2em" },
    .{ "marginBottom", "0.2em" },
};
const section_label_style: Style = &.{
    .{ "fontSize", "0.75em" },   .{ "fontWeight", "bold" },       .{ "color", muted },
    .{ "borderStyle", "solid" }, .{ "borderWidth", "1px 0 0 0" }, .{ "borderColor", rule_color },
    .{ "paddingTop", "0.25em" }, .{ "marginTop", "0.45em" },
};
const list_style: Style = &.{ .{ "paddingLeft", "1.4em" }, .{ "marginTop", "0.15em" }, .{ "marginBottom", "0" } };
const word_types_style: Style = &.{.{ "marginBottom", "0.2em" }};
const translation_style: Style = &.{ .{ "fontStyle", "italic" }, .{ "color", muted } };
const muted_small: Style = &.{ .{ "fontSize", "0.8em" }, .{ "color", muted } };
const pos_style: Style = &.{ .{ "fontSize", "0.8em" }, .{ "color", muted }, .{ "fontStyle", "italic" } };

const Extra = struct {
    style: ?Style = null,
    lang: ?[]const u8 = null,
    part: ?[]const u8 = null,
};

/// Opens `{"tag": …, [style, lang, data], "content": [` — close with `endNode`.
fn beginNode(jw: *Stringify, tag: []const u8, extra: Extra) !void {
    try jw.beginObject();
    try jw.objectField("tag");
    try jw.write(tag);
    if (extra.style) |style| {
        try jw.objectField("style");
        try jw.beginObject();
        for (style) |kv| {
            try jw.objectField(kv[0]);
            try jw.write(kv[1]);
        }
        try jw.endObject();
    }
    if (extra.lang) |lang| {
        try jw.objectField("lang");
        try jw.write(lang);
    }
    if (extra.part) |part| {
        try jw.objectField("data");
        try jw.beginObject();
        try jw.objectField("content");
        try jw.write(part);
        try jw.endObject();
    }
    try jw.objectField("content");
    try jw.beginArray();
}

fn endNode(jw: *Stringify) !void {
    try jw.endArray();
    try jw.endObject();
}

/// A node holding a single string.
fn textNode(jw: *Stringify, tag: []const u8, text: []const u8, extra: Extra) !void {
    try beginNode(jw, tag, extra);
    try jw.write(text);
    try endNode(jw);
}

fn lineBreak(jw: *Stringify) !void {
    try jw.beginObject();
    try jw.objectField("tag");
    try jw.write("br");
    try jw.endObject();
}

fn writeJoinedString(a: Allocator, jw: *Stringify, items: []const []const u8, separator: []const u8) !void {
    try jw.write(try std.mem.join(a, separator, items));
}

/// The definition's structured content as a JSON array, rendered once per
/// entry and shared by all of its terms.
fn renderWordContent(a: Allocator, e: entries.Word) ![]const u8 {
    var out: Writer.Allocating = .init(a);
    var jw: Stringify = .{ .writer = &out.writer };
    try jw.beginArray();

    if (e.vietnamese.len > 0) {
        if (e.word_types.len > 0) {
            try beginNode(&jw, "div", .{ .style = word_types_style, .lang = "vi", .part = "word-types" });
            for (e.word_types) |t| try textNode(&jw, "span", t, .{ .style = pill_style });
            try endNode(&jw);
        }
        // A single sense is shown without list numbering.
        const single = e.vietnamese.len == 1;
        if (single) {
            try beginNode(&jw, "div", .{ .lang = "vi", .part = "vietnamese" });
        } else {
            try beginNode(&jw, "ol", .{ .style = list_style, .lang = "vi", .part = "vietnamese" });
        }
        for (e.vietnamese) |sense| {
            if (!single) try beginNode(&jw, "li", .{});
            try writeJoinedString(a, &jw, sense.glosses, "; ");
            for (sense.examples) |ex| {
                try beginNode(&jw, "div", .{ .style = example_style, .part = "example" });
                try textNode(&jw, "span", ex.japanese, .{ .lang = "ja" });
                try lineBreak(&jw);
                try textNode(&jw, "span", ex.vietnamese, .{ .style = translation_style, .lang = "vi" });
                try endNode(&jw);
            }
            if (!single) try endNode(&jw);
        }
        try endNode(&jw);
    }

    if (e.english.len > 0) {
        if (e.vietnamese.len > 0) try textNode(&jw, "div", "English", .{ .style = section_label_style, .part = "section-label" });
        try beginNode(&jw, "ol", .{ .style = list_style, .lang = "en", .part = "english" });
        var previous_pos: []const []const u8 = &.{};
        for (e.english) |sense| {
            try beginNode(&jw, "li", .{});
            // Repeat the parts of speech only when they change.
            if (sense.parts_of_speech.len > 0 and !sameStrings(sense.parts_of_speech, previous_pos)) {
                try beginNode(&jw, "span", .{ .style = pos_style });
                try writeJoinedString(a, &jw, sense.parts_of_speech, ", ");
                try endNode(&jw);
                try lineBreak(&jw);
            }
            previous_pos = sense.parts_of_speech;
            try writeJoinedString(a, &jw, sense.glosses, "; ");
            if (sense.notes.len > 0) {
                try jw.write(" ");
                try textNode(&jw, "span", try std.fmt.allocPrint(a, "({s})", .{try std.mem.join(a, "; ", sense.notes)}), .{ .style = muted_small });
            }
            try endNode(&jw);
        }
        try endNode(&jw);
    }

    try jw.endArray();
    return out.written();
}

fn sameStrings(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

// ---------------------------------------------------------------- kanji

/// Kanji stats, shown by Yomitan as a table labelled by the tags below.
const kanji_stats = [_]struct { key: []const u8, label: []const u8 }{
    .{ .key = "strokes", .label = "Số nét" },
    .{ .key = "jlpt", .label = "JLPT" },
    .{ .key = "grade", .label = "Cấp học (Nhật)" },
    .{ .key = "freq", .label = "Tần suất trên báo" },
    .{ .key = "radical", .label = "Bộ thủ" },
    .{ .key = "parts", .label = "Thành phần" },
};

/// Yomitan shows kanji meanings as plain text lines.
fn addKanji(a: Allocator, jw: *Stringify, k: entries.Kanji) !void {
    try jw.beginArray();
    try jw.write(k.literal);
    try writeJoinedString(a, jw, k.onyomi, " ");
    try writeJoinedString(a, jw, k.kunyomi, " ");
    try jw.write(if (k.jlpt) |n| try std.fmt.allocPrint(a, "N{d}", .{n}) else "");

    try jw.beginArray();
    if (k.han_viet) |hv| try jw.write(try std.fmt.allocPrint(a, "【{s}】", .{hv}));
    for (k.vietnamese) |m| try jw.write(m);
    if (k.english.len > 0) try jw.write(try std.fmt.allocPrint(a, "English: {s}", .{try std.mem.join(a, ", ", k.english)}));
    if (k.mnemonic) |m| try jw.write(try std.fmt.allocPrint(a, "Mẹo nhớ: {s}", .{m}));
    if (k.examples.len > 0) {
        var line: Writer.Allocating = .init(a);
        try line.writer.writeAll("Ví dụ: ");
        for (k.examples, 0..) |ex, i| {
            if (i > 0) try line.writer.writeAll(" ・ ");
            try line.writer.writeAll(ex.word);
            if (ex.reading) |r| try line.writer.print(" ({s})", .{r});
            if (ex.han_viet) |hv| try line.writer.print(" {s}", .{hv});
            try line.writer.print(": {s}", .{ex.meaning});
        }
        try jw.write(line.written());
    }
    try jw.endArray();

    try jw.beginObject();
    if (k.strokes) |n| {
        try jw.objectField("strokes");
        try jw.write(try std.fmt.allocPrint(a, "{d}", .{n}));
    }
    if (k.jlpt) |n| {
        try jw.objectField("jlpt");
        try jw.write(try std.fmt.allocPrint(a, "N{d}", .{n}));
    }
    if (k.grade) |g| {
        try jw.objectField("grade");
        try jw.write(try gradeLabel(a, g));
    }
    if (k.freq_rank) |n| {
        try jw.objectField("freq");
        try jw.write(try std.fmt.allocPrint(a, "{d}", .{n}));
    }
    if (k.radical) |r| {
        try jw.objectField("radical");
        try jw.write(if (k.radical_meaning) |m| try std.fmt.allocPrint(a, "{s} {s}", .{ r, m }) else r);
    }
    if (k.components.len > 0) {
        var parts: Writer.Allocating = .init(a);
        for (k.components, 0..) |c, i| {
            if (i > 0) try parts.writer.writeAll(" · ");
            try parts.writer.writeAll(c.kanji);
            if (c.han_viet) |hv| try parts.writer.print(" {s}", .{hv});
        }
        try jw.objectField("parts");
        try jw.write(parts.written());
    }
    try jw.endObject();
    try jw.endArray();
}

/// KANJIDIC grades: 1–6 primary school year, 8 secondary school, 9–10 jinmeiyō.
fn gradeLabel(a: Allocator, grade: i64) ![]const u8 {
    return switch (grade) {
        1...6 => std.fmt.allocPrint(a, "tiểu học lớp {d}", .{grade}),
        8 => "trung học",
        9, 10 => "dùng cho tên người",
        else => std.fmt.allocPrint(a, "{d}", .{grade}),
    };
}

// ---------------------------------------------------------------- tags

const tag_bank = blk: {
    var json: []const u8 =
        \\[["★","popular",-10,"Từ thông dụng (common word)",10]
    ;
    for ([_][]const u8{ "N1", "N2", "N3", "N4", "N5" }) |level| {
        json = json ++ ",[\"" ++ level ++ "\",\"frequent\",-5,\"JLPT " ++ level ++ "\",0]";
    }
    for (kanji_stats, 1..) |stat, order| {
        json = json ++ std.fmt.comptimePrint(",[\"{s}\",\"misc\",{d},\"{s}\",0]", .{ stat.key, order, stat.label });
    }
    break :blk json ++ "]";
};

// ---------------------------------------------------------------- tests

test "refuses to export a database with no words" {
    const db = try Db.open(":memory:", .read_write_create);
    defer db.close();
    try db.exec(@embedFile("schema.sql"));
    try db.exec("INSERT INTO entry (ent_seq) VALUES (1); INSERT INTO reading_form (ent_seq, position, text) VALUES (1, 0, 'ああ');");
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.NoWords, write(std.testing.allocator, db, &out.writer));
}

test "Yomitan index and tag bank are valid JSON" {
    const gpa = std.testing.allocator;
    const index = try std.json.parseFromSlice(std.json.Value, gpa, index_json, .{});
    defer index.deinit();
    try std.testing.expectEqual(3, index.value.object.get("format").?.integer);
    try std.testing.expectEqualStrings(revision, index.value.object.get("revision").?.string);
    const tags = try std.json.parseFromSlice(std.json.Value, gpa, tag_bank, .{});
    defer tags.deinit();
    try std.testing.expectEqual(1 + 5 + kanji_stats.len, tags.value.array.items.len);
}

test "Yomitan inflection rules follow the term's ending" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var jw: Stringify = .{ .writer = &out.writer };
    try jw.beginArray();
    try writeRules(&jw, .{ .vs = true }, "勉強");
    try writeRules(&jw, .{ .vs = true }, "勉強する");
    try writeRules(&jw, .{ .v1 = true, .vk = true }, "来る");
    try jw.endArray();
    try std.testing.expectEqualStrings("[\"\",\"vs\",\"v1 vk\"]", out.written());
}

test "writes the Yomitan dictionary" {
    const db = try entries.testDatabase();
    defer db.close();
    const gpa = std.testing.allocator;
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const stats = try write(gpa, db, &out.writer);
    const t = std.testing;
    try t.expectEqual(3, stats.words);
    // ああ; 甲/こう, 乙/こう, 乙/おつ (おつ is restricted to 乙); 食べる/たべる, 喰べる/たべる
    try t.expectEqual(6, stats.terms);
    try t.expectEqual(2, stats.pitches);
    try t.expectEqual(1, stats.kanji);
    const bytes = out.written();
    for ([_][]const u8{ "index.json", "tag_bank_1.json", "term_bank_1.json", "term_meta_bank_1.json", "kanji_bank_1.json" }) |name| {
        try t.expect(std.mem.indexOf(u8, bytes, name) != null);
    }
}

test "renders Yomitan entries" {
    const db = try entries.testDatabase();
    defer db.close();
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try entries.Reader.init(gpa, db);
    defer r.deinit();
    _ = try r.nextWord(a);
    _ = try r.nextWord(a);
    const taberu = (try r.nextWord(a)).?;

    const content = try renderWordContent(a, taberu);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, content, .{});
    const t = std.testing;
    try t.expectEqual(4, parsed.array.items.len); // word types, Vietnamese, label, English
    try t.expect(std.mem.indexOf(u8, content, "{\"tag\":\"div\",\"lang\":\"vi\",\"data\":{\"content\":\"vietnamese\"},\"content\":[\"ăn; xơi nhé.\",") != null);
    try t.expect(std.mem.indexOf(u8, content, "\"to live on; to subsist on\"") != null);

    const rules = inflectionRules(taberu);
    try t.expect(rules.v1 and !rules.v5);

    var out: Writer.Allocating = .init(a);
    var jw: Stringify = .{ .writer = &out.writer };
    try addKanji(a, &jw, (try r.nextKanji(a)).?);
    const kanji = try std.json.parseFromSliceLeaky(std.json.Value, a, out.written(), .{});
    try t.expectEqualStrings("ショク ジキ", kanji.array.items[1].string);
    try t.expectEqualStrings("【THỰC】", kanji.array.items[4].array.items[0].string);
    try t.expectEqualStrings("tiểu học lớp 2", kanji.array.items[5].object.get("grade").?.string);
    try t.expectEqualStrings("良 LƯƠNG", kanji.array.items[5].object.get("parts").?.string);
}
