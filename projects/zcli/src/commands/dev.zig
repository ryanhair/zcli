const std = @import("std");
const zcli = @import("zcli");
const nightwatch = @import("nightwatch");

const ztheme = zcli.ztheme;
const Theme = ztheme.Theme;

pub const meta = .{
    .description = "Watch src/ and rebuild on change (optionally run a command)",
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
    const src_abs = try std.fmt.allocPrint(gpa, "{s}{c}src", .{ cwd_buf[0..cwd_len], std.fs.path.sep });
    defer gpa.free(src_abs);

    var state = WatchState{ .io = io };
    var watcher = try nightwatch.Default.init(io, gpa, &state.handler);
    defer watcher.deinit();
    try watcher.watch(src_abs);

    try paint(status, theme, "zcli dev", .header);
    try status.writeAll(" — watching src/ (Ctrl-C to stop)\n");
    try status.flush();

    var cycle_arena = std.heap.ArenaAllocator.init(gpa);
    defer cycle_arena.deinit();

    // The app started by `-- <command>`, if any. Killed and restarted each cycle.
    var app_child: ?std.process.Child = null;

    // Build once up front, then rebuild on every change.
    runCycle(io, &cycle_arena, status, theme, args.command, &app_child);
    while (true) {
        state.waitDirty();
        nap(io, debounce_ms); // let the burst settle
        state.clear(); // coalesce events that arrived during the settle window
        try paint(status, theme, "\n• change detected", .dim);
        try status.writeByte('\n');
        runCycle(io, &cycle_arena, status, theme, args.command, &app_child);
    }
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
    theme: *const Theme,
    command: []const []const u8,
    app_child: *?std.process.Child,
) void {
    _ = cycle_arena.reset(.retain_capacity);
    doCycle(io, cycle_arena.allocator(), status, theme, command, app_child) catch |err| {
        // Never let a transient failure tear down the watcher.
        status.print("dev: {s}\n", .{@errorName(err)}) catch {};
        status.flush() catch {};
    };
}

fn doCycle(
    io: std.Io,
    arena: std.mem.Allocator,
    status: *std.Io.Writer,
    theme: *const Theme,
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
        app_child.* = try startApp(io, arena, status, theme, command);
    }
}

/// Run `zig build` (blocking), reporting success. Returns false on failure.
fn build(io: std.Io, status: *std.Io.Writer, theme: *const Theme) !bool {
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
    theme: *const Theme,
    command: []const []const u8,
) !?std.process.Child {
    const binary = (try findBinary(io, arena)) orelse {
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

/// The first executable in zig-out/bin (a project produces one), or null.
fn findBinary(io: std.Io, arena: std.mem.Allocator) !?[]const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, "zig-out/bin", .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file) {
            return try std.fmt.allocPrint(arena, "zig-out{c}bin{c}{s}", .{ std.fs.path.sep, std.fs.path.sep, entry.name });
        }
    }
    return null;
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

fn paint(out: *std.Io.Writer, theme: *const Theme, text: []const u8, role: Role) !void {
    const t = ztheme.theme(text);
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
