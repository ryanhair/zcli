//! End-to-end tests for the zcli meta-tool.
//!
//! These run the *built* `zcli` binary as a subprocess against throwaway temp
//! directories and assert on the files it generates and (for the slow tier) that
//! the generated project actually builds and runs.
//!
//! Run with `zig build e2e` (NOT part of `zig build test`, since the build-and-run
//! tier compiles zcli from source and is slow). See `.context/e2e-test-plan.md`.
//!
//! Build-time injected paths (see build.zig):
//!   - build_options.zcli_exe     absolute path to the built `zcli` binary
//!   - build_options.repo_root    absolute path to the zcli package (local dep override)
//!   - build_options.fixtures_dir absolute path to test/fixtures

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const harness = @import("testing_e2e");
const testing = std.testing;
const io = testing.io;

const zcli_exe = build_options.zcli_exe;
const repo_root = build_options.repo_root;
const fixtures_dir = build_options.fixtures_dir;

// ============================================================================
// Harness
// ============================================================================

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    fn deinit(self: *RunResult) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }
};

/// Run `argv` with `cwd` as the working directory, capturing stdout/stderr.
/// Mirrors packages/testing's runSubprocess but adds the cwd we need to drive
/// the generator inside temp projects.
fn run(cwd: std.Io.Dir, argv: []const []const u8) !RunResult {
    const a = testing.allocator;

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        // Non-interactive stdin so prompts (e.g. `init`'s plugin selection)
        // fall back to their defaults instead of blocking on a TTY.
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    // Drain pipes before waiting to avoid deadlock on large output.
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out_reader = child.stdout.?.reader(io, &out_buf);
    var err_reader = child.stderr.?.reader(io, &err_buf);
    const stdout = try out_reader.interface.allocRemaining(a, .limited(10 * 1024 * 1024));
    errdefer a.free(stdout);
    const stderr = try err_reader.interface.allocRemaining(a, .limited(10 * 1024 * 1024));
    errdefer a.free(stderr);

    const term = try child.wait(io);
    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = switch (term) {
            .exited => |code| @intCast(code),
            else => 1,
        },
    };
}

fn fileExists(dir: std.Io.Dir, path: []const u8) bool {
    dir.access(io, path, .{}) catch return false;
    return true;
}

fn readFile(dir: std.Io.Dir, a: std.mem.Allocator, path: []const u8) ![]u8 {
    return dir.readFileAlloc(io, path, a, .limited(1 << 20));
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print(
            "\nexpected to find:\n  \"{s}\"\nin:\n----\n{s}\n----\n",
            .{ needle, haystack },
        );
        return error.SubstringNotFound;
    }
}

/// Assert success, printing captured output on failure to make CI logs useful.
fn expectOk(r: RunResult) !void {
    if (r.exit_code != 0) {
        std.debug.print(
            "\ncommand exited {d}\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ r.exit_code, r.stdout, r.stderr },
        );
        return error.CommandFailed;
    }
}

fn makeProjectDirs(dir: std.Io.Dir) !void {
    try dir.createDir(io, "src", .default_dir);
    try dir.createDir(io, "src/commands", .default_dir);
}

// ============================================================================
// Layer 0 — file generation
// ============================================================================

test "init scaffolds a project with the expected files and wiring" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var r = try run(tmp.dir, &.{ zcli_exe, "init", "myapp" });
    defer r.deinit();
    try expectOk(r);

    var proj = try tmp.dir.openDir(io, "myapp", .{});
    defer proj.close(io);

    try testing.expect(fileExists(proj, "build.zig"));
    try testing.expect(fileExists(proj, "build.zig.zon"));
    try testing.expect(fileExists(proj, "src/main.zig"));
    try testing.expect(fileExists(proj, "src/commands/hello.zig"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zon = try readFile(proj, a, "build.zig.zon");
    try expectContains(zon, ".name = .myapp");
    try expectContains(zon, ".zcli = .{");
    try expectContains(zon, "github.com/ryanhair/zcli");

    const build_zig = try readFile(proj, a, "build.zig");
    try expectContains(build_zig, "zcli.generate(");
    // With no TTY, the plugin prompt falls back to its preselected defaults:
    // help, version, and not_found (but not the opt-in plugins like completions).
    try expectContains(build_zig, "zcli.builtin(.help");
    try expectContains(build_zig, "zcli.builtin(.version");
    try expectContains(build_zig, "zcli.builtin(.not_found");
    try testing.expect(std.mem.indexOf(u8, build_zig, "zcli.builtin(.completions") == null);

    const hello = try readFile(proj, a, "src/commands/hello.zig");
    try expectContains(hello, "pub fn execute(");
}

test "init . scaffolds into the current directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var r = try run(tmp.dir, &.{ zcli_exe, "init", "." });
    defer r.deinit();
    try expectOk(r);

    try testing.expect(fileExists(tmp.dir, "build.zig"));
    try testing.expect(fileExists(tmp.dir, "src/commands/hello.zig"));
}

test "add command creates stubs at the right paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProjectDirs(tmp.dir);

    {
        var r = try run(tmp.dir, &.{ zcli_exe, "add", "command", "deploy" });
        defer r.deinit();
        try expectOk(r);
    }
    try testing.expect(fileExists(tmp.dir, "src/commands/deploy.zig"));

    // Nested path creates intermediate directories.
    {
        var r = try run(tmp.dir, &.{ zcli_exe, "add", "command", "users/create", "--description", "Create a user" });
        defer r.deinit();
        try expectOk(r);
    }
    try testing.expect(fileExists(tmp.dir, "src/commands/users/create.zig"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const created = try readFile(tmp.dir, a, "src/commands/users/create.zig");
    try expectContains(created, ".description = \"Create a user\"");
    try expectContains(created, "pub fn execute(");
}

test "add command outside a project fails clearly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var r = try run(tmp.dir, &.{ zcli_exe, "add", "command", "deploy" });
    defer r.deinit();
    try testing.expect(r.exit_code != 0);
    try expectContains(r.stderr, "Not in a zcli project");
}

test "gh add workflow release writes the workflow file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProjectDirs(tmp.dir); // command requires a zcli project

    var r = try run(tmp.dir, &.{ zcli_exe, "gh", "add", "workflow", "release" });
    defer r.deinit();
    try expectOk(r);

    try testing.expect(fileExists(tmp.dir, ".github/workflows/release.yml"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const yml = try readFile(tmp.dir, a, ".github/workflows/release.yml");
    try expectContains(yml, "x86_64-linux");
    try expectContains(yml, "aarch64-macos");
}

// ============================================================================
// Layer 1 — read-only commands against a checked-in fixture
// ============================================================================

fn openSampleFixture() !std.Io.Dir {
    var fx = try std.Io.Dir.cwd().openDir(io, fixtures_dir, .{});
    defer fx.close(io);
    return fx.openDir(io, "sample", .{});
}

test "tree lists the discovered commands" {
    var sample = try openSampleFixture();
    defer sample.close(io);

    var r = try run(sample, &.{ zcli_exe, "tree" });
    defer r.deinit();
    try expectOk(r);

    try expectContains(r.stdout, "hello");
    try expectContains(r.stdout, "users");
    try expectContains(r.stdout, "create");
}

test "tree --show-options surfaces args and options" {
    var sample = try openSampleFixture();
    defer sample.close(io);

    var r = try run(sample, &.{ zcli_exe, "tree", "--show-options" });
    defer r.deinit();
    try expectOk(r);

    try expectContains(r.stdout, "name"); // hello's positional arg
    try expectContains(r.stdout, "loud"); // hello's option
}

// ============================================================================
// release — dry run must not mutate git
// ============================================================================

const release_zon =
    \\.{
    \\    .name = .myapp,
    \\    .version = "0.1.0",
    \\    .fingerprint = 0x927117ca2ae2cf80,
    \\    .minimum_zig_version = "0.16.0",
    \\    .dependencies = .{
    \\        .zcli = .{ .path = "/nonexistent" },
    \\    },
    \\    .paths = .{ "build.zig", "build.zig.zon", "src" },
    \\}
    \\
;

test "release --dry-run previews without creating a tag" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = release_zon });

    // A git repo with no tags drives the initial-release path.
    {
        var r = try run(tmp.dir, &.{ "git", "init" });
        defer r.deinit();
        try expectOk(r);
    }

    var r = try run(tmp.dir, &.{
        zcli_exe,        "release", "patch",
        "--dry-run",     "--skip-checks", "--skip-tests",
        "--message",     "test notes",
    });
    defer r.deinit();
    try expectOk(r);
    try expectContains(r.stdout, "would create tag");

    // The dry run must not have created any tag.
    var tags = try run(tmp.dir, &.{ "git", "tag", "-l" });
    defer tags.deinit();
    try testing.expectEqualStrings("", std.mem.trim(u8, tags.stdout, " \t\r\n"));
}

// ============================================================================
// Layer 2 — scaffolded project builds and runs (slow)
// ============================================================================

/// Rewrite the generated zon's dependency block to point zcli at the local
/// working tree, preserving everything else `init` wrote. Zig requires path
/// dependencies to be relative to the package root, so we compute the relative
/// path from `proj_abs` to the repo root.
fn pointDependencyAtLocalTree(proj: std.Io.Dir, proj_abs: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // from/to are absolute, so cwd/environ are unused.
    const rel = try std.fs.path.relative(a, "", null, proj_abs, repo_root);

    const orig = try readFile(proj, a, "build.zig.zon");
    const dep_start = std.mem.indexOf(u8, orig, ".dependencies") orelse return error.NoDependenciesBlock;
    const paths_start = std.mem.indexOf(u8, orig, ".paths") orelse return error.NoPathsBlock;

    const rewritten = try std.fmt.allocPrint(
        a,
        "{s}.dependencies = .{{\n        .zcli = .{{ .path = \"{s}\" }},\n    }},\n    {s}",
        .{ orig[0..dep_start], rel, orig[paths_start..] },
    );
    try proj.writeFile(io, .{ .sub_path = "build.zig.zon", .data = rewritten });
}

/// Absolute path of a sub-directory created in this test run's temp dir.
/// testing.tmpDir places dirs at `<cwd>/.zig-cache/tmp/<sub_path>`.
fn tmpSubdirAbs(a: std.mem.Allocator, tmp: testing.TmpDir, sub: []const u8) ![]const u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    return std.fs.path.join(a, &.{ cwd_buf[0..cwd_len], ".zig-cache", "tmp", tmp.sub_path[0..], sub });
}

/// Absolute path of this test run's temp dir root.
fn tmpDirAbs(a: std.mem.Allocator, tmp: testing.TmpDir) ![]const u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    return std.fs.path.join(a, &.{ cwd_buf[0..cwd_len], ".zig-cache", "tmp", tmp.sub_path[0..] });
}

test "scaffolded project builds, runs, and round-trips add command" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var r = try run(tmp.dir, &.{ zcli_exe, "init", "demo" });
        defer r.deinit();
        try expectOk(r);
    }

    var proj = try tmp.dir.openDir(io, "demo", .{});
    defer proj.close(io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const proj_abs = try tmpSubdirAbs(arena.allocator(), tmp, "demo");
    try pointDependencyAtLocalTree(proj, proj_abs);

    // Build the generated project against the local zcli.
    {
        var r = try run(proj, &.{ "zig", "build" });
        defer r.deinit();
        try expectOk(r);
    }
    try testing.expect(fileExists(proj, "zig-out/bin/demo"));

    // The example command runs as generated.
    {
        var r = try run(proj, &.{ "./zig-out/bin/demo", "hello", "World" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "Hello, World!");
    }

    // Help lists the discovered command (the help plugin writes to stderr).
    {
        var r = try run(proj, &.{ "./zig-out/bin/demo", "--help" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stderr, "hello");
    }

    // Round-trip: add a command, rebuild, and run it.
    {
        var r = try run(proj, &.{ zcli_exe, "add", "command", "ping" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        var r = try run(proj, &.{ "zig", "build" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        var r = try run(proj, &.{ "./zig-out/bin/demo", "ping" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "TODO: Implement ping");
    }

    // Declarative mode (`--arg`/`--option` JSON) generates a fully-typed command
    // through the real binary. `multiple` is its own flag, independent of the
    // element type — covering a multiple string positional, a multiple integer
    // option, plus enum/numeric/nullable options and a short flag — and the
    // result must compile and parse under real zcli.
    {
        var r = try run(proj, &.{
            zcli_exe,        "add",                                                                  "command", "users/create",
            "--description", "Create a user",
            "--arg",         "{\"name\":\"email\",\"type\":\"[]const u8\"}",
            "--arg",         "{\"name\":\"names\",\"type\":\"[]const u8\",\"multiple\":true}",
            "--option",      "{\"name\":\"verbose\",\"type\":\"bool\",\"default\":false,\"short\":\"v\"}",
            "--option",      "{\"name\":\"format\",\"type\":\"enum { json, yaml }\",\"default\":\"yaml\"}",
            "--option",      "{\"name\":\"ports\",\"type\":\"u32\",\"multiple\":true}",
            "--option",      "{\"name\":\"note\",\"type\":\"[]const u8\",\"nullable\":true}",
        });
        defer r.deinit();
        try expectOk(r);
    }
    // Optional positionals (`?T = null`) are a distinct generated shape.
    {
        var r = try run(proj, &.{
            zcli_exe, "add",                                         "command", "lookup",
            "--arg",  "{\"name\":\"id\",\"type\":\"[]const u8\"}",
            "--arg",  "{\"name\":\"revision\",\"type\":\"i64\",\"nullable\":true}",
        });
        defer r.deinit();
        try expectOk(r);
    }
    {
        var r = try run(proj, &.{ "zig", "build" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        // Multiple-string positional, multiple-integer option, short flag, enum.
        var r = try run(proj, &.{ "./zig-out/bin/demo", "users", "create", "alice@example.com", "x", "y", "-v", "--format", "json", "--ports", "8080", "--ports", "9090" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "TODO: Implement users create");
    }
}

// ============================================================================
// Layer 2 — interactive (PTY) tests
// ============================================================================

test "interactive: add command drives the wizard and echoes typed input" {
    if (builtin.os.tag == .windows) return;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProjectDirs(tmp.dir);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const proj_abs = try tmpDirAbs(arena.allocator(), tmp);

    // Drive the wizard with a minimal command (no args/options). `send` appends
    // a newline (the Enter that submits a text prompt); `sendRaw` writes exactly
    // the bytes given, which is what the single-key confirm prompts need — a
    // trailing newline would otherwise be read as Enter by the *next* prompt.
    //
    // The `delay` after each prompt is essential: zinput prints+flushes the
    // prompt *before* it enables raw mode, and `enableRawMode` uses a flushing
    // tcsetattr that discards any input already buffered in cooked mode. Sending
    // the instant the prompt appears would race that window and the keystroke
    // would be dropped (single-key confirms would then block forever). The
    // settle lets the child reach its raw-mode blocking read first.
    const settle_ms = 400;
    var script = harness.InteractiveScript.init(testing.allocator);
    defer script.deinit();
    // The final step is a `select` ("What next?") whose default (index 0) is
    // "Create it", so Enter (sendRaw "\r") accepts it.
    _ = script
        .expect("Command path:").delay(settle_ms).send("deploy")
        .expect("Description:").delay(settle_ms).send("Deploy the app")
        .expect("Add a positional argument?").delay(settle_ms).sendRaw("n")
        .expect("Add an option?").delay(settle_ms).sendRaw("n")
        .expect("What next?").delay(settle_ms).sendRaw("\r");

    var result = harness.runInteractive(
        testing.allocator,
        io,
        &.{ zcli_exe, "add", "command" },
        script,
        .{ .cwd = proj_abs, .allocate_pty = true, .total_timeout_ms = 20000 },
    ) catch |err| {
        // PTY allocation can be denied in some sandboxes; don't fail the suite.
        std.debug.print("runInteractive unavailable: {any}\n", .{err});
        return;
    };
    defer result.deinit();

    // Regression for the buffered-writer bug: the wizard enables raw mode (kernel
    // echo OFF), so the description text can only appear in the PTY output if the
    // program flushed its own per-keystroke echo. Before the fix, this was blank.
    try expectContains(result.output, "Deploy the app");

    // And the wizard ran to completion against the typed answers.
    try testing.expect(result.exit_code == 0);
    try expectContains(result.output, "Created src/commands/deploy.zig");
    try testing.expect(fileExists(tmp.dir, "src/commands/deploy.zig"));
}

test "interactive: init's plugin multi-select toggles an opt-in plugin" {
    if (builtin.os.tag == .windows) return;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const proj_abs = try tmpDirAbs(arena.allocator(), tmp);

    // The multi-select enables raw mode once after printing its list, so a single
    // settle before sending is enough (see the wizard test above for the timing
    // rationale). The cursor starts on the first choice (help); three Down arrows
    // move it to `completions` (an opt-in, off by default), Space toggles it on,
    // and Enter confirms — leaving the three defaults plus completions selected.
    const settle_ms = 400;
    var script = harness.InteractiveScript.init(testing.allocator);
    defer script.deinit();
    _ = script
        .expect("Select built-in plugins").delay(settle_ms)
        .sendRaw("\x1b[B\x1b[B\x1b[B \r");

    var result = harness.runInteractive(
        testing.allocator,
        io,
        &.{ zcli_exe, "init", "myapp" },
        script,
        .{ .cwd = proj_abs, .allocate_pty = true, .total_timeout_ms = 30000 },
    ) catch |err| {
        // PTY allocation can be denied in some sandboxes; don't fail the suite.
        std.debug.print("runInteractive unavailable: {any}\n", .{err});
        return;
    };
    defer result.deinit();

    try testing.expect(result.exit_code == 0);

    var proj = try tmp.dir.openDir(io, "myapp", .{});
    defer proj.close(io);
    const build_zig = try readFile(proj, arena.allocator(), "build.zig");
    try expectContains(build_zig, "zcli.builtin(.help");
    try expectContains(build_zig, "zcli.builtin(.version");
    try expectContains(build_zig, "zcli.builtin(.not_found");
    try expectContains(build_zig, "zcli.builtin(.completions");
}
