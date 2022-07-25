const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Target = std.Target;

const arocc = @import("arocc");

const Input = struct {
    path: []const u8,
    target: Target,
};

const inputs = [_]Input{
    .{
        .path = "i386-linux-musl",
        .target = .{
            .cpu = Target.Cpu.baseline(.i386),
            .os = Target.Os.Tag.linux.defaultVersionRange(.i386),
            .abi = .musl,
        },
    },
    .{
        .path = "x86_64-linux-musl",
        .target = .{
            .cpu = Target.Cpu.baseline(.x86_64),
            .os = Target.Os.Tag.linux.defaultVersionRange(.x86_64),
            .abi = .musl,
        },
    },
};

/// Key is include path
const HeaderTable = std.StringHashMap(std.ArrayListUnmanaged(Header));

const Header = struct {
    input: *const Input,
    source_bytes: []const u8,
};

const Symbol = struct {
    target_path: []const u8,
    identifier: []const u8,
    contents: []const u8,
};

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try std.process.argsAlloc(arena);

    const zig_exe = args[1];
    const in_path = args[2];
    const out_path = args[3];

    const result = try std.ChildProcess.exec(.{
        .allocator = arena,
        .argv = &.{ zig_exe, "env" },
    });
    if (result.term.Exited != 0) return error.ExecZigFailed;
    const ZigEnv = struct {
        lib_dir: []const u8,
    };
    var json_token_stream = std.json.TokenStream.init(result.stdout);
    const zig_env = try std.json.parse(ZigEnv, &json_token_stream, .{
        .allocator = arena,
        .ignore_unknown_fields = true,
    });
    const sys_include = try fs.path.join(arena, &.{ zig_env.lib_dir, "include" });

    var in_dir = try fs.cwd().openDir(in_path, .{});
    defer in_dir.close();

    var out_dir = try fs.cwd().makeOpenPathIterable(out_path, .{});
    defer out_dir.close();

    var header_table = HeaderTable.init(arena);
    defer header_table.deinit();

    // Find all the headers from different libcs that correspond to each other.
    for (inputs) |*input| {
        var target_dir = try in_dir.openIterableDir(input.path, .{});
        defer target_dir.close();

        var walker = try target_dir.walk(arena);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .File) continue;
            const gop = try header_table.getOrPut(entry.path);
            if (!gop.found_existing) {
                gop.key_ptr.* = try arena.dupe(u8, entry.path);
                gop.value_ptr.* = .{};
            }
            const max_size = std.math.maxInt(u32);
            try gop.value_ptr.append(arena, .{
                .input = input,
                .source_bytes = try target_dir.dir.readFileAlloc(arena, entry.path, max_size),
            });
        }
    }

    var it = header_table.iterator();
    while (it.next()) |entry| {
        std.debug.print("merge '{s}'...\n", .{entry.key_ptr.*});
        var merger: Merger = .{
            .arena = arena,
            .h_path = entry.key_ptr.*,
            .headers = entry.value_ptr.items,
            .in_path = in_path,
            .sys_include = sys_include,
        };
        try merger.merge();
    }
}

const Merger = struct {
    arena: Allocator,
    h_path: []const u8,
    headers: []Header,
    in_path: []const u8,
    sys_include: []const u8,

    all_symbols: std.ArrayListUnmanaged(Symbol) = .{},

    fn merge(m: *Merger) !void {
        // Walk the full tree of the input, exploding each header into the full set of
        // key-value pairs.
        for (m.headers) |header| {
            try addSymbolsFromHeader(m, header);
        }
    }

    fn addSymbolsFromHeader(m: *Merger, header: Header) !void {
        std.debug.print("iterate: {s}/{s}\n", .{ header.input.path, m.h_path });

        var comp = arocc.Compilation.init(m.arena);
        defer comp.deinit();

        comp.target = header.input.target;
        comp.only_preprocess = true;
        try comp.system_include_dirs.append(try std.fmt.allocPrint(comp.gpa, "{s}/{s}", .{
            m.in_path, header.input.path,
        }));
        try comp.system_include_dirs.append(try comp.gpa.dupe(u8, m.sys_include));

        try comp.addDefaultPragmaHandlers();

        if (comp.target.abi == .msvc or comp.target.os.tag == .windows) {
            comp.langopts.setEmulatedCompiler(.msvc);
        }

        var pp = arocc.Preprocessor.init(&comp);
        defer pp.deinit();
        try pp.addBuiltinMacros();

        // here is where we would add macros

        const source = try comp.addSourceFromBuffer(m.h_path, header.source_bytes);

        const eof = try pp.preprocess(source);
        try pp.tokens.append(pp.comp.gpa, eof);

        if (comp.diag.list.items.len != 0) {
            comp.renderErrors();
            std.process.exit(1);
        }

        var it = pp.defines.iterator();
        while (it.next()) |entry| {
            std.debug.print("found macro: '{s}'\n", .{entry.key_ptr.*});
        }

        //var i: u32 = 0;
        //while (true) : (i += 1) {
        //    var cur: arocc.Preprocessor.Token = pp.tokens.get(i);
        //    switch (cur.id) {
        //        .eof => break,
        //        .nl => {},
        //        .keyword_pragma => {
        //            std.debug.print("{s}: error: found pragma\n", .{h_path});
        //            std.process.exit(1);
        //            //const pragma_name = pp.expandedSlice(pp.tokens.get(i + 1));
        //            //const end_idx = mem.indexOfScalarPos(Token.Id, pp.tokens.items(.id), i, .nl) orelse i + 1;
        //            //const pragma_len = @intCast(u32, end_idx) - i;

        //            //if (pp.comp.getPragma(pragma_name)) |prag| {
        //            //    if (!prag.shouldPreserveTokens(pp, i + 1)) {
        //            //        i += pragma_len;
        //            //        cur = pp.tokens.get(i);
        //            //        continue;
        //            //    }
        //            //}
        //            //try w.writeAll("#pragma");
        //            //i += 1;
        //            //while (true) : (i += 1) {
        //            //    cur = pp.tokens.get(i);
        //            //    if (cur.id == .nl) {
        //            //        try w.writeByte('\n');
        //            //        break;
        //            //    }
        //            //    try w.writeByte(' ');
        //            //    const slice = pp.expandedSlice(cur);
        //            //    try w.writeAll(slice);
        //            //}
        //        },
        //        .whitespace => {},
        //        else => {
        //            const slice = pp.expandedSlice(cur);
        //            std.debug.print("found macro: '{s}'\n", .{slice});
        //        },
        //    }
        //}

    }
};
