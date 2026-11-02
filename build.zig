const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // Default to a fully static musl binary on Linux: synoterm must never
    // depend on the host's glibc (DSM ships 2.26; a native build needs 2.36+
    // and dies at exec time with "GLIBC_2.xx not found").
    // Override with -Dtarget=native if you really want a dynamic binary.
    const default_target: std.Target.Query = if (builtin.os.tag == .linux)
        .{ .abi = .musl }
    else
        .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "synoterm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run synoterm (dev mode)");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
