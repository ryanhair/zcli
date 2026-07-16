//! End-to-end tests for the zcli meta-tool.
//!
//! These run the *built* `zcli` binary as a subprocess against throwaway temp
//! directories and assert on the files it generates and (for the slow tier) that
//! the generated project actually builds and runs.
//!
//! Run with `zig build e2e` (NOT part of `zig build test`, since the build-and-run
//! tier compiles zcli from source and is slow).
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

// The scaffolded demo binary path. `zig build` emits `demo.exe` on Windows and
// `demo` elsewhere; the suffix is empty on POSIX, so this is a no-op there.
const exe_ext = if (builtin.os.tag == .windows) ".exe" else "";
const demo_bin = "./zig-out/bin/demo" ++ exe_ext;

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

/// Run two invocations of the demo binary through a single *shell* redirect
/// `( a; b ) >log 2>&1`, reproducing an inherited shared regular-file stdout
/// (`cmd >log`, CI logs, cron, a coding agent capturing output). This is the
/// exact shape a positional-mode stdio writer corrupts: it pwrites from its own
/// offset starting at 0, so the second invocation overwrites the first from byte
/// 0. Streaming mode instead writes at the fd's shared kernel offset, so the two
/// appends serialize.
///
/// The redirect is driven by the *shell*, not by Zig's `std.process.spawn(.file
/// = ...)`, on purpose. On POSIX, `.file` uses `dup2`, sharing one open file
/// description (shared offset) — but on Windows, `.file` *reopens* the handle
/// (`NtCreateFile` with an empty name relative to the handle, Threaded.zig
/// `processSpawnWindows`), yielding a fresh FILE_OBJECT whose position starts at
/// 0. Two `.file` spawns would therefore each write from 0 on Windows regardless
/// of the writer's mode, so that path can't model the shared-offset scenario.
/// A shell (`cmd.exe` / `sh`) opens the log once and inherits the *same* handle
/// to both child processes, giving a genuinely shared file position on both
/// platforms — which is precisely what the reported real-world redirect does.
fn runTwiceIntoSharedFileViaShell(a: std.mem.Allocator, cwd: std.Io.Dir, log_name: []const u8, bin: []const u8) !void {
    const argv: []const []const u8 = if (builtin.os.tag == .windows) blk: {
        // cmd.exe wants backslashes and no leading `./`; normalize `bin`.
        const trimmed = if (std.mem.startsWith(u8, bin, "./")) bin[2..] else bin;
        const win_bin = try a.dupe(u8, trimmed);
        std.mem.replaceScalar(u8, win_bin, '/', '\\');
        // `( bin hello First & bin hello Second ) > log 2>&1`. `&` sequences
        // unconditionally (unlike `&&`); `2>&1` folds stderr in.
        break :blk &.{ "cmd", "/c", try std.fmt.allocPrint(a, "( {s} hello First & {s} hello Second ) > {s} 2>&1", .{ win_bin, win_bin, log_name }) };
    } else &.{ "sh", "-c", try std.fmt.allocPrint(a, "( '{s}' hello First; '{s}' hello Second ) > {s} 2>&1", .{ bin, bin, log_name }) };

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    _ = try child.wait(io);
}

/// Run `bin flood | head -n1` through a shell, so a downstream reader closes
/// the CLI's stdout pipe after one line while the CLI keeps writing. That is
/// the classic broken-pipe scenario (`yourcli cmd | head`). The CLI's *own*
/// stderr is redirected to `err_name` (before the `| head`, so it isn't head's
/// stderr) and returned, so the caller can assert it stays clean — no
/// `WriteFailed`, no return trace. Requires the flood output to exceed the pipe
/// buffer, so the CLI is still writing when the reader is already gone.
///
/// Driven by a shell (not `std.process.spawn`) because the pipe + early-closing
/// reader is exactly what a shell pipeline sets up, on both POSIX and Windows.
fn runIntoHeadViaShell(a: std.mem.Allocator, cwd: std.Io.Dir, bin: []const u8, cmd: []const u8, err_name: []const u8) ![]u8 {
    const argv: []const []const u8 = if (builtin.os.tag == .windows) blk: {
        const trimmed = if (std.mem.startsWith(u8, bin, "./")) bin[2..] else bin;
        const win_bin = try a.dupe(u8, trimmed);
        std.mem.replaceScalar(u8, win_bin, '/', '\\');
        // `more +2` reads a couple lines then can be closed; but the simplest
        // early-closing reader available in cmd.exe is a nested `powershell`
        // Select-Object -First 1. Redirect the CLI's stderr to a file first.
        break :blk &.{ "cmd", "/c", try std.fmt.allocPrint(a, "{s} {s} 2> {s} | powershell -NoProfile -Command \"$input | Select-Object -First 1\" > NUL", .{ win_bin, cmd, err_name }) };
    } else &.{ "sh", "-c", try std.fmt.allocPrint(a, "'{s}' {s} 2> {s} | head -n1 > /dev/null", .{ bin, cmd, err_name }) };

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = try child.wait(io);
    return readFile(cwd, a, err_name);
}

fn fileExists(dir: std.Io.Dir, path: []const u8) bool {
    // Windows rejects these characters in a path at the syscall layer with
    // OBJECT_NAME_INVALID, which Zig surfaces as an unrecoverable panic rather
    // than a catchable error. A name containing one can't exist, so treat it as
    // absent instead of handing it to access(). (POSIX allows them, e.g. the
    // `bad"name` project-name rejection test, where access just reports ENOENT.)
    if (builtin.os.tag == .windows and std.mem.indexOfAny(u8, path, "<>\"|?*") != null) return false;
    dir.access(io, path, .{}) catch return false;
    return true;
}

fn readFile(dir: std.Io.Dir, a: std.mem.Allocator, path: []const u8) ![]u8 {
    return dir.readFileAlloc(io, path, a, .limited(1 << 20));
}

/// Replace the first occurrence of `needle` with `replacement` in `path`,
/// erroring if `needle` is absent — so a test that edits generated code fails
/// loudly the moment the generator's output drifts from what it expects.
fn replaceInFile(dir: std.Io.Dir, a: std.mem.Allocator, path: []const u8, needle: []const u8, replacement: []const u8) !void {
    const orig = try readFile(dir, a, path);
    const at = std.mem.indexOf(u8, orig, needle) orelse return error.NeedleNotFound;
    const out = try std.mem.concat(a, u8, &.{ orig[0..at], replacement, orig[at + needle.len ..] });
    try dir.writeFile(io, .{ .sub_path = path, .data = out });
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

    // The zcli dependency comes from a real `zig fetch` of the release tag
    // pinned to this build's version. During a release run that tag does not
    // exist yet — tests gate the tag creation (#301), so the staged version's
    // `zig fetch` fails by design and init reports it (#328). Assert whichever
    // outcome init declared; both verify the v* tag wiring (#352).
    if (std.mem.indexOf(u8, r.stdout, "was not fetched") == null) {
        try expectContains(zon, ".zcli = .{");
        try expectContains(zon, "github.com/ryanhair/zcli");
    } else {
        try testing.expect(std.mem.indexOf(u8, zon, ".zcli = .{") == null);
        try expectContains(r.stdout, "zig fetch --save https://github.com/ryanhair/zcli/archive/refs/tags/v");
    }

    const build_zig = try readFile(proj, a, "build.zig");
    try expectContains(build_zig, "zcli.generate(");
    // Local-plugin discovery is wired so `add plugin` needs no build.zig edit.
    try expectContains(build_zig, ".plugins_dir = \"src/plugins\"");
    // With no TTY, the plugin prompt falls back to its preselected defaults:
    // help, version, and not_found (but not the opt-in plugins like completions).
    try expectContains(build_zig, "zcli.builtin(.help");
    try expectContains(build_zig, "zcli.builtin(.version");
    try expectContains(build_zig, "zcli.builtin(.not_found");
    try testing.expect(std.mem.indexOf(u8, build_zig, "zcli.builtin(.completions") == null);

    const hello = try readFile(proj, a, "src/commands/hello.zig");
    try expectContains(hello, "pub fn execute(");

    // The AGENTS.md spine (ADR-0008): thin, command-speaking, points at the guide.
    const agents = try readFile(proj, a, "AGENTS.md");
    try expectContains(agents, "<!-- zcli:begin -->");
    try expectContains(agents, "<!-- zcli:end -->");
    try expectContains(agents, "zcli guide");
    try expectContains(agents, "per-command arena");
}

test "init escapes free-text --description into a valid string literal" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var r = try run(tmp.dir, &.{ zcli_exe, "init", "myapp", "--description", "say \"hi\"\\back" });
    defer r.deinit();
    try expectOk(r);

    var proj = try tmp.dir.openDir(io, "myapp", .{});
    defer proj.close(io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The quote and backslash must be escaped — unescaped, the literal
    // terminates early and the generated build.zig doesn't compile.
    const build_zig = try readFile(proj, a, "build.zig");
    try expectContains(build_zig, ".app_description = \"say \\\"hi\\\"\\\\back\"");
}

test "init rejects a project name that would break generated source" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var r = try run(tmp.dir, &.{ zcli_exe, "init", "bad\"name" });
    defer r.deinit();
    try testing.expect(r.exit_code != 0);
    try expectContains(r.stderr, "Invalid project name");
    // Nothing half-created is left behind.
    try testing.expect(!fileExists(tmp.dir, "bad\"name"));
}

test "init rejects a Zig reserved word as the project name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // `error` is a keyword: `.name = .error` in build.zig.zon won't compile.
    var r = try run(tmp.dir, &.{ zcli_exe, "init", "error" });
    defer r.deinit();
    try testing.expect(r.exit_code != 0);
    try expectContains(r.stderr, "Invalid project name");
    try expectContains(r.stderr, "reserved word");
    try testing.expect(!fileExists(tmp.dir, "error"));
}

test "init . scaffolds into the current directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // `init .` derives the project name from the directory name, and tmpDir's
    // random name can start with a digit (rejected by name validation) — run
    // inside a stable, valid-named subdirectory.
    try tmp.dir.createDir(io, "myapp", .default_dir);
    var proj = try tmp.dir.openDir(io, "myapp", .{});
    defer proj.close(io);

    var r = try run(proj, &.{ zcli_exe, "init", "." });
    defer r.deinit();
    try expectOk(r);

    try testing.expect(fileExists(proj, "build.zig"));
    try testing.expect(fileExists(proj, "src/commands/hello.zig"));
}

test "init . rejects a directory name that can't be a project name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A leading digit can't become the zon `.name` enum literal; the error
    // must say the name came from the directory, not leave the user guessing.
    try tmp.dir.createDir(io, "7wonders", .default_dir);
    var proj = try tmp.dir.openDir(io, "7wonders", .{});
    defer proj.close(io);

    var r = try run(proj, &.{ zcli_exe, "init", "." });
    defer r.deinit();
    try testing.expect(r.exit_code != 0);
    try expectContains(r.stderr, "Invalid project name");
    try expectContains(r.stderr, "current directory");
    try testing.expect(!fileExists(proj, "build.zig"));
}

test "init . appends to a pre-existing AGENTS.md instead of refusing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Stable subdirectory: see "init . scaffolds into the current directory".
    try tmp.dir.createDir(io, "myapp", .default_dir);
    var proj = try tmp.dir.openDir(io, "myapp", .{});
    defer proj.close(io);

    // A directory whose only visible file is the user's own AGENTS.md — init
    // treats it as appendable, not a conflict (ADR-0008).
    try proj.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "# House rules\n\nRun the linter.\n" });

    var r = try run(proj, &.{ zcli_exe, "init", "." });
    defer r.deinit();
    try expectOk(r);
    try testing.expect(fileExists(proj, "build.zig"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const agents = try readFile(proj, arena.allocator(), "AGENTS.md");
    try expectContains(agents, "# House rules"); // user content preserved
    try expectContains(agents, "Run the linter.");
    try expectContains(agents, "<!-- zcli:begin -->"); // zcli section appended
    try std.testing.expect(std.mem.indexOf(u8, agents, "# House rules").? <
        std.mem.indexOf(u8, agents, "<!-- zcli:begin -->").?); // user content first
}

test "add command creates stubs at the right paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProjectDirs(tmp.dir);

    {
        var r = try run(tmp.dir, &.{ zcli_exe, "add", "command", "deploy" });
        defer r.deinit();
        try expectOk(r);
        // A flat command births no group, so no group hint.
        try testing.expect(std.mem.indexOf(u8, r.stdout, "new group") == null);
    }
    try testing.expect(fileExists(tmp.dir, "src/commands/deploy.zig"));

    // Nested path creates intermediate directories, and the new 'users' group
    // has no index.zig yet — the command hints how to describe it.
    {
        var r = try run(tmp.dir, &.{ zcli_exe, "add", "command", "users/create", "--description", "Create a user" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "new group 'users' has no description");
        try expectContains(r.stdout, "zcli add group users");
    }
    try testing.expect(fileExists(tmp.dir, "src/commands/users/create.zig"));

    // A second command under an existing group births nothing, so no hint.
    {
        var r = try run(tmp.dir, &.{ zcli_exe, "add", "command", "users/list" });
        defer r.deinit();
        try expectOk(r);
        try testing.expect(std.mem.indexOf(u8, r.stdout, "new group") == null);
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const created = try readFile(tmp.dir, a, "src/commands/users/create.zig");
    try expectContains(created, ".description = \"Create a user\"");
    try expectContains(created, "pub fn execute(");
    // Full meta surface is scaffolded as commented fields (read/write symmetry
    // with `tree --show-options`).
    try expectContains(created, "// .aliases =");
    try expectContains(created, "// .hidden =");
}

test "add group scaffolds meta-only and landing index files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProjectDirs(tmp.dir);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Meta-only group (a pure group: index.zig with just a description).
    {
        var r = try run(tmp.dir, &.{ zcli_exe, "add", "group", "users", "--description", "Manage users" });
        defer r.deinit();
        try expectOk(r);
    }
    const idx = try readFile(tmp.dir, a, "src/commands/users/index.zig");
    try expectContains(idx, ".description = \"Manage users\"");
    try testing.expect(std.mem.indexOf(u8, idx, "pub fn execute") == null); // pure group

    // Describing an already-described group is refused.
    {
        var r = try run(tmp.dir, &.{ zcli_exe, "add", "group", "users", "-d", "again" });
        defer r.deinit();
        try testing.expect(r.exit_code != 0);
        try expectContains(r.stderr, "already described");
    }

    // A landing group (nested path) gets an empty-Args execute.
    {
        var r = try run(tmp.dir, &.{ zcli_exe, "add", "group", "gh/pr", "--with-landing", "-d", "Pull requests" });
        defer r.deinit();
        try expectOk(r);
    }
    const landing = try readFile(tmp.dir, a, "src/commands/gh/pr/index.zig");
    try expectContains(landing, "pub const Args = struct {};"); // no positionals
    try expectContains(landing, "pub fn execute(_: Args, _: Options");
    try expectContains(landing, "TODO: Implement gh pr");
}

test "add plugin scaffolds a skeleton and hints when plugins_dir is missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProjectDirs(tmp.dir);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A build.zig that does NOT wire plugins_dir → the command prints the
    // one-line fix rather than editing build.zig.
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "pub fn build(b: *std.Build) void { _ = b; }\n" });
    {
        var r = try run(tmp.dir, &.{ zcli_exe, "add", "plugin", "telemetry", "-d", "Track usage" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "won't be discovered");
        try expectContains(r.stdout, ".plugins_dir = \"src/plugins\",");
    }

    const src = try readFile(tmp.dir, a, "src/plugins/telemetry.zig");
    try expectContains(src, "The `telemetry` plugin — Track usage");
    try expectContains(src, "pub fn preExecute(context: anytype, args: zcli.ParsedArgs)");
    try expectContains(src, "// pub fn onError(context: anytype, err: anyerror) !bool"); // catalog, commented
    try expectContains(src, "// pub const plugin_id = \"telemetry\";");

    // A duplicate is refused.
    {
        var r = try run(tmp.dir, &.{ zcli_exe, "add", "plugin", "telemetry" });
        defer r.deinit();
        try testing.expect(r.exit_code != 0);
        try expectContains(r.stderr, "already exists");
    }
}

test "add command outside a project fails clearly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var r = try run(tmp.dir, &.{ zcli_exe, "add", "command", "deploy" });
    defer r.deinit();
    try testing.expect(r.exit_code != 0);
    try expectContains(r.stderr, "Not in a zcli project");
    // A user mistake exits cleanly via context.fail() — no raw error trace.
    try testing.expect(std.mem.indexOf(u8, r.stderr, "error: NotInZcliProject") == null);
}

test "unknown option prints the diagnostic message, exits 2 (misuse), no error trace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProjectDirs(tmp.dir);

    var r = try run(tmp.dir, &.{ zcli_exe, "tree", "--bogus" });
    defer r.deinit();
    // CLI misuse (a bad option) exits 2 by convention.
    try testing.expect(r.exit_code == 2);
    // The wired diagnostic names the exact flag...
    try expectContains(r.stderr, "Unknown option '--bogus'");
    // ...and the raw Zig error trace no longer follows the friendly message.
    try testing.expect(std.mem.indexOf(u8, r.stderr, "error: OptionUnknown") == null);
}

test "tree outside a project exits nonzero and its message survives the exit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var r = try run(tmp.dir, &.{ zcli_exe, "tree" });
    defer r.deinit();
    try testing.expect(r.exit_code != 0);
    // The message goes to a buffered writer immediately before context.exit —
    // it only reaches us because exit() flushes the framework IO.
    try expectContains(r.stderr, "No 'src/commands' directory found");
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

test "tree --show-options surfaces the unified arg/option grammar" {
    var sample = try openSampleFixture();
    defer sample.close(io);

    var r = try run(sample, &.{ zcli_exe, "tree", "--show-options" });
    defer r.deinit();
    try expectOk(r);

    // Command-level aliases (ADR-0007): surfaced only under --show-options.
    try expectContains(r.stdout, "aliases=hi");
    // Args: required <>, defaulted [=], variadic [...].
    try expectContains(r.stdout, "<name:[]const u8> [times:u32=1] [extra:[]const u8...]");
    // Options: bool renders bare with its short flag; optional keeps its type.
    try expectContains(r.stdout, "[--loud/-l] [--repeat:u32]");
}

test "tree stays compact without --show-options" {
    var sample = try openSampleFixture();
    defer sample.close(io);

    var r = try run(sample, &.{ zcli_exe, "tree" });
    defer r.deinit();
    try expectOk(r);

    // Descriptions stay; the read-back-only aliases marker does not.
    try expectContains(r.stdout, "Say hello to someone");
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "aliases=") == null);
}

test "guide lists topics and embeds the canonical example source" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The overview lists topics.
    {
        var r = try run(tmp.dir, &.{ zcli_exe, "guide" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "Topics (zcli guide <topic>)");
        try expectContains(r.stdout, "http");
        try expectContains(r.stdout, "secrets");
    }

    // A topic embeds the *actual* compiled example source (ADR-0008): its
    // presence proves the build-wired cross-package @embedFile reached the
    // binary. `zcli.http.Client` is a line from examples/repostat/.../repo.zig.
    {
        var r = try run(tmp.dir, &.{ zcli_exe, "guide", "http" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "zcli.http.Client.init");
        try expectContains(r.stdout, "https://api.github.com/repos/");
    }

    // Same for `storage`, embedding examples/notes/src/store.zig — the canonical
    // JSON-persistence idiom (typed parse + std.json.fmt).
    {
        var r = try run(tmp.dir, &.{ zcli_exe, "guide", "storage" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "std.json.parseFromSlice");
        try expectContains(r.stdout, "std.json.fmt(notes");
    }

    // And `plugins`, embedding examples/notes/src/plugins/verbose.zig — the full
    // plugin anatomy (plugin_id + ContextData + global_options + handler).
    {
        var r = try run(tmp.dir, &.{ zcli_exe, "guide", "plugins" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "pub const plugin_id");
        try expectContains(r.stdout, "pub fn handleGlobalOption");
    }

    // An unknown topic fails (non-zero) and prints the topic list as guidance,
    // exiting cleanly rather than leaking a raw `error:` line.
    {
        var r = try run(tmp.dir, &.{ zcli_exe, "guide", "nope" });
        defer r.deinit();
        try testing.expect(r.exit_code != 0);
        try expectContains(r.stderr, "Unknown guide topic");
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "error: UnknownTopic") == null);
    }
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
        zcli_exe,    "release",       "patch",
        "--dry-run", "--skip-checks", "--skip-tests",
        "--message", "test notes",
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
/// Splice `zcli.builtin(.<tag>, .{})` into the generated build.zig's
/// `.plugins = &.{` list, right after the opening brace. Used by tests that
/// hand-write a command using a builtin plugin `init` didn't preselect — the
/// real exe (now part of the `test` step per #531) must actually have the
/// plugin registered to compile, same as any real app would need.
fn addBuiltinPlugin(proj: std.Io.Dir, tag: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const orig = try readFile(proj, a, "build.zig");
    const marker = ".plugins = &.{";
    const idx = std.mem.indexOf(u8, orig, marker) orelse return error.NoPluginsBlock;
    const insert_at = idx + marker.len;

    const rewritten = try std.fmt.allocPrint(
        a,
        "{s}\n            zcli.builtin(.{s}, .{{}}),{s}",
        .{ orig[0..insert_at], tag, orig[insert_at..] },
    );
    try proj.writeFile(io, .{ .sub_path = "build.zig", .data = rewritten });
}

fn pointDependencyAtLocalTree(proj: std.Io.Dir, proj_abs: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // from/to are absolute, so cwd/environ are unused.
    const rel = try std.fs.path.relative(a, "", null, proj_abs, repo_root);
    // build.zig.zon paths use forward slashes on every platform. On Windows the
    // relative path comes back with backslashes, which would be invalid escape
    // sequences once embedded in the generated Zig string literal below.
    std.mem.replaceScalar(u8, rel, '\\', '/');

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

    // A command that streams far more than one pipe buffer (~200 KB), so a
    // downstream `| head -n1` closes the read end while the CLI is still
    // writing — the broken-pipe regression below relies on it.
    try proj.writeFile(io, .{
        .sub_path = "src/commands/flood.zig",
        .data =
        \\const Context = @import("command_registry").Context;
        \\pub const meta = .{ .description = "Print many lines" };
        \\pub const Args = struct {};
        \\pub const Options = struct {};
        \\pub fn execute(_: Args, _: Options, context: *Context) !void {
        \\    const out = context.stdout();
        \\    var i: usize = 0;
        \\    while (i < 20000) : (i += 1) {
        \\        try out.print("line {d} padding padding padding padding\n", .{i});
        \\    }
        \\}
        \\
        ,
    });

    // Build the generated project against the local zcli.
    {
        var r = try run(proj, &.{ "zig", "build" });
        defer r.deinit();
        try expectOk(r);
    }
    try testing.expect(fileExists(proj, "zig-out/bin/demo" ++ exe_ext));

    // The example command runs as generated.
    {
        var r = try run(proj, &.{ demo_bin, "hello", "World" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "Hello, World!");
    }

    // Regression (P0 output corruption): two invocations sharing one inherited
    // regular-file stdout must both survive, in order. A positional-mode stdio
    // writer pwrites from offset 0 every time, so the second run clobbered the
    // first from byte 0 — losing output to CI logs, cron, and agents capturing
    // command output (pipes/TTYs were unaffected, masking it). Streaming mode
    // respects the fd's shared offset, so appends serialize. Driven through a
    // shell redirect (see runTwiceIntoSharedFileViaShell) so the shared handle
    // is modeled the same way on POSIX and Windows.
    {
        try runTwiceIntoSharedFileViaShell(arena.allocator(), proj, "shared.log", demo_bin);

        const contents = try readFile(proj, arena.allocator(), "shared.log");
        const first = std.mem.indexOf(u8, contents, "Hello, First!") orelse {
            std.debug.print("shared.log lost the first invocation:\n{s}\n", .{contents});
            return error.FirstOutputClobbered;
        };
        const second = std.mem.indexOf(u8, contents, "Hello, Second!") orelse {
            std.debug.print("shared.log lost the second invocation:\n{s}\n", .{contents});
            return error.SecondOutputMissing;
        };
        // Order preserved: the second append lands after the first, not over it.
        try testing.expect(second > first);
    }

    // Regression (broken pipe): `demo flood | head -n1` closes the stdout pipe
    // after one line while the command is still writing. Zig's start code
    // ignores SIGPIPE, so the write returns EPIPE (surfaced as WriteFailed) —
    // the framework must treat that as a normal end of a pipeline and exit
    // quietly, NOT dump `error: WriteFailed` and a return trace like every
    // unhandled error. A good unix citizen (`grep | head`) prints nothing here.
    {
        const cli_stderr = try runIntoHeadViaShell(arena.allocator(), proj, demo_bin, "flood", "flood.err");
        if (std.mem.indexOf(u8, cli_stderr, "WriteFailed") != null or
            std.mem.indexOf(u8, cli_stderr, "error: ") != null)
        {
            std.debug.print("broken-pipe leaked a trace to stderr:\n----\n{s}\n----\n", .{cli_stderr});
            return error.BrokenPipeLeakedTrace;
        }
    }

    // Help lists the discovered command. Explicitly-requested help goes to
    // stdout (GNU convention), not stderr.
    {
        var r = try run(proj, &.{ demo_bin, "--help" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "hello");
    }

    // `help <cmd>` shows help for THAT command (its usage line), not for the
    // `help` command itself. Regression test for the argv-rewrite fix.
    {
        var r = try run(proj, &.{ demo_bin, "help", "hello" });
        defer r.deinit();
        try expectOk(r);
        // The usage line names the target command, and the description of the
        // help command ("Show help for commands") must NOT appear.
        try expectContains(r.stdout, "hello");
        try expectContains(r.stdout, "USAGE:");
        try testing.expect(std.mem.indexOf(u8, r.stdout, "Show help for commands") == null);
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
        var r = try run(proj, &.{ demo_bin, "ping" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "TODO: Implement ping");
    }

    // `add option` splices options into the just-created `ping` command via the
    // AST editor, preserving its execute() body. The spliced source must compile
    // and the new flags must parse under the real binary — covering a scalar with
    // a short + default, a bool, and an accumulating (multiple) option.
    {
        var r = try run(proj, &.{ zcli_exe, "add", "option", "ping", "count", "--type", "u32", "--default", "1", "--short", "c", "-d", "How many pings" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        var r = try run(proj, &.{ zcli_exe, "add", "option", "ping", "loud", "--type", "bool", "--default", "false" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        var r = try run(proj, &.{ zcli_exe, "add", "option", "ping", "tags", "--type", "[]const u8", "--multiple" });
        defer r.deinit();
        try expectOk(r);
    }
    // A duplicate option name is rejected (never silently splices twice).
    {
        var r = try run(proj, &.{ zcli_exe, "add", "option", "ping", "count", "--type", "u32", "--default", "2" });
        defer r.deinit();
        try testing.expect(r.exit_code != 0);
        try expectContains(r.stderr, "already has an option named 'count'");
    }
    {
        var r = try run(proj, &.{ "zig", "build" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        var r = try run(proj, &.{ demo_bin, "ping", "-c", "3", "--loud", "--tags", "a", "--tags", "b" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "TODO: Implement ping");
    }
    // The comma-separated multi-value form is accepted by the real binary
    // (equivalent to repeating --tags), while an empty segment is rejected.
    {
        var r = try run(proj, &.{ demo_bin, "ping", "--tags", "a,b", "--tags", "c" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "TODO: Implement ping");
    }
    {
        var r = try run(proj, &.{ demo_bin, "ping", "--tags", "a,,b" });
        defer r.deinit();
        try testing.expect(r.exit_code != 0);
    }

    // A second command assembled entirely from atomic `add arg`/`add option`
    // edits — the flag interface that replaced the JSON blob (ADR-0005). This
    // exercises the full arg shape set (required, optional, variadic) with
    // `--before` positioning, plus enum/numeric/nullable/multiple options and a
    // short flag; the result must compile and parse under the real binary.
    {
        var r = try run(proj, &.{ zcli_exe, "add", "command", "users/create", "--description", "Create a user" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        // No --type: defaults to []const u8 (a string arg), same as the
        // wizard's "text" choice.
        var r = try run(proj, &.{ zcli_exe, "add", "arg", "users/create", "email" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        var r = try run(proj, &.{ zcli_exe, "add", "arg", "users/create", "names", "--type", "[]const u8", "--multiple" });
        defer r.deinit();
        try expectOk(r);
    }
    // An optional positional inserted *before* the variadic (kept valid by
    // --before: required email, optional age, variadic names).
    {
        var r = try run(proj, &.{ zcli_exe, "add", "arg", "users/create", "age", "--type", "u8", "--nullable", "--before", "names" });
        defer r.deinit();
        try expectOk(r);
    }
    // The ordering rule is enforced live: nothing may follow a variadic.
    {
        var r = try run(proj, &.{ zcli_exe, "add", "arg", "users/create", "late", "--type", "[]const u8" });
        defer r.deinit();
        try testing.expect(r.exit_code != 0);
        try expectContains(r.stderr, "must be last");
    }
    {
        var r = try run(proj, &.{ zcli_exe, "add", "option", "users/create", "verbose", "--type", "bool", "--default", "false", "--short", "v" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        var r = try run(proj, &.{ zcli_exe, "add", "option", "users/create", "format", "--type", "enum { json, yaml }", "--default", ".yaml" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        var r = try run(proj, &.{ zcli_exe, "add", "option", "users/create", "ports", "--type", "u32", "--multiple" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        var r = try run(proj, &.{ zcli_exe, "add", "option", "users/create", "note", "--type", "[]const u8", "--nullable" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        var r = try run(proj, &.{ "zig", "build" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        // required + optional + variadic positionals, short flag, enum, multiple option.
        var r = try run(proj, &.{ demo_bin, "users", "create", "alice@example.com", "5", "x", "y", "-v", "--format", "json", "--ports", "8080", "--ports", "9090" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "TODO: Implement users create");
    }

    // `rm option`/`rm arg` splice fields back out (the inverse editor). A bulk
    // removal that names a missing field rejects the whole batch and edits
    // nothing; the valid removals then splice out cleanly and the result must
    // still compile and run under the real binary.
    {
        var r = try run(proj, &.{ zcli_exe, "rm", "option", "users/create", "note", "ghost" });
        defer r.deinit();
        try testing.expect(r.exit_code != 0);
        try expectContains(r.stderr, "has no option named 'ghost'");
    }
    {
        var r = try run(proj, &.{ zcli_exe, "rm", "option", "users/create", "note", "ports" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "Removed 2 options");
    }
    {
        // Remove the optional positional; email + variadic names remain valid.
        var r = try run(proj, &.{ zcli_exe, "rm", "arg", "users/create", "age" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        var r = try run(proj, &.{ "zig", "build" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        // The removed --ports/--note flags are gone; the trimmed command still runs.
        var r = try run(proj, &.{ demo_bin, "users", "create", "alice@example.com", "x", "y", "-v", "--format", "json" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "TODO: Implement users create");
    }

    // `add group --with-landing` scaffolds a runnable group; with a subcommand
    // under it, both the group landing and the subcommand must compile and run.
    {
        var r = try run(proj, &.{ zcli_exe, "add", "group", "server", "--with-landing", "-d", "Manage the server" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        var r = try run(proj, &.{ zcli_exe, "add", "command", "server/status", "-d", "Show status" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        var r = try run(proj, &.{ "zig", "build" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        // The group runs on its own (landing execute)...
        var r = try run(proj, &.{ demo_bin, "server" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "TODO: Implement server");
    }
    {
        // ...and dispatches to its subcommand.
        var r = try run(proj, &.{ demo_bin, "server", "status" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "TODO: Implement server status");
    }
    {
        // `server` is both executable (a landing execute) AND a group (it has
        // `server status`). Its `--help` renders command help whose sections run
        // OPTIONS before COMMANDS — the command's own contract first, navigation
        // to children last — and closes with a "run <sub> --help" hint under the
        // subcommand list. Explicit help → stdout.
        var r = try run(proj, &.{ demo_bin, "server", "--help" });
        defer r.deinit();
        try expectOk(r);
        const i_opts = std.mem.indexOf(u8, r.stdout, "OPTIONS:") orelse return error.NoOptionsSection;
        const i_cmds = std.mem.indexOf(u8, r.stdout, "COMMANDS:") orelse return error.NoCommandsSection;
        try testing.expect(i_opts < i_cmds);
        try expectContains(r.stdout, "status"); // the subcommand
        // The follow-up hint lands under the subcommand list.
        const i_hint = std.mem.indexOf(u8, r.stdout, "for more information on a subcommand") orelse return error.NoSubcommandHint;
        try testing.expect(i_hint > i_cmds);
    }

    // A pure command group (no `--with-landing`): bare `demo cfg` isn't runnable
    // on its own, so it resolves to CommandNotFound → the help plugin's onError
    // detects the group and renders group help. That help path threads through
    // onError, which is exactly the real-plugin group rendering the audit found
    // untested (only a mock covered it).
    {
        var r = try run(proj, &.{ zcli_exe, "add", "group", "cfg", "-d", "Configuration" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        var r = try run(proj, &.{ zcli_exe, "add", "command", "cfg/show", "-d", "Show configuration" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        var r = try run(proj, &.{ "zig", "build" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        // Bare group invocation. A pure group's CommandNotFound is handled by the
        // help plugin, which renders the group with the same command help renderer
        // as `cfg --help` (USAGE + COMMANDS list). It doesn't propagate, so the
        // process exits 0 — but the help is error-triggered, so it goes to STDERR
        // (#236 convention), keeping a piped stdout clean.
        var r = try run(proj, &.{ demo_bin, "cfg" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stderr, "USAGE:");
        try expectContains(r.stderr, "COMMANDS:");
        try expectContains(r.stderr, "show"); // the subcommand under cfg
        // Group help is an error reaction → stderr only. stdout stays empty.
        try testing.expect(r.stdout.len == 0);
    }

    // `add plugin` drops a file into the convention-discovered src/plugins/ dir
    // (init wired `.plugins_dir`). The generated skeleton must compile and be
    // auto-discovered on the next build — no build.zig edit.
    {
        var r = try run(proj, &.{ zcli_exe, "add", "plugin", "telemetry", "-d", "Track usage" });
        defer r.deinit();
        try expectOk(r);
        // plugins_dir is wired by init, so no "won't be discovered" hint.
        try testing.expect(std.mem.indexOf(u8, r.stdout, "won't be discovered") == null);
    }
    try testing.expect(fileExists(proj, "src/plugins/telemetry.zig"));

    // Replace the pass-through skeleton with a plugin whose preExecute has a
    // *visible* effect, so the rebuild proves the plugin is genuinely discovered
    // and its hook runs — not merely that the file compiles. (A pass-through
    // hook is indistinguishable from one that never ran.)
    try proj.writeFile(io, .{
        .sub_path = "src/plugins/telemetry.zig",
        .data =
        \\const std = @import("std");
        \\const zcli = @import("zcli");
        \\pub fn preExecute(context: anytype, args: zcli.ParsedArgs) !?zcli.ParsedArgs {
        \\    try context.stderr().print("[telemetry] hook ran\n", .{});
        \\    return args;
        \\}
        \\
        ,
    });
    {
        var r = try run(proj, &.{ "zig", "build" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        var r = try run(proj, &.{ demo_bin, "hello", "World" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "Hello, World!");
        // The discovered plugin's preExecute ran (proves .plugins_dir is honored
        // and the local-plugin module resolves to the project's src/plugins/).
        try expectContains(r.stderr, "[telemetry] hook ran");
    }

    // `mv` + `rm command`: whole-file restructure. Move a command into a new
    // group, rebuild, and run it at its new path; then remove it, rebuild, and
    // confirm both the command and its now-empty group directory are gone.
    {
        var r = try run(proj, &.{ zcli_exe, "add", "command", "scratch", "-d", "Scratch" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        var r = try run(proj, &.{ zcli_exe, "mv", "scratch", "tools/scratch" });
        defer r.deinit();
        try expectOk(r);
    }
    try testing.expect(!fileExists(proj, "src/commands/scratch.zig"));
    try testing.expect(fileExists(proj, "src/commands/tools/scratch.zig"));
    {
        var r = try run(proj, &.{ "zig", "build" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        // The moved command runs at its new path (its execute() travelled intact).
        var r = try run(proj, &.{ demo_bin, "tools", "scratch" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "TODO: Implement scratch");
    }
    {
        var r = try run(proj, &.{ zcli_exe, "rm", "command", "tools/scratch" });
        defer r.deinit();
        try expectOk(r);
    }
    // The command file is gone and its sole-occupant group dir was cleaned up.
    try testing.expect(!fileExists(proj, "src/commands/tools/scratch.zig"));
    try testing.expect(!fileExists(proj, "src/commands/tools"));
    {
        var r = try run(proj, &.{ "zig", "build" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        // The removed command no longer resolves.
        var r = try run(proj, &.{ demo_bin, "tools", "scratch" });
        defer r.deinit();
        try testing.expect(r.exit_code != 0);
    }
}

test "required options and enum args: end-user messages and help" {
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
    const a = arena.allocator();
    const proj_abs = try tmpSubdirAbs(a, tmp, "demo");
    try pointDependencyAtLocalTree(proj, proj_abs);

    // The scaffolder creates a required option: a non-nullable scalar with no
    // --default is no longer rejected — it renders as a bare `name: T` and the
    // success line marks it (required). (Adds to the init-generated `hello`.)
    {
        var r = try run(proj, &.{ zcli_exe, "add", "option", "hello", "region", "--type", "[]const u8" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "(required)");
        const src = try readFile(proj, a, "src/commands/hello.zig");
        try expectContains(src, "region: []const u8,");
    }

    // A command exercising both features: a required option (`region`: a
    // defaultless, non-optional string) and an enum positional arg (`env`).
    // Commands are convention-discovered from src/commands, so writing the file
    // is enough — no registration.
    try proj.writeFile(io, .{
        .sub_path = "src/commands/deploy.zig",
        .data =
        \\const std = @import("std");
        \\const zcli = @import("zcli");
        \\const Context = @import("command_registry").Context;
        \\
        \\pub const meta = .{
        \\    .description = "Deploy to an environment",
        \\    .options = .{ .region = .{ .description = "Target region" } },
        \\};
        \\
        \\pub const Args = struct {
        \\    env: enum { dev, staging, prod },
        \\};
        \\
        \\pub const Options = struct {
        \\    region: []const u8,
        \\};
        \\
        \\pub fn execute(args: Args, options: Options, context: *Context) !void {
        \\    try context.stdout().print("Deploying {s} to {s}\n", .{ @tagName(args.env), options.region });
        \\}
        \\
        ,
    });
    {
        var r = try run(proj, &.{ "zig", "build" });
        defer r.deinit();
        try expectOk(r);
    }

    // A required option omitted from every source is a clean, humane error.
    {
        var r = try run(proj, &.{ demo_bin, "deploy", "dev" });
        defer r.deinit();
        try testing.expect(r.exit_code != 0);
        try expectContains(r.stderr, "Missing required option '--region'");
        try expectContains(r.stderr, "Run 'demo deploy --help' for usage.");
        // Humane message, not a raw error name/trace.
        try testing.expect(std.mem.indexOf(u8, r.stderr, "OptionMissingRequired") == null);
    }

    // Supplied on the CLI: the command runs.
    {
        var r = try run(proj, &.{ demo_bin, "deploy", "dev", "--region", "us-east-1" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "Deploying dev to us-east-1");
    }

    // Supplied via the environment: also satisfies the requirement. (No `.env`
    // is declared here, so this must still error — asserting the negative keeps
    // the "required" definition honest: only real sources satisfy it.)
    {
        var r = try run(proj, &.{ demo_bin, "deploy", "staging" });
        defer r.deinit();
        try testing.expect(r.exit_code != 0);
        try expectContains(r.stderr, "Missing required option '--region'");
    }

    // A mistyped enum arg reports the choices AND a did-you-mean.
    {
        var r = try run(proj, &.{ demo_bin, "deploy", "prud", "--region", "us-east-1" });
        defer r.deinit();
        try testing.expect(r.exit_code != 0);
        try expectContains(r.stderr, "Invalid value 'prud'");
        try expectContains(r.stderr, "Did you mean 'prod'?");
    }

    // Help shows the required option marker + usage placement, and the enum
    // choices for the positional arg. Explicit help renders to stdout.
    {
        var r = try run(proj, &.{ demo_bin, "deploy", "--help" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "--region <value>"); // usage line
        try expectContains(r.stdout, "(required)"); // OPTIONS marker
        try expectContains(r.stdout, "one of: dev, staging, prod"); // ARGUMENTS choices
    }
}

test "root zcli_theme declaration themes help output" {
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
    const a = arena.allocator();
    const proj_abs = try tmpSubdirAbs(a, tmp, "demo");
    try pointDependencyAtLocalTree(proj, proj_abs);

    // Declare a custom theme in the app root — the std_options-style hook.
    // Command names in help should render in this color (tomato, 255;99;71).
    // The scaffolded main.zig already imports zcli (for the panic hook).
    try replaceInFile(proj, a, "src/main.zig",
        \\const registry = @import("command_registry");
    ,
        \\const registry = @import("command_registry");
        \\
        \\pub const zcli_theme: zcli.Theme = .{
        \\    .palette = .{ .command = .{ .foreground = .{ .rgb = .{ .r = 255, .g = 99, .b = 71 } } } },
        \\};
    );

    {
        var r = try run(proj, &.{ "zig", "build" });
        defer r.deinit();
        try expectOk(r);
    }

    // Piped (non-TTY) output stays completely plain. Explicit help → stdout.
    {
        var r = try run(proj, &.{ demo_bin, "--help" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "hello");
        try testing.expect(std.mem.indexOf(u8, r.stdout, "\x1b[") == null);
    }

    // The PTY harness needs an absolute binary path: ConPTY's CreateProcessW
    // resolves a relative command-line path against the parent's cwd, not the
    // child's `cwd`.
    const demo_abs = try std.fs.path.join(a, &.{ proj_abs, "zig-out", "bin", "demo" ++ exe_ext });

    // Under a PTY in a truecolor-capable environment, help renders command
    // names in the custom palette color.
    {
        var env = std.process.Environ.Map.init(testing.allocator);
        defer env.deinit();
        try env.put("TERM", "xterm-256color");
        try env.put("COLORTERM", "truecolor"); // truecolor signal (POSIX)
        try env.put("WT_SESSION", "1"); // truecolor signal (Windows/ConPTY)
        // A replaced environment must still carry SystemRoot on Windows —
        // process startup and console plumbing consult it, and dropping it is
        // a classic source of child-process failures.
        if (builtin.os.tag == .windows) try env.put("SystemRoot", "C:\\Windows");

        var script = harness.InteractiveScript.init(testing.allocator);
        defer script.deinit();
        _ = script.expect("USAGE:");

        var result = harness.runInteractive(
            testing.allocator,
            io,
            &.{ demo_abs, "--help" },
            script,
            .{ .cwd = proj_abs, .allocate_pty = true, .total_timeout_ms = 20000, .env = env },
        ) catch |err| switch (err) {
            // PTY allocation can be denied in some sandboxes; skip rather than
            // fail here, unless ZCLI_REQUIRE_INTERACTIVE=1 demands this tier
            // actually run.
            error.PtyAllocationFailed => {
                // ZCLI_REQUIRE_INTERACTIVE=1 (set by CI) turns a PTY-unavailable
                // sandbox from a silent skip into a hard failure, so the interactive
                // tier can never regress to never-running without the build going red.
                if (harness.interactiveRequired()) {
                    std.debug.print("ZCLI_REQUIRE_INTERACTIVE=1 but a PTY could not be allocated: {any}\n", .{err});
                    return err;
                }
                std.debug.print("runInteractive unavailable: {any}\n", .{err});
                return;
            },
            else => return err,
        };
        defer result.deinit();
        try expectContains(result.output, "38;2;255;99;71");
    }

    // NO_COLOR wins even on a color-capable PTY.
    {
        var env = std.process.Environ.Map.init(testing.allocator);
        defer env.deinit();
        try env.put("TERM", "xterm-256color");
        try env.put("COLORTERM", "truecolor");
        try env.put("WT_SESSION", "1");
        try env.put("NO_COLOR", "1");
        if (builtin.os.tag == .windows) try env.put("SystemRoot", "C:\\Windows");

        var script = harness.InteractiveScript.init(testing.allocator);
        defer script.deinit();
        _ = script.expect("USAGE:");

        var result = harness.runInteractive(
            testing.allocator,
            io,
            &.{ demo_abs, "--help" },
            script,
            .{ .cwd = proj_abs, .allocate_pty = true, .total_timeout_ms = 20000, .env = env },
        ) catch |err| switch (err) {
            error.PtyAllocationFailed => {
                // ZCLI_REQUIRE_INTERACTIVE=1 (set by CI) turns a PTY-unavailable
                // sandbox from a silent skip into a hard failure, so the interactive
                // tier can never regress to never-running without the build going red.
                if (harness.interactiveRequired()) {
                    std.debug.print("ZCLI_REQUIRE_INTERACTIVE=1 but a PTY could not be allocated: {any}\n", .{err});
                    return err;
                }
                std.debug.print("runInteractive unavailable: {any}\n", .{err});
                return;
            },
            else => return err,
        };
        defer result.deinit();
        // Assert the theme's color is gone, not that the stream has zero
        // escapes: ConPTY re-renders child output as VT screen-diff frames
        // (cursor, positioning, resets), so escape-free PTY output is
        // impossible on Windows even when the child writes plain text.
        try testing.expect(std.mem.indexOf(u8, result.output, "38;2;255;99;71") == null);
    }
}

test "scaffolded commands are unit-testable via zig build test" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var r = try run(tmp.dir, &.{ zcli_exe, "init", "app" });
        defer r.deinit();
        try expectOk(r);
    }

    var proj = try tmp.dir.openDir(io, "app", .{});
    defer proj.close(io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const proj_abs = try tmpSubdirAbs(arena.allocator(), tmp, "app");
    try pointDependencyAtLocalTree(proj, proj_abs);

    const build_test = [_][]const u8{ "zig", "build", "test" };

    // A scaffolded command ships with a co-located placeholder test.
    {
        var r = try run(proj, &.{ zcli_exe, "add", "command", "greet", "-d", "Greet" });
        defer r.deinit();
        try expectOk(r);
    }

    // Prove the full runCommand chain works in a *generated* project: a command
    // tested against the TestContext stub + the bundled zcli-testing tier, with
    // captured output. If the stub Context or the exposed testing module were
    // mis-wired, this would fail to compile.
    try proj.writeFile(io, .{
        .sub_path = "src/commands/hi.zig",
        .data =
        \\const std = @import("std");
        \\const zcli = @import("zcli");
        \\const Context = @import("command_registry").Context;
        \\pub const meta = .{ .description = "hi" };
        \\pub const Args = struct {};
        \\pub const Options = struct {};
        \\pub fn execute(_: Args, _: Options, context: *Context) !void {
        \\    try context.stdout().print("hi there\n", .{});
        \\}
        \\test "hi runs via runCommand" {
        \\    const zcli_testing = @import("zcli-testing");
        \\    var r = try zcli_testing.runCommand(@This(), .{});
        \\    defer r.deinit();
        \\    try std.testing.expect(r.success);
        \\    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "hi there") != null);
        \\}
        \\
        ,
    });

    // `zig build test` (wired by init via zcli.addCommandTests) compiles each
    // command as a test binary and runs the co-located tests — the scaffolded
    // greet placeholder plus the real hi runCommand test above.
    {
        var r = try run(proj, &build_test);
        defer r.deinit();
        try expectOk(r);
    }

    // Prove the tests actually EXECUTE — a green step with zero tests would be a
    // false pass. A co-located test that fails on purpose must turn it red.
    try proj.writeFile(io, .{
        .sub_path = "src/commands/canary.zig",
        .data =
        \\const std = @import("std");
        \\const zcli = @import("zcli");
        \\const Context = @import("command_registry").Context;
        \\pub const meta = .{ .description = "canary" };
        \\pub const Args = struct {};
        \\pub const Options = struct {};
        \\pub fn execute(_: Args, _: Options, _: *Context) !void {}
        \\test "canary fails on purpose" {
        \\    try std.testing.expect(false);
        \\}
        \\
        ,
    });
    {
        var r = try run(proj, &build_test);
        defer r.deinit();
        try testing.expect(r.exit_code != 0);
    }
}

test "a shared module reaches both commands and their tests" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var r = try run(tmp.dir, &.{ zcli_exe, "init", "app" });
        defer r.deinit();
        try expectOk(r);
    }

    var proj = try tmp.dir.openDir(io, "app", .{});
    defer proj.close(io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const proj_abs = try tmpSubdirAbs(a, tmp, "app");
    try pointDependencyAtLocalTree(proj, proj_abs);

    // A helper module imported by a command AND its co-located test.
    try proj.writeFile(io, .{
        .sub_path = "src/store.zig",
        .data = "pub fn tag() []const u8 {\n    return \"from-store\";\n}\n",
    });

    // Populate the `shared_modules` list init leaves empty (with a commented
    // example). Matching that exact block also asserts the template still ships
    // the anchor — if init's output drifts, replaceInFile errors loudly.
    try replaceInFile(proj, a, "build.zig",
        \\    const shared_modules = [_]zcli.SharedModule{
        \\        // .{ .name = "store", .module = store_module },
        \\    };
    ,
        \\    const store_module = b.createModule(.{
        \\        .root_source_file = b.path("src/store.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\    const shared_modules = [_]zcli.SharedModule{
        \\        .{ .name = "store", .module = store_module },
        \\    };
    );

    // A command importing `store` in both execute() and its runCommand test.
    // `zig build test` passes only if `store` reaches the command's *test*
    // binary — i.e. shared_modules flowed to addCommandTests, not just
    // generate(). One list, two call sites (see `zcli guide sharing`).
    try proj.writeFile(io, .{
        .sub_path = "src/commands/greet.zig",
        .data =
        \\const std = @import("std");
        \\const zcli = @import("zcli");
        \\const store = @import("store");
        \\const Context = @import("command_registry").Context;
        \\pub const meta = .{ .description = "greet" };
        \\pub const Args = struct { name: []const u8 };
        \\pub const Options = struct {};
        \\pub fn execute(args: Args, _: Options, context: *Context) !void {
        \\    try context.stdout().print("hi {s} ({s})\n", .{ args.name, store.tag() });
        \\}
        \\test "greet uses the shared store module" {
        \\    const zcli_testing = @import("zcli-testing");
        \\    var r = try zcli_testing.runCommand(@This(), .{ .args = .{ .name = "Ada" } });
        \\    defer r.deinit();
        \\    try std.testing.expect(r.success);
        \\    try std.testing.expect(std.mem.indexOf(u8, r.stdout, store.tag()) != null);
        \\}
        \\
        ,
    });

    {
        var r = try run(proj, &.{ "zig", "build", "test" });
        defer r.deinit();
        try expectOk(r);
    }
}

test "a command's plugin state is testable via runCommand .plugins" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var r = try run(tmp.dir, &.{ zcli_exe, "init", "app" });
        defer r.deinit();
        try expectOk(r);
    }

    var proj = try tmp.dir.openDir(io, "app", .{});
    defer proj.close(io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const proj_abs = try tmpSubdirAbs(a, tmp, "app");
    try pointDependencyAtLocalTree(proj, proj_abs);

    // A plugin with state (a --verbose flag). init doesn't scaffold src/plugins,
    // so create it (writeFile doesn't make parent dirs).
    try proj.createDir(io, "src/plugins", .default_dir);
    try proj.writeFile(io, .{
        .sub_path = "src/plugins/verbose.zig",
        .data =
        \\const std = @import("std");
        \\const zcli = @import("zcli");
        \\pub const plugin_id = "verbose";
        \\pub const ContextData = struct { enabled: bool = false };
        \\pub const global_options = [_]zcli.GlobalOption{
        \\    zcli.option("verbose", bool, .{ .short = 'v', .default = false, .description = "Verbose" }),
        \\};
        \\pub fn handleGlobalOption(context: anytype, name: []const u8, value: anytype) !void {
        \\    if (std.mem.eql(u8, name, "verbose")) context.plugins.verbose.enabled = value;
        \\}
        \\
        ,
    });

    // A command that reads `context.plugins.verbose` UNGUARDED, with a test that
    // drives that state via `.plugins`. Compiles only if addCommandTests made the
    // stub Context plugin-aware; passes only if runCommand set the plugin state.
    try proj.writeFile(io, .{
        .sub_path = "src/commands/greet.zig",
        .data =
        \\const std = @import("std");
        \\const zcli = @import("zcli");
        \\const Context = @import("command_registry").Context;
        \\pub const meta = .{ .description = "greet" };
        \\pub const Args = struct { name: []const u8 };
        \\pub const Options = struct {};
        \\pub fn execute(args: Args, _: Options, context: *Context) !void {
        \\    if (context.plugins.verbose.enabled)
        \\        try context.stderr().print("[verbose] greeting {s}\n", .{args.name});
        \\    try context.stdout().print("Hello, {s}!\n", .{args.name});
        \\}
        \\test "greet: --verbose drives the diagnostic" {
        \\    const zcli_testing = @import("zcli-testing");
        \\    var r = try zcli_testing.runCommand(@This(), .{
        \\        .args = .{ .name = "Ada" },
        \\        .plugins = .{ .verbose = .{ .enabled = true } },
        \\    });
        \\    defer r.deinit();
        \\    try std.testing.expect(r.success);
        \\    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "[verbose] greeting Ada") != null);
        \\}
        \\
        ,
    });

    {
        var r = try run(proj, &.{ "zig", "build", "test" });
        defer r.deinit();
        try expectOk(r);
    }
}

test "a command that uses zcli_secrets is runCommand-testable without the keychain" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var r = try run(tmp.dir, &.{ zcli_exe, "init", "app" });
        defer r.deinit();
        try expectOk(r);
    }

    var proj = try tmp.dir.openDir(io, "app", .{});
    defer proj.close(io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const proj_abs = try tmpSubdirAbs(arena.allocator(), tmp, "app");
    try pointDependencyAtLocalTree(proj, proj_abs);

    // `init`'s non-interactive default plugin set doesn't include secrets;
    // register it explicitly so the *real* exe (part of the `test` step, not
    // just the command-test stub) has `context.plugins.zcli_secrets` too — a
    // command using a plugin's context data must have that plugin wired for
    // the real app to compile, same as it would for any user's project.
    try addBuiltinPlugin(proj, "secrets");

    // A command that reads a secret via the *builtin* zcli_secrets plugin, with
    // a co-located test. addCommandTests wires an in-memory zcli_secrets into the
    // test stub, so the runCommand test below runs without the real OS keychain
    // (and without a native link) even though the real exe links the real
    // plugin. Before that, `context.plugins.zcli_secrets` didn't exist in the
    // stub and the test wouldn't compile.
    try proj.writeFile(io, .{
        .sub_path = "src/commands/reveal.zig",
        .data =
        \\const std = @import("std");
        \\const zcli = @import("zcli");
        \\const Context = @import("command_registry").Context;
        \\pub const meta = .{ .description = "reveal a stored secret" };
        \\pub const Args = struct { name: []const u8 };
        \\pub const Options = struct {};
        \\pub fn execute(args: Args, _: Options, context: *Context) !void {
        \\    const secret = (try context.plugins.zcli_secrets.get(args.name)) orelse
        \\        return context.fail("no secret named '{s}'", .{args.name});
        \\    try context.stdout().print("{s}\n", .{secret});
        \\}
        \\test "reveal: missing secret fails cleanly" {
        \\    const zcli_testing = @import("zcli-testing");
        \\    var r = try zcli_testing.runCommand(@This(), .{ .args = .{ .name = "absent" } });
        \\    defer r.deinit();
        \\    try std.testing.expect(!r.success);
        \\    try std.testing.expect(r.err.? == error.CommandFailed);
        \\    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "no secret named 'absent'") != null);
        \\}
        \\
        ,
    });

    {
        var r = try run(proj, &.{ "zig", "build", "test" });
        defer r.deinit();
        try expectOk(r);
    }
}

// ============================================================================
// Layer 2 — interactive (PTY) tests
// ============================================================================

test "interactive: add command drives the wizard and echoes typed input" {
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
    // The `delay` after each prompt is essential: prompts prints+flushes the
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
        // The typed description must be visible on the RENDERED screen, not just
        // present somewhere in the byte stream. The wizard enables raw mode
        // (kernel echo OFF) and repaints frame diffs, so a regression that
        // stopped echoing keystrokes would leave "Deploy the app" out of the
        // drawn frame while stray bytes could still satisfy a stream grep. This
        // walks the terminal cells, so it only passes if the answer is on screen.
        .expectFrameContains("Deploy the app")
        // Gate the confirm-prompt sends on the RENDERED screen, not a raw-stream
        // grep. ConPTY delivers these prompts as cursor-addressed diffs — the
        // text lands on the terminal cells, but the bytes are fragmented and
        // never contiguous in the stream, so `expect("Add a positional
        // argument?")` (a substring search) times out on Windows even though the
        // prompt is plainly on screen. The vterm reassembles the frame the way a
        // terminal would, so the frame check sees the prompt on every backend.
        .expectFrameContains("Add a positional argument?").delay(settle_ms).sendRaw("n")
        .expectFrameContains("Add an option?").delay(settle_ms).sendRaw("n")
        .expectFrameContains("What next?").delay(settle_ms).sendRaw("\r");

    var result = harness.runInteractive(
        testing.allocator,
        io,
        &.{ zcli_exe, "add", "command" },
        script,
        .{ .cwd = proj_abs, .allocate_pty = true, .total_timeout_ms = 20000 },
    ) catch |err| switch (err) {
        // PTY allocation can be denied in some sandboxes; skip rather than fail
        // here, unless ZCLI_REQUIRE_INTERACTIVE=1 demands this tier actually
        // run. Every other error is a real harness/test failure — a catch-all
        // here made harness bugs read as skips.
        error.PtyAllocationFailed => {
            // ZCLI_REQUIRE_INTERACTIVE=1 (set by CI) turns a PTY-unavailable
            // sandbox from a silent skip into a hard failure, so the interactive
            // tier can never regress to never-running without the build going red.
            if (harness.interactiveRequired()) {
                std.debug.print("ZCLI_REQUIRE_INTERACTIVE=1 but a PTY could not be allocated: {any}\n", .{err});
                return err;
            }
            std.debug.print("runInteractive unavailable: {any}\n", .{err});
            return;
        },
        else => return err,
    };
    defer result.deinit();

    // Regression for the buffered-writer bug (per-keystroke echo under raw mode)
    // is now asserted on the rendered frame mid-script via expectFrameContains
    // above — strictly stronger than the old raw-stream substring here.

    // And the wizard ran to completion against the typed answers.
    try testing.expect(result.exit_code == 0);
    try expectContains(result.output, "Created src/commands/deploy.zig");
    try testing.expect(fileExists(tmp.dir, "src/commands/deploy.zig"));
}

test "interactive: a SIGTERM mid-prompt restores the terminal from raw mode" {
    // The regression this locks: a prompt enables raw mode, and an external
    // signal (kill -TERM from another shell) skips the prompt's `defer
    // raw.disable()`. The async-signal-safe restore guard must catch the signal
    // and put termios back — otherwise the user's shell is stuck in raw mode
    // (no echo, no line editing) and needs a `reset`. Prompts register their
    // raw mode with the guard (via App.init's hybrid_raw); this proves it fires.
    //
    // POSIX-only: the assertion reads the PTY's line-discipline termios, which
    // has no ConPTY analogue. On Windows the harness leaves final_termios null
    // and rawModeRestored() returns null, so we'd skip anyway.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProjectDirs(tmp.dir);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const proj_abs = try tmpDirAbs(arena.allocator(), tmp);

    // Drive the wizard to its first prompt (a raw-mode `text` prompt), let raw
    // mode engage (the same settle rationale as the wizard test above), then
    // kill it with SIGTERM instead of answering. Named `settle_ms` (matching
    // the idiom used throughout this file) rather than a bare literal, so the
    // wait reads as the same settle window every other interactive test
    // documents, not an unexplained magic number.
    const settle_ms = 500;
    var script = harness.InteractiveScript.init(testing.allocator);
    defer script.deinit();
    _ = script
        .expect("Command path:").delay(settle_ms)
        .sendSignal(.SIGTERM);

    var result = harness.runInteractive(
        testing.allocator,
        io,
        &.{ zcli_exe, "add", "command" },
        script,
        .{ .cwd = proj_abs, .allocate_pty = true, .total_timeout_ms = 20000 },
    ) catch |err| switch (err) {
        error.PtyAllocationFailed => {
            // ZCLI_REQUIRE_INTERACTIVE=1 (set by CI) turns a PTY-unavailable
            // sandbox from a silent skip into a hard failure, so the interactive
            // tier can never regress to never-running without the build going red.
            if (harness.interactiveRequired()) {
                std.debug.print("ZCLI_REQUIRE_INTERACTIVE=1 but a PTY could not be allocated: {any}\n", .{err});
                return err;
            }
            std.debug.print("runInteractive unavailable: {any}\n", .{err});
            return;
        },
        else => return err,
    };
    defer result.deinit();

    // The run completed (no PtyAllocationFailed), so a PTY was allocated and its
    // termios was sampled after the child died — a null here would be a harness
    // regression, not a legitimate skip. The guard's SIGTERM handler must have
    // restored termios: cooked (ICANON + ECHO), not the raw mode the prompt set.
    const restored = result.rawModeRestored() orelse {
        std.debug.print("expected a termios sample after a PTY run; got none\n", .{});
        return error.TestExpectedTermiosSample;
    };
    try testing.expect(restored);
}

test "interactive: text prompt handles multibyte UTF-8 typing and backspace" {
    // ConPTY delivers console input through the child's input code page. zcli
    // now switches that to UTF-8 at startup (see console_utf8.zig / the run
    // entry in packages/core), so a typed `é` round-trips intact under the
    // ConPTY harness rather than collapsing to U+FFFD.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProjectDirs(tmp.dir);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const proj_abs = try tmpDirAbs(arena.allocator(), tmp);

    // Description keystrokes: C a f é <backspace> e <enter>. The backspace lands
    // on the 2-byte é — a grapheme-aware editor deletes it whole, leaving "Cafe";
    // the old byte-oriented one popped a single byte, leaving invalid UTF-8
    // ("Caf\xC3" + "e") in the generated file. See the wizard test above for the
    // settle-delay rationale.
    //
    // The é is typed and then erased, split by a settle delay: prompts render
    // frame diffs, so the é reaches the stream only in the frame painted while
    // it is on screen — the pause lets that frame flush (and lets ConPTY, which
    // coalesces screen diffs, emit one) before the erase, on both backends.
    const settle_ms = 400;
    var script = harness.InteractiveScript.init(testing.allocator);
    defer script.deinit();
    _ = script
        .expect("Command path:").delay(settle_ms).send("greet")
        // Type "Café", then backspace (erases the whole é grapheme) + "e".
        .expect("Description:").delay(settle_ms).sendRaw("Caf\xc3\xa9").delay(settle_ms).sendRaw("\x7fe\r")
        // Frame assertion: after the grapheme-aware backspace, the description
        // line as DRAWN must read exactly "Café" (with é already erased →
        // "Cafe"). A raw substring can't prove this — the pre-backspace "Café"
        // frame and the deleted bytes both linger in the byte soup, so a
        // rendering regression that left half-glyph debris on screen would still
        // match the stream. containsText walks the rendered cells, so it only
        // passes if the final "Description: Cafe" is what a terminal shows.
        .expectFrameContains("Description: Cafe")
        // Confirm-prompt gates on the rendered screen — see the wizard test
        // above: ConPTY fragments these prompts into cursor-addressed diffs, so a
        // raw-stream `expect` substring times out on Windows though the prompt is
        // on screen. The vterm frame check is backend-robust.
        .expectFrameContains("Add a positional argument?").delay(settle_ms).sendRaw("n")
        .expectFrameContains("Add an option?").delay(settle_ms).sendRaw("n")
        .expectFrameContains("What next?").delay(settle_ms).sendRaw("\r");

    var result = harness.runInteractive(
        testing.allocator,
        io,
        &.{ zcli_exe, "add", "command" },
        script,
        .{ .cwd = proj_abs, .allocate_pty = true, .total_timeout_ms = 20000 },
    ) catch |err| switch (err) {
        // PTY allocation can be denied in some sandboxes; skip rather than fail
        // here, unless ZCLI_REQUIRE_INTERACTIVE=1 demands this tier actually
        // run. Every other error is a real harness/test failure — a catch-all
        // here made harness bugs read as skips.
        error.PtyAllocationFailed => {
            // ZCLI_REQUIRE_INTERACTIVE=1 (set by CI) turns a PTY-unavailable
            // sandbox from a silent skip into a hard failure, so the interactive
            // tier can never regress to never-running without the build going red.
            if (harness.interactiveRequired()) {
                std.debug.print("ZCLI_REQUIRE_INTERACTIVE=1 but a PTY could not be allocated: {any}\n", .{err});
                return err;
            }
            std.debug.print("runInteractive unavailable: {any}\n", .{err});
            return;
        },
        else => return err,
    };
    defer result.deinit();

    // The é was echoed intact — its two UTF-8 bytes emitted together, never
    // torn across writes. (Prompts paint frame *diffs* now, so a typed word is
    // never contiguous in the byte stream — each keystroke emits only its new
    // cell — but any single grapheme always is.) Raw-stream is the right tool
    // here: the point is the byte pairing, which the rendered screen erases.
    try expectContains(result.output, "é");
    // The "Description: Cafe" screen line is now asserted mid-script via
    // expectFrameContains above — a rendered-cell check, strictly stronger than
    // the old raw-stream substring, which the cursor-diff stream could satisfy
    // without the text ever being visible in place.

    try testing.expect(result.exit_code == 0);
    const generated = try readFile(tmp.dir, arena.allocator(), "src/commands/greet.zig");
    try expectContains(generated, ".description = \"Cafe\"");
}

test "interactive: init's plugin multi-select toggles an opt-in plugin" {
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
    ) catch |err| switch (err) {
        // PTY allocation can be denied in some sandboxes; skip rather than fail
        // here, unless ZCLI_REQUIRE_INTERACTIVE=1 demands this tier actually
        // run. Every other error is a real harness/test failure — a catch-all
        // here made harness bugs read as skips.
        error.PtyAllocationFailed => {
            // ZCLI_REQUIRE_INTERACTIVE=1 (set by CI) turns a PTY-unavailable
            // sandbox from a silent skip into a hard failure, so the interactive
            // tier can never regress to never-running without the build going red.
            if (harness.interactiveRequired()) {
                std.debug.print("ZCLI_REQUIRE_INTERACTIVE=1 but a PTY could not be allocated: {any}\n", .{err});
                return err;
            }
            std.debug.print("runInteractive unavailable: {any}\n", .{err});
            return;
        },
        else => return err,
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

test "interactive: init's plugin multi-select toggles github_upgrade and the scaffold compiles" {
    // Regression for issue #329: the only prior coverage of the picker's
    // github_upgrade path (init.zig's "renderPluginsBlock scaffolds a
    // compiling github_upgrade config" unit test) asserts the emitted
    // *string*, not that it actually compiles against the plugin's real
    // `Config` — a future rename of `.repo`/`.verification`/`.checksum_only`
    // would break the picker output silently, only surfacing when a user
    // selects it. github_upgrade is the one opt-in plugin with *required*
    // config fields (no defaults), so unlike the sibling toggle test above
    // (which picks `completions`, a configless `.{}` plugin), this drives the
    // wizard all the way to a real `zig build` of the resulting scaffold.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const proj_abs = try tmpSubdirAbs(arena.allocator(), tmp, "myapp");

    // Choice order (init.zig's builtin_choices): help, version, not_found,
    // completions, config, github_upgrade — five Down arrows from the
    // cursor's starting position (help) land on github_upgrade.
    const settle_ms = 400;
    var script = harness.InteractiveScript.init(testing.allocator);
    defer script.deinit();
    _ = script
        .expect("Select built-in plugins").delay(settle_ms)
        .sendRaw("\x1b[B\x1b[B\x1b[B\x1b[B\x1b[B \r");

    var result = harness.runInteractive(
        testing.allocator,
        io,
        &.{ zcli_exe, "init", "myapp" },
        script,
        .{ .cwd = try tmpDirAbs(arena.allocator(), tmp), .allocate_pty = true, .total_timeout_ms = 30000 },
    ) catch |err| switch (err) {
        // PTY allocation can be denied in some sandboxes; skip rather than fail
        // here, unless ZCLI_REQUIRE_INTERACTIVE=1 demands this tier actually
        // run. Every other error is a real harness/test failure — a catch-all
        // here made harness bugs read as skips.
        error.PtyAllocationFailed => {
            if (harness.interactiveRequired()) {
                std.debug.print("ZCLI_REQUIRE_INTERACTIVE=1 but a PTY could not be allocated: {any}\n", .{err});
                return err;
            }
            std.debug.print("runInteractive unavailable: {any}\n", .{err});
            return;
        },
        else => return err,
    };
    defer result.deinit();

    try testing.expect(result.exit_code == 0);

    var proj = try tmp.dir.openDir(io, "myapp", .{});
    defer proj.close(io);
    const build_zig = try readFile(proj, arena.allocator(), "build.zig");
    try expectContains(build_zig, "zcli.builtin(.help");
    try expectContains(build_zig, "zcli.builtin(.version");
    try expectContains(build_zig, "zcli.builtin(.not_found");
    try expectContains(build_zig, "zcli.builtin(.github_upgrade");
    try expectContains(build_zig, ".repo = \"OWNER/REPO\"");
    try expectContains(build_zig, ".verification = .checksum_only");

    // The point of this test: build the scaffold for real, against the local
    // zcli tree, so a Config field rename would fail here instead of only at
    // a user's first `zig build` after picking this plugin.
    try pointDependencyAtLocalTree(proj, proj_abs);
    {
        var r = try run(proj, &.{ "zig", "build" });
        defer r.deinit();
        try expectOk(r);
    }
    try testing.expect(fileExists(proj, "zig-out/bin/myapp" ++ exe_ext));
}

// ============================================================================
// Layer 2 — `dev` watch/rebuild loop (long-running; driven over a PTY)
// ============================================================================

/// A file write performed mid-script via InteractiveScript.action — the side
/// channel that drives `dev`. Unlike the wizard tests, `dev` reacts to file
/// changes, not stdin, so the harness pokes the watched tree between `expect`s.
/// The callback runs on the harness thread after the preceding `expect` matched,
/// so the write is ordered strictly after the state that step proved (e.g. the
/// watcher is armed once "watching src/" has appeared).
const DevWrite = struct {
    dir: std.Io.Dir,
    path: []const u8,
    data: []const u8,

    fn run(context: ?*anyopaque) void {
        const self: *DevWrite = @ptrCast(@alignCast(context.?));
        self.dir.writeFile(io, .{ .sub_path = self.path, .data = self.data }) catch {};
    }
};

// A valid hello.zig printing a chosen greeting. Each rebuild in the test below
// uses a UNIQUE greeting so its `expect` waits for that specific cycle to finish
// rather than matching an identical earlier line still in the cumulative buffer.
fn helloPrinting(comptime greeting: []const u8) []const u8 {
    return "const Context = @import(\"command_registry\").Context;\n" ++
        "pub const meta = .{ .description = \"Say hello to someone\" };\n" ++
        "pub const Args = struct { name: []const u8 };\n" ++
        "pub const Options = struct {};\n" ++
        "pub fn execute(args: Args, _: Options, context: *Context) !void {\n" ++
        "    try context.stdout().print(\"" ++ greeting ++ ", {s}!\\n\", .{args.name});\n" ++
        "}\n";
}

test "dev outside a project fails with a clear message" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // No src/ dir → dev refuses before arming the watcher and exits on its own,
    // so the blocking `run` helper suffices (no long-running loop to escape).
    var r = try run(tmp.dir, &.{ zcli_exe, "dev" });
    defer r.deinit();
    try testing.expect(r.exit_code != 0);
    try expectContains(r.stderr, "No 'src' directory found");
}

test "dev builds, runs the app, restarts on change, survives a failed build, and recovers" {
    // Runs on Windows too: nightwatch's Windows backend (ReadDirectoryChangesW)
    // drives the watch, and the harness maps the closing SIGINT onto a ConPTY
    // Ctrl+C that stops the loop.
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
    const a = arena.allocator();
    const proj_abs = try tmpSubdirAbs(a, tmp, "demo");
    try pointDependencyAtLocalTree(proj, proj_abs);

    // The change source for each cycle. `dev` watches src/ recursively, so
    // rewriting the compiled hello.zig triggers a rebuild; a parse error makes a
    // rebuild fail on purpose (the watcher must survive it and recover).
    const path = "src/commands/hello.zig";
    var to_hola = DevWrite{ .dir = proj, .path = path, .data = helloPrinting("Hola") };
    var to_broken = DevWrite{
        .dir = proj,
        .path = path,
        .data = "// Intentionally invalid Zig so `zig build` fails — the dev watcher\n" ++
            "// must survive this and rebuild cleanly once the file is fixed.\n" ++
            "pub fn execute( <<< not valid zig\n",
    };
    var to_recovered = DevWrite{ .dir = proj, .path = path, .data = helloPrinting("Recovered") };

    // Every `expect` after the arm targets a greeting (or the failure line) that
    // appears exactly once, so each waits for its own rebuild rather than the
    // repeated "change detected"/"build succeeded" framing shared by all cycles.
    var script = harness.InteractiveScript.init(testing.allocator);
    defer script.deinit();
    _ = script
        .expect("watching src/").withTimeout(20000)
        .expect("Hello, World!").withTimeout(240000) // initial (cold) build + run
        .action(DevWrite.run, &to_hola)
        .expect("Hola, World!").withTimeout(120000) // rebuild + restart
        .action(DevWrite.run, &to_broken)
        .expect("build failed").withTimeout(120000) // a cycle the watcher survives
        .action(DevWrite.run, &to_recovered)
        .expect("Recovered, World!").withTimeout(120000) // recovery proves survival
        .sendSignal(.SIGINT); // dev never exits on its own — stop the loop

    var result = harness.runInteractive(
        testing.allocator,
        io,
        &.{ zcli_exe, "dev", "--", "hello", "World" },
        script,
        // A PTY (not pipes) merges dev's stderr status lines with the app's
        // stdout onto one stream, so "build failed" is captured alongside the
        // greetings. total_timeout is a ceiling only — the run ends as soon as
        // the last expect matches and SIGINT lands.
        .{ .cwd = proj_abs, .allocate_pty = true, .total_timeout_ms = 600000 },
    ) catch |err| switch (err) {
        // PTY allocation can be denied in some sandboxes; skip rather than fail
        // here, unless ZCLI_REQUIRE_INTERACTIVE=1 demands this tier actually
        // run. Every other error is a real failure.
        error.PtyAllocationFailed => {
            // ZCLI_REQUIRE_INTERACTIVE=1 (set by CI) turns a PTY-unavailable
            // sandbox from a silent skip into a hard failure, so the interactive
            // tier can never regress to never-running without the build going red.
            if (harness.interactiveRequired()) {
                std.debug.print("ZCLI_REQUIRE_INTERACTIVE=1 but a PTY could not be allocated: {any}\n", .{err});
                return err;
            }
            std.debug.print("runInteractive unavailable: {any}\n", .{err});
            return;
        },
        else => return err,
    };
    defer result.deinit();

    // The whole loop ran end to end: the app was built and run, rebuilt and
    // restarted on an edit, a broken edit failed the build without tearing down
    // the watcher, and a fix rebuilt-and-reran — each proven by a once-only line.
    try expectContains(result.output, "Hello, World!");
    try expectContains(result.output, "Hola, World!");
    try expectContains(result.output, "build failed");
    try expectContains(result.output, "Recovered, World!");
}
