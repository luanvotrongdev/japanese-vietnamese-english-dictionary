//! Typed views of the crawl JSON blobs in the source database.
//! Only fields the transform uses are declared; everything else is skipped.
//! Run `javi-transform check <input>` after changing these to parse every row.

const std = @import("std");

pub const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .allocate = .alloc_if_needed,
};

/// `raw_word_crawl_json.json`
pub const WordBlob = struct {
    mazii: Mazii = .{},
    jisho: Jisho = .{},

    pub const Mazii = struct {
        words: []const MaziiWord = &.{},
    };

    pub const MaziiWord = struct {
        word: []const u8,
        phonetic: ?[]const u8 = null,
        short_mean: ?[]const u8 = null,
        mobileId: ?i64 = null,
        means: []const Mean = &.{},
        synsets: ?[]const Synset = null,
        opposite_word: ?[]const []const u8 = null,
        pronunciation: ?[]const Pronunciation = null,
    };

    pub const Mean = struct {
        mean: []const u8,
        /// Usually a code string like "n, vs". A few rows hold `false` or a list
        /// of Vietnamese labels such as ["danh từ"].
        kind: std.json.Value = .null,
        examples: []const Example = &.{},
    };

    pub const Example = struct {
        content: []const u8,
        /// Missing in a handful of rows.
        mean: ?[]const u8 = null,
        transcription: ?[]const u8 = null,
    };

    pub const Synset = struct {
        base_form: ?[]const u8 = null,
        pos: ?[]const u8 = null,
        entry: []const SynsetEntry = &.{},
    };

    pub const SynsetEntry = struct {
        synonym: []const []const u8 = &.{},
    };

    pub const Pronunciation = struct {
        kana: []const u8,
        accent: ?[]const u8 = null,
    };

    pub const Jisho = struct {
        data: []const JishoResult = &.{},
    };

    pub const JishoResult = struct {
        slug: []const u8,
        is_common: ?bool = null,
        tags: []const []const u8 = &.{},
        jlpt: []const []const u8 = &.{},
        japanese: []const Japanese = &.{},
        senses: []const Sense = &.{},
        attribution: Attribution = .{},
    };

    pub const Japanese = struct {
        word: ?[]const u8 = null,
        reading: ?[]const u8 = null,
    };

    pub const Sense = struct {
        english_definitions: []const []const u8 = &.{},
        parts_of_speech: []const []const u8 = &.{},
        tags: []const []const u8 = &.{},
        restrictions: []const []const u8 = &.{},
        see_also: []const []const u8 = &.{},
        antonyms: []const []const u8 = &.{},
        source: []const Source = &.{},
        info: []const []const u8 = &.{},
    };

    pub const Source = struct {
        language: []const u8,
        word: ?[]const u8 = null,
    };

    pub const Attribution = struct {
        jmdict: bool = false,
        jmnedict: bool = false,
    };
};

/// `raw_kanji_crawl_json.json`
pub const KanjiBlob = struct {
    mazii: []const MaziiKanji = &.{},
    jisho: Jisho = .{},

    pub const MaziiKanji = struct {
        kanji: []const u8,
        mean: ?[]const u8 = null,
        detail: ?[]const u8 = null,
        kun: ?[]const u8 = null,
        on: ?[]const u8 = null,
        /// Usually a list like ["N2"]; sometimes a string or null.
        level: std.json.Value = .null,
        stroke_count: ?[]const u8 = null,
        freq: ?i64 = null,
        mobileId: ?i64 = null,
        compDetail: ?[]const Component = null,
        examples: ?[]const Example = null,
        /// Reading -> examples. Some rows hold {"vi": null} instead.
        example_on: ?std.json.ArrayHashMap(?[]const ReadingExample) = null,
        example_kun: ?std.json.ArrayHashMap(?[]const ReadingExample) = null,
        tips: ?Tips = null,
    };

    pub const Component = struct {
        w: []const u8,
        h: ?[]const u8 = null,
    };

    pub const Example = struct {
        w: []const u8,
        m: ?[]const u8 = null,
        p: ?[]const u8 = null,
        h: ?[]const u8 = null,
    };

    pub const ReadingExample = struct {
        w: []const u8,
        m: ?[]const u8 = null,
        p: ?[]const u8 = null,
    };

    pub const Tips = struct {
        vi: ?[]const u8 = null,
    };

    pub const Jisho = struct {
        found: bool = false,
        taughtIn: ?[]const u8 = null,
        jlptLevel: ?[]const u8 = null,
        newspaperFrequencyRank: ?[]const u8 = null,
        strokeCount: ?i64 = null,
        meaning: ?[]const u8 = null,
        kunyomi: []const []const u8 = &.{},
        onyomi: []const []const u8 = &.{},
        onyomiExamples: []const JishoExample = &.{},
        kunyomiExamples: []const JishoExample = &.{},
        radical: ?Radical = null,
        parts: []const []const u8 = &.{},
    };

    pub const JishoExample = struct {
        example: []const u8,
        reading: []const u8,
        meaning: []const u8,
    };

    pub const Radical = struct {
        symbol: []const u8,
        meaning: ?[]const u8 = null,
    };
};

test "parses a word blob" {
    const json =
        \\{"type":"phrase","mazii":{"suggestWords":[],"words":[{"_id":"x","word":"仝","phonetic":"どうじょう 仝 どう",
        \\"short_mean":"như đánh dấu ở trên","mobileId":117008,"means":[{"mean":"như đánh dấu ở trên","kind":"n","examples":[]}],
        \\"synsets":null,"opposite_word":null}]},
        \\"jisho":{"meta":{"status":200},"data":[{"slug":"〃","is_common":false,"tags":[],"jlpt":[],
        \\"japanese":[{"word":"〃","reading":"おなじ"}],"senses":[{"english_definitions":["ditto mark"],
        \\"parts_of_speech":["Noun"],"links":[],"tags":[],"restrictions":[],"see_also":[],"antonyms":[],"source":[],"info":[]}],
        \\"attribution":{"jmdict":true,"jmnedict":false,"dbpedia":false}}]}}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const blob = try std.json.parseFromSliceLeaky(WordBlob, arena.allocator(), json, parse_options);

    try std.testing.expectEqualStrings("仝", blob.mazii.words[0].word);
    try std.testing.expectEqualStrings("n", blob.mazii.words[0].means[0].kind.string);
    try std.testing.expect(blob.jisho.data[0].attribution.jmdict);
    try std.testing.expectEqualStrings("ditto mark", blob.jisho.data[0].senses[0].english_definitions[0]);
}

test "parses a kanji blob" {
    const json =
        \\{"type":"kanji","mazii":[{"kanji":"日","mean":"NHẬT","kun":"ひ -び -か","on":"ニチ ジツ","level":["N5"],
        \\"stroke_count":"4","freq":1,"mobileId":1,"compDetail":null,"tips":{"vi":"mặt trời"},
        \\"example_kun":{"ひ":[{"w":"日々","m":"Ngày ngày","p":"ひび"}]}}],
        \\"jisho":{"query":"日","found":true,"strokeCount":4,"kunyomi":["ひ"],"onyomi":["ニチ"],
        \\"radical":{"symbol":"日","meaning":"sun"},"parts":["日"]}}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const blob = try std.json.parseFromSliceLeaky(KanjiBlob, arena.allocator(), json, parse_options);

    const m = blob.mazii[0];
    try std.testing.expectEqualStrings("NHẬT", m.mean.?);
    try std.testing.expectEqualStrings("N5", m.level.array.items[0].string);
    try std.testing.expectEqualStrings("日々", m.example_kun.?.map.get("ひ").?.?[0].w);
    try std.testing.expectEqual(4, blob.jisho.strokeCount.?);
}
