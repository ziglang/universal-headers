//! The purpose of this program is to visualize the include graphs of all the
//! different libcs on top of one another
const std = @import("std");
const arocc = @import("std");

const assert = std.debug.assert;

const HeaderId = u32;
const Include = struct {
    from: HeaderId,
    to: HeaderId,
};

pub const HeaderDb = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    header_ids: std.StringHashMapUnmanaged(HeaderId) = .{},
    headers: std.ArrayListUnmanaged([]const u8) = .{},
    include_counts: std.AutoArrayHashMapUnmanaged(Include, u8) = .{},

    pub fn init(allocator: std.mem.Allocator) HeaderDb {
        return HeaderDb{
            .gpa = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(db: *HeaderDb) void {
        db.header_ids.deinit(db.gpa);
        db.headers.deinit(db.gpa);
        db.include_counts.deinit(db.gpa);
        db.arena.deinit();
    }

    /// this will find you the id for an existing header, or create a new header id
    pub fn getHeaderId(db: *HeaderDb, header: []const u8) !HeaderId {
        return if (db.header_ids.get(header)) |header_id|
            header_id
        else ret: {
            const duped_header = try db.arena.allocator().dupe(u8, header);
            const header_id = @intCast(HeaderId, db.headers.items.len);
            try db.headers.append(db.gpa, duped_header);
            try db.header_ids.put(db.gpa, duped_header, header_id);
            break :ret header_id;
        };
    }

    /// increments the count of includes going from one header to another
    pub fn incrementIncludeCount(
        db: *HeaderDb,
        from: HeaderId,
        to: []const u8,
    ) !void {
        const include = Include{
            .from = from,
            .to = try db.getHeaderId(to),
        };

        if (db.include_counts.getEntry(include)) |entry|
            entry.value_ptr.* += 1
        else
            try db.include_counts.put(db.gpa, include, 1);
    }
};

pub fn addIncludesToDb(
    db: *HeaderDb,
    header_entry: std.fs.IterableDir.Walker.WalkerEntry,
) !void {
    const text = try header_entry.dir.readFileAlloc(db.gpa, header_entry.basename, std.math.maxInt(usize));
    defer db.gpa.free(text);

    const header_id = try db.getHeaderId(header_entry.path);

    // hacky because I'm not familiar with arocc internals, but should work
    // fine for now. One upside of this naive approach is that we get to see
    // all includes, even if they're behind a define
    var line_it = std.mem.tokenize(u8, text, "\n");
    while (line_it.next()) |line| {
        var token_it = std.mem.tokenize(u8, line, " \t\r");
        while (token_it.next()) |token| {
            if (std.mem.eql(u8, "#include", token)) {
                const with_brackets = token_it.next().?;
                const len = with_brackets.len;
                if ((with_brackets[0] == '"' or with_brackets[0] == '<') and
                    (with_brackets[len - 1] == '"' or with_brackets[len - 1] == '>'))
                {
                    const include_path = with_brackets[1 .. len - 1];
                    try db.incrementIncludeCount(header_id, include_path);
                }
            }
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var header_db = HeaderDb.init(gpa.allocator());
    defer header_db.deinit();

    // this program assumes each directory under headers is the root of libc headers
    var header_dir = try std.fs.cwd().openIterableDir("headers", .{});
    defer header_dir.close();

    var dir_it = header_dir.iterate();
    while (try dir_it.next()) |libc_entry| {
        var libc_dir = try header_dir.dir.openIterableDir(libc_entry.name, .{});
        defer libc_dir.close();

        var walker = try libc_dir.walk(gpa.allocator());
        defer walker.deinit();

        while (try walker.next()) |header_entry| {
            if (!std.mem.endsWith(u8, header_entry.basename, ".h"))
                continue;

            try addIncludesToDb(&header_db, header_entry);
        }
    }

    // now let's print out a dot graph
    const stdout = std.io.getStdOut().writer();

    try stdout.writeAll("digraph {\n");

    var it = header_db.include_counts.iterator();
    while (it.next()) |entry| {
        try stdout.print("    \"{s}\" -> \"{s}\" [weight={}]\n", .{
            header_db.headers.items[entry.key_ptr.from],
            header_db.headers.items[entry.key_ptr.to],
            entry.value_ptr.*,
        });
    }

    try stdout.writeAll("}\n");
}
