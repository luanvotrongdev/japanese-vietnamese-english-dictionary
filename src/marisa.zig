//! Builds marisa tries, the format of a Kobo dictionary's `words` index.
//!
//! A port of the build and write path of marisa-trie 0.2.6
//! (https://github.com/s-yata/marisa-trie, BSD-2-Clause / LGPL-2.1+) with its
//! default config: 3 tries, text tail, weight order, normal cache. That is
//! what dictgen and `marisa-build` produce. Lookup is not ported; the test
//! compares bytes with `marisa-build` output instead.
//!
//! The file layout is the same on 32- and 64-bit readers: bit vectors are
//! padded to 64-bit units, and every integer is little-endian.

const std = @import("std");
const Allocator = std.mem.Allocator;

const num_tries = 3;
const normal_cache = 0x00200; // also the divisor that sizes the cache
const text_tail = 0x01000;
const weight_order = 0x20000;
const invalid_extra: u32 = std.math.maxInt(u32) >> 8;

/// Serializes a trie of `keys`, each with weight 1. Duplicates are allowed.
/// Keys must not be empty or contain NUL bytes (that would need a binary
/// tail, which is not ported). The result is owned by the caller.
pub fn build(gpa: Allocator, keys: []const []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // All keys in one buffer, so a key is a [begin, end) range into it.
    var total: usize = 0;
    for (keys) |k| {
        if (k.len == 0 or std.mem.indexOfScalar(u8, k, 0) != null) return error.UnsupportedKey;
        total += k.len;
    }
    if (total > std.math.maxInt(u32)) return error.TooManyKeys;
    const mem = try arena.alloc(u8, total);
    var list = try std.ArrayList(Key).initCapacity(arena, keys.len);
    var pos: u32 = 0;
    for (keys) |k| {
        @memcpy(mem[pos..][0..k.len], k);
        list.appendAssumeCapacity(.{ .begin = pos, .end = pos + @as(u32, @intCast(k.len)), .weight = 1.0 });
        pos += @intCast(k.len);
    }

    var b: Builder = .{ .a = arena, .mem = mem };
    var top: Trie = .{};
    var terminals: std.ArrayList(u32) = .empty;
    try b.buildTrie(&top, false, &list, &terminals, 1);

    // Mark the nodes where keys end.
    const ends = try arena.dupe(u32, terminals.items);
    std.mem.sortUnstable(u32, ends, {}, std.sort.asc(u32));
    var node: u32 = 0;
    for (ends) |end| {
        while (node < end) : (node += 1) try top.terminal_flags.push(arena, false);
        if (node == end) {
            try top.terminal_flags.push(arena, true);
            node += 1;
        }
    }
    while (node < top.bases.items.len) : (node += 1) try top.terminal_flags.push(arena, false);
    try top.terminal_flags.push(arena, false);
    try top.terminal_flags.build(arena, false, true);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll("We love Marisa.\x00");
    try top.write(&out.writer);
    return out.toOwnedSlice();
}

const Key = struct {
    begin: u32,
    end: u32,
    weight: f32 = 0,
    terminal: u32 = 0,
    id: u32 = 0,

    fn len(k: Key) usize {
        return k.end - k.begin;
    }

    /// Byte `i`, reading forward, or backward from the end for the reversed
    /// keys of the second and later tries.
    fn at(k: Key, comptime reverse: bool, mem: []const u8, i: usize) u8 {
        return if (reverse) mem[k.end - 1 - i] else mem[k.begin + i];
    }

    fn substr(k: Key, comptime reverse: bool, pos: usize, length: usize) Key {
        var r = k;
        if (reverse) {
            r.end = @intCast(k.end - pos);
            r.begin = @intCast(r.end - length);
        } else {
            r.begin = @intCast(k.begin + pos);
            r.end = @intCast(r.begin + length);
        }
        return r;
    }

    fn lessThan(comptime reverse: bool) fn ([]const u8, Key, Key) bool {
        return struct {
            fn lt(mem: []const u8, a: Key, b: Key) bool {
                return order(reverse, mem, a, b) == .lt;
            }
        }.lt;
    }

    fn order(comptime reverse: bool, mem: []const u8, a: Key, b: Key) std.math.Order {
        const n = @min(a.len(), b.len());
        for (0..n) |i| {
            const x = a.at(reverse, mem, i);
            const y = b.at(reverse, mem, i);
            if (x != y) return std.math.order(x, y);
        }
        return std.math.order(a.len(), b.len());
    }
};

const Range = struct {
    begin: u32,
    end: u32,
    key_pos: u32,
};

const WeightedRange = struct {
    range: Range,
    weight: f32,

    fn heavier(_: void, a: WeightedRange, b: WeightedRange) bool {
        return a.weight > b.weight;
    }
};

const Cache = struct {
    parent: u32 = 0,
    child: u32 = 0,
    /// Weight while building; base | extra << 8 afterwards.
    weight: f32 = std.math.floatMin(f32),
    link: u32 = 0,
};

const RankIndex = struct {
    abs: u32 = 0,
    rel_lo: u32 = 0,
    rel_hi: u32 = 0,

    /// Ones counted in the first `k` 64-bit units of this 512-bit block (k = 1..7).
    fn setRel(r: *RankIndex, k: usize, value: usize) void {
        const v: u32 = @intCast(value);
        switch (k) {
            1 => r.rel_lo = (r.rel_lo & ~@as(u32, 0x7F)) | (v & 0x7F),
            2 => r.rel_lo = (r.rel_lo & ~(@as(u32, 0xFF) << 7)) | ((v & 0xFF) << 7),
            3 => r.rel_lo = (r.rel_lo & ~(@as(u32, 0xFF) << 15)) | ((v & 0xFF) << 15),
            4 => r.rel_lo = (r.rel_lo & ~(@as(u32, 0x1FF) << 23)) | ((v & 0x1FF) << 23),
            5 => r.rel_hi = (r.rel_hi & ~@as(u32, 0x1FF)) | (v & 0x1FF),
            6 => r.rel_hi = (r.rel_hi & ~(@as(u32, 0x1FF) << 9)) | ((v & 0x1FF) << 9),
            7 => r.rel_hi = (r.rel_hi & ~(@as(u32, 0x1FF) << 18)) | ((v & 0x1FF) << 18),
            else => unreachable,
        }
    }

    fn rel(r: RankIndex, k: usize) usize {
        return switch (k) {
            0 => 0,
            1 => r.rel_lo & 0x7F,
            2 => (r.rel_lo >> 7) & 0xFF,
            3 => (r.rel_lo >> 15) & 0xFF,
            4 => (r.rel_lo >> 23) & 0x1FF,
            5 => r.rel_hi & 0x1FF,
            6 => (r.rel_hi >> 9) & 0x1FF,
            7 => (r.rel_hi >> 18) & 0x1FF,
            else => unreachable,
        };
    }
};

const BitVector = struct {
    units: std.ArrayList(u64) = .empty,
    size: u32 = 0,
    num_1s: u32 = 0,
    ranks: std.ArrayList(RankIndex) = .empty,
    select0s: std.ArrayList(u32) = .empty,
    select1s: std.ArrayList(u32) = .empty,

    fn push(bv: *BitVector, a: Allocator, bit: bool) !void {
        if (bv.size == 64 * bv.units.items.len) try bv.units.append(a, 0);
        if (bit) {
            bv.units.items[bv.size / 64] |= @as(u64, 1) << @intCast(bv.size % 64);
            bv.num_1s += 1;
        }
        bv.size += 1;
    }

    fn get(bv: BitVector, i: usize) bool {
        return bv.units.items[i / 64] & (@as(u64, 1) << @intCast(i % 64)) != 0;
    }

    fn rank1(bv: BitVector, i: usize) usize {
        const r = bv.ranks.items[i / 512];
        const mask = (@as(u64, 1) << @intCast(i % 64)) - 1;
        return r.abs + r.rel((i / 64) % 8) + @popCount(bv.units.items[i / 64] & mask);
    }

    /// Builds the rank index and, if asked, the select indexes
    /// (BitVector::build_index).
    fn build(bv: *BitVector, a: Allocator, select0: bool, select1: bool) !void {
        const num_bits: usize = bv.size;
        bv.ranks.clearRetainingCapacity();
        bv.select0s.clearRetainingCapacity();
        bv.select1s.clearRetainingCapacity();
        try bv.ranks.appendNTimes(a, .{}, num_bits / 512 + @intFromBool(num_bits % 512 != 0) + 1);

        var num_0s: usize = 0;
        var num_1s: usize = 0;
        for (bv.units.items, 0..) |unit, unit_id| {
            const bit_id = unit_id * 64;
            const r = &bv.ranks.items[bit_id / 512];
            switch ((bit_id / 64) % 8) {
                0 => r.abs = @intCast(num_1s),
                else => |k| r.setRel(k, num_1s - r.abs),
            }

            const unit_1s: usize = @popCount(unit);
            if (select0) {
                const unit_0s = @min(num_bits - bit_id, 64) - unit_1s;
                const zero_bit_id = (~num_0s +% 1) % 512;
                if (unit_0s > zero_bit_id) try bv.select0s.append(a, @intCast(selectBit(zero_bit_id, bit_id, ~unit)));
                num_0s += unit_0s;
            }
            if (select1) {
                const one_bit_id = (~num_1s +% 1) % 512;
                if (unit_1s > one_bit_id) try bv.select1s.append(a, @intCast(selectBit(one_bit_id, bit_id, unit)));
            }
            num_1s += unit_1s;
        }

        if (num_bits % 512 != 0) {
            // The last block's remaining relative counts all equal its total.
            const r = &bv.ranks.items[(num_bits - 1) / 512];
            var k = ((num_bits - 1) / 64) % 8 + 1;
            while (k <= 7) : (k += 1) r.setRel(k, num_1s - r.abs);
        }
        bv.ranks.items[bv.ranks.items.len - 1].abs = @intCast(num_1s);
        if (select0) try bv.select0s.append(a, @intCast(num_bits));
        if (select1) try bv.select1s.append(a, @intCast(num_bits));
    }

    fn write(bv: BitVector, w: *std.Io.Writer) !void {
        try writeVector(w, u64, bv.units.items);
        try w.writeInt(u32, bv.size, .little);
        try w.writeInt(u32, bv.num_1s, .little);
        try writeVector(w, RankIndex, bv.ranks.items);
        try writeVector(w, u32, bv.select0s.items);
        try writeVector(w, u32, bv.select1s.items);
    }
};

/// Position of the `i`-th (0-based) set bit of `unit`, plus `bit_id`.
fn selectBit(i: usize, bit_id: usize, unit: u64) usize {
    var u = unit;
    for (0..i) |_| u &= u - 1;
    return bit_id + @ctz(u);
}

/// Packs values into the fewest bits that fit the largest one.
const FlatVector = struct {
    units: []u64 = &.{},
    value_size: u32 = 0,
    mask: u32 = 0,
    size: u64 = 0,

    fn build(a: Allocator, values: []const u32) !FlatVector {
        var max: u32 = 0;
        for (values) |v| max = @max(max, v);
        const value_size: u32 = 32 - @clz(max);
        var num_units: usize = if (values.len == 0) 0 else 1;
        if (value_size != 0) num_units = (value_size * values.len + 63) / 64;

        var fv: FlatVector = .{
            .units = try a.alloc(u64, num_units),
            .value_size = value_size,
            .mask = if (value_size == 0) 0 else @as(u32, std.math.maxInt(u32)) >> @intCast(32 - value_size),
            .size = values.len,
        };
        @memset(fv.units, 0);
        if (value_size == 0) return fv;
        for (values, 0..) |v, i| {
            const p = i * value_size;
            const offset: u7 = @intCast(p % 64);
            fv.units[p / 64] |= @as(u64, v) << @intCast(offset);
            if (offset + value_size > 64) fv.units[p / 64 + 1] |= @as(u64, v) >> @intCast(64 - offset);
        }
        return fv;
    }

    fn write(fv: FlatVector, w: *std.Io.Writer) !void {
        try writeVector(w, u64, fv.units);
        try w.writeInt(u32, fv.value_size, .little);
        try w.writeInt(u32, fv.mask, .little);
        try w.writeInt(u64, fv.size, .little);
    }
};

/// Vector<T>::write: byte size, the items, then zero padding to 8 bytes.
fn writeVector(w: *std.Io.Writer, comptime T: type, items: []const T) !void {
    const item_size: usize = switch (T) {
        u8 => 1,
        u32 => 4,
        u64 => 8,
        RankIndex, Cache => 12,
        else => @compileError("unsupported vector type"),
    };
    const bytes = items.len * item_size;
    try w.writeInt(u64, bytes, .little);
    for (items) |item| switch (T) {
        u8 => try w.writeByte(item),
        u32, u64 => try w.writeInt(T, item, .little),
        RankIndex => {
            try w.writeInt(u32, item.abs, .little);
            try w.writeInt(u32, item.rel_lo, .little);
            try w.writeInt(u32, item.rel_hi, .little);
        },
        Cache => {
            try w.writeInt(u32, item.parent, .little);
            try w.writeInt(u32, item.child, .little);
            try w.writeInt(u32, item.link, .little);
        },
        else => unreachable,
    };
    try w.splatByteAll(0, (8 - bytes % 8) % 8);
}

/// One level of the nested LOUDS tries (LoudsTrie).
const Trie = struct {
    louds: BitVector = .{},
    terminal_flags: BitVector = .{},
    link_flags: BitVector = .{},
    bases: std.ArrayList(u8) = .empty,
    extras: FlatVector = .{},
    tail: std.ArrayList(u8) = .empty,
    next: ?*Trie = null,
    cache: []Cache = &.{},
    cache_mask: usize = 0,
    num_l1_nodes: usize = 0,
    /// Tries in this level and the levels below it.
    num_tries: u32 = 1,

    fn write(t: Trie, w: *std.Io.Writer) !void {
        try t.louds.write(w);
        try t.terminal_flags.write(w);
        try t.link_flags.write(w);
        try writeVector(w, u8, t.bases.items);
        try t.extras.write(w);
        try writeVector(w, u8, t.tail.items);
        try (BitVector{}).write(w); // tail end flags: only used by binary tails
        if (t.next) |next| try next.write(w);
        try writeVector(w, Cache, t.cache);
        try w.writeInt(u32, @intCast(t.num_l1_nodes), .little);
        try w.writeInt(u32, t.num_tries | text_tail | weight_order, .little);
    }
};

const Builder = struct {
    a: Allocator,
    mem: []const u8,

    /// LoudsTrie::build_trie. `keys` is consumed; `terminals` gets the node
    /// where each key ends, in input order.
    fn buildTrie(b: *Builder, t: *Trie, comptime reverse: bool, keys: *std.ArrayList(Key), terminals: *std.ArrayList(u32), trie_id: u32) Allocator.Error!void {
        try b.buildCurrentTrie(t, reverse, keys, terminals, trie_id);

        var next_terminals: std.ArrayList(u32) = .empty;
        if (keys.items.len > 0) try b.buildNextTrie(t, keys, &next_terminals, trie_id);
        t.num_tries = if (t.next) |next| next.num_tries + 1 else 1;

        // Link nodes point into the next trie or the tail: low byte in
        // `bases`, the rest in `extras`.
        try t.link_flags.build(b.a, false, false);
        var node: usize = 0;
        for (next_terminals.items) |*terminal| {
            while (!t.link_flags.get(node)) node += 1;
            t.bases.items[node] = @truncate(terminal.*);
            terminal.* /= 256;
            node += 1;
        }
        t.extras = try .build(b.a, next_terminals.items);
        fillCache(t, next_terminals.items);
    }

    fn buildCurrentTrie(b: *Builder, t: *Trie, comptime reverse: bool, keys: *std.ArrayList(Key), terminals: *std.ArrayList(u32), trie_id: u32) Allocator.Error!void {
        const a = b.a;
        const mem = b.mem;
        for (keys.items, 0..) |*k, i| k.id = @intCast(i);
        std.mem.sortUnstable(Key, keys.items, mem, Key.lessThan(reverse));
        var num_keys: usize = @intFromBool(keys.items.len > 0);
        for (1..keys.items.len) |i| {
            if (Key.order(reverse, mem, keys.items[i - 1], keys.items[i]) != .eq) num_keys += 1;
        }

        var cache_size: usize = if (trie_id == 1) 256 else 1;
        while (cache_size < num_keys / normal_cache) cache_size *= 2;
        t.cache = try a.alloc(Cache, cache_size);
        @memset(t.cache, .{});
        t.cache_mask = cache_size - 1;

        try t.louds.push(a, true);
        try t.louds.push(a, false);
        try t.bases.append(a, 0);
        try t.link_flags.push(a, false);

        const items = keys.items;
        var next_keys: std.ArrayList(Key) = .empty;
        var queue: std.ArrayList(Range) = .empty;
        var head: usize = 0;
        var w_ranges: std.ArrayList(WeightedRange) = .empty;

        try queue.append(a, .{ .begin = 0, .end = @intCast(items.len), .key_pos = 0 });
        while (head < queue.items.len) {
            const node_id = t.link_flags.size - (queue.items.len - head);
            var range = queue.items[head];
            head += 1;

            while (range.begin < range.end and items[range.begin].len() == range.key_pos) {
                items[range.begin].terminal = @intCast(node_id);
                range.begin += 1;
            }
            if (range.begin == range.end) {
                try t.louds.push(a, false);
                continue;
            }

            // One child per distinct byte at key_pos.
            w_ranges.clearRetainingCapacity();
            var weight: f64 = items[range.begin].weight;
            for (range.begin + 1..range.end) |i| {
                if (items[i - 1].at(reverse, mem, range.key_pos) != items[i].at(reverse, mem, range.key_pos)) {
                    try w_ranges.append(a, .{ .range = .{ .begin = range.begin, .end = @intCast(i), .key_pos = range.key_pos }, .weight = @floatCast(weight) });
                    range.begin = @intCast(i);
                    weight = 0;
                }
                weight += items[i].weight;
            }
            try w_ranges.append(a, .{ .range = range, .weight = @floatCast(weight) });
            std.mem.sort(WeightedRange, w_ranges.items, {}, WeightedRange.heavier); // stable

            if (node_id == 0) t.num_l1_nodes = w_ranges.items.len;

            for (w_ranges.items) |*wr| {
                // Extend the edge while every key in the range agrees.
                const first = items[wr.range.begin];
                var key_pos: usize = wr.range.key_pos + 1;
                extend: while (key_pos < first.len()) : (key_pos += 1) {
                    for (wr.range.begin + 1..wr.range.end) |j| {
                        if (items[j - 1].at(reverse, mem, key_pos) != items[j].at(reverse, mem, key_pos)) break :extend;
                    }
                }
                const label = first.at(reverse, mem, wr.range.key_pos);
                cacheNode(t, reverse, node_id, t.bases.items.len, wr.weight, label);

                if (key_pos == wr.range.key_pos + 1) {
                    try t.bases.append(a, label);
                    try t.link_flags.push(a, false);
                } else {
                    try t.bases.append(a, 0);
                    try t.link_flags.push(a, true);
                    var next_key = first.substr(reverse, wr.range.key_pos, key_pos - wr.range.key_pos);
                    next_key.weight = wr.weight;
                    try next_keys.append(a, next_key);
                }
                wr.range.key_pos = @intCast(key_pos);
                try queue.append(a, wr.range);
                try t.louds.push(a, true);
            }
            try t.louds.push(a, false);
        }
        try t.louds.push(a, false);
        try t.louds.build(a, trie_id == 1, true);

        terminals.clearRetainingCapacity();
        try terminals.resize(a, items.len);
        for (items) |k| terminals.items[k.id] = k.terminal;
        keys.* = next_keys;
    }

    fn buildNextTrie(b: *Builder, t: *Trie, keys: *std.ArrayList(Key), terminals: *std.ArrayList(u32), trie_id: u32) Allocator.Error!void {
        if (trie_id == num_tries) return b.buildTail(t, keys.items, terminals);
        const next = try b.a.create(Trie);
        next.* = .{};
        t.next = next;
        // Later tries store the leftover key parts reversed.
        try b.buildTrie(next, true, keys, terminals, trie_id + 1);
    }

    /// Tail::build_ in text mode: the remaining key parts, NUL-terminated,
    /// sharing storage when one is a suffix of another. `terminals` gets each
    /// part's offset.
    fn buildTail(b: *Builder, t: *Trie, keys: []Key, terminals: *std.ArrayList(u32)) Allocator.Error!void {
        const a = b.a;
        const mem = b.mem;
        for (keys, 0..) |*k, i| k.id = @intCast(i);
        // Entries compare their bytes from the end (a reversed view).
        std.mem.sortUnstable(Key, keys, mem, Key.lessThan(true));

        try terminals.resize(a, keys.len);
        var last: ?Key = null;
        var i = keys.len;
        while (i > 0) {
            i -= 1;
            const current = keys[i];
            var match: usize = 0;
            if (last) |l| {
                while (match < current.len() and match < l.len() and
                    l.at(true, mem, match) == current.at(true, mem, match)) match += 1;
            }
            if (last != null and match == current.len()) {
                terminals.items[current.id] = @intCast(terminals.items[last.?.id] + (last.?.len() - match));
            } else {
                terminals.items[current.id] = @intCast(t.tail.items.len);
                try t.tail.appendSlice(a, mem[current.begin..current.end]);
                try t.tail.append(a, 0);
            }
            last = current;
        }
    }
};

/// LoudsTrie::cache: remembers the heaviest child per cache slot.
fn cacheNode(t: *Trie, comptime reverse: bool, parent: usize, child: usize, weight: f32, label: u8) void {
    const id = if (reverse)
        child & t.cache_mask
    else
        (parent ^ (parent << 5) ^ label) & t.cache_mask;
    const c = &t.cache[id];
    if (weight > c.weight) {
        c.parent = @intCast(parent);
        c.child = @intCast(child);
        c.weight = weight;
    }
}

/// LoudsTrie::fill_cache. `extras` holds the values stored in `t.extras`.
fn fillCache(t: *Trie, extras: []const u32) void {
    for (t.cache) |*c| {
        if (c.child != 0) {
            const extra = if (t.link_flags.get(c.child)) extras[t.link_flags.rank1(c.child)] else invalid_extra;
            c.link = t.bases.items[c.child] | (extra << 8);
        } else {
            c.parent = std.math.maxInt(u32);
            c.child = std.math.maxInt(u32);
            c.link = @bitCast(c.weight);
        }
    }
}

test "matches marisa-build byte for byte" {
    // Expected bytes: `marisa-build` (marisa-trie 0.2.6 defaults) on these keys.
    const expected_hex = @embedFile("testdata/marisa-sample.hex");
    const gpa = std.testing.allocator;
    const expected = try gpa.alloc(u8, expected_hex.len / 2);
    defer gpa.free(expected);
    _ = try std.fmt.hexToBytes(expected, std.mem.trim(u8, expected_hex, "\n"));

    const trie = try build(gpa, &sample_keys);
    defer gpa.free(trie);
    try std.testing.expectEqualSlices(u8, expected, trie);
}

/// Sample keys for the test: shared prefixes and suffixes, kana and kanji,
/// a duplicate, so every trie level and the tail get used.
pub const sample_keys = [_][]const u8{
    "たべる",
    "タベル",
    "食べる",
    "喰べる",
    "たべもの",
    "食べ物",
    "たべすぎる",
    "食べ過ぎる",
    "のむ",
    "ノム",
    "飲む",
    "のみもの",
    "飲み物",
    "cd",
    "cds",
    "abcdefghij",
    "xabcdefghij",
    "yabcdefghij",
    "日本",
    "日本語",
    "にほん",
    "にほんご",
    "ニホン",
    "たべる",
    "a",
    "ab",
    "abc",
    "abcd",
    "abcde",
    "zabcde",
    "qqqqqqqqqqqqqqqqqqqqq",
};
