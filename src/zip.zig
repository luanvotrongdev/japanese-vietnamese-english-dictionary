//! Minimal ZIP writer: whole files added one at a time, stored or deflated.
//! No ZIP64, so every file and the archive must stay under 4 GiB.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

pub const Method = enum(u16) { store = 0, deflate = 8 };

const Entry = struct {
    name: []const u8,
    method: Method,
    crc: u32,
    compressed_size: u32,
    size: u32,
    offset: u32,
};

pub const Writer = struct {
    gpa: Allocator,
    out: *std.Io.Writer,
    entries: std.ArrayList(Entry) = .empty,
    offset: u64 = 0,

    pub fn init(gpa: Allocator, out: *std.Io.Writer) Writer {
        return .{ .gpa = gpa, .out = out };
    }

    pub fn deinit(w: *Writer) void {
        for (w.entries.items) |e| w.gpa.free(e.name);
        w.entries.deinit(w.gpa);
    }

    pub fn addFile(w: *Writer, name: []const u8, data: []const u8, method: Method) !void {
        var compressed: ?[]u8 = null;
        defer if (compressed) |c| w.gpa.free(c);
        if (method == .deflate) compressed = try compress(w.gpa, data, .raw);
        const body = compressed orelse data;

        const entry: Entry = .{
            .name = try w.gpa.dupe(u8, name),
            .method = method,
            .crc = std.hash.Crc32.hash(data),
            .compressed_size = try fit32(body.len),
            .size = try fit32(data.len),
            .offset = try fit32(w.offset),
        };
        errdefer w.gpa.free(entry.name);
        try w.entries.append(w.gpa, entry);

        const o = w.out;
        try o.writeInt(u32, 0x04034b50, .little);
        try o.writeInt(u16, 20, .little); // version needed: 2.0
        try o.writeInt(u16, 1 << 11, .little); // flags: names are UTF-8
        try o.writeInt(u16, @intFromEnum(method), .little);
        try o.writeInt(u16, 0, .little); // mod time
        try o.writeInt(u16, dos_date, .little);
        try o.writeInt(u32, entry.crc, .little);
        try o.writeInt(u32, entry.compressed_size, .little);
        try o.writeInt(u32, entry.size, .little);
        try o.writeInt(u16, try fit16(name.len), .little);
        try o.writeInt(u16, 0, .little); // extra length
        try o.writeAll(name);
        try o.writeAll(body);
        w.offset += 30 + name.len + body.len;
    }

    /// Writes the central directory. The caller flushes `out`.
    pub fn finish(w: *Writer) !void {
        const o = w.out;
        const dir_start = w.offset;
        for (w.entries.items) |e| {
            try o.writeInt(u32, 0x02014b50, .little);
            try o.writeInt(u16, 20, .little); // version made by
            try o.writeInt(u16, 20, .little); // version needed
            try o.writeInt(u16, 1 << 11, .little);
            try o.writeInt(u16, @intFromEnum(e.method), .little);
            try o.writeInt(u16, 0, .little);
            try o.writeInt(u16, dos_date, .little);
            try o.writeInt(u32, e.crc, .little);
            try o.writeInt(u32, e.compressed_size, .little);
            try o.writeInt(u32, e.size, .little);
            try o.writeInt(u16, try fit16(e.name.len), .little);
            try o.writeInt(u16, 0, .little); // extra length
            try o.writeInt(u16, 0, .little); // comment length
            try o.writeInt(u16, 0, .little); // disk number
            try o.writeInt(u16, 0, .little); // internal attributes
            try o.writeInt(u32, 0, .little); // external attributes
            try o.writeInt(u32, e.offset, .little);
            try o.writeAll(e.name);
            w.offset += 46 + e.name.len;
        }
        const count = try fit16(w.entries.items.len);
        try o.writeInt(u32, 0x06054b50, .little);
        try o.writeInt(u16, 0, .little); // disk number
        try o.writeInt(u16, 0, .little); // disk with the directory
        try o.writeInt(u16, count, .little);
        try o.writeInt(u16, count, .little);
        try o.writeInt(u32, try fit32(w.offset - dir_start), .little);
        try o.writeInt(u32, try fit32(dir_start), .little);
        try o.writeInt(u16, 0, .little); // comment length
    }
};

/// 2020-01-01: a fixed date keeps the output reproducible.
const dos_date: u16 = ((2020 - 1980) << 9) | (1 << 5) | 1;

fn fit32(n: u64) !u32 {
    return std.math.cast(u32, n) orelse error.ZipTooLarge;
}

fn fit16(n: usize) !u16 {
    return std.math.cast(u16, n) orelse error.ZipTooLarge;
}

/// Deflates `data` (raw for ZIP entries, gzip for Kobo shards). Caller owns the result.
pub fn compress(gpa: Allocator, data: []const u8, container: flate.Container) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, data.len / 3 + 64);
    errdefer out.deinit();

    // The compressor is large (~224 KiB) and must not move after init.
    const c = try gpa.create(flate.Compress);
    defer gpa.destroy(c);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);

    c.* = try flate.Compress.init(&out.writer, window, container, .default);
    try c.writer.writeAll(data);
    try c.finish();
    return out.toOwnedSlice();
}

test "deflate round trip" {
    const gpa = std.testing.allocator;
    const text = "食べる たべる タベル " ** 50;
    const packed_bytes = try compress(gpa, text, .gzip);
    defer gpa.free(packed_bytes);
    try std.testing.expect(packed_bytes.len < text.len);

    var in: std.Io.Reader = .fixed(packed_bytes);
    var window: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&in, .gzip, &window);
    const back = try d.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(text, back);
}

test "writes an archive std.zip can read" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var zip: Writer = .init(gpa, &out.writer);
    defer zip.deinit();
    try zip.addFile("index.json", "{\"title\":\"x\"}", .deflate);
    try zip.addFile("words", "abc", .store);
    try zip.finish();

    const bytes = out.written();
    // std.zip.EndRecord.findBuffer does not compile in 0.16, so read the end record by hand.
    const end = std.mem.lastIndexOf(u8, bytes, "PK\x05\x06").?;
    try std.testing.expectEqual(bytes.len, end + 22);
    try std.testing.expectEqual(2, std.mem.readInt(u16, bytes[end + 10 ..][0..2], .little));
    const dir_offset = std.mem.readInt(u32, bytes[end + 16 ..][0..4], .little);
    try std.testing.expect(std.mem.startsWith(u8, bytes[dir_offset..], "PK\x01\x02"));
    try std.testing.expect(std.mem.startsWith(u8, bytes, "PK\x03\x04"));
}
