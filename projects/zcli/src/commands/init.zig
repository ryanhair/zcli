const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const scaffold = @import("scaffold");

/// A built-in plugin the user can opt into during `init`. `tag` is the enum
/// tag passed to `zcli.builtin(.<tag>, <config>)` in the generated build.zig;
/// `config` is the config snippet rendered verbatim into that call. Plugins
/// with required config fields (github_upgrade) must supply a snippet that
/// COMPILES — an empty `.{}` would make the very first `zig build` of a fresh
/// scaffold fail with a missing-field error the user never asked for. TODO
/// placeholders inside the snippet mark what to edit, matching the scaffold's
/// existing placeholder idiom.
const BuiltinChoice = struct {
    tag: []const u8,
    label: []const u8,
    default: bool,
    config: []const u8 = ".{}",
};

const builtin_choices = [_]BuiltinChoice{
    .{ .tag = "help", .label = "zcli_help — --help output for the app and every command", .default = true },
    .{ .tag = "version", .label = "zcli_version — --version flag", .default = true },
    .{ .tag = "not_found", .label = "zcli_not_found — \"did you mean?\" suggestions for mistyped commands", .default = true },
    .{ .tag = "completions", .label = "zcli_completions — shell completion scripts (bash/zsh/fish)", .default = false },
    .{ .tag = "config", .label = "zcli_config — load option defaults from a config file", .default = false },
    .{
        .tag = "github_upgrade",
        .label = "zcli_github_upgrade — self-update from GitHub releases",
        .default = false,
        // Both fields are required (no defaults): `repo` names where releases
        // live, and `verification` is the plugin's integrity control — the
        // checksum_only placeholder is the explicit opt-out that compiles out
        // of the box, with the TODO pointing at the fail-closed upgrade path.
        // Indentation matches the generated build.zig: the builtin() call
        // sits at 12 spaces, so fields land at 16 and the closer at 12.
        .config = ".{\n" ++
            "                .repo = \"OWNER/REPO\", // TODO: your GitHub repo\n" ++
            "                .verification = .checksum_only, // TODO: pin a minisign key for fail-closed signature verification (see zcli's docs/RELEASE-SIGNING.md)\n" ++
            "            }",
    },
};

pub const meta = .{
    .description = "Initialize a new zcli project",
    .examples = &.{
        "init my-app",
        "init my-app --description \"My awesome CLI\"",
        "init my-app --app-version 1.0.0",
        "init . --description \"Initialize in current directory\"",
    },
    .args = .{
        .name = "Name of the project or '.' for current directory",
    },
    .options = .{
        .description = .{ .description = "Description of your CLI application" },
        // Named app_version (--app-version), not version: the zcli_version
        // plugin's global --version/-V flag is consumed before command routing,
        // so a command option spelled --version would be unreachable from the
        // CLI (#565).
        .app_version = .{ .description = "Initial version number" },
    },
};

pub const Args = struct {
    name: []const u8,
};

pub const Options = struct {
    description: ?[]const u8 = null,
    app_version: ?[]const u8 = null,
};

pub fn execute(args: Args, options: Options, context: *Context) !void {
    const allocator = context.allocator;
    var stdout = context.stdout();
    var stderr = context.stderr();

    const cwd = std.Io.Dir.cwd();

    // Determine if we're using current directory or creating a new one
    const use_current_dir = std.mem.eql(u8, args.name, ".");

    // Get the project name
    const io = context.io;
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

    // The name lands in generated Zig/zon source (`.name = .{s}`,
    // `.app_name = "{s}"`) and becomes the directory and executable name —
    // restrict it to identifier-safe characters up front rather than escaping
    // it into every context separately.
    // For `init .` the name is a fact of the environment, not a typo — say so.
    const name_origin: []const u8 = if (use_current_dir) " (taken from the current directory's name)" else "";
    if (project_name.len == 0 or std.ascii.isDigit(project_name[0])) {
        return context.fail("Error: Invalid project name '{s}'{s}\n  Names must be non-empty and must not start with a digit", .{ project_name, name_origin });
    }
    for (project_name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') {
            return context.fail("Error: Invalid project name '{s}'{s}\n  Use only letters, digits, '-' and '_'", .{ project_name, name_origin });
        }
    }

    // Create a sanitized identifier-safe version (replace dashes with underscores)
    const project_identifier = blk: {
        var sanitized = try allocator.alloc(u8, project_name.len);
        for (project_name, 0..) |c, i| {
            sanitized[i] = if (c == '-') '_' else c;
        }
        break :blk sanitized;
    };
    defer allocator.free(project_identifier);

    // The identifier lands in build.zig.zon as `.name = .<identifier>` — an enum
    // literal. A Zig keyword there produces uncompilable generated source, so
    // reject reserved words up front.
    if (scaffold.spec.isReservedWord(project_identifier)) {
        return context.fail("Error: Invalid project name '{s}'{s}\n  '{s}' is a Zig reserved word and cannot be used as a package name", .{ project_name, name_origin, project_identifier });
    }

    // The version lands verbatim in build.zig.zon's `.version` field, which Zig's
    // manifest parser requires to be a semantic version. Validate it up front so a
    // typo fails immediately with a clear message here, rather than surfacing later
    // as an opaque manifest error from `zig fetch`/`zig build` in a half-set-up
    // project (#507).
    const version_str = options.app_version orelse "0.1.0";
    if (!isValidSemanticVersion(version_str)) {
        return context.fail("Error: Invalid version '{s}'\n  Must be a semantic version like 1.2.3 (see https://semver.org)", .{version_str});
    }

    // Free-text options are embedded in generated string literals — escape so
    // `--description 'say "hi"'` scaffolds a project that still compiles
    // instead of breaking (or injecting code into) build.zig / build.zig.zon.
    const app_description = try escapeStringLiteral(allocator, options.description orelse "A CLI application built with zcli");
    defer allocator.free(app_description);
    const app_version = try escapeStringLiteral(allocator, version_str);
    defer allocator.free(app_version);

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
            // Ignore hidden files (starting with .) and a pre-existing AGENTS.md,
            // which init appends its (marker-delimited) section to rather than
            // treating as a conflict (ADR-0008).
            if (entry.name[0] != '.' and !std.mem.eql(u8, entry.name, "AGENTS.md")) {
                has_visible_files = true;
                break;
            }
        }

        if (has_visible_files) {
            return context.fail("Error: Current directory is not empty\nTip: only hidden files and an existing AGENTS.md are allowed", .{});
        }

        try stdout.print("Initializing zcli project in current directory: {s}\n", .{project_name});
    } else {
        // Check if directory already exists (access succeeds => the path exists).
        if (cwd.access(io, args.name, .{})) |_| {
            return context.fail("Error: Directory '{s}' already exists", .{args.name});
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
    const p = context.prompts();
    const selected = p.multiSelect(.{
        .message = "Select built-in plugins to include:",
        .choices = &choices,
        .defaults = &defaults,
    }) catch |err| switch (err) {
        // Non-interactive invocation (piped/closed stdin): take the preselected
        // defaults rather than aborting — `init` must work in scripts and CI.
        error.EndOfStream => try collectDefaultPlugins(allocator, &defaults),
        else => return err,
    };
    defer allocator.free(selected);

    // Build the `zcli.builtin(...)` registration lines for build.zig.
    const plugins_block = try renderPluginsBlock(allocator, selected);
    defer allocator.free(plugins_block);

    // Now that the destination is validated and plugins are chosen, create and
    // open the project directory.
    if (!use_current_dir) try cwd.createDir(io, args.name, .default_dir);
    // If init created the directory, tear the whole tree down on any later
    // scaffold failure so a retry isn't blocked by a "Directory already exists"
    // half-created project. deleteTree is safe here: the directory did not exist
    // before this run (validated above). Declared before `project_dir.close` so
    // the dir handle is closed first (Windows won't delete an open dir). For
    // use_current_dir we deliberately don't clean up — we didn't create the dir.
    errdefer if (!use_current_dir) cwd.deleteTree(io, args.name) catch {};
    var project_dir = try cwd.openDir(io, if (use_current_dir) "." else args.name, .{});
    defer project_dir.close(io);

    // Create src and src/commands directories
    try project_dir.createDir(io, "src", .default_dir);
    try project_dir.createDir(io, "src/commands", .default_dir);

    // Generate build.zig.zon
    try stdout.print("  Creating build.zig.zon...\n", .{});
    // Pin the generated project to the same zcli release as this CLI.
    // `context.app_version` is read from build.zig.zon at build time, so it
    // tracks releases automatically. Releases are dual-tagged: `zcli-v<version>`
    // for the CLI binary, `v<version>` for the library — build.zig.zon deps must
    // reference the library tag (see README's dual-tag contract).
    const zcli_version = context.app_version;
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
    // The zcli dependency is added below by `zig fetch --save`, which computes
    // the real hash. We must NOT pre-write a placeholder entry here: zig parses
    // the existing manifest before fetching, and an incomplete hash makes that
    // parse (and therefore the fetch) fail.
    const zon_content = try std.fmt.allocPrint(allocator,
        \\.{{
        \\    .name = .{s},
        \\    .version = "{s}",
        \\    .fingerprint = 0x{x:0>16},
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{{}},
        \\    .paths = .{{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\    }},
        \\}}
        \\
    , .{ project_identifier, app_version, fingerprint });
    defer allocator.free(zon_content);

    var zon_file = try project_dir.createFile(io, "build.zig.zon", .{});
    defer zon_file.close(io);
    try zon_file.writeStreamingAll(io, zon_content);

    // Generate build.zig from the embedded reference source. The reference is
    // the `examples/init-scaffold` project the root build compiles against the
    // local zcli, so a framework API change breaks that build instead of shipping
    // a broken scaffold (issue #679 part 2; see renderBuildZig and
    // scaffold/reference.zig).
    try stdout.print("  Creating build.zig...\n", .{});
    const build_content = try renderBuildZig(allocator, project_name, app_description, plugins_block);
    defer allocator.free(build_content);

    var build_file = try project_dir.createFile(io, "build.zig", .{});
    defer build_file.close(io);
    try build_file.writeStreamingAll(io, build_content);

    // Generate src/main.zig — emitted verbatim from the compiled reference.
    try stdout.print("  Creating src/main.zig...\n", .{});

    var src_dir = try project_dir.openDir(io, "src", .{});
    defer src_dir.close(io);

    var main_file = try src_dir.createFile(io, "main.zig", .{});
    defer main_file.close(io);
    try main_file.writeStreamingAll(io, scaffold.reference.main_zig);

    // Generate example command: src/commands/hello.zig — verbatim from the
    // compiled reference.
    try stdout.print("  Creating example command (hello)...\n", .{});

    var commands_dir = try src_dir.openDir(io, "commands", .{});
    defer commands_dir.close(io);

    var hello_file = try commands_dir.createFile(io, "hello.zig", .{});
    defer hello_file.close(io);
    try hello_file.writeStreamingAll(io, scaffold.reference.hello_zig);

    // Scaffold AGENTS.md — the thin, frozen, command-speaking spine that points
    // coding agents at `zcli guide` (ADR-0008). Marker-delimited so it never
    // clobbers a user's own AGENTS.md, and a future upgrade can refresh just the
    // zcli section.
    switch (try scaffoldAgentsMd(allocator, io, project_dir)) {
        .created => try stdout.print("  Creating AGENTS.md...\n", .{}),
        .appended => try stdout.print("  Adding zcli section to existing AGENTS.md...\n", .{}),
        .refreshed => try stdout.print("  Refreshing zcli section in AGENTS.md...\n", .{}),
    }

    // Fetch the zcli dependency. `zig fetch --save` computes the real hash and
    // writes the dependency into build.zig.zon; without it the generated project
    // won't build, so warn with the exact command if it doesn't run, and reflect
    // the failure in the final success/next-steps messaging below.
    const zcli_url = try std.fmt.allocPrint(allocator, "https://github.com/ryanhair/zcli/archive/refs/tags/v{s}.tar.gz", .{zcli_version});
    defer allocator.free(zcli_url);

    try stdout.print("  Fetching dependencies (this may take a moment)...\n", .{});
    const fetch_ok = ok: {
        var fetch_child = std.process.spawn(io, .{
            .argv = &.{ "zig", "fetch", "--save", zcli_url },
            .cwd = .{ .dir = project_dir },
            .stdout = .ignore,
            .stderr = .inherit,
        }) catch break :ok false;
        const term = fetch_child.wait(io) catch break :ok false;
        break :ok term == .exited and term.exited == 0;
    };
    if (!fetch_ok) {
        try stderr.print("  Warning: could not add the zcli dependency automatically.\n", .{});
        try stderr.print("  Run this inside the project to finish setup:\n    zig fetch --save {s}\n", .{zcli_url});
    }

    // Success message. When the fetch failed, `zig build` would only fail with
    // a missing-dependency error the user never asked for — don't claim success
    // or suggest a next step that can't work yet.
    if (fetch_ok) {
        try stdout.print("\n✓ Project '{s}' created successfully!\n\n", .{project_name});
        try stdout.print("Next steps:\n", .{});
        if (!use_current_dir) {
            try stdout.print("  cd {s}\n", .{args.name});
        }
        try stdout.print("  zig build\n", .{});
        try stdout.print("  ./zig-out/bin/{s} hello World\n", .{project_name});
        try stdout.print("  ./zig-out/bin/{s} --help\n", .{project_name});
    } else {
        try stdout.print("\n⚠ Project '{s}' created, but the zcli dependency was not fetched.\n\n", .{project_name});
        try stdout.print("Next steps:\n", .{});
        if (!use_current_dir) {
            try stdout.print("  cd {s}\n", .{args.name});
        }
        try stdout.print("  zig fetch --save {s}\n", .{zcli_url});
        try stdout.print("  zig build\n", .{});
        try stdout.print("  ./zig-out/bin/{s} hello World\n", .{project_name});
        try stdout.print("  ./zig-out/bin/{s} --help\n", .{project_name});
    }
}

// ---------------------------------------------------------------------------
// AGENTS.md scaffolding (ADR-0008)
// ---------------------------------------------------------------------------

const agents_begin = "<!-- zcli:begin -->";
const agents_end = "<!-- zcli:end -->";

/// The zcli section, delimited by markers. Thin and "speaks commands" — no Zig
/// API signatures (those live in the drift-proof `zcli guide`), so it stays true
/// even as the framework's code evolves. Between the markers only.
const agents_section = agents_begin ++
    \\
    \\## Building this CLI with zcli
    \\
    \\**Start here: before writing or changing any code, run `zcli guide`.** It is the
    \\version-matched source of truth for how to do everything in this project —
    \\persistence, testing, errors, plugins, HTTP, and more. Reach for it first: don't
    \\hand-roll what it documents, and don't read zcli's own source — `zcli guide
    \\<topic>` has the worked, compile-checked example.
    \\
    \\This project is built with [zcli](https://github.com/ryanhair/zcli): its command
    \\structure *is* the files under `src/commands/`. `zcli guide` always matches the
    \\exact zcli this project builds against.
    \\
    \\**The loop**
    \\
    \\- **Read** what exists — `zcli tree --show-options`
    \\- **Change** structure — `zcli add command|arg|option|group|plugin`, `zcli rm ...`,
    \\  `zcli mv ...` (never edit structure by hand)
    \\- **Write** logic — freeform Zig in each command's `execute()` body
    \\- **Verify** — `zig build && zig build test`
    \\
    \\**Invariants**
    \\
    \\1. Never `free`/`deinit` memory you allocate in `execute()` — `context.allocator` is
    \\   a per-command arena, reclaimed automatically. (Do still `deinit` non-memory
    \\   resources: files, sockets, `http.Client`.)
    \\2. Change command *structure* with `zcli add`/`rm`/`mv`, not by editing files by
    \\   hand — write freeform code inside `execute()` bodies. (Editing `build.zig`
    \\   config, like plugins or shared modules, by hand is expected: that's build
    \\   wiring, not structure.)
    \\3. Print through `context.stdout()` / `context.stderr()` — never `std.debug.print` or
    \\   a raw stdout handle.
    \\4. Don't hand-roll terminal I/O — use `prompts` (interactive input), `progress`
    \\   (bars/spinners), `theme` (color).
    \\5. Verify with `zig build` and `zig build test`. Run `zcli guide <topic>` for
    \\   version-matched API detail and worked examples.
    \\6. File path = command path: `src/commands/foo/bar.zig` → `app foo bar`; a directory's
    \\   `index.zig` is the group landing; plugins live in `src/plugins/`.
    \\
    \\`zcli guide` topics: structure, sharing, storage, arena, output, prompts, http, secrets, plugins, testing.
    \\
++ agents_end ++ "\n";

const AgentsResult = enum { created, appended, refreshed };

/// Write the zcli section into AGENTS.md without ever clobbering the user's own
/// content: create the file if absent, replace the marker-delimited block if it
/// exists (an idempotent re-run / upgrade), or append it if the file exists but
/// has no zcli section yet.
/// Render `s` escaped for the inside of a double-quoted Zig/zon string
/// literal (same rule as the registry codegen's escapeStringLiteral).
/// Owned slice of the indices whose `defaults` bit is set — the non-interactive
/// fallback for the plugin picker (mirrors what `multiSelect` returns for a
/// submitted-defaults selection).
fn collectDefaultPlugins(allocator: std.mem.Allocator, defaults: []const bool) ![]usize {
    var list = std.ArrayList(usize).empty;
    errdefer list.deinit(allocator);
    for (defaults, 0..) |on, i| {
        if (on) try list.append(allocator, i);
    }
    return list.toOwnedSlice(allocator);
}

test "collectDefaultPlugins returns only the preselected indices" {
    const allocator = std.testing.allocator;
    const selected = try collectDefaultPlugins(allocator, &.{ true, false, true, false });
    defer allocator.free(selected);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, selected);
}

/// Render the `zcli.builtin(...)` registration lines the generated build.zig
/// splices into its `.plugins = &.{ ... }` list, one line per selected picker
/// index, each with that choice's config snippet. Owned slice.
fn renderPluginsBlock(allocator: std.mem.Allocator, selected: []const usize) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    for (selected) |idx| {
        try aw.writer.print("            zcli.builtin(.{s}, {s}),\n", .{ builtin_choices[idx].tag, builtin_choices[idx].config });
    }
    var al = aw.toArrayList();
    return al.toOwnedSlice(allocator);
}

test "renderPluginsBlock renders configless plugins as .{}" {
    const allocator = std.testing.allocator;
    // help (0) and version (1) take no config.
    const block = try renderPluginsBlock(allocator, &.{ 0, 1 });
    defer allocator.free(block);
    try std.testing.expectEqualStrings(
        "            zcli.builtin(.help, .{}),\n" ++
            "            zcli.builtin(.version, .{}),\n",
        block,
    );
}

test "renderPluginsBlock scaffolds a compiling github_upgrade config, not an empty .{}" {
    const allocator = std.testing.allocator;
    // github_upgrade's Config has two required fields (`repo`,
    // `verification`), so `zcli.builtin(.github_upgrade, .{})` is a
    // missing-field compile error in the fresh scaffold — the picker must emit
    // a compiling placeholder instead. Locate the choice by tag rather than
    // hardcoding its index so reordering the picker can't silently break this.
    const idx = for (builtin_choices, 0..) |choice, i| {
        if (std.mem.eql(u8, choice.tag, "github_upgrade")) break i;
    } else return error.TestUnexpectedResult;

    const block = try renderPluginsBlock(allocator, &.{idx});
    defer allocator.free(block);
    try std.testing.expectEqualStrings(
        "            zcli.builtin(.github_upgrade, .{\n" ++
            "                .repo = \"OWNER/REPO\", // TODO: your GitHub repo\n" ++
            "                .verification = .checksum_only, // TODO: pin a minisign key for fail-closed signature verification (see zcli's docs/RELEASE-SIGNING.md)\n" ++
            "            }),\n",
        block,
    );
}

// The plugins-list region in the reference build.zig, delimited so init can
// swap the reference's default builtins for the user's selection. The markers
// keep the reference itself compiling (with the defaults between them).
const ref_plugins_begin = "            //<zcli:plugins>\n";
const ref_plugins_end = "            //</zcli:plugins>\n";

/// Assemble the project's `build.zig` from the embedded reference source
/// (`scaffold.reference.build_zig`), substituting this project's values:
///   - the `//<zcli:plugins>…//</zcli:plugins>` region → the selected builtins;
///   - the reference app name (`"myapp"`, at both `.name` and `.app_name`) and
///     its default description string → this project's name and (already-escaped)
///     description.
///
/// The reference is written against the *local* (unreleased) zcli so it stays
/// compile-checked by the `examples/init-scaffold` build. `init`, though, pins
/// the released tag `context.app_version` points at, whose `addCommandTests`
/// still predates the `exe` parameter (#531) — so emit the 3-arg form that
/// release expects. (The local-tree e2e build bridges it back up; the
/// pinned-release e2e, #623, builds this unmodified against the real tag.) Drop
/// this last rewrite once the pinned release carries the `exe` signature.
fn renderBuildZig(
    allocator: std.mem.Allocator,
    project_name: []const u8,
    app_description: []const u8,
    plugins_block: []const u8,
) ![]u8 {
    const ref = scaffold.reference.build_zig;
    const begin = std.mem.indexOf(u8, ref, ref_plugins_begin) orelse return error.MalformedReference;
    const end = (std.mem.indexOf(u8, ref, ref_plugins_end) orelse return error.MalformedReference) + ref_plugins_end.len;

    const name_quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{project_name});
    defer allocator.free(name_quoted);
    const desc_quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{app_description});
    defer allocator.free(desc_quoted);

    // 1) Replace the marked plugins region with the rendered selection.
    const spliced = try std.mem.concat(allocator, u8, &.{ ref[0..begin], plugins_block, ref[end..] });
    defer allocator.free(spliced);
    // 2) App name — both the exe `.name` and `.app_name` sites.
    const named = try std.mem.replaceOwned(u8, allocator, spliced, "\"myapp\"", name_quoted);
    defer allocator.free(named);
    // 3) Description (name is substituted first so it can't collide with a
    //    user-supplied description, which is inserted last and never rescanned).
    const described = try std.mem.replaceOwned(u8, allocator, named, "\"A CLI application built with zcli\"", desc_quoted);
    defer allocator.free(described);
    // 4) Pin `addCommandTests` down to the released 3-arg shape (see doc comment).
    return std.mem.replaceOwned(u8, allocator, described, "zcli.addCommandTests(b, exe, zcli_dep,", "zcli.addCommandTests(b, zcli_dep,");
}

test "renderBuildZig substitutes name, description, plugins and pins addCommandTests" {
    const allocator = std.testing.allocator;
    const plugins =
        "            zcli.builtin(.help, .{}),\n" ++
        "            zcli.builtin(.version, .{}),\n";
    const build = try renderBuildZig(allocator, "cool-app", "Say \\\"hi\\\"", plugins);
    defer allocator.free(build);

    // Name lands at the exe `.name` and `.app_name`; the reference sentinel is gone.
    try std.testing.expect(std.mem.indexOf(u8, build, ".name = \"cool-app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, ".app_name = \"cool-app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "myapp") == null);
    // Description (already escaped) lands verbatim.
    try std.testing.expect(std.mem.indexOf(u8, build, ".app_description = \"Say \\\"hi\\\"\"") != null);
    // Selected plugins are spliced in, markers removed.
    try std.testing.expect(std.mem.indexOf(u8, build, "zcli.builtin(.help, .{}),") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "//<zcli:plugins>") == null);
    // Emitted call matches the pinned release's 3-arg signature, not the
    // reference's local 4-arg one.
    try std.testing.expect(std.mem.indexOf(u8, build, "zcli.addCommandTests(b, zcli_dep,") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "zcli.addCommandTests(b, exe, zcli_dep,") == null);
    // Framework-coupled call the reference compile-guards survives verbatim.
    try std.testing.expect(std.mem.indexOf(u8, build, "try zcli.generate(b, exe, zcli_dep, .{") != null);
}

/// True if `s` is a semantic version acceptable to Zig's build.zig.zon manifest
/// parser (which requires `.version` to be semver). `init` validates the
/// `--app-version` value with this up front so a bad value fails immediately
/// rather than as an opaque manifest error downstream (#507).
fn isValidSemanticVersion(s: []const u8) bool {
    _ = std.SemanticVersion.parse(s) catch return false;
    return true;
}

test "isValidSemanticVersion accepts semver and rejects junk (#507)" {
    try std.testing.expect(isValidSemanticVersion("0.1.0"));
    try std.testing.expect(isValidSemanticVersion("1.2.3"));
    try std.testing.expect(isValidSemanticVersion("1.2.3-rc.1+build5")); // prerelease + build metadata
    try std.testing.expect(!isValidSemanticVersion("foo"));
    try std.testing.expect(!isValidSemanticVersion("1.2")); // not full semver
    try std.testing.expect(!isValidSemanticVersion("v1.2.3")); // leading v is not semver
    try std.testing.expect(!isValidSemanticVersion(""));
}

fn escapeStringLiteral(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.zig.stringEscape(s, &aw.writer);
    var al = aw.toArrayList();
    return al.toOwnedSlice(allocator);
}

test "escapeStringLiteral escapes quotes, backslashes, and newlines" {
    const allocator = std.testing.allocator;
    const escaped = try escapeStringLiteral(allocator, "say \"hi\"\nback\\slash");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("say \\\"hi\\\"\\nback\\\\slash", escaped);
}

fn scaffoldAgentsMd(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !AgentsResult {
    const existing = dir.readFileAlloc(io, "AGENTS.md", allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            try dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = agents_section });
            return .created;
        },
        else => return err,
    };
    defer allocator.free(existing);

    if (std.mem.indexOf(u8, existing, agents_begin)) |begin| {
        // Refresh: splice the fresh section in place of the old markers-region.
        const end_rel = std.mem.indexOf(u8, existing[begin..], agents_end) orelse return error.MalformedAgentsMarkers;
        const after = begin + end_rel + agents_end.len;
        const trailing = if (after < existing.len and existing[after] == '\n') after + 1 else after;
        const updated = try std.mem.concat(allocator, u8, &.{ existing[0..begin], agents_section, existing[trailing..] });
        defer allocator.free(updated);
        try dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = updated });
        return .refreshed;
    }

    // Append, keeping exactly one blank line between the user's content and ours.
    const sep = if (std.mem.endsWith(u8, existing, "\n")) "\n" else "\n\n";
    const updated = try std.mem.concat(allocator, u8, &.{ existing, sep, agents_section });
    defer allocator.free(updated);
    try dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = updated });
    return .appended;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn readAgents(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]u8 {
    return dir.readFileAlloc(io, "AGENTS.md", a, .limited(1 << 20));
}

test "scaffoldAgentsMd creates AGENTS.md when absent" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expectEqual(AgentsResult.created, try scaffoldAgentsMd(testing.allocator, io, tmp.dir));

    const content = try readAgents(testing.allocator, io, tmp.dir);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(agents_section, content);
    try testing.expect(std.mem.indexOf(u8, content, "zcli guide") != null);
}

test "scaffoldAgentsMd appends without clobbering the user's AGENTS.md" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "# Mine\n\nkeep me\n" });

    try testing.expectEqual(AgentsResult.appended, try scaffoldAgentsMd(testing.allocator, io, tmp.dir));

    const content = try readAgents(testing.allocator, io, tmp.dir);
    defer testing.allocator.free(content);
    try testing.expect(std.mem.startsWith(u8, content, "# Mine\n\nkeep me\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, agents_begin));
}

test "scaffoldAgentsMd refreshes an existing zcli block idempotently" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // User content wrapped around a STALE zcli block.
    const stale = "# Mine\n\n" ++ agents_begin ++ "\nold stale text\n" ++ agents_end ++ "\n\nmore mine\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = stale });

    try testing.expectEqual(AgentsResult.refreshed, try scaffoldAgentsMd(testing.allocator, io, tmp.dir));

    const content = try readAgents(testing.allocator, io, tmp.dir);
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "old stale text") == null); // stale replaced
    try testing.expect(std.mem.indexOf(u8, content, "more mine") != null); // user tail kept
    try testing.expect(std.mem.startsWith(u8, content, "# Mine")); // user head kept
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, agents_begin)); // exactly one block

    // Running again is a no-op-shaped refresh: still exactly one block.
    try testing.expectEqual(AgentsResult.refreshed, try scaffoldAgentsMd(testing.allocator, io, tmp.dir));
    const again = try readAgents(testing.allocator, io, tmp.dir);
    defer testing.allocator.free(again);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, again, agents_begin));
}
