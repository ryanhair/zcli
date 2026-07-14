const std = @import("std");
const builtin = @import("builtin");
const zcli = @import("zcli");
const nightwatch = @import("nightwatch");

const themed = zcli.theme.styled;
const ThemeContext = zcli.theme.ThemeContext;

/// Whether build.zig/build.zig.zon are watched alongside src/. Windows can't:
/// nightwatch's backend (ReadDirectoryChangesW) only watches directories, and
/// the only directory containing the build files is the project root — which
/// the backend rescans recursively on every create/rename, racing zig's own
/// package extraction under zig-pkg/ and corrupting builds. So Windows watches
/// src/ only; build-file edits there need a dev restart.
const watch_build_files = builtin.os.tag != .windows;

pub const meta = .{
    .description = if (watch_build_files)
        "Watch src/, build.zig, and build.zig.zon; rebuild on change (optionally run a command)"
    else
        "Watch src/ and rebuild on change (optionally run a command)",
    .examples = &.{
        "dev",
        "dev -- users create alice@example.com",
    },
    .args = .{
        .command = "Command to run after each successful build (everything after --)",
    },
};

pub const Args = struct {
    /// Everything after `--`: a command to run on each successful build.
    command: [][]const u8 = &.{},
};

pub const Options = struct {};

/// Settle window after the first change event, to coalesce an editor's burst of
/// writes into a single rebuild.
const debounce_ms = 80;

// Convention: this command takes `context: anytype` (not `*Context`) so tests
// can pass a lightweight stub instead of a full app registry; commands that
// don't need that testability use `*Context` for the compile-time contract.
pub fn execute(args: Args, options: Options, context: anytype) !void {
    _ = options;

    const io = context.io;
    const gpa = context.allocator;
    // Status/framing goes to stderr so it never competes with a redirected
    // stdout (e.g. `zcli dev > log`) or the build child's inherited stdout.
    const status = context.stderr();
    const theme = &context.theme;

    // Confirm we're in a project before arming the watcher.
    var probe = std.Io.Dir.cwd().openDir(io, "src", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try status.writeAll("No 'src' directory found. Run this from a zcli project root.\n");
            context.exit(1);
        },
        else => return err,
    };
    probe.close(io);

    // nightwatch needs an absolute path on Zig 0.16: its relative-path branch
    // calls std.Io.Dir.cwd().realPath, which is broken on 0.16.0. currentPath works.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];

    var state = WatchState{ .io = io };
    var watcher = try nightwatch.Default.init(io, gpa, &state.handler);
    defer watcher.deinit();

    // Watch src/ (the command tree) plus — where the platform allows it, see
    // watch_build_files — the build description itself: editing build.zig or
    // build.zig.zon (e.g. adding a shared module or dependency) needs a
    // rebuild just as much as editing a command file does.
    var watched = std.ArrayList([]const u8).empty;
    defer {
        for (watched.items) |p| gpa.free(p);
        watched.deinit(gpa);
    }
    try watchPath(&watcher, io, gpa, cwd, "src", &watched);
    if (watch_build_files) {
        try watchPath(&watcher, io, gpa, cwd, "build.zig", &watched);
        try watchPath(&watcher, io, gpa, cwd, "build.zig.zon", &watched);
    }

    try paint(status, theme, "zcli dev", .header);
    try status.writeAll(if (watch_build_files)
        " — watching src/, build.zig, build.zig.zon (Ctrl-C to stop)\n"
    else
        " — watching src/; build.zig changes need a restart (Ctrl-C to stop)\n");
    try status.flush();

    var cycle_arena = std.heap.ArenaAllocator.init(gpa);
    defer cycle_arena.deinit();

    // The app started by `-- <command>`, if any. Killed and restarted each cycle.
    // The loop below never returns normally — Ctrl-C kills the whole process
    // group (including this child) — so there's nothing to clean up here.
    var app_child: ?std.process.Child = null;

    // Build once up front, then rebuild on every change.
    runCycle(io, &cycle_arena, status, theme, context.app_name, args.command, &app_child);
    while (true) {
        state.waitDirty();
        nap(io, debounce_ms); // let the burst settle
        state.clear(); // coalesce events that arrived during the settle window
        try paint(status, theme, "\n• change detected", .dim);
        try status.writeByte('\n');
        runCycle(io, &cycle_arena, status, theme, context.app_name, args.command, &app_child);
    }
}

/// Watch `name` (relative to `cwd`) if it exists, recording the allocated
/// absolute path in `watched` so it can be freed later. Missing files (e.g. a
/// project without a build.zig.zon) are silently skipped.
fn watchPath(
    watcher: *nightwatch.Default,
    io: std.Io,
    gpa: std.mem.Allocator,
    cwd: []const u8,
    name: []const u8,
    watched: *std.ArrayList([]const u8),
) !void {
    std.Io.Dir.cwd().access(io, name, .{}) catch return;
    const abs = try std.fmt.allocPrint(gpa, "{s}{c}{s}", .{ cwd, std.fs.path.sep, name });
    errdefer gpa.free(abs);
    try watcher.watch(abs);
    try watched.append(gpa, abs);
}

// ============================================================================
// Change signal — bridges nightwatch's background thread to the main loop
// ============================================================================

const vtable = nightwatch.Default.Handler.VTable{ .change = onChange, .rename = onRename };

/// nightwatch delivers events on its own thread; the callbacks just flip a
/// flag that the main loop waits on. A mutex+condvar keeps it race-free and
/// lets the loop block instead of spin.
const WatchState = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    dirty: bool = false,
    handler: nightwatch.Default.Handler = .{ .vtable = &vtable },

    fn mark(self: *WatchState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.dirty = true;
        self.cond.signal(self.io);
    }

    /// Block until a change has been signalled, then consume it.
    fn waitDirty(self: *WatchState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (!self.dirty) self.cond.waitUncancelable(self.io, &self.mutex);
        self.dirty = false;
    }

    fn clear(self: *WatchState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.dirty = false;
    }

    /// Non-blocking consume — used by tests.
    fn takeIfDirty(self: *WatchState) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.dirty) {
            self.dirty = false;
            return true;
        }
        return false;
    }
};

fn onChange(h: *nightwatch.Default.Handler, path: []const u8, event: nightwatch.EventType, obj: nightwatch.ObjectType) error{HandlerFailed}!void {
    _ = path;
    _ = event;
    _ = obj;
    const self: *WatchState = @fieldParentPtr("handler", h);
    self.mark();
}

fn onRename(h: *nightwatch.Default.Handler, src: []const u8, dst: []const u8, obj: nightwatch.ObjectType) error{HandlerFailed}!void {
    _ = src;
    _ = dst;
    _ = obj;
    const self: *WatchState = @fieldParentPtr("handler", h);
    self.mark();
}

// ============================================================================
// Build / run cycle
// ============================================================================

fn runCycle(
    io: std.Io,
    cycle_arena: *std.heap.ArenaAllocator,
    status: *std.Io.Writer,
    theme: *const ThemeContext,
    app_name: []const u8,
    command: []const []const u8,
    app_child: *?std.process.Child,
) void {
    _ = cycle_arena.reset(.retain_capacity);
    doCycle(io, cycle_arena.allocator(), status, theme, app_name, command, app_child) catch |err| {
        // Never let a transient failure tear down the watcher.
        status.print("dev: {s}\n", .{@errorName(err)}) catch {};
        status.flush() catch {};
    };
}

fn doCycle(
    io: std.Io,
    arena: std.mem.Allocator,
    status: *std.Io.Writer,
    theme: *const ThemeContext,
    app_name: []const u8,
    command: []const []const u8,
    app_child: *?std.process.Child,
) !void {
    // Stop the previous run before rebuilding (restart-on-change). kill() blocks
    // until the child is reaped and is idempotent.
    if (app_child.*) |*child| {
        child.kill(io);
        app_child.* = null;
    }

    try paint(status, theme, "▸ rebuilding…", .info);
    try status.writeByte('\n');
    try status.flush(); // child inherits the real fds — flush ours first so order is right

    if (!try build(io, status, theme)) return; // build failed → don't run

    if (command.len > 0) {
        app_child.* = try startApp(io, arena, status, theme, app_name, command);
    }
}

/// Run `zig build` (blocking), reporting success. Returns false on failure.
fn build(io: std.Io, status: *std.Io.Writer, theme: *const ThemeContext) !bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ "zig", "build" },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            try paint(status, theme, "✗ could not launch `zig` — is it on your PATH?", .err);
            try status.writeByte('\n');
            try status.flush();
            return false;
        },
        else => return err,
    };
    const term = try child.wait(io);
    const ok = term == .exited and term.exited == 0;
    try paint(status, theme, if (ok) "✓ build succeeded" else "✗ build failed", if (ok) .ok else .err);
    try status.writeByte('\n');
    try status.flush();
    return ok;
}

/// Spawn the freshly built binary (non-blocking) so it can be killed and
/// restarted on the next change. Returns null if no executable was produced.
fn startApp(
    io: std.Io,
    arena: std.mem.Allocator,
    status: *std.Io.Writer,
    theme: *const ThemeContext,
    app_name: []const u8,
    command: []const []const u8,
) !?std.process.Child {
    const binary = (try findBinary(io, arena, status, theme, app_name)) orelse {
        try paint(status, theme, "  (no executable in zig-out/bin to run)", .dim);
        try status.writeByte('\n');
        try status.flush();
        return null;
    };

    try paint(status, theme, "▸ running ", .info);
    try status.writeAll(binary);
    try status.writeByte('\n');
    try status.flush();

    return try std.process.spawn(io, .{
        .argv = try appArgv(arena, binary, command),
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
}

/// Picks the executable in zig-out/bin to run. A scaffolded project produces
/// exactly one, so the common case is unambiguous; if a project's build
/// produces several (multiple `b.addExecutable` calls), prefer the one whose
/// name matches the app (`app_name`, e.g. from `.app_name` in `generate()`),
/// falling back to the first entry (sorted for determinism) with a warning so
/// the choice is visible rather than silent.
fn findBinary(
    io: std.Io,
    arena: std.mem.Allocator,
    status: *std.Io.Writer,
    theme: *const ThemeContext,
    app_name: []const u8,
) !?[]const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, "zig-out/bin", .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var names = std.ArrayList([]const u8).empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, std.fs.path.stem(entry.name), app_name)) {
            return try std.fmt.allocPrint(arena, "zig-out{c}bin{c}{s}", .{ std.fs.path.sep, std.fs.path.sep, entry.name });
        }
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    if (names.items.len == 0) return null;

    std.mem.sort([]const u8, names.items, {}, lessThanStr);
    if (names.items.len > 1) {
        try paint(status, theme, "  (multiple executables in zig-out/bin; running ", .dim);
        try status.writeAll(names.items[0]);
        try status.writeAll(" — pass a distinct app_name or clean zig-out/bin to disambiguate)\n");
        try status.flush();
    }
    return try std.fmt.allocPrint(arena, "zig-out{c}bin{c}{s}", .{ std.fs.path.sep, std.fs.path.sep, names.items[0] });
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// `<binary> <command...>`.
fn appArgv(arena: std.mem.Allocator, binary: []const u8, command: []const []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    try list.append(arena, binary);
    try list.appendSlice(arena, command);
    return list.items;
}

fn nap(io: std.Io, ms: u32) void {
    std.Io.sleep(io, std.Io.Duration.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

// ============================================================================
// Output
// ============================================================================

const Role = enum { header, info, ok, err, dim };

fn paint(out: *std.Io.Writer, theme: *const ThemeContext, text: []const u8, role: Role) !void {
    const t = themed(text);
    switch (role) {
        .header => try t.header().bold().render(out, theme),
        .info => try t.info().render(out, theme),
        .ok => try t.success().bold().render(out, theme),
        .err => try t.err().bold().render(out, theme),
        .dim => try t.dim().render(out, theme),
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "appArgv prepends the binary to the command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const cmd = [_][]const u8{ "users", "create", "alice" };
    const argv = try appArgv(arena_state.allocator(), "zig-out/bin/app", &cmd);
    try testing.expectEqual(@as(usize, 4), argv.len);
    try testing.expectEqualStrings("zig-out/bin/app", argv[0]);
    try testing.expectEqualStrings("users", argv[1]);
    try testing.expectEqualStrings("alice", argv[3]);
}

test "appArgv with no command is just the binary" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const argv = try appArgv(arena_state.allocator(), "zig-out/bin/app", &.{});
    try testing.expectEqual(@as(usize, 1), argv.len);
    try testing.expectEqualStrings("zig-out/bin/app", argv[0]);
}

test "WatchState coalesces and consumes the dirty signal" {
    var s = WatchState{ .io = std.testing.io };
    try testing.expect(!s.takeIfDirty()); // clean to start

    s.mark();
    s.mark(); // multiple events collapse to one
    try testing.expect(s.takeIfDirty());
    try testing.expect(!s.takeIfDirty()); // consumed

    s.mark();
    s.clear();
    try testing.expect(!s.takeIfDirty()); // clear() drops it
}
