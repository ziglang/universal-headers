const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Target = std.Target;
const assert = std.debug.assert;

const arocc = @import("arocc");
const RawToken = arocc.Tokenizer.Token;
const Token = arocc.Tree.Token;
const Tokenizer = arocc.Tokenizer;

const Input = struct {
    path: []const u8,
    target: Target,
    defines: []const []const u8,
};

const inputs = [_]Input{
    //.{
    //    .path = "i386-linux-musl",
    //    .target = .{
    //        .cpu = Target.Cpu.baseline(.i386),
    //        .os = Target.Os.Tag.linux.defaultVersionRange(.i386),
    //        .abi = .musl,
    //        .ofmt = .elf,
    //    },
    //},
    .{
        .path = "x86_64-linux-musl",
        .target = .{
            .cpu = Target.Cpu.baseline(.x86_64),
            .os = Target.Os.Tag.linux.defaultVersionRange(.x86_64),
            .abi = .musl,
            .ofmt = .elf,
        },
        .defines = &.{
            "__x86_64__",
            "__linux__",
            "__ZIG_ABI_MUSL__",
        },
    },
    .{
        .path = "aarch64-linux-musl",
        .target = .{
            .cpu = Target.Cpu.baseline(.aarch64),
            .os = Target.Os.Tag.linux.defaultVersionRange(.aarch64),
            .abi = .musl,
            .ofmt = .elf,
        },
        .defines = &.{
            "__aarch64__",
            "__linux__",
            "__ZIG_ABI_MUSL__",
        },
    },
    //.{
    //    .path = "x86_64-macos.11-none",
    //    .target = .{
    //        .cpu = Target.Cpu.baseline(.x86_64),
    //        .os = .{
    //            .tag = .macos,
    //            .version_range = .{
    //                .semver = .{
    //                    .min = .{ .major = 11, .minor = 0, .patch = 0 },
    //                    .max = .{ .major = 11, .minor = std.math.maxInt(u32) },
    //                },
    //            },
    //        },
    //        .abi = .none,
    //        .ofmt = .macho,
    //    },
    //    .defines = &.{
    //        .{
    //            .name = "__APPLE__",
    //            .define = .def,
    //        },
    //        .{
    //            .name = "__ZIG_OS_VERSION_MIN_MAJOR__",
    //            .define = .{ .string = "11" },
    //        },
    //    },
    //},
    //.{
    //    .path = "x86_64-macos.12-none",
    //    .target = .{
    //        .cpu = Target.Cpu.baseline(.x86_64),
    //        .os = .{
    //            .tag = .macos,
    //            .version_range = .{
    //                .semver = .{
    //                    .min = .{ .major = 12, .minor = 0, .patch = 0 },
    //                    .max = .{ .major = 12, .minor = std.math.maxInt(u32) },
    //                },
    //            },
    //        },
    //        .abi = .none,
    //        .ofmt = .macho,
    //    },
    //    .defines = &.{
    //        .{
    //            .name = "__APPLE__",
    //            .define = .def,
    //        },
    //        .{
    //            .name = "__ZIG_OS_VERSION_MIN_MAJOR__",
    //            .define = .{ .string = "12" },
    //        },
    //    },
    //},
};

/// Key is include path
const HeaderTable = std.StringHashMap(std.ArrayListUnmanaged(Header));

const Header = struct {
    input: *const Input,
    source_bytes: []const u8,
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
    const zig_env = try std.json.parseFromSlice(ZigEnv, arena, result.stdout, .{
        .ignore_unknown_fields = true,
    });
    defer std.json.parseFree(ZigEnv, arena, zig_env);

    const sys_include = try fs.path.join(arena, &.{ zig_env.lib_dir, "include" });

    var in_dir = try fs.cwd().openDir(in_path, .{});
    defer in_dir.close();

    var out_dir = try fs.cwd().makeOpenPathIterable(out_path, .{});
    defer out_dir.close();

    var header_table = HeaderTable.init(arena);
    defer header_table.deinit();

    // Find all the headers from different libcs that correspond to each other.
    for (&inputs) |*input| {
        var target_dir = try in_dir.openIterableDir(input.path, .{});
        defer target_dir.close();

        var walker = try target_dir.walk(arena);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .File) continue;
            if (entry.path[0] == '.') continue;

            // testing only 1 file for now:
            if (!mem.endsWith(u8, entry.path, "alltypes.h")) continue;

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

    std.debug.print("found: {d} unique headers across {d} targets\n", .{
        header_table.count(), inputs.len,
    });

    var it = header_table.iterator();
    while (it.next()) |entry| {
        const h_path = entry.key_ptr.*;
        std.debug.print("merge '{s}'...\n", .{h_path});

        // parse the headers into graphs
        var graph_set = std.ArrayList(Graph).init(arena);
        for (entry.value_ptr.items) |header| {
            std.debug.print("doing {s} now\n", .{header.input.path});
            const graph = try parseHeaderIntoGraph(arena, h_path, header, sys_include);

            for (graph.nodes.items) |node| {
                std.debug.print("node: definition: '{s}' => '{s}'\n", .{ node.definition.name, node.definition.source });
            }
            try graph_set.append(graph);
        }

        // topological sort the graphs
        // TODO

        // consume nodes from inputs to output
        var output_nodes = std.ArrayList(Node).init(arena);
        while (anyLeft(&graph_set)) {
            const first_graph = &graph_set.items[0];
            const first_node = first_graph.popFirst();
            // figure out where to put this node in the output
            try output_nodes.append(first_node);
            for (graph_set.items[1..]) |*graph| {
                const node = graph.popFirst();
                if (!mem.eql(u8, node.definition.name, first_node.definition.name)) {
                    std.debug.print("non-matching name: {s} {s}\n", .{ node.definition.name, first_node.definition.name });
                    @panic("TODO");
                }
            }
        }

        // render output
        if (fs.path.dirname(h_path)) |dirname| {
            try out_dir.dir.makePath(dirname);
        }

        var out_file = try out_dir.dir.createFile(h_path, .{});
        defer out_file.close();

        var bw = std.io.bufferedWriter(out_file.writer());
        const w = bw.writer();

        //try w.writeAll("#pragma once\n");

        for (output_nodes.items) |node| {
            switch (node) {
                .definition => |definition| {
                    try w.print("{s}\n", .{definition.source});
                },
                .condition => @panic("TODO"),
            }
        }

        try bw.flush();
    }
}

const Graph = struct {
    nodes: std.ArrayList(Node),

    fn popFirst(graph: *Graph) Node {
        return graph.nodes.orderedRemove(0);
    }
};

const Node = union(enum) {
    condition: Condition,
    definition: Definition,
};

// This is using Conjunctive Normal Form.
// The inner list is each Define OR'd together.
// The outer list AND's those inner lists together.
const Condition = struct {
    conjunctives: [][]NamedDefine,
};

const NamedDefine = struct {
    name: []const u8,
    define: Define,
};

const Define = union(enum) {
    undef,
    def,
    string: []const u8,

    fn eql(a: Define, b: Define) bool {
        switch (a) {
            .undef => return b == .undef,
            .def => return b == .def,
            .string => |a_s| switch (b) {
                .undef, .def => return false,
                .string => |b_s| return mem.eql(u8, a_s, b_s),
            },
        }
    }
};

const Definition = struct {
    // example: "_Addr"
    name: []const u8,
    // example: "#define _Addr long"
    source: []const u8,
};

fn parseHeaderIntoGraph(arena: Allocator, h_path: []const u8, header: Header, sys_include: []const u8) !Graph {
    var nodes = std.ArrayList(Node).init(arena);

    var comp = arocc.Compilation.init(arena);
    defer comp.deinit();

    comp.target = header.input.target;
    try comp.system_include_dirs.append(sys_include);

    try comp.addDefaultPragmaHandlers();

    if (comp.target.abi == .msvc or comp.target.os.tag == .windows) {
        comp.langopts.setEmulatedCompiler(.msvc);
    }

    var pp = arocc.Preprocessor.init(&comp);
    defer pp.deinit();

    var macro_buf = std.ArrayList(u8).init(comp.gpa);
    defer macro_buf.deinit();

    //try pp.addBuiltinMacros();

    const source = try comp.addSourceFromBuffer(h_path, header.source_bytes);

    var guard_name = pp.findIncludeGuard(source);

    pp.preprocess_count += 1;
    var tokenizer = arocc.Tokenizer{
        .buf = source.buf,
        .comp = pp.comp,
        .source = source.id,
    };

    var if_level: u8 = 0;
    //var if_kind = std.PackedIntArray(u2, 256).init([1]u2{0} ** 256);
    //const until_else = 0;
    //const until_endif = 1;
    //const until_endif_seen_else = 2;

    var start_of_line = true;

    while (true) {
        var tok = tokenizer.next();
        switch (tok.id) {
            .hash => if (!start_of_line) try pp.tokens.append(pp.gpa, tokFromRaw(tok)) else {
                const directive = tokenizer.nextNoWS();
                switch (directive.id) {
                    .keyword_error, .keyword_warning => {
                        @panic("TODO keyword_error, keyword_warning");
                    },
                    .keyword_if => {
                        @panic("TODO keyword_if");
                    },
                    .keyword_ifdef => {
                        @panic("TODO keyword_ifdef");
                    },
                    .keyword_ifndef => {
                        @panic("TODO keyword_ifndef");
                    },
                    .keyword_elif => {
                        @panic("TODO keyword_elif");
                    },
                    .keyword_else => {
                        @panic("TODO keyword_else");
                    },
                    .keyword_endif => {
                        @panic("TODO keyword_endif");
                    },
                    .keyword_define => try handleKeywordDefine(arena, source, &nodes, &tokenizer),
                    .keyword_undef => {
                        @panic("TODO keyword_undef");
                    },
                    .keyword_include => {
                        @panic("TODO keyword_include");
                    },
                    .keyword_include_next => {
                        @panic("TODO include_next");
                    },
                    .keyword_pragma => {
                        @panic("TODO pragma");
                    },
                    .keyword_line => {
                        @panic("unsupported directive: #line");
                    },
                    .pp_num => {
                        @panic("TODO pp_num??");
                    },
                    .nl => {},
                    .eof => {
                        if (if_level != 0) @panic("unterminated_conditional_directive");
                        @panic("TODO eof inside hash");
                    },
                    else => {
                        try pp.err(tok, .invalid_preprocessing_directive);
                        skipToNl(&tokenizer);
                    },
                }
            },
            .whitespace => {},
            .nl => {
                start_of_line = true;
            },
            .eof => {
                if (if_level != 0) @panic("unterminated_conditional_directive");
                // The following check needs to occur here and not at the top of the function
                // because a pragma may change the level during preprocessing
                if (source.buf.len > 0 and source.buf[source.buf.len - 1] != '\n') {
                    @panic("newline_eof");
                }
                if (guard_name) |name| {
                    std.debug.print("found include guard: '{s}'\n", .{name});
                    @panic("TODO handle include guard");
                }
                break;
            },
            else => {
                std.debug.print("TODO handle token '{s}'\n", .{@tagName(tok.id)});
            },
        }
    }

    return .{
        .nodes = nodes,
    };
}

/// Convert a token from the Tokenizer into a token used by the parser.
fn tokFromRaw(raw: RawToken) Token {
    return .{
        .id = raw.id,
        .loc = .{
            .id = raw.source,
            .byte_offset = raw.start,
            .line = raw.line,
        },
    };
}

// Skip until newline, ignore other tokens.
fn skipToNl(tokenizer: *Tokenizer) void {
    while (true) {
        const tok = tokenizer.next();
        if (tok.id == .nl or tok.id == .eof) return;
    }
}

fn handleKeywordDefine(arena: Allocator, source: arocc.Source, nodes: *std.ArrayList(Node), tokenizer: *Tokenizer) !void {
    // We want to extract two things:
    // 1. the macro identifier name.
    // 2. the source code for the macro, with whitespace stripped.
    var macro_src_bytes = std.ArrayList(u8).init(arena);

    const macro_name = tokenizer.nextNoWS();
    const macro_name_bytes = tokSlice(source, macro_name);
    try macro_src_bytes.appendSlice("#define ");
    try macro_src_bytes.appendSlice(macro_name_bytes);
    assert(macro_name.id != .keyword_defined);
    assert(macro_name.id.isMacroIdentifier());
    var macro_name_token_id = macro_name.id;
    macro_name_token_id.simplifyMacroKeyword();
    switch (macro_name_token_id) {
        .identifier, .extended_identifier => {},
        else => assert(!macro_name_token_id.isMacroIdentifier()),
    }

    // Check for function macros and empty defines.
    var first = tokenizer.next();
    switch (first.id) {
        .nl, .eof => {
            try nodes.append(.{
                .definition = .{
                    .name = try arena.dupe(u8, macro_name_bytes),
                    .source = macro_src_bytes.items,
                },
            });
            return;
        },
        .whitespace => first = tokenizer.next(),
        .l_paren => @panic("TODO macro function"),
        else => @panic("whitespace_after_macro_name"),
    }
    if (first.id == .hash_hash) {
        @panic("hash_hash_at_start");
    }
    first.id.simplifyMacroKeyword();

    try macro_src_bytes.append(' ');

    var need_ws = false;
    // Collect the token body and validate any ## found.
    var tok = first;
    while (true) {
        tok.id.simplifyMacroKeyword();
        switch (tok.id) {
            .hash_hash => {
                const next = tokenizer.nextNoWS();
                switch (next.id) {
                    .nl, .eof => {
                        @panic("hash_hash_at_end");
                    },
                    .hash_hash => {
                        @panic("hash_hash_at_end");
                    },
                    else => {},
                }
                try macro_src_bytes.appendSlice(tokSlice(source, tok));
                try macro_src_bytes.appendSlice(tokSlice(source, next));
            },
            .nl, .eof => break,
            .whitespace => need_ws = true,
            else => {
                if (tok.id != .whitespace and need_ws) {
                    need_ws = false;
                    try macro_src_bytes.appendSlice(tokSlice(source, .{ .id = .macro_ws, .source = .generated }));
                }
                try macro_src_bytes.appendSlice(tokSlice(source, tok));
            },
        }
        tok = tokenizer.next();
    }

    try nodes.append(.{
        .definition = .{
            .name = try arena.dupe(u8, macro_name_bytes),
            .source = macro_src_bytes.items,
        },
    });
}

pub fn tokSlice(source: arocc.Source, tok: Tokenizer.Token) []const u8 {
    if (tok.id.lexeme()) |s| return s;
    return source.buf[tok.start..tok.end];
}

fn anyLeft(graph_set: *std.ArrayList(Graph)) bool {
    for (graph_set.items) |graph| {
        if (graph.nodes.items.len > 0) return true;
    }
    return false;
}
