//! Fills the gaps in the crawl cache: fetches Mazii and Jisho data for entries
//! that have no `raw_word_crawl_json` row and for kanji that have no
//! `raw_kanji_crawl_json` row. Rows that already exist are never touched.
//!
//! This is a port of the old Bun crawler (`old_crawler/src/crawl.ts`), and it
//! stores blobs in the same shape:
//!   word:  {"type":"phrase","mazii":<Mazii `data`>,"jisho":<Jisho API body>}
//!   kanji: {"type":"kanji","mazii":<Mazii `results`>,"jisho":<scraped page>}
//! Each row is committed on its own, so the run can be stopped at any time and
//! started again later.

const std = @import("std");
const Db = @import("db.zig").Db;

const mazii_word_url = "https://mazii.net/api/search/word";
const mazii_kanji_url = "https://mazii.net/api/search/kanji";
const jisho_api_url = "https://jisho.org/api/v1/search/words?keyword=";
const jisho_scrape_url = "https://jisho.org/search/";
const user_agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36";

/// JMdict's metadata entry, not a word. The transform skips it too.
const metadata_ent_seq = 9999999;

pub const Options = struct {
    /// Stop after this many new rows (words and kanji together).
    limit: ?usize = null,
    /// Random pause before each item, in milliseconds.
    min_sleep_ms: u32 = 500,
    max_sleep_ms: u32 = 1500,
    /// Random pause before the first retry of a failed item, in milliseconds.
    /// It doubles with each further attempt.
    min_retry_ms: u32 = 10_000,
    max_retry_ms: u32 = 30_000,
    /// Give up after this many failed attempts on one item (about 40 minutes
    /// of waiting with the defaults).
    max_attempts: u32 = 8,
    /// Only report what is missing; make no requests.
    dry_run: bool = false,
};

pub const Stats = struct {
    kanji_missing: usize = 0,
    kanji_crawled: usize = 0,
    words_missing: usize = 0,
    words_crawled: usize = 0,
};

const Word = struct { entry_id: i64, text: []const u8 };

pub fn run(io: std.Io, gpa: std.mem.Allocator, db: Db, options: Options) !Stats {
    var list_arena = std.heap.ArenaAllocator.init(gpa);
    defer list_arena.deinit();

    const kanji = try missingKanji(list_arena.allocator(), db);
    const words = try missingWords(list_arena.allocator(), db);
    var stats: Stats = .{ .kanji_missing = kanji.len, .words_missing = words.len };
    std.log.info("uncrawled: {d} kanji, {d} entries", .{ kanji.len, words.len });
    if (options.dry_run) return stats;

    var crawler: Crawler = .{
        .io = io,
        .client = .{ .allocator = gpa, .io = io },
        .options = options,
    };
    defer crawler.client.deinit();

    const insert_kanji = try db.prepare("INSERT INTO raw_kanji_crawl_json (textId, json) VALUES (?, ?)");
    defer insert_kanji.deinit();
    const insert_word = try db.prepare("INSERT INTO raw_word_crawl_json (entry_id, json) VALUES (?, ?)");
    defer insert_word.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var remaining: usize = options.limit orelse std.math.maxInt(usize);

    for (kanji, 1..) |char, n| {
        if (remaining == 0) return stats;
        defer _ = arena.reset(.retain_capacity);
        const json = try crawler.withRetry(arena.allocator(), .kanji, char);
        try insert_kanji.run(.{ char, json });
        stats.kanji_crawled += 1;
        remaining -= 1;
        std.log.info("kanji {d}/{d} {s}", .{ n, kanji.len, char });
    }

    for (words, 1..) |word, n| {
        if (remaining == 0) return stats;
        defer _ = arena.reset(.retain_capacity);
        const json = try crawler.withRetry(arena.allocator(), .word, word.text);
        try insert_word.run(.{ word.entry_id, json });
        stats.words_crawled += 1;
        remaining -= 1;
        std.log.info("entry {d}/{d} id {d} {s}", .{ n, words.len, word.entry_id, word.text });
    }
    return stats;
}

/// Entries with no crawl row, each with the text to search for: the first
/// kanji spelling, or the first reading when the entry has no kanji spelling.
fn missingWords(arena: std.mem.Allocator, db: Db) ![]const Word {
    const stmt = try db.prepare(
        \\SELECT entry_id, text FROM (
        \\  SELECT entry_id, keb AS text, 0 AS kind, position FROM k_ele
        \\  UNION ALL
        \\  SELECT entry_id, reb, 1, position FROM r_ele
        \\)
        \\WHERE entry_id NOT IN (SELECT entry_id FROM raw_word_crawl_json)
        \\  AND entry_id NOT IN (SELECT id FROM entry WHERE ent_seq = ?)
        \\ORDER BY entry_id, kind, position
    );
    defer stmt.deinit();
    try stmt.bindAll(.{metadata_ent_seq});

    var words: std.ArrayList(Word) = .empty;
    var last_id: ?i64 = null;
    while (try stmt.step()) {
        const id = stmt.int(0);
        if (last_id == id) continue;
        last_id = id;
        try words.append(arena, .{ .entry_id = id, .text = try arena.dupe(u8, stmt.text(1) orelse continue) });
    }
    return words.items;
}

/// Kanji used in any spelling that have no crawl row, in code point order.
fn missingKanji(arena: std.mem.Allocator, db: Db) ![]const []const u8 {
    var have: std.StringHashMapUnmanaged(void) = .empty;
    {
        const stmt = try db.prepare("SELECT textId FROM raw_kanji_crawl_json WHERE textId IS NOT NULL");
        defer stmt.deinit();
        while (try stmt.step()) try have.put(arena, try arena.dupe(u8, stmt.text(0).?), {});
    }

    var missing: std.ArrayList([]const u8) = .empty;
    const stmt = try db.prepare("SELECT keb FROM k_ele");
    defer stmt.deinit();
    while (try stmt.step()) {
        const keb = stmt.text(0) orelse continue;
        var it = (std.unicode.Utf8View.init(keb) catch continue).iterator();
        while (it.nextCodepointSlice()) |char| {
            if (!isKanji(std.unicode.utf8Decode(char) catch continue)) continue;
            const gop = try have.getOrPut(arena, char);
            if (gop.found_existing) continue;
            gop.key_ptr.* = try arena.dupe(u8, char);
            try missing.append(arena, gop.key_ptr.*);
        }
    }
    std.mem.sort([]const u8, missing.items, {}, lessThanBytes);
    return missing.items;
}

fn lessThanBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Same ranges as the old crawler: CJK Unified Ideographs and extensions A-F.
fn isKanji(cp: u21) bool {
    return (cp >= 0x4e00 and cp <= 0x9fff) or
        (cp >= 0x3400 and cp <= 0x4dbf) or
        (cp >= 0x20000 and cp <= 0x2a6df) or
        (cp >= 0x2a700 and cp <= 0x2ebef);
}

const Crawler = struct {
    io: std.Io,
    client: std.http.Client,
    options: Options,

    const Kind = enum { word, kanji };

    /// Returns the blob to store. Network and response-shape errors are retried
    /// after a pause; the error is returned once `max_attempts` is used up.
    fn withRetry(c: *Crawler, arena: std.mem.Allocator, kind: Kind, text: []const u8) ![]const u8 {
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            try c.sleepBetween(c.options.min_sleep_ms, c.options.max_sleep_ms);
            const result = switch (kind) {
                .word => c.crawlWord(arena, text),
                .kanji => c.crawlKanji(arena, text),
            };
            if (result) |json| return json else |err| {
                if (err == error.OutOfMemory or err == error.Canceled) return err;
                std.log.warn("{s} {s}: {s} (attempt {d}/{d})", .{
                    @tagName(kind), text, @errorName(err), attempt, c.options.max_attempts,
                });
                if (attempt >= c.options.max_attempts) return err;
                // Start the next attempt with a fresh client. A long-running one
                // has been seen to fail every request until the process restarted.
                const gpa = c.client.allocator;
                c.client.deinit();
                c.client = .{ .allocator = gpa, .io = c.io };
                // Double the pause each time, so a short outage is waited out.
                const factor = @as(u32, 1) << @intCast(@min(attempt - 1, 10));
                try c.sleepBetween(c.options.min_retry_ms *| factor, c.options.max_retry_ms *| factor);
            }
        }
    }

    fn sleepBetween(c: *Crawler, min_ms: u32, max_ms: u32) !void {
        var bytes: [4]u8 = undefined;
        c.io.random(&bytes);
        const span = @as(u64, max_ms -| min_ms) + 1;
        const ms = min_ms + std.mem.readInt(u32, &bytes, .little) % span;
        if (ms > 0) try c.io.sleep(.fromMilliseconds(@intCast(ms)), .awake);
    }

    fn crawlWord(c: *Crawler, arena: std.mem.Allocator, word: []const u8) ![]const u8 {
        const jisho_body = try c.get(arena, try std.fmt.allocPrint(arena, "{s}{f}", .{ jisho_api_url, uriComponent(word) }));
        const jisho = try parseJson(arena, jisho_body);
        if (jisho != .object or jisho.object.get("data") == null) return error.UnexpectedJishoResponse;

        const mazii = try c.maziiSearch(arena, mazii_word_url, "word", word, 10);
        const data = mazii.get("data") orelse return error.UnexpectedMaziiResponse;
        if (data != .object or !isArray(data.object.get("words")) or !isArray(data.object.get("suggestWords")))
            return error.UnexpectedMaziiResponse;

        var out: std.Io.Writer.Allocating = .init(arena);
        var js: std.json.Stringify = .{ .writer = &out.writer };
        try js.beginObject();
        try js.objectField("type");
        try js.write("phrase");
        try js.objectField("mazii");
        try js.write(data);
        try js.objectField("jisho");
        try js.write(jisho);
        try js.endObject();
        return out.written();
    }

    fn crawlKanji(c: *Crawler, arena: std.mem.Allocator, kanji: []const u8) ![]const u8 {
        const uri = try std.fmt.allocPrint(arena, "{s}{f}%23kanji", .{ jisho_scrape_url, uriComponent(kanji) });
        const html = try c.get(arena, uri);

        const mazii = try c.maziiSearch(arena, mazii_kanji_url, "kanji", kanji, 1);
        const results = mazii.get("results") orelse return error.UnexpectedMaziiResponse;
        if (results != .array or mazii.get("total") == null) return error.UnexpectedMaziiResponse;

        var out: std.Io.Writer.Allocating = .init(arena);
        var js: std.json.Stringify = .{ .writer = &out.writer };
        try js.beginObject();
        try js.objectField("type");
        try js.write("kanji");
        try js.objectField("mazii");
        try js.write(results);
        try js.objectField("jisho");
        try writeKanjiPage(arena, &js, html, kanji, uri);
        try js.endObject();
        return out.written();
    }

    /// POSTs a Mazii search and returns the response object after checking `status`.
    fn maziiSearch(
        c: *Crawler,
        arena: std.mem.Allocator,
        url: []const u8,
        kind: []const u8,
        query: []const u8,
        limit: u32,
    ) !std.json.ObjectMap {
        const payload = try std.json.Stringify.valueAlloc(arena, .{
            .dict = "javi",
            .type = kind,
            .query = query,
            .limit = limit,
            .page = 1,
        }, .{});
        const body = try c.fetch(arena, url, payload);
        const root = try parseJson(arena, body);
        if (root != .object or root.object.get("status") == null) return error.UnexpectedMaziiResponse;
        return root.object;
    }

    fn get(c: *Crawler, arena: std.mem.Allocator, url: []const u8) ![]const u8 {
        return c.fetch(arena, url, null);
    }

    fn fetch(c: *Crawler, arena: std.mem.Allocator, url: []const u8, payload: ?[]const u8) ![]const u8 {
        var body: std.Io.Writer.Allocating = .init(arena);
        const result = c.client.fetch(.{
            .location = .{ .url = url },
            .payload = payload,
            .response_writer = &body.writer,
            // One connection per request: items are seconds apart, and a pooled
            // connection the server has closed fails the next request.
            .keep_alive = false,
            .headers = .{
                .user_agent = .{ .override = user_agent },
                .content_type = if (payload != null) .{ .override = "application/json" } else .default,
            },
        }) catch |err| {
            std.log.warn("{s}: {s}", .{ url, @errorName(err) });
            return err;
        };
        if (result.status != .ok) {
            std.log.warn("{s}: HTTP {d}", .{ url, @intFromEnum(result.status) });
            return error.HttpStatus;
        }
        return body.written();
    }
};

fn parseJson(arena: std.mem.Allocator, text: []const u8) !std.json.Value {
    // Numbers are kept as their source text, so they are stored unchanged.
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{ .parse_numbers = false });
}

fn isArray(value: ?std.json.Value) bool {
    return if (value) |v| v == .array else false;
}

/// Formats text the way JavaScript's `encodeURIComponent` does.
fn uriComponent(text: []const u8) std.fmt.Alt([]const u8, writeUriComponent) {
    return .{ .data = text };
}

fn writeUriComponent(text: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-_.!~*'()", byte) != null) {
            try w.writeByte(byte);
        } else {
            try w.print("%{X:0>2}", .{byte});
        }
    }
}

// --- Jisho kanji page -------------------------------------------------------
// Jisho has no kanji API. This reads the same fields from the search page as
// the `unofficial-jisho-api` package the old crawler used, with the same keys
// in the same order. Fields the page lacks are left out.

fn writeKanjiPage(
    arena: std.mem.Allocator,
    js: *std.json.Stringify,
    html: []const u8,
    kanji: []const u8,
    uri: []const u8,
) !void {
    try js.beginObject();
    try js.objectField("query");
    try js.write(kanji);

    const glyph = try std.fmt.allocPrint(arena, "<h1 class=\"character\" data-area-name=\"print\" lang=\"ja\">{s}</h1>", .{kanji});
    const found = std.mem.indexOf(u8, html, glyph) != null;
    try js.objectField("found");
    try js.write(found);
    if (!found) return js.endObject();

    if (between(html, "taught in <strong>", "</strong>")) |v| {
        try js.objectField("taughtIn");
        try js.write(v);
    }
    if (between(html, "JLPT level <strong>", "</strong>")) |v| {
        try js.objectField("jlptLevel");
        try js.write(v);
    }
    if (between(html, "<div class=\"frequency\">", "</div>")) |section| {
        if (between(section, "<strong>", "</strong>")) |v| {
            try js.objectField("newspaperFrequencyRank");
            try js.write(v);
        }
    }
    if (strokeCount(html)) |n| {
        try js.objectField("strokeCount");
        try js.write(n);
    }

    try js.objectField("meaning");
    const meaning = between(html, "<div class=\"kanji-details__main-meanings\">", "</div>") orelse "";
    try js.write(try decodeEntities(arena, trim(try removeNewlines(arena, meaning))));

    try js.objectField("kunyomi");
    try js.write(try anchors(arena, between(html, "<dt>Kun:</dt>", "</dl>") orelse ""));
    try js.objectField("onyomi");
    try js.write(try anchors(arena, between(html, "<dt>On:</dt>", "</dl>") orelse ""));
    try js.objectField("onyomiExamples");
    try js.write(try yomiExamples(arena, html, "<h2>On reading compounds</h2>"));
    try js.objectField("kunyomiExamples");
    try js.write(try yomiExamples(arena, html, "<h2>Kun reading compounds</h2>"));

    if (try radical(arena, html)) |r| {
        try js.objectField("radical");
        try js.beginObject();
        try js.objectField("symbol");
        try js.write(r.symbol);
        if (r.forms) |forms| {
            try js.objectField("forms");
            try js.write(forms);
        }
        try js.objectField("meaning");
        try js.write(r.meaning);
        try js.endObject();
    }

    const parts = try anchors(arena, between(html, "<dt>Parts:</dt>", "</dl>") orelse "");
    std.mem.sort([]const u8, parts, {}, lessThanBytes);
    try js.objectField("parts");
    try js.write(parts);

    // The old crawler built these two from JavaScript's charCodeAt(0) and
    // codePointAt(0): the first UTF-16 unit in decimal, and the code point in hex.
    const cp = try std.unicode.utf8Decode(kanji);
    const first_unit: u21 = if (cp >= 0x10000) 0xd800 + ((cp - 0x10000) >> 10) else cp;
    try js.objectField("strokeOrderDiagramUri");
    try js.print("\"http://classic.jisho.org/static/images/stroke_diagrams/{d}_frames.png\"", .{first_unit});
    if (svgUri(html)) |svg| {
        try js.objectField("strokeOrderSvgUri");
        try js.print("\"https:{s}\"", .{svg});
    }
    try js.objectField("strokeOrderGifUri");
    try js.print("\"https://raw.githubusercontent.com/mistval/kanji_images/master/gifs/{x}.gif\"", .{cp});
    try js.objectField("uri");
    try js.write(uri);
    try js.endObject();
}

const whitespace = " \t\r\n";

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, whitespace);
}

/// The text between the first `start` and the next `end` after it.
fn between(text: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const from = (std.mem.indexOf(u8, text, start) orelse return null) + start.len;
    const len = std.mem.indexOf(u8, text[from..], end) orelse return null;
    return text[from..][0..len];
}

fn removeNewlines(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, text.len);
    var n: usize = 0;
    for (text) |byte| {
        if (byte == '\r' or byte == '\n') continue;
        out[n] = byte;
        n += 1;
    }
    return out[0..n];
}

/// The number in `<strong>N</strong> strokes`.
fn strokeCount(html: []const u8) ?u32 {
    const end = std.mem.indexOf(u8, html, "</strong> strokes") orelse return null;
    const open = "<strong>";
    const start = (std.mem.lastIndexOf(u8, html[0..end], open) orelse return null) + open.len;
    return std.fmt.parseInt(u32, trim(html[start..end]), 10) catch null;
}

/// The text of every `<a href="...">text</a>` in `section`.
fn anchors(arena: std.mem.Allocator, section: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var rest = section;
    while (std.mem.indexOf(u8, rest, "<a href=\"")) |open| {
        rest = rest[open..];
        const text_start = (std.mem.indexOf(u8, rest, "\">") orelse break) + 2;
        const text_len = std.mem.indexOf(u8, rest[text_start..], "</a>") orelse break;
        try list.append(arena, rest[text_start..][0..text_len]);
        rest = rest[text_start + text_len ..];
    }
    return list.items;
}

const YomiExample = struct { example: []const u8, reading: []const u8, meaning: []const u8 };

/// Each `<li>` holds three lines: the word, its reading in 【】, and the meaning.
fn yomiExamples(arena: std.mem.Allocator, html: []const u8, heading: []const u8) ![]const YomiExample {
    const section = between(html, heading, "</ul>") orelse return &.{};
    var list: std.ArrayList(YomiExample) = .empty;
    var rest = section;
    while (between(rest, "<li>", "</li>")) |item| {
        rest = rest[@intFromPtr(item.ptr) - @intFromPtr(rest.ptr) + item.len ..];
        var lines = std.mem.splitScalar(u8, trim(item), '\n');
        const example = trim(lines.next() orelse continue);
        const reading = trim(lines.next() orelse continue);
        const meaning = trim(lines.next() orelse continue);
        try list.append(arena, .{
            .example = example,
            .reading = try removeFirst(arena, try removeFirst(arena, reading, "【"), "】"),
            .meaning = try decodeEntities(arena, meaning),
        });
    }
    return list.items;
}

fn removeFirst(arena: std.mem.Allocator, text: []const u8, needle: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, text, needle) orelse return text;
    return std.mem.concat(arena, u8, &.{ text[0..at], text[at + needle.len ..] });
}

const Radical = struct { symbol: []const u8, forms: ?[]const []const u8, meaning: []const u8 };

/// The page shows the radical as `<span class="radical_meaning">meaning</span> 食 (飠)</span>`.
fn radical(arena: std.mem.Allocator, html: []const u8) !?Radical {
    const open = "<span class=\"radical_meaning\">";
    const close = "</span>";
    const raw_meaning = between(html, open, close) orelse return null;
    const meaning = trim(raw_meaning);
    if (meaning.len == 0) return null;

    const after = html[@intFromPtr(raw_meaning.ptr) - @intFromPtr(html.ptr) + raw_meaning.len + close.len ..];
    const symbols_end = std.mem.indexOf(u8, after, close) orelse return null;
    const symbols = trim(try removeNewlines(arena, after[0..symbols_end]));
    if (symbols.len == 0) return .{ .symbol = symbols, .forms = null, .meaning = meaning };

    const first_len = std.unicode.utf8ByteSequenceLength(symbols[0]) catch 1;
    if (first_len >= symbols.len) return .{ .symbol = symbols, .forms = null, .meaning = meaning };

    const rest = try removeFirst(arena, try removeFirst(arena, symbols[first_len..], "("), ")");
    var forms: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitSequence(u8, trim(rest), ", ");
    while (it.next()) |form| try forms.append(arena, form);
    return .{ .symbol = symbols[0..first_len], .forms = forms.items, .meaning = meaning };
}

/// The first `//<host>.cloudfront.net/<path>.svg` on the page, without the scheme.
fn svgUri(html: []const u8) ?[]const u8 {
    const host = ".cloudfront.net/";
    const at = std.mem.indexOf(u8, html, host) orelse return null;
    const start = std.mem.lastIndexOf(u8, html[0..at], "//") orelse return null;
    const ext = ".svg";
    const end = (std.mem.indexOf(u8, html[at..], ext) orelse return null) + at + ext.len;
    return html[start..end];
}

const named_entities = std.StaticStringMap([]const u8).initComptime(.{
    .{ "amp", "&" },   .{ "lt", "<" },   .{ "gt", ">" },
    .{ "quot", "\"" }, .{ "apos", "'" }, .{ "nbsp", "\u{a0}" },
});

/// Decodes numeric character references and the common named ones. Anything
/// else is kept as written.
fn decodeEntities(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '&') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') decode: {
            const semi = std.mem.indexOfScalarPos(u8, text, i, ';') orelse break :decode;
            const name = text[i + 1 .. semi];
            if (name.len == 0 or name.len > 10) break :decode;
            if (named_entities.get(name)) |replacement| {
                try out.appendSlice(arena, replacement);
            } else if (name[0] == '#' and name.len > 1) {
                const hex = name[1] == 'x' or name[1] == 'X';
                const digits = name[if (hex) 2 else 1..];
                const cp = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch break :decode;
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buf) catch break :decode;
                try out.appendSlice(arena, buf[0..len]);
            } else break :decode;
            i = semi + 1;
            continue;
        }
        try out.append(arena, text[i]);
        i += 1;
    }
    return out.items;
}

// --- Tests ------------------------------------------------------------------

test "uriComponent matches encodeURIComponent" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "%E9%A3%9F%20a-b_c.!~*'()%2F",
        try std.fmt.bufPrint(&buf, "{f}", .{uriComponent("食 a-b_c.!~*'()/")}),
    );
}

test "decodeEntities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "one's \"a\" & <b> é &unknown; & end",
        try decodeEntities(arena.allocator(), "one&#39;s &quot;a&quot; &amp; &lt;b&gt; &#xe9; &unknown; & end"),
    );
}

test "kanji page is scraped into the old crawler's shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html =
        \\<h1 class="character" data-area-name="print" lang="ja">食</h1>
        \\<div class="kanji-details__main-meanings">
        \\  eat, food
        \\</div>
        \\<dl><dt>Kun:</dt><dd><a href="/a">く.う</a>、<a href="/b">た.べる</a></dd></dl>
        \\<dl><dt>On:</dt><dd><a href="/c">ショク</a></dd></dl>
        \\<div class="kanji-details__stroke_count"><strong>9</strong> strokes</div>
        \\<dt>Radical:</dt><dd><span><span class="radical_meaning">
        \\  eat, food
        \\</span>
        \\食 (飠)</span></dd>
        \\<dl><dt>Parts:</dt><dd><a href="/p">食</a><a href="/q">人</a></dd></dl>
        \\<div class="grade">taught in <strong>grade 2</strong></div>
        \\<div class="jlpt">JLPT level <strong>N5</strong></div>
        \\<div class="frequency"><strong>328</strong> of 2500</div>
        \\<img src="//d1w6u4xc3l95km.cloudfront.net/kanji-2015-03/098df.svg">
        \\<h2>On reading compounds</h2><ul class="no-bullet">
        \\<li>
        \\  食堂
        \\  【ジキドウ】
        \\  dining hall &amp; one&#39;s
        \\</li>
        \\</ul>
    ;
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try writeKanjiPage(arena.allocator(), &js, html, "食", "https://jisho.org/search/%E9%A3%9F%23kanji");
    try std.testing.expectEqualStrings(
        \\{"query":"食","found":true,"taughtIn":"grade 2","jlptLevel":"N5","newspaperFrequencyRank":"328","strokeCount":9,"meaning":"eat, food","kunyomi":["く.う","た.べる"],"onyomi":["ショク"],"onyomiExamples":[{"example":"食堂","reading":"ジキドウ","meaning":"dining hall & one's"}],"kunyomiExamples":[],"radical":{"symbol":"食","forms":["飠"],"meaning":"eat, food"},"parts":["人","食"],"strokeOrderDiagramUri":"http://classic.jisho.org/static/images/stroke_diagrams/39135_frames.png","strokeOrderSvgUri":"https://d1w6u4xc3l95km.cloudfront.net/kanji-2015-03/098df.svg","strokeOrderGifUri":"https://raw.githubusercontent.com/mistval/kanji_images/master/gifs/98df.gif","uri":"https://jisho.org/search/%E9%A3%9F%23kanji"}
    , out.written());

    out.clearRetainingCapacity();
    js = .{ .writer = &out.writer };
    try writeKanjiPage(arena.allocator(), &js, "<p>no results</p>", "仝", "u");
    try std.testing.expectEqualStrings("{\"query\":\"仝\",\"found\":false}", out.written());
}

test "missing entries and kanji are found" {
    const db = try Db.open(":memory:", .read_write_create);
    defer db.close();
    try db.exec(
        \\CREATE TABLE entry (id INTEGER PRIMARY KEY, ent_seq INTEGER NOT NULL);
        \\CREATE TABLE k_ele (id INTEGER PRIMARY KEY, entry_id INTEGER, keb TEXT, position INTEGER);
        \\CREATE TABLE r_ele (id INTEGER PRIMARY KEY, entry_id INTEGER, reb TEXT, position INTEGER);
        \\CREATE TABLE raw_word_crawl_json (id INTEGER PRIMARY KEY, entry_id INTEGER, json TEXT);
        \\CREATE TABLE raw_kanji_crawl_json (id INTEGER PRIMARY KEY AUTOINCREMENT, textId TEXT, json TEXT);
        \\INSERT INTO entry VALUES (1, 1000), (2, 1001), (3, 1002), (4, 9999999);
        \\INSERT INTO k_ele (entry_id, keb, position) VALUES (1, '食べる', 0), (2, '喰う', 1), (2, '食う', 0);
        \\INSERT INTO r_ele (entry_id, reb, position) VALUES
        \\  (1, 'たべる', 0), (2, 'くう', 0), (3, 'キャメル', 0), (4, 'ジェイエムディクト', 0);
        \\INSERT INTO raw_word_crawl_json (entry_id, json) VALUES (1, '{}');
        \\INSERT INTO raw_kanji_crawl_json (textId, json) VALUES ('食', '{}');
    );
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const words = try missingWords(arena.allocator(), db);
    try std.testing.expectEqual(2, words.len);
    try std.testing.expectEqual(2, words[0].entry_id);
    try std.testing.expectEqualStrings("食う", words[0].text);
    try std.testing.expectEqualStrings("キャメル", words[1].text);

    const kanji = try missingKanji(arena.allocator(), db);
    try std.testing.expectEqual(1, kanji.len);
    try std.testing.expectEqualStrings("喰", kanji[0]);

    const stats = try run(std.testing.io, std.testing.allocator, db, .{ .dry_run = true });
    try std.testing.expectEqual(2, stats.words_missing);
    try std.testing.expectEqual(1, stats.kanji_missing);
}
