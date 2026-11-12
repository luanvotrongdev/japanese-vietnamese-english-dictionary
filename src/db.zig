//! Thin wrapper over the SQLite C API.

const std = @import("std");
const c = @import("sqlite_c");

pub const Error = error{SqliteError};

pub const Db = struct {
    handle: *c.sqlite3,

    pub const Mode = enum { read_only, read_write, read_write_create };

    pub fn open(path: [:0]const u8, mode: Mode) Error!Db {
        const flags: c_int = switch (mode) {
            .read_only => c.SQLITE_OPEN_READONLY,
            .read_write => c.SQLITE_OPEN_READWRITE,
            .read_write_create => c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
        };
        var handle: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(path.ptr, &handle, flags, null) != c.SQLITE_OK) {
            if (handle) |h| {
                std.log.err("sqlite open {s}: {s}", .{ path, std.mem.span(c.sqlite3_errmsg(h)) });
                _ = c.sqlite3_close(h);
            }
            return error.SqliteError;
        }
        return .{ .handle = handle.? };
    }

    pub fn close(db: Db) void {
        _ = c.sqlite3_close(db.handle);
    }

    /// Runs one or more statements that return no rows.
    pub fn exec(db: Db, sql: [:0]const u8) Error!void {
        var err_msg: [*c]u8 = null;
        if (c.sqlite3_exec(db.handle, sql.ptr, null, null, &err_msg) != c.SQLITE_OK) {
            std.log.err("sqlite: {s}", .{std.mem.span(err_msg)});
            c.sqlite3_free(err_msg);
            return error.SqliteError;
        }
    }

    pub fn prepare(db: Db, sql: []const u8) Error!Stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
            db.logError();
            return error.SqliteError;
        }
        return .{ .handle = stmt.?, .db = db };
    }

    pub fn lastInsertRowId(db: Db) i64 {
        return c.sqlite3_last_insert_rowid(db.handle);
    }

    fn logError(db: Db) void {
        std.log.err("sqlite: {s}", .{std.mem.span(c.sqlite3_errmsg(db.handle))});
    }
};

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,
    db: Db,

    pub fn deinit(s: Stmt) void {
        _ = c.sqlite3_finalize(s.handle);
    }

    /// Binds `args` (a tuple) to parameters 1..n, runs a statement that returns
    /// no rows, then resets it for reuse.
    pub fn run(s: Stmt, args: anytype) Error!void {
        try s.bindAll(args);
        defer s.reset();
        if (c.sqlite3_step(s.handle) != c.SQLITE_DONE) {
            s.db.logError();
            return error.SqliteError;
        }
    }

    /// Binds `args` (a tuple) to parameters 1..n. Text is not copied, so it must
    /// stay alive until the statement has been stepped.
    pub fn bindAll(s: Stmt, args: anytype) Error!void {
        inline for (args, 0..) |arg, i| try s.bind(@intCast(i + 1), arg);
    }

    fn bind(s: Stmt, index: c_int, value: anytype) Error!void {
        const T = @TypeOf(value);
        const rc = switch (@typeInfo(T)) {
            .null => c.sqlite3_bind_null(s.handle, index),
            .optional => if (value) |v| return s.bind(index, v) else c.sqlite3_bind_null(s.handle, index),
            .int, .comptime_int => c.sqlite3_bind_int64(s.handle, index, @intCast(value)),
            .bool => c.sqlite3_bind_int64(s.handle, index, @intFromBool(value)),
            .pointer => blk: {
                const str: []const u8 = value;
                // A null destructor is SQLITE_STATIC: SQLite does not copy the text.
                break :blk c.sqlite3_bind_text(s.handle, index, str.ptr, @intCast(str.len), null);
            },
            else => @compileError("unsupported bind type: " ++ @typeName(T)),
        };
        if (rc != c.SQLITE_OK) {
            s.db.logError();
            return error.SqliteError;
        }
    }

    /// Moves to the next row. Returns false when there are no more rows.
    pub fn step(s: Stmt) Error!bool {
        return switch (c.sqlite3_step(s.handle)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => {
                s.db.logError();
                return error.SqliteError;
            },
        };
    }

    pub fn int(s: Stmt, col: c_int) i64 {
        return c.sqlite3_column_int64(s.handle, col);
    }

    /// Returns null for SQL NULL. The slice is valid until the next step or reset.
    pub fn text(s: Stmt, col: c_int) ?[]const u8 {
        const ptr = c.sqlite3_column_text(s.handle, col);
        if (ptr == null) return null;
        const len = c.sqlite3_column_bytes(s.handle, col);
        return ptr[0..@intCast(len)];
    }

    pub fn reset(s: Stmt) void {
        _ = c.sqlite3_reset(s.handle);
    }
};

test "insert and read back" {
    const db = try Db.open(":memory:", .read_write_create);
    defer db.close();
    try db.exec("CREATE TABLE t (n INTEGER, s TEXT)");

    const insert = try db.prepare("INSERT INTO t (n, s) VALUES (?, ?)");
    defer insert.deinit();
    try insert.run(.{ 1, "日本" });
    try insert.run(.{ 2, @as(?[]const u8, null) });

    const select = try db.prepare("SELECT n, s FROM t ORDER BY n");
    defer select.deinit();
    try std.testing.expect(try select.step());
    try std.testing.expectEqual(1, select.int(0));
    try std.testing.expectEqualStrings("日本", select.text(1).?);
    try std.testing.expect(try select.step());
    try std.testing.expectEqual(null, select.text(1));
    try std.testing.expect(!try select.step());
}
