const std = @import("std");
const zcli = @import("zcli");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("zcli", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{ .name = "metadata-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    exe.root_module.addImport("zcli", dep.module("zcli"));
    const options = b.addOptions();
    options.addOption([]const u8, "case", b.option([]const u8, "case", "Metadata validation case") orelse "valid");
    const registry = try zcli.generate(b, exe, dep, .{
        .commands_dir = "src/commands",
        .plugins_dir = "src/plugins",
        .shared_modules = &.{.{ .name = "fixture_case", .module = options.createModule() }},
        .app_name = "metadata-fixture",
        .app_description = "Metadata validation fixture",
    });
    exe.root_module.addImport("command_registry", registry);
    b.installArtifact(exe);
}
