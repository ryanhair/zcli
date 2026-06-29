const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Initialize a new zcli project",
    .examples = &.{
        "init my-app",
        "init my-app --description \"My awesome CLI\"",
        "init . --description \"Initialize in current directory\"",
    },
    .args = .{
        .name = "Name of the project or '.' for current directory",
    },
    .options = .{
        .description = .{ .description = "Description of your CLI application" },
        .version = .{ .description = "Initial version number" },
    },
};

pub const Args = struct {
    name: []const u8,
};

pub const Options = struct {
    description: ?[]const u8 = null,
    version: ?[]const u8 = null,
};

pub fn execute(args: Args, options: Options, context: anytype) !void {
    const allocator = context.allocator;
    var stdout = context.stdout();
    var stderr = context.stderr();

    const cwd = std.Io.Dir.cwd();

    // Determine if we're using current directory or creating a new one
    const use_current_dir = std.mem.eql(u8, args.name, ".");

    // Get the project name
    const io = context.io.io;
    const project_name = if (use_current_dir) blk: {
        // Get current directory name
        var buf: [4096]u8 = undefined;
        const len = std.process.currentPath(io, &buf) catch break :blk try allocator.dupe(u8, "my-project");
        const cwd_path = buf[0..len];

        // Extract the directory name from the path
        const last_slash = std.mem.lastIndexOfScalar(u8, cwd_path, std.fs.path.sep) orelse 0;
        const dir_name = cwd_path[last_slash + 1 ..];

        break :blk try allocator.dupe(u8, dir_name);
    } else try allocator.dupe(u8, args.name);
    defer allocator.free(project_name);

    // Create a sanitized identifier-safe version (replace dashes with underscores)
    const project_identifier = blk: {
        var sanitized = try allocator.alloc(u8, project_name.len);
        for (project_name, 0..) |c, i| {
            sanitized[i] = if (c == '-') '_' else c;
        }
        break :blk sanitized;
    };
    defer allocator.free(project_identifier);

    const app_description = options.description orelse "A CLI application built with zcli";
    const app_version = options.version orelse "0.1.0";

    // Handle directory creation/validation
    var project_dir = if (use_current_dir) blk: {
        // Check if current directory is empty or contains only hidden files
        var dir = try cwd.openDir(io, ".", .{ .iterate = true });
        var iterator = dir.iterate();

        var has_visible_files = false;
        while (try iterator.next(io)) |entry| {
            // Ignore hidden files (starting with .)
            if (entry.name[0] != '.') {
                has_visible_files = true;
                break;
            }
        }

        if (has_visible_files) {
            try stderr.print("Error: Current directory is not empty\n", .{});
            try stderr.print("Tip: Only hidden files (starting with '.') are allowed\n", .{});
            return error.DirectoryNotEmpty;
        }

        try stdout.print("Initializing zcli project in current directory: {s}\n", .{project_name});
        break :blk try cwd.openDir(io, ".", .{});
    } else blk: {
        // Check if directory already exists
        cwd.access(io, args.name, .{}) catch |err| switch (err) {
            error.FileNotFound => {}, // Good, directory doesn't exist
            else => {
                try stderr.print("Error: Directory '{s}' already exists\n", .{args.name});
                return err;
            },
        };

        try stdout.print("Creating new zcli project: {s}\n", .{project_name});

        // Create project directory
        try cwd.createDir(io, args.name, .default_dir);
        break :blk try cwd.openDir(io, args.name, .{});
    };
    defer project_dir.close(io);

    // Create src and src/commands directories
    try project_dir.createDir(io, "src", .default_dir);
    try project_dir.createDir(io, "src/commands", .default_dir);

    // Generate build.zig.zon
    try stdout.print("  Creating build.zig.zon...\n", .{});
    // Use zcli package from GitHub archive
    const zcli_version = "0.9.3";
    const zon_content = try std.fmt.allocPrint(allocator,
        \\.{{
        \\    .name = .{s},
        \\    .version = "{s}",
        \\    .fingerprint = 0x0000000000000000,
        \\    .minimum_zig_version = "0.15.1",
        \\    .dependencies = .{{
        \\        .zcli = .{{
        \\            .url = "https://github.com/ryanhair/zcli/archive/refs/tags/v{s}.tar.gz",
        \\            .hash = "1220000000000000000000000000000000000000000000000000000000000000",
        \\        }},
        \\    }},
        \\    .paths = .{{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\    }},
        \\}}
        \\
    , .{ project_identifier, app_version, zcli_version });
    defer allocator.free(zon_content);

    var zon_file = try project_dir.createFile(io, "build.zig.zon", .{});
    defer zon_file.close(io);
    try zon_file.writeStreamingAll(io, zon_content);

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
        \\        .root_module = b.createModule(.{{
        \\            .root_source_file = b.path("src/main.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }}),
        \\    }});
        \\
        \\    exe.root_module.addImport("zcli", zcli_module);
        \\
        \\    // Generate command registry with built-in plugins
        \\    const zcli = @import("zcli");
        \\    const cmd_registry = zcli.generate(b, exe, zcli_dep, zcli_module, .{{
        \\        .commands_dir = "src/commands",
        \\        .plugins = &.{{
        \\            zcli.builtin(.help, .{{}}),
        \\            zcli.builtin(.version, .{{}}),
        \\            zcli.builtin(.not_found, .{{}}),
        \\            zcli.builtin(.completions, .{{}}),
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

    var build_file = try project_dir.createFile(io, "build.zig", .{});
    defer build_file.close(io);
    try build_file.writeStreamingAll(io, build_content);

    // Generate src/main.zig
    try stdout.print("  Creating src/main.zig...\n", .{});
    const main_content =
        \\const std = @import("std");
        \\const registry = @import("command_registry");
        \\
        \\pub fn main() !void {
        \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        \\    defer {
        \\        const deinit_status = gpa.deinit();
        \\        if (deinit_status == .leak) {
        \\            std.log.err("Memory leak detected!", .{});
        \\        }
        \\    }
        \\
        \\    var app = registry.init();
        \\    app.run(gpa.allocator()) catch |err| switch (err) {
        \\        error.CommandNotFound => std.process.exit(1),
        \\        else => return err,
        \\    };
        \\}
        \\
    ;

    var src_dir = try project_dir.openDir(io, "src", .{});
    defer src_dir.close(io);

    var main_file = try src_dir.createFile(io, "main.zig", .{});
    defer main_file.close(io);
    try main_file.writeStreamingAll(io, main_content);

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
        \\pub fn execute(args: Args, options: Options, context: anytype) !void {
        \\    comptime zcli.assertValidContext(@TypeOf(context));
        \\    const greeting = if (options.loud) "HELLO" else "Hello";
        \\    try context.stdout().print("{s}, {s}!\n", .{ greeting, args.name });
        \\}
        \\
    ;

    var commands_dir = try src_dir.openDir(io, "commands", .{});
    defer commands_dir.close(io);

    var hello_file = try commands_dir.createFile(io, "hello.zig", .{});
    defer hello_file.close(io);
    try hello_file.writeStreamingAll(io, hello_content);

    // Fetch zcli dependency
    fetch_deps: {
        try stdout.print("  Fetching dependencies (this may take a moment)...\n", .{});
        const zcli_url = try std.fmt.allocPrint(allocator, "https://github.com/ryanhair/zcli/archive/refs/tags/v{s}.tar.gz", .{zcli_version});
        defer allocator.free(zcli_url);

        var fetch_child = std.process.spawn(io, .{
            .argv = &.{ "zig", "fetch", "--save", zcli_url },
            .cwd = .{ .dir = project_dir },
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch {
            stdout.print("  Note: Run 'zig fetch --save {s}' to add the dependency\n", .{zcli_url}) catch {};
            break :fetch_deps;
        };
        _ = fetch_child.wait(io) catch {};
    }

    // Success message
    try stdout.print("\n✓ Project '{s}' created successfully!\n\n", .{project_name});
    try stdout.print("Next steps:\n", .{});
    if (!use_current_dir) {
        try stdout.print("  cd {s}\n", .{args.name});
    }
    try stdout.print("  zig build\n", .{});
    try stdout.print("  ./zig-out/bin/{s} hello World\n", .{project_name});
    try stdout.print("  ./zig-out/bin/{s} --help\n", .{project_name});
}
