const std = @import("std");
const zcli = @import("zcli");
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("zcli", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{ .name = "invocation-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    exe.root_module.addImport("zcli", dep.module("zcli"));
    const policy = b.createModule(.{ .root_source_file = b.path("src/policy.zig"), .target = target, .optimize = optimize });
    const registry = try zcli.generate(b, exe, dep, .{
        .commands_dir = "src/commands",
        .app_name = "invocation-fixture",
        .app_description = "Failure policy integration fixture",
        .failure_policy_module = policy,
        .exit_codes = .{ .usage = 64, .command_not_found = 65, .command_failed = 7 },
    });
    exe.root_module.addImport("command_registry", registry);
    b.installArtifact(exe);
}
