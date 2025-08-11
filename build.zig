
const std = @import("std");

pub fn build(b: *std.Build) void {

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const apps = [_][]const u8{"server", "client"};

    inline for (apps) |app| {
        const exe = b.addExecutable(.{
            .name = app,
            .root_source_file = b.path("src/" ++ app ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
//            .strip = true,
        });
        b.installArtifact(exe);
    }
}
