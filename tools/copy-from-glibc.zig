//! This script is for copying headers from an external glibc directory after
//! building them locally, into the set of input headers in this repository
//! to be checked into source control.

const std = @import("std");

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    const args = try std.process.argsAlloc(arena);
    const glibcs = args[1]; // e.g. $HOME/Downloads/glibc/multi-2.33/install/glibcs
    const headers = args[2]; // e.g. ./headers if you run from source checkout
    const glibc_ver = args[3]; // e.g. 2.34

    var glibcs_dir = try std.fs.cwd().openDir(glibcs, .{});
    defer glibcs_dir.close();

    for (glibc_target_names) |glibc_target_name| {
        const sub_path = try std.fs.path.join(arena, &.{ glibc_target_name, "usr", "include" });
        var sub_dir = try glibcs_dir.openIterableDir(sub_path, .{});
        defer sub_dir.close();

        var walker = try sub_dir.walk(arena);
        while (try walker.next()) |entry| {
            if (entry.kind != .File) continue;
            const dest_path = try std.fmt.allocPrint(arena, "{s}/{s}.{s}/{s}", .{
                headers, glibc_target_name, glibc_ver, entry.path,
            });
            const dest_dirname = std.fs.path.dirname(dest_path).?;
            var dest_dir = try std.fs.cwd().makeOpenPath(dest_dirname, .{});
            defer dest_dir.close();
            try sub_dir.dir.copyFile(entry.path, dest_dir, entry.basename, .{});
        }
    }
}

const glibc_target_names = [_][]const u8{
    "aarch64_be-linux-gnu",
    "aarch64-linux-gnu",
    "arc-linux-gnu",
    "arc-linux-gnuhf",
    "armeb-linux-gnueabi",
    "armeb-linux-gnueabihf",
    "arm-linux-gnueabi",
    "arm-linux-gnueabihf",
    "arm-linux-gnueabihf-v7a",
    "arm-linux-gnueabi-v4t",
    "csky-linux-gnuabiv2",
    "csky-linux-gnuabiv2-soft",
    "i486-linux-gnu",
    "i586-linux-gnu",
    "i686-linux-gnu",
    "ia64-linux-gnu",
    "m68k-linux-gnu",
    "mips64el-linux-gnu-n32",
    "mips64el-linux-gnu-n32-nan2008",
    "mips64el-linux-gnu-n32-nan2008-soft",
    "mips64el-linux-gnu-n32-soft",
    "mips64el-linux-gnu-n64",
    "mips64el-linux-gnu-n64-nan2008",
    "mips64el-linux-gnu-n64-nan2008-soft",
    "mips64el-linux-gnu-n64-soft",
    "mips64-linux-gnu-n32",
    "mips64-linux-gnu-n32-nan2008",
    "mips64-linux-gnu-n32-nan2008-soft",
    "mips64-linux-gnu-n32-soft",
    "mips64-linux-gnu-n64",
    "mips64-linux-gnu-n64-nan2008",
    "mips64-linux-gnu-n64-nan2008-soft",
    "mips64-linux-gnu-n64-soft",
    "mipsel-linux-gnu",
    "mipsel-linux-gnu-nan2008",
    "mipsel-linux-gnu-nan2008-soft",
    "mipsel-linux-gnu-soft",
    "mipsisa32r6el-linux-gnu",
    "mipsisa64r6el-linux-gnu-n32",
    "mipsisa64r6el-linux-gnu-n64",
    "mips-linux-gnu",
    "mips-linux-gnu-nan2008",
    "mips-linux-gnu-nan2008-soft",
    "mips-linux-gnu-soft",
    "powerpc64le-linux-gnu",
    "powerpc64-linux-gnu",
    "powerpc-linux-gnu",
    "powerpc-linux-gnu-power4",
    "powerpc-linux-gnu-soft",
    "riscv32-linux-gnu-rv32imac-ilp32",
    "riscv32-linux-gnu-rv32imafdc-ilp32",
    "riscv32-linux-gnu-rv32imafdc-ilp32d",
    "riscv64-linux-gnu-rv64imac-lp64",
    "riscv64-linux-gnu-rv64imafdc-lp64",
    "riscv64-linux-gnu-rv64imafdc-lp64d",
    "s390x-linux-gnu",
    "sparc64-linux-gnu",
    "sparcv8-linux-gnu-leon3",
    "sparcv9-linux-gnu",
    "x86_64-linux-gnu",
    "x86_64-linux-gnu-x32",
};
