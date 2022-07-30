const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Target = std.Target;
const assert = std.debug.assert;

const arocc = @import("arocc");

const Input = struct {
    path: []const u8,
    target: Target,
    // These need to be unique enough to distinguish between the inputs.
    // In other words, no two inputs should have an identical set of defines.
    defines: []const NamedDefine,
};

const inputs = [_]Input{
    //.{
    //    .path = "i386-linux-musl",
    //    .target = .{
    //        .cpu = Target.Cpu.baseline(.i386),
    //        .os = Target.Os.Tag.linux.defaultVersionRange(.i386),
    //        .abi = .musl,
    //    },
    //},
    //.{
    //    .path = "x86_64-linux-musl",
    //    .target = .{
    //        .cpu = Target.Cpu.baseline(.x86_64),
    //        .os = Target.Os.Tag.linux.defaultVersionRange(.x86_64),
    //        .abi = .musl,
    //    },
    //},
    .{
        .path = "x86_64-macos.11-none",
        .target = .{
            .cpu = Target.Cpu.baseline(.x86_64),
            .os = .{
                .tag = .macos,
                .version_range = .{
                    .semver = .{
                        .min = .{ .major = 11, .minor = 0, .patch = 0 },
                        .max = .{ .major = 11, .minor = std.math.maxInt(u32) },
                    },
                },
            },
            .abi = .none,
        },
        .defines = &.{
            .{
                .name = "__APPLE__",
                .define = .def,
            },
            .{
                .name = "__ZIG_OS_VERSION_MIN_MAJOR__",
                .define = .{ .string = "11" },
            },
        },
    },
    .{
        .path = "x86_64-macos.12-none",
        .target = .{
            .cpu = Target.Cpu.baseline(.x86_64),
            .os = .{
                .tag = .macos,
                .version_range = .{
                    .semver = .{
                        .min = .{ .major = 12, .minor = 0, .patch = 0 },
                        .max = .{ .major = 12, .minor = std.math.maxInt(u32) },
                    },
                },
            },
            .abi = .none,
        },
        .defines = &.{
            .{
                .name = "__APPLE__",
                .define = .def,
            },
            .{
                .name = "__ZIG_OS_VERSION_MIN_MAJOR__",
                .define = .{ .string = "12" },
            },
        },
    },
};

/// Key is include path
const HeaderTable = std.StringHashMap(std.ArrayListUnmanaged(Header));
const Defines = std.StringArrayHashMapUnmanaged(Define);

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

const Header = struct {
    input: *const Input,
    source_bytes: []const u8,
};

// This is using Conjunctive Normal Form.
// The inner list is each Define OR'd together.
// The outer list AND's those inner lists together.
const Clauses = struct {
    conjunctives: [][]NamedDefine,
};

const Symbol = struct {
    // This field acts as a condition. If the condition holds, then the
    // identifier exists with contents.
    clauses: Clauses,
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

    std.debug.print("found: {d} unique headers across {d} targets\n", .{
        header_table.count(), inputs.len,
    });

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

        if (fs.path.dirname(merger.h_path)) |dirname| {
            try out_dir.dir.makePath(dirname);
        }

        var out_file = try out_dir.dir.createFile(merger.h_path, .{});
        defer out_file.close();

        var bw = std.io.bufferedWriter(out_file.writer());
        const w = bw.writer();

        for (merger.all_symbols.items) |symbol| {
            try w.print("#if ", .{});
            for (symbol.clauses.conjunctives) |conjunctive, conjunctive_i| {
                if (conjunctive_i != 0) try w.writeAll(" && ");
                if (conjunctive.len > 1) {
                    try w.writeAll("(");
                }
                for (conjunctive) |named_define, define_i| {
                    if (define_i != 0) try w.writeAll(" || ");
                    switch (named_define.define) {
                        .def => {
                            try w.print("defined({s})", .{named_define.name});
                        },
                        .undef => {
                            try w.print("!defined({s})", .{named_define.name});
                        },
                        .string => |s| {
                            try w.print("{s} == {s}", .{ named_define.name, s });
                        },
                    }
                }
                if (conjunctive.len > 1) {
                    try w.writeAll(")");
                }
            }
            try w.print("\n", .{});

            if (symbol.contents.len == 0) {
                try w.print("#define {s}\n", .{symbol.identifier});
            } else {
                try w.print("#define {s} {s}\n", .{ symbol.identifier, symbol.contents });
            }

            try w.print("#endif\n", .{});
        }

        //const State = std.StringHashMapUnmanaged(Define);
        //var state_stack = std.ArrayList(Clauses).init(arena);
        //try state_stack.append(.{});

        //for (merger.all_symbols.items) |symbol| {
        //    // Pop until we have no conflicts with the current state.
        //    search: while (true) {
        //        const top = &state_stack.items[state_stack.items.len - 1];
        //        for (symbol.clauses) |conjunction| {
        //            for (conjunction) |sym_define| {
        //                if (top.get(sym_define.name)) |cur_define| {
        //                    if (!cur_define.eql(sym_define)) {
        //                        try w.writeAll("#endif\n");
        //                        _ = state_stack.pop();
        //                        continue :search;
        //                    }
        //                }
        //            }
        //        }
        //        break;
        //    }

        //    // Push until all constraints are satisfied.
        //    cond: while (true) {
        //        const top = &state_stack.items[state_stack.items.len - 1];
        //        for (symbol.clauses) |conjunction| {
        //            const define_name = define_names[i];
        //            if (top.contains(define_name)) continue;

        //            var new_state = try top.clone(arena);
        //            try new_state.put(arena, define_name, define_value);
        //            try state_stack.append(new_state);

        //            switch (define_value) {
        //                .def => {
        //                    try w.print("#ifdef {s}\n", .{define_name});
        //                },
        //                .undef => {
        //                    try w.print("#ifndef {s}\n", .{define_name});
        //                },
        //                .string => |s| {
        //                    try w.print("#if {s} == {s}\n", .{ define_name, s });
        //                },
        //            }
        //            continue :cond;
        //        }
        //        break;
        //    }

        //    if (symbol.contents.len == 0) {
        //        try w.print("#define {s}\n", .{symbol.identifier});
        //    } else {
        //        try w.print("#define {s} {s}\n", .{ symbol.identifier, symbol.contents });
        //    }
        //}

        //for (state_stack.items[1..]) |_| {
        //    try w.writeAll("#endif\n");
        //}

        try bw.flush();
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

        std.debug.print("{s} symbols superposition set size {d}\n", .{
            m.h_path, m.all_symbols.items.len,
        });

        // Score each define to find out which ones apply to the most symbols.
        var define_scores = std.StringHashMap(u32).init(m.arena);
        for (m.all_symbols.items) |symbol| {
            for (symbol.clauses.conjunctives) |conjunctive| {
                // only score the first OR
                const name = conjunctive[0].name;
                const gop = try define_scores.getOrPut(name);
                if (!gop.found_existing) {
                    gop.value_ptr.* = 0;
                }
                gop.value_ptr.* += 1;
            }
        }

        // Each symbol from the list needs to be accounted for. First we try
        // to prune symbols.

        // Now each symbol's defines table needs to be sorted according to these scores.
        //for (m.all_symbols.items) |*symbol| {
        //    for (symbol.clauses) |*defines| {
        //        defines.sort(struct {
        //            define_scores: *std.StringHashMap(u32),
        //            names: []const []const u8,

        //            pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
        //                const a = ctx.define_scores.get(ctx.names[a_index]).?;
        //                const b = ctx.define_scores.get(ctx.names[b_index]).?;
        //                return b < a;
        //            }
        //        }{
        //            .define_scores = &define_scores,
        //            .names = defines.keys(),
        //        });
        //    }
        //}

        std.sort.sort(Symbol, m.all_symbols.items, &define_scores, struct {
            pub fn lessThan(context: *std.StringHashMap(u32), lhs: Symbol, rhs: Symbol) bool {
                // TODO notice symbol dependencies, prioritize those

                // Now we sort by the defines that apply to the most symbols.
                const lhs_conjunctives = lhs.clauses.conjunctives;
                const rhs_conjunctives = rhs.clauses.conjunctives;
                for (lhs_conjunctives[0..@minimum(lhs_conjunctives.len, rhs_conjunctives.len)]) |lhs_conjunctive, i| {
                    const lhs_name = lhs_conjunctive[0].name;
                    const rhs_name = rhs_conjunctives[i][0].name;
                    if (mem.eql(u8, lhs_name, rhs_name)) {
                        continue;
                    }
                    const lhs_score = context.get(lhs_name).?;
                    const rhs_score = context.get(rhs_name).?;
                    if (rhs_score < lhs_score) {
                        return true;
                    }
                    return mem.lessThan(u8, lhs_name, rhs_name);
                }

                if (lhs_conjunctives.len < rhs_conjunctives.len) {
                    return true;
                }

                // Tiebreaker is the identifier.
                return mem.lessThan(u8, lhs.identifier, rhs.identifier);
            }
        }.lessThan);
    }

    fn addSymbolsFromHeader(m: *Merger, header: Header) !void {
        if (!mem.eql(u8, m.h_path, "sys/appleapiopts.h")) return; // TODO remove this

        std.debug.print("iterate: {s}/{s}\n", .{ header.input.path, m.h_path });

        // We will repeatedly invoke Aro, bailing out when we see a dependency on
        // an unrecognized macro. In such case, we add it to the stack, and invoke
        // Aro for each possibility.
        var invoke_stack = std.ArrayList(Defines).init(m.arena);

        {
            // The first invocation is empty, no macros are available to inspect, except
            // for the input macros.
            var init_defines: Defines = .{};
            for (header.input.defines) |kv| {
                try init_defines.put(m.arena, kv.name, kv.define);
            }
            try invoke_stack.append(init_defines);
        }

        while (invoke_stack.popOrNull()) |macro_set| {
            {
                std.debug.print("invoke with inspectable macros:", .{});
                var it = macro_set.iterator();
                while (it.next()) |entry| {
                    const name = entry.key_ptr.*;
                    std.debug.print(" {s}", .{name});
                }
                std.debug.print("\n", .{});
            }

            var comp = arocc.Compilation.init(m.arena);
            defer comp.deinit();

            comp.target = header.input.target;
            comp.only_preprocess = true;
            comp.skip_standard_macros = true;
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

            var macro_buf = std.ArrayList(u8).init(comp.gpa);
            defer macro_buf.deinit();

            //try pp.addBuiltinMacros();

            {
                var it = macro_set.iterator();
                while (it.next()) |entry| {
                    const name = entry.key_ptr.*;
                    try pp.ok_defines.put(comp.gpa, name, {});
                    switch (entry.value_ptr.*) {
                        .def => {
                            try macro_buf.writer().print("#define {s}\n", .{name});
                        },
                        .undef => {},
                        .string => |s| {
                            try macro_buf.writer().print("#define {s} {s}\n", .{ name, s });
                        },
                    }
                }
            }

            const builtin = try comp.generateBuiltinMacros(&macro_buf);
            const source = try comp.addSourceFromBuffer(m.h_path, header.source_bytes);

            _ = try pp.preprocess(builtin);
            const eof = pp.preprocess(source) catch |err| switch (err) {
                error.UnexpectedMacro => {
                    const macro_name = try m.arena.dupe(u8, pp.unexpected_macro);
                    std.debug.print("branch on '{s}', adding both ifdef and ifndef to stack\n", .{
                        macro_name,
                    });
                    var def_case = try macro_set.clone(comp.gpa);
                    var undef_case = try macro_set.clone(comp.gpa);
                    try def_case.put(comp.gpa, macro_name, .def);
                    try undef_case.put(comp.gpa, macro_name, .undef);
                    try invoke_stack.appendSlice(&.{ def_case, undef_case });
                    continue;
                },
                else => |e| return e,
            };
            try pp.tokens.append(pp.comp.gpa, eof);

            if (comp.diag.list.items.len != 0) {
                comp.renderErrors();
                // TODO output errors and warnings
                continue;
            }

            {
                // Remove uninteresting macros
                for (header.input.defines) |kv| {
                    _ = pp.defines.remove(kv.name);
                }
            }

            var it = pp.defines.iterator();
            while (it.next()) |entry| {
                const name = entry.key_ptr.*;
                const tokens = entry.value_ptr.tokens;
                // TODO strip whitespace and comments
                const body = b: {
                    if (tokens.len == 0) break :b "";
                    const source_bytes = comp.getSource(tokens[0].source).buf;
                    break :b source_bytes[tokens[0].start..tokens[tokens.len - 1].end];
                };
                // avoid emitting symbols which would define a macro already defined
                if (macro_set.get(name)) |dep_macro| {
                    switch (dep_macro) {
                        .def => if (body.len == 0) continue,
                        .string => |s| if (mem.eql(u8, body, s)) continue,
                        .undef => {},
                    }
                }
                std.debug.print("found macro: '{s}': '{s}'\n", .{ name, body });
                try m.all_symbols.append(m.arena, .{
                    .clauses = try definesToClauses(m.arena, macro_set),
                    .identifier = try m.arena.dupe(u8, name),
                    .contents = try m.arena.dupe(u8, body),
                });
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
    }
};

/// converts e.g. `a and b and c` to `(a) and (b) and (c)`
fn definesToClauses(arena: Allocator, defines: Defines) !Clauses {
    const conjunctives = try arena.alloc([]NamedDefine, defines.count());
    for (conjunctives) |*inner_list, i| {
        inner_list.* = try arena.create([1]NamedDefine);
        inner_list.*[0] = .{
            .name = defines.keys()[i],
            .define = defines.values()[i],
        };
    }
    return .{ .conjunctives = conjunctives };
}
