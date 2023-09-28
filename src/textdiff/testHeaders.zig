const std = @import("std");

pub fn main() !void {
    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_allocator.allocator();

    var args = try std.process.argsWithAllocator(arena);

    {
        var i: usize = 0;
        while (args.skip()) {
            i += 1;
        }

        if (i != 4) {
            std.debug.print("usage: testHeaders <dir> <outdir> <version>\n", .{});
            std.debug.print("takes universal headers from <dir>, partially evaluates, and outputs to <outdir>\n", .{});
            std.debug.print("output files should match originals from that version (maybe whitespace differences)\n", .{});
            return;
        }
    }

    args = try std.process.argsWithAllocator(arena);
    _ = args.skip();
    const inDir = args.next() orelse return;
    const outDir = args.next() orelse return;
    const versionStr = args.next() orelse return;

    var dir = try std.fs.cwd().openIterableDir(inDir, .{});
    defer dir.close();

    var walker = try dir.walk(arena);
    while (try walker.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        //if (!std.mem.eql(u8, entry.basename, "unistd_ext.h")) continue;

        //std.debug.print("entry: base {s} path {s}\n", .{ entry.basename, entry.path });

        var inpath = try std.fs.path.join(arena, &.{ inDir, entry.path });

        var inlines = std.ArrayList([]const u8).init(arena);
        {
            var file = try std.fs.cwd().openFile(inpath, .{});
            defer file.close();
            var contents = try file.reader().readAllAlloc(arena, 20 * 1024 * 1024);
            while (contents.len > 0 and contents[contents.len - 1] == '\n') {
                contents = contents[0 .. contents.len - 1];
            }

            if (contents.len > 0) {
                var it = std.mem.splitScalar(u8, contents, '\n');
                while (it.next()) |line| {
                    try inlines.append(line);
                }
            }
        }

        var outpath = try std.fs.path.join(arena, &.{ outDir, entry.path });
        if (std.fs.path.dirname(outpath)) |dirname| {
            try std.fs.cwd().makePath(dirname);
        }
        std.debug.print("createFile {s}\n", .{outpath});
        var outfile = try std.fs.cwd().createFile(outpath, .{});
        var outwriter = outfile.writer();

        var outputing = std.ArrayList(u2).init(arena);
        var in_comment: bool = false;
        for (inlines.items) |line| {
            std.debug.print("{d} line {s}\n", .{ outputing.items.len, line });
            var com = in_comment;
            if (!in_comment and std.mem.indexOf(u8, line, "/*") != null and std.mem.indexOf(u8, line, "*/") == null) {
                in_comment = true;
                com = true;
            } else if (in_comment and std.mem.indexOf(u8, line, "/*") == null and std.mem.indexOf(u8, line, "*/") != null) {
                in_comment = false; // next line will be out of comment
            }
            var trimmed = std.mem.trimLeft(u8, line, " ");
            if (!com and std.mem.startsWith(u8, trimmed, "#")) {
                trimmed = trimmed[1..];
                trimmed = std.mem.trimLeft(u8, trimmed, " ");
                if (std.mem.startsWith(u8, trimmed, "if")) {
                    if (std.mem.indexOf(u8, trimmed, "_ZIG_UH_TEST") != null) {
                        if (std.mem.indexOf(u8, trimmed, versionStr) != null) {
                            try outputing.append(3);
                        } else {
                            try outputing.append(2);
                        }
                        continue;
                    } else {
                        const currently_outputting = (outputing.items.len == 0 or outputing.items[outputing.items.len - 1] & 1 > 0);
                        try outputing.append(if (currently_outputting) 1 else 0);
                    }
                } else if (std.mem.startsWith(u8, trimmed, "endif")) {
                    if (outputing.items.len == 0) {
                        return error.dangling_endif;
                    }

                    if (outputing.items[outputing.items.len - 1] & 2 > 0) {
                        _ = outputing.pop();
                        continue;
                    } else {
                        _ = outputing.pop();
                    }
                }
            }

            if (outputing.items.len == 0 or outputing.items[outputing.items.len - 1] & 1 > 0) {
                try outwriter.print("{s}\n", .{line});
            }
        }
    }
}
