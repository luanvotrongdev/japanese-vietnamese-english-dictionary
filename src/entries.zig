//! Reads dictionary entries from the standardized database (`build` output)
//! into the shape the Kobo and Yomitan exporters render. Port of the old Bun
//! exporter's entries.ts, which read the raw crawl JSON instead.
//!
//! Text is used as stored: cleanup belongs in the transform (docs/known-issues.md).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("db.zig").Db;
const Stmt = @import("db.zig").Stmt;

pub const max_examples_per_sense = 2;
pub const max_kanji_examples = 4;

pub const Reading = struct {
    text: []const u8,
    /// Downstep position from Mazii's accent string: 0 = heiban.
    pitch: ?u8,
    /// Kanji forms this reading applies to (indexes into `Word.kanji`). Empty = all.
    kanji: []const usize,

    pub fn appliesTo(r: Reading, kanji_index: usize) bool {
        if (r.kanji.len == 0) return true;
        return std.mem.indexOfScalar(usize, r.kanji, kanji_index) != null;
    }
};

pub const Example = struct {
    japanese: []const u8,
    vietnamese: []const u8,
};

pub const VietnameseSense = struct {
    glosses: []const []const u8,
    examples: []const Example,
};

pub const EnglishSense = struct {
    /// English labels of the part-of-speech tags.
    parts_of_speech: []const []const u8,
    glosses: []const []const u8,
    /// Labels of the other tags (usage, field, dialect), then Jisho's info.
    notes: []const []const u8,
};

pub const Word = struct {
    ent_seq: i64,
    kanji: []const []const u8,
    readings: []const Reading,
    is_common: bool,
    jlpt: ?u8,
    /// Vietnamese labels for the Mazii senses' tags, in first-seen order.
    word_types: []const []const u8,
    /// Every JMdict tag code on the entry's senses (both sources), for
    /// Yomitan's inflection rules.
    tag_codes: []const []const u8,
    vietnamese: []const VietnameseSense,
    english: []const EnglishSense,

    /// First kanji form, else first reading.
    pub fn headword(w: Word) []const u8 {
        return if (w.kanji.len > 0) w.kanji[0] else w.readings[0].text;
    }

    /// Readings shown next to the headword (all but the headword itself).
    pub fn shownReadings(w: Word) []const Reading {
        return if (w.kanji.len > 0) w.readings else w.readings[1..];
    }

    /// Pitch accent of the first reading.
    pub fn pitch(w: Word) ?u8 {
        return w.readings[0].pitch;
    }

    pub fn hasTag(w: Word, code: []const u8) bool {
        for (w.tag_codes) |c| if (std.mem.eql(u8, c, code)) return true;
        return false;
    }
};

pub const KanjiExample = struct {
    word: []const u8,
    reading: ?[]const u8,
    han_viet: ?[]const u8,
    meaning: []const u8,
};

pub const Component = struct {
    kanji: []const u8,
    han_viet: ?[]const u8,
};

pub const Kanji = struct {
    literal: []const u8,
    han_viet: ?[]const u8,
    /// Mazii explanations, one per paragraph.
    vietnamese: []const []const u8,
    /// Jisho meanings.
    english: []const []const u8,
    onyomi: []const []const u8,
    kunyomi: []const []const u8,
    jlpt: ?u8,
    strokes: ?i64,
    grade: ?i64,
    freq_rank: ?i64,
    radical: ?[]const u8,
    radical_meaning: ?[]const u8,
    components: []const Component,
    mnemonic: ?[]const u8,
    examples: []const KanjiExample,
};

/// Mazii accent strings look like "LHL-L": one L/H per mora, then the
/// particle after a dash. Returns the downstep: 0 = heiban, n = drop after mora n.
pub fn pitchAccentNumber(accent: []const u8) ?u8 {
    var parts = std.mem.splitScalar(u8, accent, '-');
    const word = parts.first();
    const particle = parts.next() orelse "";
    if (word.len == 0 or word.len > 255) return null;
    for (word) |c| if (c != 'L' and c != 'H') return null;
    if (word[0] == 'H') return if (word.len > 1 and word[1] == 'H') null else 1;
    const last_high = std.mem.lastIndexOfScalar(u8, word, 'H') orelse
        return if (std.mem.eql(u8, particle, "H")) 0 else null; // one-mora heiban: "L-H"
    if (last_high == word.len - 1 and !std.mem.eql(u8, particle, "L")) return 0;
    return @intCast(last_high + 1);
}

/// JMdict tag code -> Vietnamese label, for the word-type line above the
/// Vietnamese senses.
pub fn vietnameseLabel(code: []const u8) ?[]const u8 {
    if (vi_labels.get(code)) |label| return label;
    if (std.mem.startsWith(u8, code, "v5")) return "động từ nhóm 1";
    if (std.mem.startsWith(u8, code, "v2") or std.mem.startsWith(u8, code, "v4")) return "động từ cổ";
    return null;
}

const vi_labels = std.StaticStringMap([]const u8).initComptime(.{
    .{ "n", "danh từ" },
    .{ "n-adv", "danh từ làm phó từ" },
    .{ "n-t", "danh từ chỉ thời gian" },
    .{ "n-suf", "hậu tố danh từ" },
    .{ "n-pref", "tiền tố danh từ" },
    .{ "n-pr", "danh từ riêng" },
    .{ "vs", "danh từ + する" },
    .{ "vs-i", "động từ nhóm 3" },
    .{ "vs-s", "động từ nhóm 3" },
    .{ "vs-c", "động từ nhóm 3" },
    .{ "vk", "động từ nhóm 3" },
    .{ "vz", "động từ nhóm 3" },
    .{ "vn", "động từ bất quy tắc" },
    .{ "v1", "động từ nhóm 2" },
    .{ "v1-s", "động từ nhóm 2" },
    .{ "aux-v", "trợ động từ" },
    .{ "vt", "tha động từ" },
    .{ "vi", "tự động từ" },
    .{ "adj-i", "tính từ đuôi い" },
    .{ "adj-ix", "tính từ đuôi い" },
    .{ "adj-na", "tính từ đuôi な" },
    .{ "adj-no", "danh từ + の" },
    .{ "adj-pn", "liên thể từ" },
    .{ "adj-t", "tính từ đuôi たる" },
    .{ "adj-f", "định ngữ" },
    .{ "aux-adj", "tính từ phụ trợ" },
    .{ "adj-ku", "tính từ cổ" },
    .{ "adj-nari", "tính từ cổ" },
    .{ "adj-shiku", "tính từ cổ" },
    .{ "adv", "phó từ" },
    .{ "adv-to", "phó từ đuôi と" },
    .{ "exp", "cụm từ" },
    .{ "id", "thành ngữ" },
    .{ "int", "thán từ" },
    .{ "conj", "liên từ" },
    .{ "prt", "trợ từ" },
    .{ "aux", "trợ từ" },
    .{ "cop", "hệ từ" },
    .{ "pn", "đại từ" },
    .{ "num", "số từ" },
    .{ "ctr", "trợ số từ" },
    .{ "pref", "tiền tố" },
    .{ "suf", "hậu tố" },
    .{ "abbr", "viết tắt" },
    .{ "uk", "thường viết bằng kana" },
    .{ "sl", "tiếng lóng" },
    .{ "col", "khẩu ngữ" },
    .{ "fam", "thân mật" },
    .{ "hon", "tôn kính ngữ" },
    .{ "hum", "khiêm nhường ngữ" },
    .{ "pol", "lịch sự" },
    .{ "derog", "miệt thị" },
    .{ "arch", "cổ ngữ" },
    .{ "obs", "lỗi thời" },
    .{ "gramm", "ngữ pháp" },
    .{ "ksb", "phương ngữ Kansai" },
    .{ "osb", "phương ngữ Osaka" },
    .{ "on-mim", "từ tượng thanh" },
    .{ "yoji", "thành ngữ bốn chữ" },
    .{ "proverb", "tục ngữ" },
});

const Tag = struct {
    label: []const u8,
    is_pos: bool,
};

/// Streams words and kanji from an open output database.
pub const Reader = struct {
    gpa: Allocator,
    /// Labels and preloaded lookups; lives as long as the reader.
    arena: std.heap.ArenaAllocator,
    tags: std.StringHashMapUnmanaged(Tag) = .empty,
    /// sense id -> examples, preloaded: `example` has no index on sense_id.
    examples: std.AutoHashMapUnmanaged(i64, std.ArrayList(Example)) = .empty,
    /// reading id -> kanji form ids it is restricted to.
    restrictions: std.AutoHashMapUnmanaged(i64, std.ArrayList(i64)) = .empty,

    entries: Stmt,
    kanji_of: Stmt,
    readings_of: Stmt,
    senses_of: Stmt,
    glosses_of: Stmt,
    tags_of: Stmt,
    kanji_rows: Stmt,
    kanji_readings: Stmt,
    kanji_meanings: Stmt,
    kanji_components: Stmt,
    kanji_examples: Stmt,

    pub fn init(gpa: Allocator, db: Db) !Reader {
        var r: Reader = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .entries = try db.prepare("SELECT ent_seq, is_common, jlpt FROM entry ORDER BY ent_seq"),
            .kanji_of = try db.prepare("SELECT id, text FROM kanji_form WHERE ent_seq = ? ORDER BY position"),
            .readings_of = try db.prepare("SELECT id, text, pitch_accent FROM reading_form WHERE ent_seq = ? ORDER BY position"),
            // Wikipedia senses only repeat the headword in English.
            .senses_of = try db.prepare(
                \\SELECT id, source, info FROM sense
                \\WHERE ent_seq = ? AND source IN ('mazii', 'jmdict') ORDER BY source DESC, position
            ),
            .glosses_of = try db.prepare("SELECT text FROM gloss WHERE sense_id = ? ORDER BY position"),
            .tags_of = try db.prepare("SELECT tag_code FROM sense_tag WHERE sense_id = ? ORDER BY rowid"),
            .kanji_rows = try db.prepare(
                \\SELECT k.literal, k.han_viet, k.jlpt, k.stroke_count, k.grade, k.freq_rank,
                \\       k.radical, r.meaning_en, k.mnemonic_vi
                \\FROM kanji k LEFT JOIN radical r ON r.symbol = k.radical ORDER BY k.rowid
            ),
            .kanji_readings = try db.prepare("SELECT type, text FROM kanji_reading WHERE literal = ? ORDER BY type, position"),
            .kanji_meanings = try db.prepare("SELECT lang, text FROM kanji_meaning WHERE literal = ? ORDER BY lang, position"),
            .kanji_components = try db.prepare("SELECT component, han_viet FROM kanji_component WHERE literal = ?1 AND component != ?1 ORDER BY position"),
            // Mazii's general example list first, then its on/kun examples.
            .kanji_examples = try db.prepare(std.fmt.comptimePrint(
                \\SELECT word, reading, han_viet, meaning FROM kanji_example
                \\WHERE literal = ? AND lang = 'vi' ORDER BY reading_type IS NOT NULL, id LIMIT {d}
            , .{max_kanji_examples})),
        };
        errdefer r.deinit();
        try r.preload(db);
        return r;
    }

    pub fn deinit(r: *Reader) void {
        inline for (.{
            "entries",        "kanji_of",         "readings_of",    "senses_of",
            "glosses_of",     "tags_of",          "kanji_rows",     "kanji_readings",
            "kanji_meanings", "kanji_components", "kanji_examples",
        }) |name| @field(r, name).deinit();
        r.arena.deinit();
    }

    fn preload(r: *Reader, db: Db) !void {
        const a = r.arena.allocator();

        const tags = try db.prepare("SELECT code, label_en, category FROM tag");
        defer tags.deinit();
        while (try tags.step()) {
            try r.tags.put(a, try a.dupe(u8, tags.text(0).?), .{
                .label = try a.dupe(u8, tags.text(1).?),
                .is_pos = std.mem.eql(u8, tags.text(2).?, "pos"),
            });
        }

        const examples = try db.prepare("SELECT sense_id, ja, translation FROM example ORDER BY sense_id, position");
        defer examples.deinit();
        while (try examples.step()) {
            const list = try r.examples.getOrPut(a, examples.int(0));
            if (!list.found_existing) list.value_ptr.* = .empty;
            if (list.value_ptr.items.len == max_examples_per_sense) continue;
            try list.value_ptr.append(a, .{
                .japanese = try a.dupe(u8, examples.text(1).?),
                .vietnamese = try a.dupe(u8, examples.text(2).?),
            });
        }

        const restrictions = try db.prepare("SELECT reading_id, kanji_id FROM reading_restriction");
        defer restrictions.deinit();
        while (try restrictions.step()) {
            const list = try r.restrictions.getOrPut(a, restrictions.int(0));
            if (!list.found_existing) list.value_ptr.* = .empty;
            try list.value_ptr.append(a, restrictions.int(1));
        }
    }

    /// Next word with at least one Vietnamese or English sense, allocated in
    /// `a`. Null when there are no more entries.
    pub fn nextWord(r: *Reader, a: Allocator) !?Word {
        while (try r.entries.step()) {
            const ent_seq = r.entries.int(0);
            const jlpt = r.entries.int(2);
            if (try r.loadWord(a, ent_seq, r.entries.int(1) != 0, if (jlpt == 0) null else @intCast(jlpt))) |w| return w;
        }
        return null;
    }

    fn loadWord(r: *Reader, a: Allocator, ent_seq: i64, is_common: bool, jlpt: ?u8) !?Word {
        var kanji: std.ArrayList([]const u8) = .empty;
        var kanji_ids: std.ArrayList(i64) = .empty;
        {
            const s = r.kanji_of;
            try s.bindAll(.{ent_seq});
            defer s.reset();
            while (try s.step()) {
                try kanji_ids.append(a, s.int(0));
                try kanji.append(a, try a.dupe(u8, s.text(1).?));
            }
        }

        var readings: std.ArrayList(Reading) = .empty;
        {
            const s = r.readings_of;
            try s.bindAll(.{ent_seq});
            defer s.reset();
            while (try s.step()) {
                var allowed: std.ArrayList(usize) = .empty;
                if (r.restrictions.get(s.int(0))) |ids| {
                    for (ids.items) |id| {
                        if (std.mem.indexOfScalar(i64, kanji_ids.items, id)) |i| try allowed.append(a, i);
                    }
                }
                try readings.append(a, .{
                    .text = try a.dupe(u8, s.text(1).?),
                    .pitch = if (s.text(2)) |accent| pitchAccentNumber(accent) else null,
                    .kanji = allowed.items,
                });
            }
        }
        if (readings.items.len == 0) return null;

        const Sense = struct { id: i64, mazii: bool, info: ?[]const u8 };
        var senses: std.ArrayList(Sense) = .empty;
        {
            const s = r.senses_of;
            try s.bindAll(.{ent_seq});
            defer s.reset();
            while (try s.step()) {
                try senses.append(a, .{
                    .id = s.int(0),
                    .mazii = std.mem.eql(u8, s.text(1).?, "mazii"),
                    .info = if (s.text(2)) |t| try a.dupe(u8, t) else null,
                });
            }
        }

        var vietnamese: std.ArrayList(VietnameseSense) = .empty;
        var english: std.ArrayList(EnglishSense) = .empty;
        var word_types: std.ArrayList([]const u8) = .empty;
        var tag_codes: std.ArrayList([]const u8) = .empty;
        for (senses.items) |sense| {
            const glosses = try r.loadGlosses(a, sense.id);
            if (glosses.len == 0) continue;

            var pos: std.ArrayList([]const u8) = .empty;
            var notes: std.ArrayList([]const u8) = .empty;
            const s = r.tags_of;
            try s.bindAll(.{sense.id});
            defer s.reset();
            while (try s.step()) {
                const code = s.text(0).?;
                const tag = r.tags.getEntry(code) orelse continue;
                const stored_code = tag.key_ptr.*; // lives as long as the reader
                if (!containsString(tag_codes.items, stored_code)) try tag_codes.append(a, stored_code);
                if (sense.mazii) {
                    if (vietnameseLabel(stored_code)) |label| {
                        if (!containsString(word_types.items, label)) try word_types.append(a, label);
                    }
                } else if (tag.value_ptr.is_pos) {
                    try pos.append(a, tag.value_ptr.label);
                } else {
                    try notes.append(a, tag.value_ptr.label);
                }
            }

            if (sense.mazii) {
                const examples: []const Example = if (r.examples.get(sense.id)) |list| list.items else &.{};
                try vietnamese.append(a, .{ .glosses = glosses, .examples = examples });
            } else {
                if (sense.info) |info| try notes.append(a, info);
                try english.append(a, .{ .parts_of_speech = pos.items, .glosses = glosses, .notes = notes.items });
            }
        }
        if (vietnamese.items.len == 0 and english.items.len == 0) return null;

        return .{
            .ent_seq = ent_seq,
            .kanji = kanji.items,
            .readings = readings.items,
            .is_common = is_common,
            .jlpt = jlpt,
            .word_types = word_types.items,
            .tag_codes = tag_codes.items,
            .vietnamese = vietnamese.items,
            .english = english.items,
        };
    }

    fn loadGlosses(r: *Reader, a: Allocator, sense_id: i64) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        const s = r.glosses_of;
        try s.bindAll(.{sense_id});
        defer s.reset();
        while (try s.step()) try list.append(a, try a.dupe(u8, s.text(0).?));
        return list.items;
    }

    /// Next kanji with a Hán Việt reading or a meaning, allocated in `a`.
    pub fn nextKanji(r: *Reader, a: Allocator) !?Kanji {
        const s = r.kanji_rows;
        while (try s.step()) {
            const literal = try a.dupe(u8, s.text(0).?);
            var k: Kanji = .{
                .literal = literal,
                .han_viet = try dupeOpt(a, s.text(1)),
                .jlpt = if (s.text(2) == null) null else @intCast(s.int(2)),
                .strokes = if (s.text(3) == null) null else s.int(3),
                .grade = if (s.text(4) == null) null else s.int(4),
                .freq_rank = if (s.text(5) == null) null else s.int(5),
                .radical = try dupeOpt(a, s.text(6)),
                .radical_meaning = try dupeOpt(a, s.text(7)),
                .mnemonic = try dupeOpt(a, s.text(8)),
                .vietnamese = &.{},
                .english = &.{},
                .onyomi = &.{},
                .kunyomi = &.{},
                .components = &.{},
                .examples = &.{},
            };

            var on: std.ArrayList([]const u8) = .empty;
            var kun: std.ArrayList([]const u8) = .empty;
            try forEachPair(r.kanji_readings, literal, a, &on, &kun, "on");
            k.onyomi = on.items;
            k.kunyomi = kun.items;

            var vi: std.ArrayList([]const u8) = .empty;
            var en: std.ArrayList([]const u8) = .empty;
            try forEachPair(r.kanji_meanings, literal, a, &vi, &en, "vi");
            k.vietnamese = vi.items;
            k.english = en.items;

            var components: std.ArrayList(Component) = .empty;
            {
                const c = r.kanji_components;
                try c.bindAll(.{literal});
                defer c.reset();
                while (try c.step()) try components.append(a, .{
                    .kanji = try a.dupe(u8, c.text(0).?),
                    .han_viet = try dupeOpt(a, c.text(1)),
                });
            }
            k.components = components.items;

            var examples: std.ArrayList(KanjiExample) = .empty;
            {
                const e = r.kanji_examples;
                try e.bindAll(.{literal});
                defer e.reset();
                while (try e.step()) try examples.append(a, .{
                    .word = try a.dupe(u8, e.text(0).?),
                    .reading = try dupeOpt(a, e.text(1)),
                    .han_viet = try dupeOpt(a, e.text(2)),
                    .meaning = try a.dupe(u8, e.text(3).?),
                });
            }
            k.examples = examples.items;

            if (k.han_viet != null or k.vietnamese.len > 0 or k.english.len > 0) return k;
        }
        return null;
    }
};

/// Runs a `SELECT kind, text ... WHERE literal = ?` statement and sorts the
/// texts into `first` (kind == first_kind) or `second`.
fn forEachPair(s: Stmt, literal: []const u8, a: Allocator, first: *std.ArrayList([]const u8), second: *std.ArrayList([]const u8), first_kind: []const u8) !void {
    try s.bindAll(.{literal});
    defer s.reset();
    while (try s.step()) {
        const list = if (std.mem.eql(u8, s.text(0).?, first_kind)) first else second;
        try list.append(a, try a.dupe(u8, s.text(1).?));
    }
}

fn dupeOpt(a: Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |t| try a.dupe(u8, t) else null;
}

fn containsString(list: []const []const u8, s: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, s)) return true;
    return false;
}

// ---------------------------------------------------------------- tests

/// A small output database for exporter tests: 食べる (Vietnamese and
/// English senses, pitch, two spellings), a kana-only word with a restricted
/// reading elsewhere, an entry with no senses, and the kanji 食.
pub fn testDatabase() !Db {
    const tags = @import("tags.zig");
    const db = try Db.open(":memory:", .read_write_create);
    errdefer db.close();
    try db.exec(@embedFile("schema.sql"));
    try tags.seed(db);
    try db.exec(
        \\INSERT INTO entry (ent_seq, is_common, jlpt) VALUES (1358280, 1, 5), (1000320, 0, NULL), (2000000, 0, NULL), (1000330, 0, NULL);
        \\INSERT INTO kanji_form (id, ent_seq, position, text) VALUES (1, 1358280, 0, '食べる'), (2, 1358280, 1, '喰べる'),
        \\  (3, 1000330, 0, '甲'), (4, 1000330, 1, '乙');
        \\INSERT INTO reading_form (id, ent_seq, position, text, pitch_accent) VALUES
        \\  (1, 1358280, 0, 'たべる', 'LHL-L'), (2, 1000320, 0, 'ああ', NULL), (3, 2000000, 0, 'なし', NULL),
        \\  (4, 1000330, 0, 'こう', NULL), (5, 1000330, 1, 'おつ', NULL);
        \\INSERT INTO reading_restriction (reading_id, kanji_id) VALUES (5, 4);
        \\INSERT INTO sense (id, ent_seq, source, lang, position, info) VALUES
        \\  (1, 1358280, 'jmdict', 'en', 0, NULL), (2, 1358280, 'jmdict', 'en', 1, 'colloquial'),
        \\  (3, 1358280, 'mazii', 'vi', 0, NULL), (4, 1358280, 'wikipedia', 'en', 0, NULL),
        \\  (5, 1000320, 'jmdict', 'en', 0, NULL), (6, 1000330, 'jmdict', 'en', 0, NULL);
        \\INSERT INTO gloss (sense_id, position, text) VALUES (1, 0, 'to eat'), (2, 0, 'to live on'), (2, 1, 'to subsist on'),
        \\  (3, 0, 'ăn'), (4, 0, 'Taberu'), (5, 0, 'like that'), (6, 0, 'A <B> & C');
        \\INSERT INTO sense_tag (sense_id, tag_code) VALUES (1, 'v1'), (1, 'vt'), (2, 'v1'), (2, 'col'), (3, 'v1'), (3, 'vt'),
        \\  (5, 'adv'), (6, 'n');
        \\INSERT INTO example (sense_id, position, ja, translation, lang) VALUES
        \\  (3, 0, '食べるな。', 'Cấm ăn.', 'vi'), (3, 1, 'もっと食べて。', 'Ăn thêm đi.', 'vi'), (3, 2, '三つ目', 'bị bỏ', 'vi');
        \\INSERT INTO radical (symbol, meaning_en) VALUES ('食', 'eat, food');
        \\INSERT INTO kanji (literal, stroke_count, grade, jlpt, freq_rank, han_viet, radical, mnemonic_vi) VALUES
        \\  ('食', 9, 2, 5, 328, 'THỰC', '食', 'Cái làm tôi thấy tốt ở nhà là ăn'), ('乙', NULL, NULL, NULL, NULL, NULL, NULL, NULL);
        \\INSERT INTO kanji_reading (literal, type, position, text) VALUES
        \\  ('食', 'on', 0, 'ショク'), ('食', 'on', 1, 'ジキ'), ('食', 'kun', 0, 'く.う'), ('食', 'kun', 1, 'た.べる');
        \\INSERT INTO kanji_meaning (literal, lang, position, text) VALUES
        \\  ('食', 'vi', 0, 'Đồ để ăn.'), ('食', 'vi', 1, 'Ăn.'), ('食', 'en', 0, 'eat'), ('食', 'en', 1, 'food');
        \\INSERT INTO kanji_component (literal, position, component, han_viet) VALUES ('食', 0, '良', 'LƯƠNG'), ('食', 1, '食', 'THỰC');
        \\INSERT INTO kanji_example (literal, reading_type, word, reading, meaning, han_viet, lang) VALUES
        \\  ('食', 'on', '食事', 'しょくじ', 'bữa ăn', 'THỰC SỰ', 'vi'), ('食', NULL, '食う', 'くう', 'ăn', 'THỰC', 'vi');
    );
    return db;
}

test "pitchAccentNumber" {
    try std.testing.expectEqual(1, pitchAccentNumber("HLL-L").?);
    try std.testing.expectEqual(2, pitchAccentNumber("LHL-L").?);
    try std.testing.expectEqual(0, pitchAccentNumber("LHH-H").?);
    try std.testing.expectEqual(3, pitchAccentNumber("LHH-L").?);
    try std.testing.expectEqual(0, pitchAccentNumber("L-H").?);
    try std.testing.expectEqual(null, pitchAccentNumber("HH"));
    try std.testing.expectEqual(null, pitchAccentNumber("x"));
}

test "reads words and kanji" {
    const db = try testDatabase();
    defer db.close();
    var r = try Reader.init(std.testing.allocator, db);
    defer r.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = std.testing;

    const aa = (try r.nextWord(a)).?;
    try t.expectEqualStrings("ああ", aa.headword());
    try t.expectEqual(0, aa.shownReadings().len);

    const kou = (try r.nextWord(a)).?;
    try t.expectEqualStrings("甲", kou.headword());
    try t.expect(kou.readings[0].appliesTo(0));
    try t.expect(!kou.readings[1].appliesTo(0));
    try t.expect(kou.readings[1].appliesTo(1));

    const taberu = (try r.nextWord(a)).?;
    try t.expectEqual(1358280, taberu.ent_seq);
    try t.expectEqualStrings("食べる", taberu.headword());
    try t.expectEqual(2, taberu.pitch().?);
    try t.expectEqual(5, taberu.jlpt.?);
    try t.expectEqual(1, taberu.vietnamese.len);
    try t.expectEqual(2, taberu.vietnamese[0].examples.len);
    try t.expectEqual(2, taberu.english.len); // the Wikipedia sense is left out
    try t.expectEqualStrings("Ichidan verb", taberu.english[0].parts_of_speech[0]);
    try t.expectEqualStrings("colloquial", taberu.english[1].notes[1]);
    try t.expectEqualStrings("động từ nhóm 2", taberu.word_types[0]);
    try t.expectEqualStrings("tha động từ", taberu.word_types[1]);
    try t.expect(taberu.hasTag("v1"));
    try t.expectEqual(null, try r.nextWord(a)); // なし has no senses

    const shoku = (try r.nextKanji(a)).?;
    try t.expectEqualStrings("THỰC", shoku.han_viet.?);
    try t.expectEqual(2, shoku.onyomi.len);
    try t.expectEqualStrings("た.べる", shoku.kunyomi[1]);
    try t.expectEqual(2, shoku.vietnamese.len);
    try t.expectEqualStrings("food", shoku.english[1]);
    try t.expectEqual(1, shoku.components.len); // the kanji itself is dropped
    try t.expectEqualStrings("食う", shoku.examples[0].word); // general examples first
    try t.expectEqual(null, try r.nextKanji(a)); // 乙 has nothing to show
}
