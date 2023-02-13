const std = @import("std");
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("espresso.h");
    @cInclude("x.h");
    @cInclude("hdr.h");
});

export var exprs: [c.NOUTPUTS]*c.BNODE = undefined;
export var pts: [c.NPTERMS]*c.PTERM = undefined;

extern var ninputs: i32;
extern var noutputs: i32;
extern var inorder: [*]*c.Nt;
extern var outorder: [*]*c.Nt;
extern var yyfile: *c.FILE;

extern "c" fn yyparse() void;
extern "c" fn canon(*c.BNODE) *c.BNODE;
extern "c" fn read_ones(*c.BNODE, i32) *c.PTERM;
extern "c" fn cmppt(?*const anyopaque, ?*const anyopaque) i32;

extern var cube: c.cube_struct;

pub fn eqnToTruthTable(s: [:0]const u8, writer: anytype) !void {
    const ptr = @ptrCast(?*anyopaque, @qualCast([*:0]u8, s.ptr));
    yyfile = c.fmemopen(ptr, s.len, "r");
    defer _ = c.fclose(yyfile);
    yyparse();

    var ptexprs: [c.NOUTPUTS]*c.PTERM = undefined;

    var o: i32 = 0;
    while (o < noutputs) : (o += 1) {
        const expr = &exprs[@intCast(usize, o)];
        expr.* = canon(expr.*);
        ptexprs[@intCast(usize, o)] = read_ones(expr.*, o);
    }

    var npts: i32 = 0;
    o = 0;
    while (o < noutputs) : (o += 1) {
        var pt = ptexprs[@intCast(usize, o)];
        while (true) {
            pt.index = @intCast(i16, c.ptindex(pt.ptand, ninputs));
            if (npts < c.NPTERMS) {
                pts[@intCast(usize, npts)] = pt;
                npts += 1;
            }
            if (pt.next) |next| {
                pt = next;
            } else break;
        }
    }

    try writer.print(".i {d}\n", .{ninputs});
    try writer.print(".o {d}\n", .{noutputs});
    try writer.print(".p {d}\n", .{npts});
    try writeTruthTable(&pts, npts, writer);
    try writer.writeAll(".e\n");
}

fn writeTruthTable(pterms: [*]*c.PTERM, npts: i32, writer: anytype) !void {
    c.qsort(@intToPtr(?*anyopaque, @ptrToInt(pterms)), @intCast(usize, npts), @sizeOf(*c.PTERM), cmppt);
    var i: usize = 0;
    while (i < npts) : (i += 1) {
        try writeRow(pterms[i], writer);
    }
}

fn writeRow(pterm: *c.PTERM, writer: anytype) !void {
    const inc: [3]u8 = .{ '0', '1', '-' };
    const outc: [3]u8 = .{ '0', '1', 'x' };

    var i: usize = 0;
    while (i < ninputs) : (i += 1) {
        try writer.writeByte(inc[@intCast(usize, pterm.ptand[i])]);
    }

    try writer.writeAll("  ");

    i = 0;
    while (i < noutputs) : (i += 1) {
        try writer.writeByte(outc[@intCast(usize, pterm.ptor[i])]);
    }

    try writer.writeByte('\n');
}

pub const PLA = struct {
    raw_pla: c.pPLA,

    /// TODO unpack c.read_pla and re-implement with Zig.
    pub fn openPath(path: [:0]const u8) !PLA {
        const file = c.fopen(path, "r") orelse return error.NotFound;
        defer _ = c.fclose(file);
        return openStream(file);
    }

    /// TODO a hack so that I can postpone reimplementing internal espresso
    /// routines to work with memory or file descriptors rather than C streams.
    pub fn openMem(s: [:0]const u8) !PLA {
        const ptr = @ptrCast(?*anyopaque, @qualCast([*:0]u8, s.ptr));
        const memf = c.fmemopen(ptr, s.len + 1, "r");
        defer _ = c.fclose(memf);
        return openStream(memf);
    }

    fn openStream(file: *c.FILE) !PLA {
        var raw_pla: c.pPLA = undefined;
        switch (c.read_pla(file, c.TRUE, c.TRUE, c.FD_type, &raw_pla)) {
            1 => {}, // success
            -1 => return error.UnexpectedEOF,
            else => |e| {
                std.log.err("unexpected errno: {d}", .{e});
                return error.UnexpectedError;
            },
        }
        raw_pla.*.filename = null; // TODO is this really needed here?

        return PLA{ .raw_pla = raw_pla };
    }

    pub fn minimize(pla: PLA) !c.cost_t {
        const fold = c.sf_save(pla.raw_pla.*.F);
        errdefer {
            pla.raw_pla.*.F = fold;
            _ = c.check_consistency(pla.raw_pla);
        }

        pla.raw_pla.*.F = c.espresso(pla.raw_pla.*.F, pla.raw_pla.*.D, pla.raw_pla.*.R);

        const ret = try execute(.@"error", c.verify, .{
            pla.raw_pla.*.F, fold, pla.raw_pla.*.D,
        }, c.VERIFY_TIME, pla.raw_pla.*.F);

        c.free_cover(fold);

        return ret.cost;
    }

    /// Based on `fprint_pla` routine with eqntott output mode.
    /// See `eqn_output` routine.
    pub fn writeSolution(pla: PLA, var_labels: []const []const u8, writer: anytype) !void {
        assert(cube.output != -1);

        var first_or: bool = false;
        var first_and: bool = false;
        var i: i32 = 0;

        assert(cube.part_size[@intCast(usize, cube.output)] == 1);

        while (i < cube.part_size[@intCast(usize, cube.output)]) : (i += 1) {
            first_or = true;

            // foreach_set(PLA->F, last, p)
            var set_i: i32 = 0;
            const F = pla.raw_pla.*.F.*;
            const set_count = F.count * F.wsize;
            var p = F.data;

            while (set_i < set_count) : (set_i += 1) {
                if (isInSet(p, i + cube.first_part[@intCast(usize, cube.output)])) {
                    if (first_or) {
                        try writer.writeByte('(');
                    } else {
                        try writer.writeAll(" || (");
                    }
                    first_or = false;
                    first_and = true;

                    var var_i: i32 = 0;
                    while (var_i < cube.num_binary_vars) : (var_i += 1) {
                        const x = getInput(p, var_i);
                        if (x == c.DASH) continue;

                        const label = var_labels[@intCast(usize, var_i)];
                        if (!first_and) {
                            try writer.writeAll(" && ");
                        }
                        first_and = false;

                        if (x == c.ZERO) {
                            try writer.writeByte('!');
                        }
                        try writer.print("{s}", .{label});
                    }

                    try writer.writeByte(')');
                }

                p += @intCast(usize, F.wsize);
            }
        }
    }

    /// #define WHICH_WORD(e)  (((e) >> LOGBPI) + 1)
    fn whichWord(e: i32) i32 {
        return (e >> c.LOGBPI) + 1;
    }

    /// #define WHICH_BIT(e)  ((e) & (BPI - 1))
    fn whichBit(e: i32) u5 {
        return @intCast(u5, e & (c.BPI - 1));
    }

    /// #define is_in_set(set, e)  (set[WHICH_WORD(e)] & (1 << WHICH_BIT(e)))
    fn isInSet(p: c.pset, e: i32) bool {
        const index = whichWord(e);
        const tst = p[@intCast(usize, index)] & (@as(u32, 1) << whichBit(e));
        return tst != 0;
    }

    /// #define GETINPUT(c, pos)
    fn getInput(p: c.pset, pos: i32) u32 {
        const index = whichWord(2 * pos);
        return (p[@intCast(usize, index)] >> whichBit(2 * pos)) & 3;
    }

    pub fn logSolution(pla: PLA) !void {
        _ = try execute(.{ .type = void }, c.fprint_pla, .{
            c.stderr, pla.raw_pla, c.FD_type,
        }, c.WRITE_TIME, pla.raw_pla.*.F);
    }

    pub fn deinit(pla: PLA) void {
        c.free_PLA(pla.raw_pla);
        if (@as(?*c_int, c.cube.part_size)) |x| {
            c.free(x);
        }
        c.setdown_cube();
        c.sf_cleanup();
        c.sm_cleanup();
    }

    const ExecuteRetType = union(enum) {
        @"error",
        type: type,
    };

    fn ExecuteResult(comptime Ret: type) type {
        return struct {
            ret: Ret,
            cost: c.cost_t,
        };
    }

    /// Encapsulation of the EXECUTE macro
    fn execute(
        comptime ret_type: ExecuteRetType,
        func: anytype,
        args: anytype,
        record_type: u8,
        s: anytype,
    ) !ExecuteResult(switch (ret_type) {
        .@"error" => void,
        .type => |t| t,
    }) {
        var cost: c.cost_t = undefined;
        var t = c.ptime();
        const ret = @call(.auto, func, args);
        c.totals(t, record_type, s, &cost);
        if (ret_type == .@"error" and ret > 0) {
            std.log.err("execute failed with errno: {d}", .{ret});
            return error.ExecuteFailed;
        }
        return ExecuteResult(switch (ret_type) {
            .@"error" => void,
            .type => |tt| tt,
        }){
            .ret = if (ret_type == .@"error") {} else ret,
            .cost = cost,
        };
    }
};
