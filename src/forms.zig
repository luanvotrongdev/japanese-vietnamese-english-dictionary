//! Copies JMdict entries and their kanji/kana forms, which the source already
//! stores relationally. Re-keys everything from the cache's internal id to ent_seq.

const std = @import("std");
const Db = @import("db.zig").Db;

/// JMdict's last entry ("ＪＭｄｉｃｔ") describes the dictionary itself, not a word.
pub const metadata_ent_seq = 9999999;

pub const Counts = struct {
    entries: usize = 0,
    kanji_forms: usize = 0,
    reading_forms: usize = 0,
};

pub fn copy(src: Db, out: Db) !Counts {
    return .{
        .entries = try copyRows(src, out, std.fmt.comptimePrint(
            \\SELECT ent_seq FROM entry WHERE ent_seq != {d} ORDER BY ent_seq
        , .{metadata_ent_seq}),
            \\INSERT INTO entry (ent_seq) VALUES (?)
        , 1),
        .kanji_forms = try copyRows(src, out, std.fmt.comptimePrint(
            \\SELECT e.ent_seq, k.position, k.keb
            \\FROM k_ele k JOIN entry e ON e.id = k.entry_id
            \\WHERE e.ent_seq != {d}
            \\ORDER BY e.ent_seq, k.position
        , .{metadata_ent_seq}),
            \\INSERT INTO kanji_form (ent_seq, position, text) VALUES (?, ?, ?)
        , 3),
        .reading_forms = try copyRows(src, out, std.fmt.comptimePrint(
            \\SELECT e.ent_seq, r.position, r.reb, r.re_nokanji IS NOT NULL
            \\FROM r_ele r JOIN entry e ON e.id = r.entry_id
            \\WHERE e.ent_seq != {d}
            \\ORDER BY e.ent_seq, r.position
        , .{metadata_ent_seq}),
            \\INSERT INTO reading_form (ent_seq, position, text, no_kanji) VALUES (?, ?, ?, ?)
        , 4),
    };
}

/// Streams rows from `select` into `insert`. Column 2, when present, is text;
/// all other columns are integers.
fn copyRows(src: Db, out: Db, select: []const u8, insert: []const u8, comptime columns: usize) !usize {
    const read = try src.prepare(select);
    defer read.deinit();
    const write = try out.prepare(insert);
    defer write.deinit();

    var n: usize = 0;
    while (try read.step()) : (n += 1) {
        switch (columns) {
            1 => try write.run(.{read.int(0)}),
            3 => try write.run(.{ read.int(0), read.int(1), read.text(2) }),
            4 => try write.run(.{ read.int(0), read.int(1), read.text(2), read.int(3) }),
            else => @compileError("unsupported column count"),
        }
    }
    return n;
}
