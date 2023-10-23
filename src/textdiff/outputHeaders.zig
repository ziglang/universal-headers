const std = @import("std");
const reductions = @import("reductions.zig"){};

pub fn main() !void {
    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_allocator.allocator();

    var args = try std.process.argsWithAllocator(arena);

    {
        var i: usize = 0;
        while (args.skip()) {
            i += 1;
        }

        if (i != 2 and i != 3) {
            std.debug.print("usage: outputHeaders <dir> [version]\n", .{});
            std.debug.print("takes headers from uh_workspace and outputs to <dir>\n", .{});
            std.debug.print("if version is given, only output lines matching that version (for testing)\n", .{});
            return;
        }
    }

    args = try std.process.argsWithAllocator(arena);
    _ = args.skip();
    const outDir = args.next() orelse return;
    const versionStr = args.next();

    var dir = try std.fs.cwd().openIterableDir("uh_workspace", .{});
    defer dir.close();

    var walker = try dir.walk(arena);
    while (try walker.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        const extra = ".uhversion.txt";

        if (std.mem.endsWith(u8, entry.path, extra)) {
            continue;
        }

        //if (!std.mem.eql(u8, entry.basename, "features.h")) continue;

        //std.debug.print("entry: base {s} path {s}\n", .{ entry.basename, entry.path });

        // read work-in-progress file into memory
        var workpath = try std.fs.path.join(arena, &.{ "uh_workspace", entry.path });
        var worklines = std.ArrayList([]const u8).init(arena);
        {
            var file = try std.fs.cwd().openFile(workpath, .{});
            defer file.close();
            var contents = try file.reader().readAllAlloc(arena, 100 * 1024 * 1024);
            while (contents.len > 0 and contents[contents.len - 1] == '\n') {
                contents = contents[0 .. contents.len - 1];
            }

            if (contents.len > 0) {
                var it = std.mem.splitScalar(u8, contents, '\n');
                while (it.next()) |line| {
                    try worklines.append(line);
                }
            }
        }

        // read work-in-progress sidecar version file into memory
        var buf = try arena.alloc(u8, 1000);
        const versionpath = try std.fmt.bufPrint(buf, "{s}{s}", .{ workpath, extra });
        var versionlines = std.ArrayList([]const u8).init(arena);
        {
            var file = try std.fs.cwd().openFile(versionpath, .{});
            defer file.close();
            var contents = try file.reader().readAllAlloc(arena, 100 * 1024 * 1024);
            while (contents.len > 0 and contents[contents.len - 1] == '\n') {
                contents = contents[0 .. contents.len - 1];
            }

            if (contents.len > 0) {
                var it = std.mem.splitScalar(u8, contents, '\n');
                while (it.next()) |line| {
                    try versionlines.append(line);
                }
            }
        }

        // make writer to output file that will be our universal header
        var filepath = try std.fs.path.join(arena, &.{ outDir, entry.path });
        if (std.fs.path.dirname(filepath)) |dirname| {
            try std.fs.cwd().makePath(dirname);
        }
        //std.debug.print("createFile {s}\n", .{filepath});
        var outfile = try std.fs.cwd().createFile(filepath, .{});
        defer outfile.close();
        var outwriter = outfile.writer();

        if (versionStr) |version| {
            // this is for debugging
            for (worklines.items, versionlines.items) |workline, versionline| {
                if (std.mem.indexOf(u8, versionline, version) != null) {
                    try outwriter.print("{s}\n", .{workline[9..]});
                }
            }
        } else {
            // output the universal header
            // - we maintain a stack of the version #if blocks we are inside of
            // - if the version changes, then either:
            // - - it is a subset of the previous version, so we can add a new nested #if block
            // - - it is not a subset, so #endif the block and start a new one
            var versionstack = std.ArrayList([]const u8).init(arena);
            for (worklines.items, versionlines.items) |workline, versionline| {
                if (versionstack.items.len > 0 and std.mem.eql(u8, versionline, versionstack.items[versionstack.items.len - 1])) {
                    // line is a continuation
                    try outwriter.print("{s}\n", .{workline[9..]});
                } else {
                    // version changed

                    // are we changing to a subset?
                    var subset: bool = false;
                    while (versionstack.items.len > 0) {
                        subset = true;
                        var vit = std.mem.splitScalar(u8, versionline, '|');
                        while (vit.next()) |version| {
                            if (std.mem.eql(u8, version, "")) {
                                continue;
                            }

                            if (std.mem.indexOf(u8, versionstack.items[versionstack.items.len - 1], version) == null) {
                                subset = false;
                                break;
                            }
                        }

                        if (subset) {
                            break;
                        } else {
                            _ = versionstack.pop();
                            try outwriter.print("#endif /*_ZIG_UH_*/\n", .{});
                        }
                    }

                    if (versionstack.items.len > 0 and std.mem.eql(u8, versionline, versionstack.items[versionstack.items.len - 1])) {
                        // we popped to an exact match of our version, so can continue without a new #if
                        try outwriter.print("{s}\n", .{workline[9..]});
                    } else {

                        // we've put any #endif we need, now start a new #if
                        try outputIfLine(arena, outwriter, versionline);

                        try versionstack.append(versionline);

                        //for (versionstack.items) |vline| {
                        //    try outwriter.print("//vline {s}\n", .{vline});
                        //}

                        try outwriter.print("{s}\n", .{workline[9..]});
                    }
                }
            }

            while (versionstack.items.len > 0) {
                _ = versionstack.pop();
                try outwriter.print("#endif /*_ZIG_UH_*/\n", .{});
            }
        }
    }
}

pub fn outputIfLine(arena: std.mem.Allocator, writer: anytype, versionline: []const u8) !void {
    var vit = std.mem.splitScalar(u8, versionline, '|');
    var versions = std.StringArrayHashMap(void).init(arena);
    while (vit.next()) |version| {
        if (std.mem.eql(u8, version, "")) {
            continue;
        }

        try versions.put(version, {});
    }

    var replacements = std.ArrayList([]const u8).init(arena);

    inline for (@typeInfo(@TypeOf(reductions)).Struct.fields) |f| {
        const field = @field(reductions, f.name);
        var found_all = true;
        for (0..field.len - 1) |i| {
            // are all of this reduction's versions here?
            if (!versions.contains(field[i])) {
                found_all = false;
                break;
            }
        }

        if (found_all) {
            // we can replace all these versions with the reduction
            for (0..field.len - 1) |i| {
                _ = versions.orderedRemove(field[i]);
            }

            try replacements.append(field[field.len - 1]);
        }
    }

    try writer.print("#if ", .{});
    var first_v: bool = true;
    for (replacements.items) |rep| {
        if (!first_v) {
            try writer.print(" OR ", .{});
        }
        first_v = false;
        try writer.print("{s}", .{rep});
    }
    for (versions.keys()) |version| {
        if (!first_v) {
            try writer.print(" OR ", .{});
        }
        first_v = false;
        try writer.print("defined {s}", .{version});
    }
    try writer.print(" OR _ZIG_UH_\n", .{});
}
