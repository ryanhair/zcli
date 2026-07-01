const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const zinput = zcli.zinput;

/// A built-in plugin the user can opt into during `init`. `tag` is the enum
/// tag passed to `zcli.builtin(.<tag>, .{})` in the generated build.zig.
const BuiltinChoice = struct {
    tag: []const u8,
    label: []const u8,
    default: bool,
};

const builtin_choices = [_]BuiltinChoice{
    .{ .tag = "help", .label = "zcli_help — --help output for the app and every command", .default = true },
    .{ .tag = "version", .label = "zcli_version — --version flag", .default = true },
    .{ .tag = "not_found", .label = "zcli_not_found — \"did you mean?\" suggestions for mistyped commands", .default = true },
    .{ .tag = "completions", .label = "zcli_completions — shell completion scripts (bash/zsh/fish)", .default = false },
    .{ .tag = "config", .label = "zcli_config — load option defaults from a config file", .default = false },
    .{ .tag = "output", .label = "zcli_output — --output flag for json/table/plain output", .default = false },
    .{ .tag = "github_upgrade", .label = "zcli_github_upgrade — self-update from GitHub releases", .default = false },
};

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

pub fn execute(args: Args, options: Options, context: *Context) !void {
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

    // Validate the target directory before prompting or creating anything, so we
    // never leave a half-created project behind if validation fails or the user
    // aborts the plugin prompt.
    if (use_current_dir) {
        // Check if current directory is empty or contains only hidden files
        var dir = try cwd.openDir(io, ".", .{ .iterate = true });
        defer dir.close(io);
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
    } else {
        // Check if directory already exists (access succeeds => the path exists).
        if (cwd.access(io, args.name, .{})) |_| {
            try stderr.print("Error: Directory '{s}' already exists\n", .{args.name});
            return error.PathAlreadyExists;
        } else |err| switch (err) {
            error.FileNotFound => {}, // Good, directory doesn't exist
            else => return err,
        }

        try stdout.print("Creating new zcli project: {s}\n", .{project_name});
    }

    // Ask which built-in plugins to include, before touching the filesystem.
    // Falls back to the preselected defaults when stdin is not a TTY.
    var choices: [builtin_choices.len][]const u8 = undefined;
    var defaults: [builtin_choices.len]bool = undefined;
    for (builtin_choices, 0..) |choice, i| {
        choices[i] = choice.label;
        defaults[i] = choice.default;
    }
    const selected = try zinput.multiSelect(stdout, context.stdin(), allocator, .{
        .message = "Select built-in plugins to include:",
        .choices = &choices,
        .defaults = &defaults,
    });
    defer allocator.free(selected);

    // Build the `zcli.builtin(...)` registration lines for build.zig.
    var plugins_aw = std.Io.Writer.Allocating.init(allocator);
    defer plugins_aw.deinit();
    for (selected) |idx| {
        try plugins_aw.writer.print("            zcli.builtin(.{s}, .{{}}),\n", .{builtin_choices[idx].tag});
    }
    const plugins_block = plugins_aw.written();

    // Now that the destination is validated and plugins are chosen, create and
    // open the project directory.
    if (!use_current_dir) try cwd.createDir(io, args.name, .default_dir);
    var project_dir = try cwd.openDir(io, if (use_current_dir) "." else args.name, .{});
    defer project_dir.close(io);

    // Create src and src/commands directories
    try project_dir.createDir(io, "src", .default_dir);
    try project_dir.createDir(io, "src/commands", .default_dir);

    // Generate build.zig.zon
    try stdout.print("  Creating build.zig.zon...\n", .{});
    // Use zcli package from GitHub archive
    const zcli_version = "0.9.3";
    // Package fingerprint: high 32 bits are a checksum of the package name, low
    // 32 bits a random id. Zig rejects a zero fingerprint at build time.
    const fingerprint: u64 = blk: {
        const checksum = std.hash.Crc32.hash(project_identifier);
        var id_bytes: [4]u8 = undefined;
        io.random(&id_bytes);
        var id = std.mem.readInt(u32, &id_bytes, .little);
        if (id == 0) id = 1;
        break :blk (@as(u64, checksum) << 32) | id;
    };
    const zon_content = try std.fmt.allocPrint(allocator,
        \\.{{
        \\    .name = .{s},
        \\    .version = "{s}",
        \\    .fingerprint = 0x{x:0>16},
        \\    .minimum_zig_version = "0.16.0",
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
    , .{ project_identifier, app_version, fingerprint, zcli_version });
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
        \\{s}        }},
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
    , .{ project_name, plugins_block, project_name, app_version, app_description });
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
        \\pub fn main(init: std.process.Init) !void {
        \\    const args = try init.minimal.args.toSlice(init.arena.allocator());
        \\    var app = registry.init();
        \\    app.run(init.gpa, init.io, init.environ_map, args) catch |err| switch (err) {
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
        \\const Context = @import("command_registry").Context;
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
        \\pub fn execute(args: Args, options: Options, context: *Context) !void {
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
