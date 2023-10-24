const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const textual = true;
    if (!textual) {
        const arocc_dep = b.anonymousDependency("arocc", @import("arocc/build.zig"), .{
            .target = target,
            .optimize = optimize,
        });

        const exe = b.addExecutable(.{
            .name = "universal-headers",
            .root_source_file = .{ .path = "src/main.zig" },
            .target = target,
            .optimize = optimize,
        });
        exe.addModule("arocc", arocc_dep.module("aro"));
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    } else {
        const addHeaders = b.addExecutable(.{
            .name = "addHeaders",
            .root_source_file = .{ .path = "src/textdiff/addHeaders.zig" },
            .target = target,
            .optimize = optimize,
        });
        b.installArtifact(addHeaders);

        const outputHeaders = b.addExecutable(.{
            .name = "outputHeaders",
            .root_source_file = .{ .path = "src/textdiff/outputHeaders.zig" },
            .target = target,
            .optimize = optimize,
        });
        b.installArtifact(outputHeaders);

        const testHeaders = b.addExecutable(.{
            .name = "testHeaders",
            .root_source_file = .{ .path = "src/textdiff/testHeaders.zig" },
            .target = target,
            .optimize = optimize,
        });
        b.installArtifact(testHeaders);
    }
}
