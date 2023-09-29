const std = @import("std");

const debug = false;

pub fn main() !void {
    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_allocator.allocator();

    var args = try std.process.argsWithAllocator(arena);

    {
        var i: usize = 0;
        while (args.skip()) {
            i += 1;
        }

        if (i != 2) {
            std.debug.print("usage: addHeaders <dir>\n", .{});
            std.debug.print("adds headers from <dir> into uh_workspace\n", .{});
            return;
        }
    }

    // load lines of file into memory
    args = try std.process.argsWithAllocator(arena);
    _ = args.skip();
    const headerDir = args.next() orelse return;

    var buf = try arena.alloc(u8, 1000);
    const versionStr = try std.fmt.bufPrint(buf, "{s}|", .{std.fs.path.basename(headerDir)});

    var dir = try std.fs.cwd().openIterableDir(headerDir, .{});
    defer dir.close();

    std.fs.cwd().makeDir("uh_workspace") catch {};

    var walker = try dir.walk(arena);
    while (try walker.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) {
            continue;
        }

        //if (!std.mem.eql(u8, entry.basename, "_ctype.h")) continue;

        //std.debug.print("entry: base {s} path {s}\n", .{ entry.basename, entry.path });

        const extra = ".uhversion.txt";

        var filepath = try std.fs.path.join(arena, &.{ headerDir, entry.path });
        var workpath = try std.fs.path.join(arena, &.{ "uh_workspace", entry.path });

        var worklines = std.ArrayList([]const u8).init(arena);
        {
            if (debug) std.debug.print("createFile {s}\n", .{workpath});
            if (std.fs.path.dirname(workpath)) |dirname| {
                try std.fs.cwd().makePath(dirname);
            }
            var file = try std.fs.cwd().createFile(workpath, .{ .read = true, .truncate = false });
            defer file.close();
            var contents = try file.reader().readAllAlloc(arena, 20 * 1024 * 1024);
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

        buf = try arena.alloc(u8, 1000);
        const versionpath = try std.fmt.bufPrint(buf, "{s}{s}", .{ workpath, extra });
        var versionlines = std.ArrayList([]const u8).init(arena);
        {
            var file = try std.fs.cwd().createFile(versionpath, .{ .read = true, .truncate = false });
            defer file.close();
            var contents = try file.reader().readAllAlloc(arena, 20 * 1024 * 1024);
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

        var filelines = std.ArrayList([]const u8).init(arena);
        {
            var file = try std.fs.cwd().openFile(filepath, .{});
            defer file.close();
            var contents = try file.reader().readAllAlloc(arena, 20 * 1024 * 1024);
            while (contents.len > 0 and contents[contents.len - 1] == '\n') {
                contents = contents[0 .. contents.len - 1];
            }

            if (contents.len > 0) {
                var it = std.mem.splitScalar(u8, contents, '\n');
                while (it.next()) |line| {
                    // normalize whitespace (replace tabs with spaces)
                    buf = try arena.alloc(u8, line.len);
                    _ = std.mem.replace(u8, line, "\t", " ", buf);
                    try filelines.append(buf);
                }
            }
        }

        // first add context to the new file
        try addContext(arena, &filelines);

        {
            var file = try std.fs.cwd().createFile("uh_workfile", .{});
            defer file.close();
            var writer = file.writer();
            for (filelines.items) |line| {
                try writer.print("{s}\n", .{line});
            }
        }

        //std.debug.print("filepath: {s}, workpath: {s}\n", .{ filepath, workpath });

        var diff_stdout = std.ArrayList(u8).init(arena);
        var diff_stderr = std.ArrayList(u8).init(arena);
        var diff_child = std.process.Child.init(&.{ "diff", "-wdN", workpath, "uh_workfile" }, arena);
        diff_child.stdout_behavior = .Pipe;
        diff_child.stderr_behavior = .Pipe;
        try diff_child.spawn();
        try diff_child.collectOutput(&diff_stdout, &diff_stderr, 20 * 1024 * 1024);
        _ = try diff_child.wait();

        //std.debug.print("diff says:\n{s}\n", .{diff_stdout.items});

        // worklines has all lines accumulated from headers so far
        // versionlines has versions for all lines in worklines
        // ctx_stdout.items has new header lines

        // go through diff output and adjust worklines and versionlines
        var line_adj: isize = 0;
        var ignore: usize = 0;
        var last_line: usize = 0;

        var it = std.mem.splitScalar(u8, diff_stdout.items, '\n');
        while (it.next()) |line| {
            if (ignore > 0) {
                if (debug) std.debug.print("ignore {d} {s}\n", .{ ignore, line });
                ignore -= 1;
                continue;
            }

            if (std.mem.eql(u8, line, "")) {
                // diff might be empty or end with an empty line
            } else if (std.mem.indexOfScalar(u8, line, 'a')) |p| {
                const before = line[0..p];
                const after = line[p + 1 ..];
                const addafter = try std.fmt.parseInt(usize, before, 10);
                var start: usize = undefined;
                var end: usize = undefined;
                if (std.mem.indexOfScalar(u8, after, ',')) |pc| {
                    start = try std.fmt.parseInt(usize, after[0..pc], 10);
                    end = try std.fmt.parseInt(usize, after[pc + 1 ..], 10);
                } else {
                    start = try std.fmt.parseInt(usize, after, 10);
                    end = start;
                }

                start -= 1;

                if (debug) std.debug.print("diff a says {s} -> {d}-{d}\n", .{ line, start, end });

                // from line_adj to addafter, the lines were the same, so add the version
                for (last_line..@intCast(line_adj + @as(isize, @intCast(addafter)))) |i| {
                    const old = versionlines.items[i];
                    buf = try arena.alloc(u8, old.len + versionStr.len);
                    versionlines.items[i] = try std.fmt.bufPrint(buf, "{s}{s}", .{ old, versionStr });
                }

                // add lines start..end from new header after line addafter
                const where: usize = @intCast(line_adj + @as(isize, @intCast(addafter)));
                try worklines.insertSlice(where, filelines.items[start..end]);
                //std.debug.print("versionlines.len {d}\n", .{versionlines.items.len});
                for (0..end - start) |_| {
                    try versionlines.insert(where, versionStr);
                }

                //std.debug.print("versionlines.len {d}\n", .{versionlines.items.len});

                last_line = where + end - start;
                line_adj += @intCast(end - start);
                ignore = end - start;
            } else if (std.mem.indexOfScalar(u8, line, 'c')) |p| {
                var start1: usize = undefined;
                var end1: usize = undefined;
                var start2: usize = undefined;
                var end2: usize = undefined;

                const before = line[0..p];
                if (std.mem.indexOfScalar(u8, before, ',')) |pc| {
                    start1 = try std.fmt.parseInt(usize, before[0..pc], 10);
                    end1 = try std.fmt.parseInt(usize, before[pc + 1 ..], 10);
                } else {
                    start1 = try std.fmt.parseInt(usize, before, 10);
                    end1 = start1;
                }
                start1 -= 1;

                const after = line[p + 1 ..];
                if (std.mem.indexOfScalar(u8, after, ',')) |pc| {
                    start2 = try std.fmt.parseInt(usize, after[0..pc], 10);
                    end2 = try std.fmt.parseInt(usize, after[pc + 1 ..], 10);
                } else {
                    start2 = try std.fmt.parseInt(usize, after, 10);
                    end2 = start2;
                }
                start2 -= 1;

                if (debug) std.debug.print("diff c says {s} -> {d}-{d} to {d}-{d}\n", .{ line, start1, end1, start2, end2 });

                // from line_adj to start1, the lines were the same, so add the version
                for (last_line..@intCast(line_adj + @as(isize, @intCast(start1)))) |i| {
                    const old = versionlines.items[i];
                    buf = try arena.alloc(u8, old.len + versionStr.len);
                    versionlines.items[i] = try std.fmt.bufPrint(buf, "{s}{s}", .{ old, versionStr });
                }

                const where: usize = @intCast(line_adj + @as(isize, @intCast(end1)));
                try worklines.insertSlice(where, filelines.items[start2..end2]);
                for (0..end2 - start2) |_| {
                    try versionlines.insert(where, versionStr);
                }
                last_line = where + end2 - start2;
                line_adj += @intCast(end2 - start2);
                ignore = end1 - start1 + end2 - start2 + 1;
                //std.debug.print("setting ignore to {d} {d} {d} {d} {d}\n", .{ ignore, start1, end1, start2, end2 });
            } else if (std.mem.indexOfScalar(u8, line, 'd')) |p| {
                const before = line[0..p];

                var start: usize = undefined;
                var end: usize = undefined;
                if (std.mem.indexOfScalar(u8, before, ',')) |pc| {
                    start = try std.fmt.parseInt(usize, before[0..pc], 10);
                    end = try std.fmt.parseInt(usize, before[pc + 1 ..], 10);
                } else {
                    start = try std.fmt.parseInt(usize, before, 10);
                    end = start;
                }

                start -= 1;

                if (debug) std.debug.print("diff d says {s} -> {d}-{d}\n", .{ line, start, end });

                for (last_line..@intCast(line_adj + @as(isize, @intCast(start)))) |i| {
                    const old = versionlines.items[i];
                    buf = try arena.alloc(u8, old.len + versionStr.len);
                    versionlines.items[i] = try std.fmt.bufPrint(buf, "{s}{s}", .{ old, versionStr });
                }

                // we just skip over the lines
                ignore = end - start;
                last_line = @intCast(line_adj + @as(isize, @intCast(end)));
            } else {
                //std.debug.print("diff says {s}\n", .{line});
                return error.asdf;
            }
        }

        // from line_adj to the end, the lines must have been the same
        //std.debug.print("last_line {d} {d}\n", .{ last_line, versionlines.items.len });
        for (last_line..versionlines.items.len) |i| {
            const old = versionlines.items[i];
            buf = try arena.alloc(u8, old.len + versionStr.len);
            versionlines.items[i] = try std.fmt.bufPrint(buf, "{s}{s}", .{ old, versionStr });
        }

        // write out worklines and versionlines back to disk
        {
            var file = try std.fs.cwd().createFile(workpath, .{});
            defer file.close();
            var writer = file.writer();
            for (worklines.items) |line| {
                try writer.print("{s}\n", .{line});
            }
        }

        {
            var file = try std.fs.cwd().createFile(versionpath, .{});
            defer file.close();
            var writer = file.writer();
            for (versionlines.items) |line| {
                try writer.print("{s}\n", .{line});
            }
        }
    }
}

pub fn addContext(arena: std.mem.Allocator, lines: *std.ArrayList([]const u8)) !void {
    var seen_contexts = std.ArrayList(u32).init(arena);
    var context = std.ArrayList(u32).init(arena);
    try context.append(0);
    var in_comment: bool = false;
    for (lines.items, 0..) |line, i| {
        if ((i + 1) == lines.items.len and std.mem.eql(u8, line, "")) {
            // don't add a line after last newline
            break;
        }

        var pop_context: bool = false;

        var com = in_comment;
        if (!in_comment and std.mem.indexOf(u8, line, "/*") != null and std.mem.indexOf(u8, line, "*/") == null) {
            in_comment = true;
        } else if (in_comment and std.mem.indexOf(u8, line, "/*") == null and std.mem.indexOf(u8, line, "*/") != null) {
            in_comment = false; // next line will be out of comment
            pop_context = true;
        }

        if (!com) {
            // could be spaces between # and directive
            var trimmed = std.mem.trimLeft(u8, line, " ");
            if (std.mem.startsWith(u8, trimmed, "#")) {
                trimmed = trimmed[1..];
                trimmed = std.mem.trimLeft(u8, trimmed, " ");
                if (std.mem.startsWith(u8, trimmed, "if")) {
                    var ctx = newContext(lines.items, i, context.items[context.items.len - 1]);
                    for (seen_contexts.items) |sc| {
                        if (ctx == sc) {
                            ctx += 1;
                            break;
                        }
                    }
                    try context.append(ctx);
                    try seen_contexts.append(ctx);
                } else if (std.mem.startsWith(u8, trimmed, "endif")) {
                    pop_context = true;
                }
            }
        }

        if (!com and in_comment) {
            // just transitioned into a comment
            // need to context the comments as well otherwise it might break into two pieces
            var ii = i;
            const fnv = std.hash.Fnv1a_32;
            var h = fnv.init();
            h.value = context.items[context.items.len - 1];
            while (true) : (ii += 1) {
                h.update(lines.items[ii]);
                h.update("1"); // update even on an empty line
                if (std.mem.indexOf(u8, lines.items[ii], "/*") == null and std.mem.indexOf(u8, lines.items[ii], "*/") != null) {
                    break;
                }
            }
            var ctx = h.final();
            for (seen_contexts.items) |sc| {
                if (ctx == sc) {
                    ctx += 1;
                    break;
                }
            }
            try context.append(ctx);
            try seen_contexts.append(ctx);
        }

        var buf = try arena.alloc(u8, 9 + line.len);
        lines.items[i] = try std.fmt.bufPrint(buf, "{x:0<8} {s}", .{ context.items[context.items.len - 1], line });

        if (pop_context) {
            _ = context.pop();
        }
    }
}

pub fn newContext(lines: [][]const u8, i: usize, ctx: u32) u32 {
    const fnv = std.hash.Fnv1a_32;
    var h = fnv.init();
    h.value = ctx;
    if (debug) std.debug.print("updating hash: {s}\n", .{lines[i]});
    h.update(lines[i]);
    var ii = i + 1;
    var depth: usize = 0;
    var in_comment: bool = false;
    while (ii < lines.len) : (ii += 1) {
        const line = lines[ii];
        var com = in_comment;
        if (!in_comment and std.mem.indexOf(u8, line, "/*") != null and std.mem.indexOf(u8, line, "*/") == null) {
            in_comment = true;
        } else if (in_comment and std.mem.indexOf(u8, line, "/*") == null and std.mem.indexOf(u8, line, "*/") != null) {
            in_comment = false; // next line will be out of comment
        }
        if (debug) std.debug.print("{s} {d} {s}\n", .{ if (com) "c" else " ", depth, line });
        if (com) {
            continue;
        }
        var trimmed = std.mem.trimLeft(u8, line, " ");
        if (std.mem.startsWith(u8, trimmed, "#")) {
            trimmed = trimmed[1..];
            trimmed = std.mem.trimLeft(u8, trimmed, " ");
            if (std.mem.startsWith(u8, trimmed, "if")) {
                depth += 1;
            } else if (std.mem.startsWith(u8, trimmed, "elif")) {
                if (depth == 0) {
                    if (debug) std.debug.print("updating hash: {s}\n", .{line});
                    h.update(line);
                }
            } else if (std.mem.startsWith(u8, trimmed, "endif")) {
                if (depth == 0) {
                    if (debug) std.debug.print("updating hash: {s}\n", .{line});
                    h.update(line);
                    break;
                }
                depth -|= 1;
            }
        }
    }

    return h.final();
}
