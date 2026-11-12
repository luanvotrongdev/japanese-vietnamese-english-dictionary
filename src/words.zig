//! Word transform: fills entry fields, senses, glosses, tags, examples,
//! cross-references, relations, pitch accents and reading restrictions from
//! `raw_word_crawl_json`. The rules are in docs/schema.md ("Transform rules").
//! Runs after forms.copy, which creates the entries and forms this step reads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("db.zig").Db;
const Stmt = @import("db.zig").Stmt;
const crawl = @import("crawl.zig");
const forms = @import("forms.zig");
const lang = @import("lang.zig");
const tags = @import("tags.zig");

const Word = crawl.WordBlob;

pub const Stats = struct {
    rows: usize = 0,
    jisho_matched: usize = 0,
    mazii_matched: usize = 0,
    /// Rows whose only Mazii match was a spelling shared with other entries.
    mazii_homographs_skipped: usize = 0,
};

pub fn transform(gpa: Allocator, src: Db, out: Db) !Stats {
    var ctx: Context = .{
        .out = out,
        .st = try Statements.init(out),
        .arena = .init(gpa),
        .unmapped = .init(gpa),
    };
    defer ctx.deinit();

    const rows = try src.prepare(std.fmt.comptimePrint(
        \\SELECT e.ent_seq, w.json
        \\FROM raw_word_crawl_json w JOIN entry e ON e.id = w.entry_id
        \\WHERE e.ent_seq != {d}
        \\ORDER BY e.ent_seq
    , .{forms.metadata_ent_seq}));
    defer rows.deinit();

    while (try rows.step()) {
        defer _ = ctx.arena.reset(.retain_capacity);
        try ctx.row(rows.int(0), rows.text(1) orelse continue);
        ctx.stats.rows += 1;
    }
    ctx.unmapped.report();
    return ctx.stats;
}

const Form = struct {
    id: i64,
    text: []const u8,
};

/// The entry's own spellings and readings, as stored in the output database.
const Forms = struct {
    kanji: []const Form,
    readings: []const Form,

    fn kanjiIndex(f: Forms, text: []const u8) ?usize {
        return indexOf(f.kanji, text);
    }

    fn readingIndex(f: Forms, text: []const u8) ?usize {
        return indexOf(f.readings, text);
    }

    fn has(f: Forms, text: []const u8) bool {
        return f.kanjiIndex(text) != null or f.readingIndex(text) != null;
    }

    fn indexOf(list: []const Form, text: []const u8) ?usize {
        for (list, 0..) |form, i| {
            if (std.mem.eql(u8, form.text, text)) return i;
        }
        return null;
    }
};

const EntryFields = struct {
    is_common: bool = false,
    jlpt: ?i64 = null,
    summary_vi: ?[]const u8 = null,
    mazii_id: ?i64 = null,
};

const Statements = struct {
    kanji_of: Stmt,
    readings_of: Stmt,
    update_entry: Stmt,
    insert_sense: Stmt,
    insert_gloss: Stmt,
    insert_sense_tag: Stmt,
    insert_sense_restriction: Stmt,
    insert_xref: Stmt,
    insert_origin: Stmt,
    insert_example: Stmt,
    insert_relation: Stmt,
    insert_reading_restriction: Stmt,
    set_pitch_accent: Stmt,
    find_by_text: Stmt,
    find_by_kanji_and_reading: Stmt,
    count_kanji_owners: Stmt,
    count_kana_owners: Stmt,

    const sql = .{
        .kanji_of = "SELECT id, text FROM kanji_form WHERE ent_seq = ? ORDER BY position",
        .readings_of = "SELECT id, text FROM reading_form WHERE ent_seq = ? ORDER BY position",
        .update_entry = "UPDATE entry SET is_common = ?, jlpt = ?, summary_vi = ?, mazii_id = ? WHERE ent_seq = ?",
        .insert_sense = "INSERT INTO sense (ent_seq, source, lang, position, info) VALUES (?, ?, ?, ?, ?)",
        .insert_gloss = "INSERT INTO gloss (sense_id, position, text) VALUES (?, ?, ?)",
        .insert_sense_tag = "INSERT OR IGNORE INTO sense_tag (sense_id, tag_code) VALUES (?, ?)",
        .insert_sense_restriction = "INSERT OR IGNORE INTO sense_restriction (sense_id, form_text) VALUES (?, ?)",
        .insert_xref = "INSERT OR IGNORE INTO sense_xref (sense_id, type, target_text, target_ent_seq) VALUES (?, ?, ?, ?)",
        .insert_origin = "INSERT INTO sense_origin (sense_id, position, language, word) VALUES (?, ?, ?, ?)",
        .insert_example = "INSERT INTO example (sense_id, position, ja, reading, translation, lang) VALUES (?, ?, ?, ?, ?, ?)",
        .insert_relation = "INSERT OR IGNORE INTO entry_relation (ent_seq, type, target_text, target_ent_seq) VALUES (?, ?, ?, ?)",
        .insert_reading_restriction = "INSERT OR IGNORE INTO reading_restriction (reading_id, kanji_id) VALUES (?, ?)",
        .set_pitch_accent = "UPDATE reading_form SET pitch_accent = ? WHERE ent_seq = ? AND text = ? AND pitch_accent IS NULL",
        // LIMIT 2 is enough to tell "exactly one entry" from "several".
        .find_by_text = "SELECT ent_seq FROM kanji_form WHERE text = ?1 UNION SELECT ent_seq FROM reading_form WHERE text = ?1 LIMIT 2",
        .find_by_kanji_and_reading =
        \\SELECT DISTINCT k.ent_seq FROM kanji_form k JOIN reading_form r ON r.ent_seq = k.ent_seq
        \\WHERE k.text = ? AND r.text = ? LIMIT 2
        ,
        // How many entries Mazii would merge under one spelling.
        .count_kanji_owners = "SELECT count(DISTINCT ent_seq) FROM kanji_form WHERE text = ?",
        .count_kana_owners =
        \\SELECT count(DISTINCT r.ent_seq) FROM reading_form r
        \\WHERE r.text = ? AND NOT EXISTS (SELECT 1 FROM kanji_form k WHERE k.ent_seq = r.ent_seq)
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
    out: Db,
    st: Statements,
    /// Reset after every row.
    arena: std.heap.ArenaAllocator,
    unmapped: Unmapped,
    stats: Stats = .{},

    fn deinit(ctx: *Context) void {
        ctx.st.deinit();
        ctx.arena.deinit();
        ctx.unmapped.deinit();
    }

    fn row(ctx: *Context, ent_seq: i64, json: []const u8) !void {
        const blob = try std.json.parseFromSliceLeaky(Word, ctx.arena.allocator(), json, crawl.parse_options);
        const f: Forms = .{
            .kanji = try ctx.loadForms(ctx.st.kanji_of, ent_seq),
            .readings = try ctx.loadForms(ctx.st.readings_of, ent_seq),
        };

        var fields: EntryFields = .{};
        if (pickJisho(blob.jisho.data, f)) |result| {
            ctx.stats.jisho_matched += 1;
            try ctx.addJisho(ent_seq, result, f, &fields);
        }
        if (try ctx.pickMazii(blob.mazii.words, f)) |word| {
            ctx.stats.mazii_matched += 1;
            try ctx.addMazii(ent_seq, word, f, &fields);
        }
        try ctx.st.update_entry.run(.{ fields.is_common, fields.jlpt, fields.summary_vi, fields.mazii_id, ent_seq });
    }

    fn loadForms(ctx: *Context, stmt: Stmt, ent_seq: i64) ![]const Form {
        const a = ctx.arena.allocator();
        var list: std.ArrayList(Form) = .empty;
        try stmt.bindAll(.{ent_seq});
        defer stmt.reset();
        while (try stmt.step()) {
            try list.append(a, .{ .id = stmt.int(0), .text = try a.dupe(u8, stmt.text(1).?) });
        }
        return list.items;
    }

    fn addJisho(ctx: *Context, ent_seq: i64, result: *const Word.JishoResult, f: Forms, fields: *EntryFields) !void {
        fields.is_common = result.is_common orelse false;
        fields.jlpt = parseJlpt(result.jlpt);

        var next_jmdict: i64 = 0;
        var next_wikipedia: i64 = 0;
        for (result.senses) |sense| {
            if (!hasText(sense.english_definitions)) continue;
            const is_wiki = containsString(sense.parts_of_speech, tags.wikipedia_pos);
            const source: []const u8 = if (is_wiki) "wikipedia" else "jmdict";
            const position = if (is_wiki) &next_wikipedia else &next_jmdict;
            const info: ?[]const u8 = if (sense.info.len == 0)
                null
            else
                try std.mem.join(ctx.arena.allocator(), "; ", sense.info);

            try ctx.st.insert_sense.run(.{ ent_seq, source, "en", position.*, info });
            position.* += 1;
            const sense_id = ctx.out.lastInsertRowId();
            try ctx.addGlosses(sense_id, sense.english_definitions);

            if (!is_wiki) {
                for (sense.parts_of_speech) |label| try ctx.addJishoTag(sense_id, label);
                for (sense.tags) |label| try ctx.addJishoTag(sense_id, label);
            }
            for (sense.restrictions) |form| try ctx.st.insert_sense_restriction.run(.{ sense_id, form });
            for (sense.see_also) |target| try ctx.addXref(sense_id, "see_also", target);
            for (sense.antonyms) |target| try ctx.addXref(sense_id, "antonym", target);
            for (sense.source, 0..) |origin, i| {
                const code = lang.iso639_2b.get(origin.language) orelse code: {
                    try ctx.unmapped.add("loanword language", origin.language);
                    break :code origin.language;
                };
                try ctx.st.insert_origin.run(.{ sense_id, i, code, stripQuotes(origin.word) });
            }
        }
        try ctx.addReadingRestrictions(result.japanese, f);
    }

    fn addMazii(ctx: *Context, ent_seq: i64, word: *const Word.MaziiWord, f: Forms, fields: *EntryFields) !void {
        fields.summary_vi = nonEmpty(word.short_mean);
        fields.mazii_id = word.mobileId;

        var next_position: i64 = 0;
        for (word.means) |mean| {
            const glosses = try splitGlosses(ctx.arena.allocator(), mean.mean orelse continue);
            if (glosses.len == 0) continue;

            try ctx.st.insert_sense.run(.{ ent_seq, "mazii", "vi", next_position, null });
            next_position += 1;
            const sense_id = ctx.out.lastInsertRowId();
            try ctx.addGlosses(sense_id, glosses);

            // Only code strings carry tags; `false` and Vietnamese label lists are dropped.
            if (mean.kind == .string) {
                var codes = tags.maziiKindCodes(mean.kind.string);
                while (codes.next()) |raw| switch (tags.maziiCode(raw)) {
                    .known => |code| try ctx.st.insert_sense_tag.run(.{ sense_id, code }),
                    .ignored => {},
                    .unknown => try ctx.unmapped.add("mazii code", raw),
                };
            }

            var next_example: i64 = 0;
            for (mean.examples) |example| {
                const ja = nonEmpty(example.content) orelse continue;
                const translation = nonEmpty(example.mean) orelse continue;
                try ctx.st.insert_example.run(.{ sense_id, next_example, ja, nonEmpty(example.transcription), translation, "vi" });
                next_example += 1;
            }
        }

        if (word.pronunciation) |list| {
            for (list) |p| {
                const accent = nonEmpty(p.accent) orelse continue;
                try ctx.st.set_pitch_accent.run(.{ accent, ent_seq, trim(p.kana) });
            }
        }
        if (word.synsets) |synsets| {
            for (synsets) |synset| for (synset.entry) |group| for (group.synonym) |target| {
                try ctx.addRelation(ent_seq, "synonym", target, f);
            };
        }
        if (word.opposite_word) |targets| {
            for (targets) |target| try ctx.addRelation(ent_seq, "antonym", target, f);
        }
    }

    fn addGlosses(ctx: *Context, sense_id: i64, glosses: []const []const u8) !void {
        var position: i64 = 0;
        for (glosses) |raw| {
            const text = trim(raw);
            if (text.len == 0) continue;
            try ctx.st.insert_gloss.run(.{ sense_id, position, text });
            position += 1;
        }
    }

    fn addJishoTag(ctx: *Context, sense_id: i64, label: []const u8) !void {
        if (tags.by_jisho_label.get(label)) |tag| {
            try ctx.st.insert_sense_tag.run(.{ sense_id, tag.code });
        } else {
            try ctx.unmapped.add("jisho label", label);
        }
    }

    fn addXref(ctx: *Context, sense_id: i64, kind: []const u8, raw: []const u8) !void {
        const target = trim(raw);
        if (target.len == 0) return;
        try ctx.st.insert_xref.run(.{ sense_id, kind, target, try ctx.resolve(target) });
    }

    fn addRelation(ctx: *Context, ent_seq: i64, kind: []const u8, raw: []const u8, f: Forms) !void {
        const target = trim(raw);
        if (target.len == 0 or f.has(target)) return;
        try ctx.st.insert_relation.run(.{ ent_seq, kind, target, try ctx.resolve(target) });
    }

    /// Finds the entry a reference points to. References look like "雑煮" or
    /// "雑煮 ぞうに" (spelling, then reading). Null unless exactly one entry matches.
    fn resolve(ctx: *Context, target: []const u8) !?i64 {
        var parts = std.mem.tokenizeScalar(u8, target, ' ');
        const word = parts.next() orelse return null;
        if (parts.next()) |reading| return uniqueEntry(ctx.st.find_by_kanji_and_reading, .{ word, reading });
        return uniqueEntry(ctx.st.find_by_text, .{word});
    }

    /// A reading that Jisho pairs with only some of the entry's kanji forms is
    /// restricted to those (JMdict re_restr). Kanji forms that appear in no pair
    /// are ignored, since Jisho hides some forms entirely.
    fn addReadingRestrictions(ctx: *Context, japanese: []const Word.Japanese, f: Forms) !void {
        if (f.kanji.len < 2 or f.kanji.len > 64) return;

        const paired = try ctx.arena.allocator().alloc(u64, f.readings.len);
        @memset(paired, 0);
        var seen: u64 = 0;
        for (japanese) |pair| {
            const k = f.kanjiIndex(pair.word orelse continue) orelse continue;
            const r = f.readingIndex(pair.reading orelse continue) orelse continue;
            const bit = @as(u64, 1) << @intCast(k);
            seen |= bit;
            paired[r] |= bit;
        }

        for (paired, f.readings) |mask, reading| {
            if (mask == 0 or mask == seen) continue;
            for (f.kanji, 0..) |kanji, k| {
                if (mask & (@as(u64, 1) << @intCast(k)) != 0) {
                    try ctx.st.insert_reading_restriction.run(.{ reading.id, kanji.id });
                }
            }
        }
    }

    /// Picks the Mazii word spelled like the entry, preferring one whose
    /// `phonetic` lists one of the entry's readings.
    ///
    /// Entries with kanji forms must match on a kanji form: a kana-only Mazii
    /// word is almost always a different word with the same reading (火器
    /// "firearm" vs かき "persimmon"). Spellings shared with another entry are
    /// skipped: Mazii merges all readings of a spelling into one word, so its
    /// meanings can't be split between homographs (上手 じょうず / うわて).
    fn pickMazii(ctx: *Context, words: []const Word.MaziiWord, f: Forms) !?*const Word.MaziiWord {
        var first: ?*const Word.MaziiWord = null;
        var skipped_homograph = false;
        for (words) |*word| {
            const spelled_like_entry = if (f.kanji.len > 0)
                f.kanjiIndex(word.word) != null
            else
                f.readingIndex(word.word) != null;
            if (!spelled_like_entry) continue;
            if (try ctx.isHomograph(word.word, f)) {
                skipped_homograph = true;
                continue;
            }
            if (first == null) first = word;
            var tokens = std.mem.tokenizeScalar(u8, word.phonetic orelse continue, ' ');
            while (tokens.next()) |token| {
                if (f.readingIndex(token) != null) return word;
            }
        }
        if (first == null and skipped_homograph) ctx.stats.mazii_homographs_skipped += 1;
        return first;
    }

    /// True when another entry shares this spelling (kanji form for entries
    /// with kanji, reading among kana-only entries otherwise).
    fn isHomograph(ctx: *Context, spelling: []const u8, f: Forms) !bool {
        const stmt = if (f.kanji.len > 0) ctx.st.count_kanji_owners else ctx.st.count_kana_owners;
        try stmt.bindAll(.{spelling});
        defer stmt.reset();
        _ = try stmt.step();
        return stmt.int(0) > 1;
    }
};

/// Picks the JMdict result whose forms overlap the entry's the most.
/// Ties keep Jisho's order. Null when nothing overlaps.
fn pickJisho(results: []const Word.JishoResult, f: Forms) ?*const Word.JishoResult {
    var best: ?*const Word.JishoResult = null;
    var best_score: i64 = 0;
    for (results) |*result| {
        if (!result.attribution.jmdict) continue;
        var score: i64 = 0;
        for (result.japanese) |pair| {
            if (pair.word) |w| score += if (f.has(w)) 1 else -1;
            if (pair.reading) |r| score += if (f.has(r)) 1 else -1;
        }
        if (score > best_score) {
            best = result;
            best_score = score;
        }
    }
    return best;
}

/// "jlpt-n3" -> 3. With several levels, keeps the easiest (largest number).
fn parseJlpt(levels: []const []const u8) ?i64 {
    var best: ?i64 = null;
    for (levels) |level| {
        if (level.len != 7 or !std.mem.startsWith(u8, level, "jlpt-n")) continue;
        if (level[6] < '1' or level[6] > '5') continue;
        const n: i64 = level[6] - '0';
        if (best == null or n > best.?) best = n;
    }
    return best;
}

/// Mazii packs several glosses into one string: "hai mặt; hai phía.".
fn splitGlosses(a: Allocator, mean: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, mean, ';');
    while (parts.next()) |part| {
        const text = dropFinalPeriod(trim(part));
        if (text.len > 0) try list.append(a, text);
    }
    return list.items;
}

/// Mazii often ends a gloss with a stray period ("ăn."). Keeps "v.v." (etc.)
/// and ellipses.
pub fn dropFinalPeriod(s: []const u8) []const u8 {
    if (!std.mem.endsWith(u8, s, ".")) return s;
    if (std.mem.endsWith(u8, s, "v.v.") or std.mem.endsWith(u8, s, "..")) return s;
    return trim(s[0 .. s.len - 1]);
}

/// Jisho wraps loanword origins in curly quotes: "“Holanda”".
fn stripQuotes(word: ?[]const u8) ?[]const u8 {
    var s = nonEmpty(word) orelse return null;
    inline for (.{ "“", "\"" }) |q| {
        if (std.mem.startsWith(u8, s, q)) s = s[q.len..];
    }
    inline for (.{ "”", "\"" }) |q| {
        if (std.mem.endsWith(u8, s, q)) s = s[0 .. s.len - q.len];
    }
    return nonEmpty(s);
}

fn uniqueEntry(stmt: Stmt, args: anytype) !?i64 {
    try stmt.bindAll(args);
    defer stmt.reset();
    if (!try stmt.step()) return null;
    const ent_seq = stmt.int(0);
    if (try stmt.step()) return null;
    return ent_seq;
}

pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

pub fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const t = trim(s orelse return null);
    return if (t.len == 0) null else t;
}

fn hasText(list: []const []const u8) bool {
    for (list) |s| {
        if (trim(s).len > 0) return true;
    }
    return false;
}

fn containsString(list: []const []const u8, s: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, s)) return true;
    }
    return false;
}

/// Labels and codes with no mapping, counted so the tables can be extended.
pub const Unmapped = struct {
    arena: std.heap.ArenaAllocator,
    counts: std.StringArrayHashMapUnmanaged(usize) = .empty,

    pub fn init(gpa: Allocator) Unmapped {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(u: *Unmapped) void {
        u.arena.deinit();
    }

    pub fn add(u: *Unmapped, kind: []const u8, value: []const u8) !void {
        const a = u.arena.allocator();
        const key = try std.fmt.allocPrint(a, "{s}: {s}", .{ kind, value });
        const entry = try u.counts.getOrPut(a, key);
        if (entry.found_existing) a.free(key) else entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }

    pub fn report(u: *Unmapped) void {
        const ByCountDesc = struct {
            values: []const usize,
            pub fn lessThan(s: @This(), a: usize, b: usize) bool {
                return s.values[a] > s.values[b];
            }
        };
        u.counts.sort(ByCountDesc{ .values = u.counts.values() });
        for (u.counts.keys(), u.counts.values()) |key, n| std.log.warn("unmapped {s} ({d}x)", .{ key, n });
    }
};

// ---------------------------------------------------------------- tests

test "parseJlpt keeps the easiest level" {
    try std.testing.expectEqual(3, parseJlpt(&.{ "jlpt-n1", "jlpt-n3" }).?);
    try std.testing.expectEqual(null, parseJlpt(&.{"wanikani5"}));
}

test "splitGlosses and stripQuotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const glosses = try splitGlosses(arena.allocator(), " hai mặt.;  hai phía ; thuận lợi, v.v.;");
    try std.testing.expectEqual(3, glosses.len);
    try std.testing.expectEqualStrings("hai mặt", glosses[0]);
    try std.testing.expectEqualStrings("hai phía", glosses[1]);
    try std.testing.expectEqualStrings("thuận lợi, v.v.", glosses[2]);
    try std.testing.expectEqualStrings("Holanda", stripQuotes("“Holanda”").?);
}

pub fn queryInt(db: Db, sql: []const u8) !i64 {
    const stmt = try db.prepare(sql);
    defer stmt.deinit();
    try std.testing.expect(try stmt.step());
    return stmt.int(0);
}

test "transforms crawl rows" {
    const db = try Db.open(":memory:", .read_write_create);
    defer db.close();
    try db.exec(@embedFile("schema.sql"));
    try tags.seed(db);
    try db.exec(
        \\INSERT INTO entry (ent_seq) VALUES (1), (2), (3), (4), (5);
        \\INSERT INTO kanji_form (ent_seq, position, text) VALUES
        \\  (1, 0, '両面'), (2, 0, '片面'), (3, 0, '甲'), (3, 1, '乙'), (4, 0, '生物'), (5, 0, '生物');
        \\INSERT INTO reading_form (ent_seq, position, text) VALUES
        \\  (1, 0, 'りょうめん'), (2, 0, 'かためん'), (3, 0, 'こう'), (3, 1, 'おつ'), (4, 0, 'せいぶつ'), (5, 0, 'なまもの');
    );

    var ctx: Context = .{
        .out = db,
        .st = try Statements.init(db),
        .arena = .init(std.testing.allocator),
        .unmapped = .init(std.testing.allocator),
    };
    defer ctx.deinit();

    try ctx.row(1,
        \\{"mazii":{"words":[{"word":"両面","phonetic":"りょうめん","short_mean":" hai mặt ","mobileId":42,
        \\  "means":[{"mean":"hai mặt; hai phía","kind":"n, adj-no, bogus","examples":[
        \\    {"content":"紙の両面","mean":"hai mặt giấy","transcription":"かみのりょうめん"},{"content":"không dịch"}]}],
        \\  "opposite_word":["片面"],"pronunciation":[{"kana":"りょうめん","accent":"LHHHH"}]}]},
        \\ "jisho":{"data":[
        \\  {"slug":"x","japanese":[{"word":"両面","reading":"りょうめん"}],"senses":[],"attribution":{"jmdict":false}},
        \\  {"slug":"両面","is_common":true,"jlpt":["jlpt-n1","jlpt-n3"],"japanese":[{"word":"両面","reading":"りょうめん"}],
        \\   "senses":[{"english_definitions":["both sides"],"parts_of_speech":["Noun","Made-up label"],
        \\     "see_also":["片面 かためん"],"source":[{"language":"Dutch; Flemish","word":"“x”"}]},
        \\    {"english_definitions":["Ryomen"],"parts_of_speech":["Wikipedia definition"]}],
        \\   "attribution":{"jmdict":true}}]}}
    );
    // The kana-only Mazii word "こう" must not attach to an entry spelled 甲/乙.
    try ctx.row(3,
        \\{"mazii":{"words":[{"word":"こう","phonetic":"こう","mobileId":7,"means":[{"mean":"như thế này"}]}]},
        \\ "jisho":{"data":[{"slug":"甲","japanese":[{"word":"甲","reading":"こう"},{"word":"乙","reading":"こう"},
        \\  {"word":"甲","reading":"おつ"}],"senses":[{"english_definitions":["A"]}],"attribution":{"jmdict":true}}]}}
    );
    try std.testing.expectEqual(0, try queryInt(db, "SELECT count(*) FROM sense WHERE ent_seq = 3 AND source = 'mazii'"));

    // 生物 belongs to two entries, so Mazii's merged meanings are skipped.
    try ctx.row(4,
        \\{"mazii":{"words":[{"word":"生物","phonetic":"なまもの せいぶつ","mobileId":9,
        \\  "means":[{"mean":"đồ ăn sống"},{"mean":"sinh vật"}]}]}}
    );
    try std.testing.expectEqual(0, try queryInt(db, "SELECT count(*) FROM sense WHERE ent_seq = 4"));
    try std.testing.expectEqual(1, ctx.stats.mazii_homographs_skipped);

    const t = std.testing;
    try t.expectEqual(1, try queryInt(db, "SELECT is_common FROM entry WHERE ent_seq = 1"));
    try t.expectEqual(3, try queryInt(db, "SELECT jlpt FROM entry WHERE ent_seq = 1"));
    try t.expectEqual(42, try queryInt(db, "SELECT mazii_id FROM entry WHERE ent_seq = 1"));
    try t.expectEqual(1, try queryInt(db, "SELECT count(*) FROM entry WHERE ent_seq = 1 AND summary_vi = 'hai mặt'"));
    try t.expectEqual(3, try queryInt(db, "SELECT count(*) FROM sense WHERE ent_seq = 1"));
    try t.expectEqual(1, try queryInt(db, "SELECT count(*) FROM sense WHERE ent_seq = 1 AND source = 'wikipedia'"));
    try t.expectEqual(2, try queryInt(db, "SELECT count(*) FROM gloss JOIN sense ON sense.id = sense_id WHERE source = 'mazii'"));
    try t.expectEqual(3, try queryInt(db, "SELECT count(*) FROM sense_tag")); // jmdict n + mazii n, adj-no
    try t.expectEqual(1, try queryInt(db, "SELECT count(*) FROM example"));
    try t.expectEqual(2, try queryInt(db, "SELECT target_ent_seq FROM sense_xref"));
    try t.expectEqual(2, try queryInt(db, "SELECT target_ent_seq FROM entry_relation WHERE type = 'antonym'"));
    try t.expectEqual(1, try queryInt(db, "SELECT count(*) FROM sense_origin WHERE language = 'dut' AND word = 'x'"));
    try t.expectEqual(1, try queryInt(db, "SELECT count(*) FROM reading_form WHERE pitch_accent = 'LHHHH'"));
    try t.expect(ctx.unmapped.counts.contains("jisho label: Made-up label"));
    try t.expect(ctx.unmapped.counts.contains("mazii code: bogus"));

    // おつ pairs only with 甲, so it is restricted to 甲; こう pairs with both.
    try t.expectEqual(1, try queryInt(db,
        \\SELECT count(*) FROM reading_restriction rr
        \\JOIN reading_form r ON r.id = rr.reading_id JOIN kanji_form k ON k.id = rr.kanji_id
        \\WHERE r.text = 'おつ' AND k.text = '甲'
    ));
    try t.expectEqual(1, try queryInt(db, "SELECT count(*) FROM reading_restriction"));
}
