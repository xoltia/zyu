const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const echo_exe = b.addExecutable(.{
        .name = "echo",
        .root_source_file = b.path("src/echo.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cat_exe = b.addExecutable(.{
        .name = "cat",
        .root_source_file = b.path("src/cat.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(echo_exe);
    b.installArtifact(cat_exe);
}
