const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const themed = zcli.theme.styled;
const ThemeContext = zcli.theme.ThemeContext;

const scaffold = @import("scaffold");
const spec = scaffold.spec;

pub const meta = .{
    .description = "Add a local plugin to your zcli project",
    .examples = &.{
        "add plugin telemetry",
        "add plugin auth -d \"Attach an auth token to every request\"",
    },
    .args = .{
        .name = "Plugin name (snake_case or kebab-case)",
    },
    .options = .{
        .description = .{ .description = "One-line description (used in the file header)", .short = 'd' },
    },
};

pub const Args = struct {
    name: []const u8,
};

pub const Options = struct {
    description: ?[]const u8 = null,
};

/// Maximum bytes read from build.zig when checking for `plugins_dir`.
const max_source_bytes = 1024 * 1024;

pub fn execute(args: Args, options: Options, context: *Context) !void {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const io = context.io;
    const cwd = std.Io.Dir.cwd();

    cwd.access(io, "src/commands", .{}) catch {
        return context.fail("Error: Not in a zcli project directory\nRun this command from the root of your zcli project (where build.zig is)", .{});
    };

    const name = spec.normalizeName(arena, args.name) catch |err| {
        return context.fail("Error: Invalid plugin name '{s}': {s}", .{ args.name, @errorName(err) });
    };

    // Single-file plugin, matching `add command`'s default (the directory form
    // `plugins/<name>/plugin.zig` remains available for plugins that grow).
    const file_path = try std.fmt.allocPrint(arena, "src/plugins/{s}.zig", .{name});
    if (fileExists(io, file_path)) {
        return context.fail("Error: plugin already exists: {s}", .{file_path});
    }

    cwd.createDir(io, "src/plugins", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const description = options.description orelse "TODO: describe this plugin";
    const content = generatePlugin(arena, name, description) catch |err| switch (err) {
        // `description` lands on a `///` line, so a newline would end the doc
        // comment and splice the remainder in as live top-level Zig (build-time
        // code injection). Reject multi-line input rather than escape it — a doc
        // comment has no escape for a line break.
        error.DescriptionNotSingleLine => return context.fail("Error: --description must be a single line (no newlines)", .{}),
        // Defense-in-depth: never write a plugin file that doesn't parse.
        error.GeneratedSourceInvalid => return context.fail("Error: generated plugin source did not parse (unexpected --description content)", .{}),
        else => return err,
    };

    var file = try cwd.createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);

    try finish(context.stdout(), &context.theme, file_path, hasPluginsDir(arena, io));
}

/// A guided plugin skeleton (ADR-0006): a header, one working pass-through
/// `preExecute` hook, and a commented catalog of the remaining hooks with exact
/// signatures. `plugin_id`/`ContextData` are commented out — a minimal plugin
/// needs neither (hooks are `@hasDecl`-gated; `plugin_id` is only required
/// alongside `ContextData`).
fn generatePlugin(arena: std.mem.Allocator, name: []const u8, description: []const u8) ![]u8 {
    // `description` is spliced verbatim into a `///` doc-comment line; a newline
    // would terminate the comment and turn the rest into live top-level code.
    // There is no in-comment escape for a line break, so reject it outright.
    if (std.mem.indexOfAny(u8, description, "\r\n") != null) return error.DescriptionNotSingleLine;

    var aw = std.Io.Writer.Allocating.init(arena);
    const w = &aw.writer;

    try w.print(
        \\const std = @import("std");
        \\const zcli = @import("zcli");
        \\
        \\/// The `{s}` plugin — {s}
        \\///
        \\/// Plugins shape command execution through optional hooks, each discovered
        \\/// by name (@hasDecl-gated) — declare only the ones you need. This skeleton
        \\/// wires a pass-through `preExecute`; uncomment others from the catalog below.
        \\
        \\/// Runs before a command's execute(). Return `args` to continue, or `null`
        \\/// to halt the pipeline (e.g. after handling a global flag yourself).
        \\pub fn preExecute(context: anytype, args: zcli.ParsedArgs) !?zcli.ParsedArgs {{
        \\    _ = context;
        \\    return args;
        \\}}
        \\
    , .{ name, description });

    // The commented catalog is static (no interpolation) except the plugin_id
    // line at the end, so it is written verbatim.
    try w.writeAll(
        \\
        \\// ===========================================================================
        \\// Hook catalog — uncomment and implement the ones you need.
        \\// ===========================================================================
        \\
        \\// Rewrite raw argv before global options are parsed (e.g. expand an alias).
        \\// pub fn preParse(context: anytype, args: []const []const u8) ![]const []const u8 {
        \\//     _ = context;
        \\//     return args;
        \\// }
        \\
        \\// Transform args after global options are stripped. Set
        \\// `continue_processing = false` to stop the pipeline.
        \\// pub fn transformArgs(context: anytype, args: []const []const u8) !zcli.TransformResult {
        \\//     _ = context;
        \\//     return .{ .args = args };
        \\// }
        \\
        \\// Inspect or replace parsed positionals. Return `null` to leave them as-is.
        \\// pub fn postParse(context: anytype, args: zcli.ParsedArgs) !?zcli.ParsedArgs {
        \\//     _ = context;
        \\//     _ = args;
        \\//     return null;
        \\// }
        \\
        \\// Runs after a command's execute(); `success` is false if it errored.
        \\// pub fn postExecute(context: anytype, success: bool) !void {
        \\//     _ = context;
        \\//     _ = success;
        \\// }
        \\
        \\// Handle an error raised during execution. Return `true` if you handled it
        \\// (which suppresses the framework's default handling).
        \\// pub fn onError(context: anytype, err: anyerror) !bool {
        \\//     _ = context;
        \\//     _ = err;
        \\//     return false;
        \\// }
        \\
        \\// Provide and handle global options (available on every command).
        \\// pub const global_options = [_]zcli.GlobalOption{
        \\//     zcli.option("verbose", bool, .{ .short = 'v', .default = false, .description = "Verbose output" }),
        \\// };
        \\// pub fn handleGlobalOption(context: anytype, name: []const u8, value: anytype) !void {
        \\//     _ = context;
        \\//     _ = name;
        \\//     _ = value;
        \\// }
        \\
        \\// Per-plugin state, reachable as `context.plugins.<plugin_id>`. `plugin_id`
        \\// is REQUIRED whenever `ContextData` is present (and only then).
        \\
    );
    try w.print("// pub const plugin_id = \"{s}\";\n", .{name});
    try w.writeAll("// pub const ContextData = struct {};\n");
    try w.writeAll(
        \\
        \\// Capture references off the context into ContextData once per invocation,
        \\// before any hook — lets `context.plugins.<plugin_id>` methods serve calls
        \\// without re-threading `context`. Optional; requires ContextData.
        \\// pub fn initContextData(data: *ContextData, context: anytype) !void {
        \\//     _ = data;
        \\//     _ = context;
        \\// }
        \\
        \\// Cleanup hook for ContextData, called from Context.deinit(). Only needed
        \\// when ContextData owns resources (allocations, handles). Requires ContextData.
        \\// pub fn deinitContextData(data: *ContextData, allocator: std.mem.Allocator) void {
        \\//     _ = data;
        \\//     _ = allocator;
        \\// }
        \\
    );

    // Defense-in-depth: match `add command`'s pre-write guard — never hand back
    // source that doesn't parse, even if some future interpolation slips through.
    const source = aw.written();
    if (!try scaffold.splice.parses(arena, source)) return error.GeneratedSourceInvalid;
    return source;
}

/// Whether build.zig already sets `plugins_dir` (best-effort; on any read error
/// we assume it does, to avoid a misleading hint).
fn hasPluginsDir(arena: std.mem.Allocator, io: std.Io) bool {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, "build.zig", arena, .limited(max_source_bytes)) catch return true;
    return std.mem.indexOf(u8, raw, "plugins_dir") != null;
}

fn finish(w: *std.Io.Writer, theme: *const ThemeContext, file_path: []const u8, plugins_dir_wired: bool) !void {
    try w.writeAll("\n  ");
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "\u{2714} Created plugin {s}", .{file_path}) catch "\u{2714} Created plugin";
    try themed(line).success().render(w, theme);

    if (!plugins_dir_wired) {
        // The one residual build.zig case (ADR-0006): no plugins_dir to discover
        // through. Print the single line to add — not a multi-site splice.
        try w.writeAll("\n\n  ");
        try themed("Note: your build.zig has no plugins_dir, so this plugin won't be discovered.").warning().render(w, theme);
        try w.writeAll("\n    Add `.plugins_dir = \"src/plugins\",` to the zcli.generate(...) call.\n");
    }

    try w.writeAll("\n\n  Next steps\n");
    try w.print("    1. Implement the preExecute hook (or uncomment others) in {s}\n", .{file_path});
    try w.writeAll("    2. zig build\n");
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "generatePlugin: wires a pass-through preExecute and a commented catalog" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try generatePlugin(a, "telemetry", "Track usage");
    try testing.expect(std.mem.indexOf(u8, src, "The `telemetry` plugin — Track usage") != null);
    try testing.expect(std.mem.indexOf(u8, src, "pub fn preExecute(context: anytype, args: zcli.ParsedArgs) !?zcli.ParsedArgs") != null);
    // Catalog hooks are present but commented out.
    try testing.expect(std.mem.indexOf(u8, src, "// pub fn onError(context: anytype, err: anyerror) !bool") != null);
    try testing.expect(std.mem.indexOf(u8, src, "// pub const plugin_id = \"telemetry\";") != null);
    try expectParses(a, src);
}

test "generatePlugin: only the working hook is uncommented" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try generatePlugin(a, "auth", "x");
    // Exactly one uncommented `pub fn` (preExecute); the rest are `// pub fn`.
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " ");
        if (std.mem.startsWith(u8, t, "pub fn ")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "generatePlugin: rejects a newline in the description (code injection)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Repro from issue #664: an embedded newline would end the `///` doc comment
    // and land the next line as live top-level Zig.
    const payload = "x\npub fn pwned() void {}\n///";
    try testing.expectError(error.DescriptionNotSingleLine, generatePlugin(a, "foo", payload));

    // A bare carriage return is rejected too (can act as a line ending).
    try testing.expectError(error.DescriptionNotSingleLine, generatePlugin(a, "foo", "x\rpub fn pwned() void {}"));
}

test "generatePlugin: a single-line description with quotes is accepted verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Quotes and other single-line punctuation are harmless on a `///` line.
    const src = try generatePlugin(a, "auth", "attach a \"bearer\" token");
    try testing.expect(std.mem.indexOf(u8, src, "The `auth` plugin — attach a \"bearer\" token") != null);
    try expectParses(a, src);
}

fn expectParses(arena: std.mem.Allocator, source: []const u8) !void {
    const ast = try std.zig.Ast.parse(arena, try arena.dupeZ(u8, source), .zig);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);
}
