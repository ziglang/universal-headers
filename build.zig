const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});

    const libespresso = b.dependency("libespresso", .{
        .target = target,
        .optimize = mode,
    });
    const libeqntott = b.dependency("libeqntott", .{
        .target = target,
        .optimize = mode,
    });

    const exe = b.addExecutable(.{
        .name = "universal-headers",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
    });
    exe.addAnonymousModule("arocc", .{
        .source_file = .{ .path = "arocc/src/lib.zig" },
    });
    exe.linkLibrary(libespresso.artifact("espresso"));
    exe.linkLibrary(libeqntott.artifact("eqntott-lib"));
    exe.linkLibC();
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
