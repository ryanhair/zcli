const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Initialize a new zcli project",
    .examples = &.{
        "init my-app",
        "init my-app --description \"My awesome CLI\"",
    },
    .args = .{
        .name = "Name of the project (will be the executable name)",
    },
    .options = .{
        .description = .{ .desc = "Description of your CLI application" },
        .version = .{ .desc = "Initial version number" },
    },
};

pub const Args = struct {
    name: []const u8,
};

pub const Options = struct {
    description: ?[]const u8 = null,
    version: ?[]const u8 = null,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    const allocator = context.allocator;
    const stdout = context.stdout();
    const stderr = context.stderr();

    const project_name = args.name;
    const app_description = options.description orelse "A CLI application built with zcli";
    const app_version = options.version orelse "0.1.0";

    // Check if directory already exists
    const cwd = std.fs.cwd();
    cwd.access(project_name, .{}) catch |err| switch (err) {
        error.FileNotFound => {}, // Good, directory doesn't exist
        else => {
            try stderr.print("Error: Directory '{s}' already exists\n", .{project_name});
            return err;
        },
    };

    try stdout.print("Creating new zcli project: {s}\n", .{project_name});

    // Create project directory
    try cwd.makeDir(project_name);
    var project_dir = try cwd.openDir(project_name, .{});
    defer project_dir.close();

    // Create src and src/commands directories
    try project_dir.makeDir("src");
    try project_dir.makeDir("src/commands");

    // Generate build.zig.zon
    try stdout.print("  Creating build.zig.zon...\n", .{});
    const zon_content = try std.fmt.allocPrint(allocator,
        \\.{{
        \\    .name = .{s},
        \\    .version = "{s}",
        \\    .minimum_zig_version = "0.14.1",
        \\    .dependencies = .{{
        \\        .zcli = .{{
        \\            .url = "https://github.com/ryanhair/zcli/archive/refs/heads/main.tar.gz",
        \\        }},
        \\    }},
        \\    .paths = .{{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\    }},
        \\}}
        \\
    , .{ project_name, app_version });
    defer allocator.free(zon_content);

    var zon_file = try project_dir.createFile("build.zig.zon", .{});
    defer zon_file.close();
    try zon_file.writeAll(zon_content);

    // Generate build.zig
    try stdout.print("  Creating build.zig...\n", .{});
    const build_content = try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const target = b.standardTargetOptions(.{{}});
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\
        \\    // Get zcli dependency
        \\    const zcli_dep = b.dependency("zcli", .{{
        \\        .target = target,
        \\        .optimize = optimize,
        \\    }});
        \\    const zcli_module = zcli_dep.module("zcli");
        \\
        \\    // Create the executable
        \\    const exe = b.addExecutable(.{{
        \\        .name = "{s}",
        \\        .root_source_file = b.path("src/main.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    }});
        \\
        \\    exe.root_module.addImport("zcli", zcli_module);
        \\
        \\    // Generate command registry with built-in plugins
        \\    const zcli = @import("zcli");
        \\    const cmd_registry = zcli.generate(b, exe, zcli_module, .{{
        \\        .commands_dir = "src/commands",
        \\        .plugins = &[_]zcli.PluginConfig{{
        \\            .{{ .name = "zcli-help", .path = zcli_dep.builder.pathFromRoot("packages/core/plugins/zcli-help") }},
        \\            .{{ .name = "zcli-not-found", .path = zcli_dep.builder.pathFromRoot("packages/core/plugins/zcli-not-found") }},
        \\        }},
        \\        .app_name = "{s}",
        \\        .app_version = "{s}",
        \\        .app_description = "{s}",
        \\    }});
        \\
        \\    exe.root_module.addImport("command_registry", cmd_registry);
        \\    b.installArtifact(exe);
        \\
        \\    // Add run step for convenience
        \\    const run_cmd = b.addRunArtifact(exe);
        \\    run_cmd.step.dependOn(b.getInstallStep());
        \\    if (b.args) |args| run_cmd.addArgs(args);
        \\
        \\    const run_step = b.step("run", "Run the app");
        \\    run_step.dependOn(&run_cmd.step);
        \\}}
        \\
    , .{ project_name, project_name, app_version, app_description });
    defer allocator.free(build_content);

    var build_file = try project_dir.createFile("build.zig", .{});
    defer build_file.close();
    try build_file.writeAll(build_content);

    // Generate src/main.zig
    try stdout.print("  Creating src/main.zig...\n", .{});
    const main_content =
        \\const std = @import("std");
        \\const registry = @import("command_registry");
        \\
        \\pub fn main() !void {
        \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        \\    defer _ = gpa.deinit();
        \\
        \\    var app = registry.init();
        \\    app.run(gpa.allocator()) catch |err| switch (err) {
        \\        error.CommandNotFound => std.process.exit(1),
        \\        else => return err,
        \\    };
        \\}
        \\
    ;

    var src_dir = try project_dir.openDir("src", .{});
    defer src_dir.close();

    var main_file = try src_dir.createFile("main.zig", .{});
    defer main_file.close();
    try main_file.writeAll(main_content);

    // Generate example command: src/commands/hello.zig
    try stdout.print("  Creating example command (hello)...\n", .{});
    const hello_content =
        \\const std = @import("std");
        \\const zcli = @import("zcli");
        \\
        \\pub const meta = .{
        \\    .description = "Say hello to someone",
        \\    .examples = &.{
        \\        "hello World",
        \\        "hello Alice --loud",
        \\    },
        \\};
        \\
        \\pub const Args = struct {
        \\    name: []const u8,
        \\};
        \\
        \\pub const Options = struct {
        \\    loud: bool = false,
        \\};
        \\
        \\pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
        \\    const greeting = if (options.loud) "HELLO" else "Hello";
        \\    try context.stdout().print("{s}, {s}!\n", .{ greeting, args.name });
        \\}
        \\
    ;

    var commands_dir = try src_dir.openDir("commands", .{});
    defer commands_dir.close();

    var hello_file = try commands_dir.createFile("hello.zig", .{});
    defer hello_file.close();
    try hello_file.writeAll(hello_content);

    // Success message
    try stdout.print("\n✓ Project '{s}' created successfully!\n\n", .{project_name});
    try stdout.print("Next steps:\n", .{});
    try stdout.print("  cd {s}\n", .{project_name});
    try stdout.print("  zig build\n", .{});
    try stdout.print("  ./zig-out/bin/{s} hello World\n", .{project_name});
    try stdout.print("  ./zig-out/bin/{s} --help\n", .{project_name});
}
