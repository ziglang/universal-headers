const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Target = std.Target;
const assert = std.debug.assert;

const arocc = @import("arocc");
const espresso = @import("espresso.zig");

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
    //        .ofmt = .elf,
    //    },
    //},
    //.{
    //    .path = "x86_64-linux-musl",
    //    .target = .{
    //        .cpu = Target.Cpu.baseline(.x86_64),
    //        .os = Target.Os.Tag.linux.defaultVersionRange(.x86_64),
    //        .abi = .musl,
    //        .ofmt = .elf,
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
            .ofmt = .macho,
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
            .ofmt = .macho,
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

    pub fn format(value: Symbol, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("Symbol '{s}'\n", .{value.identifier});
        try writer.print("  contents: {s}\n", .{value.contents});
        for (value.clauses.conjunctives) |conj| {
            try writer.writeAll("  AND\n");
            try writer.writeAll("    OR\n");
            for (conj) |def| switch (def.define) {
                .def => try writer.print("      {s}\n", .{def.name}),
                .undef => try writer.print("      !{s}\n", .{def.name}),
                .string => |s| try writer.print("      {s} == {s}\n", .{ def.name, s }),
            };
        }
    }
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
    for (&inputs) |*input| {
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

        try w.writeAll("#pragma once\n");

        try merger.minimize(w);

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
    }

    fn minimize(m: *Merger, writer: anytype) !void {
        var symbols_by_name = std.StringHashMap(std.ArrayList(Symbol)).init(m.arena);
        for (m.all_symbols.items) |symbol| {
            const gop = try symbols_by_name.getOrPut(symbol.identifier);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(Symbol).init(m.arena);
            }
            try gop.value_ptr.append(symbol);
        }

        var it = symbols_by_name.iterator();
        while (it.next()) |entry| {
            const first = entry.value_ptr.items[0];

            std.debug.print("minimizing boolean expression for symbol '{s}'\n", .{first.identifier});

            var in_labels = std.ArrayList([]const u8).init(m.arena);
            const out_label = "z";

            var start: u16 = 0;
            var encoding = std.StringArrayHashMap(struct {
                index: u16,
                def: NamedDefine,
            }).init(m.arena);
            for (entry.value_ptr.items) |symbol| {
                for (symbol.clauses.conjunctives) |conj| {
                    for (conj) |def| {
                        const name = switch (def.define) {
                            .def, .undef => try std.fmt.allocPrint(m.arena, "{s}", .{def.name}),
                            .string => |s| try std.fmt.allocPrint(m.arena, "{s} == {s}", .{ def.name, s }),
                        };
                        const gop = try encoding.getOrPut(name);
                        if (!gop.found_existing) {
                            const index = @intCast(u16, in_labels.items.len);
                            const enc = try std.fmt.allocPrint(m.arena, "a_{d}", .{start});
                            try in_labels.append(enc);
                            gop.value_ptr.* = .{
                                .index = index,
                                .def = def,
                            };
                            start += 1;
                        }
                    }
                }
            }

            var encoded_input = std.ArrayList(u8).init(m.arena);
            const in_writer = encoded_input.writer();
            try in_writer.writeAll("INORDER = ");
            for (in_labels.items) |label| {
                try in_writer.print("{s} ", .{label});
            }
            try in_writer.writeAll(";\n");
            try in_writer.print("OUTORDER = {s};\n", .{out_label});

            try in_writer.print("{s} = ", .{out_label});
            for (entry.value_ptr.items, 0..) |symbol, i| {
                for (symbol.clauses.conjunctives, 0..) |conj, k| {
                    for (conj, 0..) |def, j| {
                        const name = switch (def.define) {
                            .def, .undef => try std.fmt.allocPrint(m.arena, "{s}", .{def.name}),
                            .string => |s| try std.fmt.allocPrint(m.arena, "{s} == {s}", .{ def.name, s }),
                        };
                        const index = encoding.get(name).?.index;
                        const enc = in_labels.items[index];
                        try in_writer.print("(", .{});
                        switch (def.define) {
                            .def, .string => try in_writer.print("{s}", .{enc}),
                            .undef => try in_writer.print("!{s}", .{enc}),
                        }
                        if (conj.len > 1 and j < conj.len - 1) {
                            try in_writer.print(" | ", .{});
                        } else {
                            try in_writer.print(")", .{});
                        }
                    }

                    if (symbol.clauses.conjunctives.len > 1 and k < symbol.clauses.conjunctives.len - 1) {
                        try in_writer.print(" & ", .{});
                    }
                }
                if (entry.value_ptr.items.len > 1 and i < entry.value_ptr.items.len - 1) {
                    try in_writer.print(" | ", .{});
                }
            }
            try in_writer.writeAll(";\n");
            try in_writer.writeByte(0);

            var tt = std.ArrayList(u8).init(m.arena);
            try espresso.eqnToTruthTable(encoded_input.items[0 .. encoded_input.items.len - 1 :0], tt.writer());
            try tt.append(0);

            const pla = try espresso.PLA.openMem(tt.items[0 .. tt.items.len - 1 :0]);
            defer pla.deinit();
            const cost = try pla.minimize();
            _ = cost;

            try writer.print("#if ", .{});

            var output_labels = std.ArrayList([]const u8).init(m.arena);
            for (encoding.keys(), 0..) |_, i| {
                const def = encoding.values()[i].def;
                const name = switch (def.define) {
                    .def, .undef => try std.fmt.allocPrint(m.arena, "defined({s})", .{def.name}),
                    .string => |s| try std.fmt.allocPrint(m.arena, "{s} == {s}", .{ def.name, s }),
                };
                try output_labels.append(name);
            }

            try pla.writeSolution(output_labels.items, writer);
            try writer.writeByte('\n');

            if (first.contents.len == 0) {
                try writer.print("#define {s}\n", .{first.identifier});
            } else {
                try writer.print("#define {s} {s}\n", .{ first.identifier, first.contents });
            }

            try writer.print("#endif\n", .{});
        }
    }

    fn addSymbolsFromHeader(m: *Merger, header: Header) !void {
        if (!mem.eql(u8, m.h_path, "sys/appleapiopts.h")) return; // TODO remove this

        std.debug.print("iterate: {s}/{s}\n", .{ header.input.path, m.h_path });

        std.debug.print("find include guards: {s}/{s}\n", .{ header.input.path, m.h_path });
        const include_guard_name = name: {
            var comp = arocc.Compilation.init(m.arena);
            defer comp.deinit();

            comp.target = header.input.target;

            try comp.system_include_dirs.append(try comp.gpa.dupe(u8, m.sys_include));

            try comp.addDefaultPragmaHandlers();

            if (comp.target.abi == .msvc or comp.target.os.tag == .windows) {
                comp.langopts.setEmulatedCompiler(.msvc);
            }

            var pp = arocc.Preprocessor.init(&comp);
            defer pp.deinit();

            var macro_buf = std.ArrayList(u8).init(comp.gpa);
            defer macro_buf.deinit();

            try pp.addBuiltinMacros();

            const builtin = try comp.generateBuiltinMacros(&macro_buf);
            const source = try comp.addSourceFromBuffer(m.h_path, header.source_bytes);

            _ = try pp.preprocess(builtin);
            const eof = try pp.preprocess(source);
            try pp.tokens.append(pp.comp.gpa, eof);

            assert(pp.include_guards.count() == 1);
            var it = pp.include_guards.iterator();
            const entry = it.next().?;
            const include_guard_name = entry.value_ptr.*;
            break :name try m.arena.dupe(u8, include_guard_name);
        };
        std.debug.print("include guard: {s}\n", .{include_guard_name});

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
            pp.preserve_whitespace = true;

            var macro_buf = std.ArrayList(u8).init(comp.gpa);
            defer macro_buf.deinit();

            //try pp.addBuiltinMacros();

            // Ignore include guard
            try pp.ok_defines.put(comp.gpa, include_guard_name, {});

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

                // omit the include guard
                if (mem.eql(u8, name, include_guard_name)) continue;

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
    for (conjunctives, 0..) |*inner_list, i| {
        inner_list.* = try arena.create([1]NamedDefine);
        inner_list.*[0] = .{
            .name = defines.keys()[i],
            .define = defines.values()[i],
        };
    }
    return .{ .conjunctives = conjunctives };
}
