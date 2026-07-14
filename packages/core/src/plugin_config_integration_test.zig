//! Integration tests for the zcli_config plugin: a real config file on disk,
//! driven end-to-end through `preExecute` (discovery + read) and
//! `applyConfigDefaults` (coercion + precedence), via a minimal duck-typed
//! context — the shape the registry passes. Complements the in-file unit tests
//! (which drive the apply functions directly).

const std = @import("std");
const zcli = @import("zcli");
const config = @import("plugins/zcli_config/plugin.zig");
const testing = std.testing;

/// The slice of `context` the config plugin reads. `plugins.zcli_config` is the
/// per-command ContextData the framework threads; the rest are plain accessors.
const FakeContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    app_name: []const u8,
    command_path: []const []const u8,
    stderr_writer: *std.Io.Writer,
    plugins: struct { zcli_config: config.ContextData = .{} },

    pub fn stderr(self: *@This()) *std.Io.Writer {
        return self.stderr_writer;
    }
};

fn makeCtx(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, cmd_path: []const []const u8, stderr: *std.Io.Writer) FakeContext {
    return .{
        .allocator = allocator,
        .io = testing.io,
        .environ = environ,
        .app_name = "myapp",
        .command_path = cmd_path,
        .stderr_writer = stderr,
        .plugins = .{},
    };
}

// Every test runs the plugin under an arena, exactly as the registry does
// (docs/adr/0001) — so array coercion and the parse arena are reclaimed
// wholesale and there's nothing to hand-free.
fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

var discard = std.Io.Writer.Discarding.init(&.{});

test "integration: --config path drives coercion for every type through the real pipeline" {
    var a = arena();
    defer a.deinit();
    const alloc = a.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const content =
        \\{ "flag": true, "name": "hi", "color": "green", "count": 7,
        \\  "ratio": 2.5, "tags": ["a", "b"] }
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "myapp.json", .data = content });
    const abs = try tmp.dir.realPathFileAlloc(io, "myapp.json", alloc);

    var environ = std.process.Environ.Map.init(alloc);

    const cmd_path = [_][]const u8{};
    var ctx = makeCtx(alloc, &environ, &cmd_path, &discard.writer);
    // The --config global option handler stores this before preExecute runs.
    ctx.plugins.zcli_config.custom_path = abs;

    const args = zcli.ParsedArgs.init(alloc);
    _ = try config.preExecute(&ctx, args);
    try testing.expect(ctx.plugins.zcli_config.format.? == .json);

    const Color = enum { red, green, blue };
    const Opts = struct {
        flag: bool = false,
        name: []const u8 = "def",
        color: Color = .red,
        count: u32 = 0,
        ratio: f64 = 0,
        tags: []const []const u8 = &.{},
    };
    var opts = Opts{};
    const provided = [_]bool{false} ** 6;
    config.applyConfigDefaults(&ctx, Opts, &opts, &provided);

    try testing.expect(opts.flag);
    try testing.expectEqualStrings("hi", opts.name);
    try testing.expect(opts.color == .green);
    try testing.expectEqual(@as(u32, 7), opts.count);
    try testing.expectEqual(@as(f64, 2.5), opts.ratio);
    try testing.expectEqual(@as(usize, 2), opts.tags.len);
    try testing.expectEqualStrings("b", opts.tags[1]);

    config.deinitContextData(&ctx.plugins.zcli_config, alloc);
}

test "integration: cwd discovery finds .{app}.config.toml (via chdir into tmp)" {
    var a = arena();
    defer a.deinit();
    const alloc = a.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".myapp.config.toml", .data = "count = 42\n" });

    // preExecute discovers relative to the process cwd; point it at tmp for the
    // duration of this test, then restore. (Serial test file — no other test
    // depends on cwd concurrently.)
    var orig_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer orig_dir.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, orig_dir) catch {};

    var environ = std.process.Environ.Map.init(alloc);
    const cmd_path = [_][]const u8{};
    var ctx = makeCtx(alloc, &environ, &cmd_path, &discard.writer);

    const args = zcli.ParsedArgs.init(alloc);
    _ = try config.preExecute(&ctx, args);
    try testing.expect(ctx.plugins.zcli_config.format != null);
    try testing.expect(ctx.plugins.zcli_config.format.? == .toml);

    const Opts = struct { count: u32 = 0 };
    var opts = Opts{};
    const provided = [_]bool{false};
    config.applyConfigDefaults(&ctx, Opts, &opts, &provided);
    try testing.expectEqual(@as(u32, 42), opts.count);

    config.deinitContextData(&ctx.plugins.zcli_config, alloc);
}

test "integration: required option satisfied by config (through parseCommandLine + apply)" {
    var a = arena();
    defer a.deinit();
    const alloc = a.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "myapp.yaml", .data = "token: secret123\n" });
    const abs = try tmp.dir.realPathFileAlloc(io, "myapp.yaml", alloc);

    var environ = std.process.Environ.Map.init(alloc);
    const cmd_path = [_][]const u8{};
    var ctx = makeCtx(alloc, &environ, &cmd_path, &discard.writer);
    ctx.plugins.zcli_config.custom_path = abs;

    const args = zcli.ParsedArgs.init(alloc);
    _ = try config.preExecute(&ctx, args);

    // `token` is a required option (no default, non-optional). Nothing on the
    // CLI supplies it — parse yields the placeholder + provided[i] == false.
    const Opts = struct { token: []const u8 };
    const result = try zcli.parseCommandLine(struct {}, Opts, null, alloc, &environ, &.{}, null);
    defer result.deinit();
    try testing.expect(!result.options_provided[0]); // no source yet

    var opts = result.options;
    const before = opts;
    config.applyConfigDefaults(&ctx, Opts, &opts, &result.options_provided);

    // Config filled it — the value differs from the pre-config snapshot, which
    // is exactly what the registry's required-option check treats as "supplied".
    try testing.expectEqualStrings("secret123", opts.token);
    try testing.expect(!std.mem.eql(u8, before.token, opts.token));

    config.deinitContextData(&ctx.plugins.zcli_config, alloc);
}

test "integration: CLI-provided value beats config (equal-to-default regression)" {
    var a = arena();
    defer a.deinit();
    const alloc = a.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "myapp.json", .data = "{\"count\": 10}" });
    const abs = try tmp.dir.realPathFileAlloc(io, "myapp.json", alloc);

    var environ = std.process.Environ.Map.init(alloc);
    const cmd_path = [_][]const u8{};
    var ctx = makeCtx(alloc, &environ, &cmd_path, &discard.writer);
    ctx.plugins.zcli_config.custom_path = abs;
    const args = zcli.ParsedArgs.init(alloc);
    _ = try config.preExecute(&ctx, args);

    // User typed --count 5, which equals the struct default. The provided bitset
    // (not a value comparison) records that the CLI set it.
    const Opts = struct { count: u32 = 5 };
    const result = try zcli.parseCommandLine(struct {}, Opts, null, alloc, &environ, &.{ "--count", "5" }, null);
    defer result.deinit();
    try testing.expect(result.options_provided[0]);

    var opts = result.options;
    config.applyConfigDefaults(&ctx, Opts, &opts, &result.options_provided);
    try testing.expectEqual(@as(u32, 5), opts.count); // config's 10 did NOT win

    config.deinitContextData(&ctx.plugins.zcli_config, alloc);
}

test "integration: env-provided value beats config" {
    var a = arena();
    defer a.deinit();
    const alloc = a.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "myapp.json", .data = "{\"count\": 10}" });
    const abs = try tmp.dir.realPathFileAlloc(io, "myapp.json", alloc);

    var environ = std.process.Environ.Map.init(alloc);
    try environ.put("MYAPP_COUNT", "99");

    const cmd_path = [_][]const u8{};
    var ctx = makeCtx(alloc, &environ, &cmd_path, &discard.writer);
    ctx.plugins.zcli_config.custom_path = abs;
    const args = zcli.ParsedArgs.init(alloc);
    _ = try config.preExecute(&ctx, args);

    // The env fallback sets count=99 and marks it provided; config's 10 must lose.
    const Opts = struct { count: u32 = 0 };
    const meta = .{ .options = .{ .count = .{ .env = "MYAPP_COUNT" } } };
    const result = try zcli.parseCommandLine(struct {}, Opts, meta, alloc, &environ, &.{}, null);
    defer result.deinit();
    try testing.expect(result.options_provided[0]); // env supplied it

    var opts = result.options;
    config.applyConfigDefaults(&ctx, Opts, &opts, &result.options_provided);
    try testing.expectEqual(@as(u32, 99), opts.count); // env wins over config

    config.deinitContextData(&ctx.plugins.zcli_config, alloc);
}

// --- Project-local config notice (security-audit finding: silent CWD load) ---
//
// Discovering `.{app}.config.{ext}` from the process cwd means an attacker-
// controlled directory (e.g. a cloned repo) can silently supply defaults.
// preExecute must print a one-line stderr notice naming the file whenever a
// project-local config is actually loaded — but stay silent for an explicit
// --config path and for the user-level (home/XDG) config, since those aren't
// cwd-controlled by whatever directory the CLI happens to run in.

test "integration: notice printed when a project-local (cwd) config is applied" {
    var a = arena();
    defer a.deinit();
    const alloc = a.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".myapp.config.toml", .data = "count = 42\n" });

    var orig_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer orig_dir.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, orig_dir) catch {};

    var aw = std.Io.Writer.Allocating.init(alloc);
    var environ = std.process.Environ.Map.init(alloc);
    const cmd_path = [_][]const u8{};
    var ctx = makeCtx(alloc, &environ, &cmd_path, &aw.writer);

    const args = zcli.ParsedArgs.init(alloc);
    _ = try config.preExecute(&ctx, args);

    const written = aw.written();
    try testing.expect(std.mem.indexOf(u8, written, "note:") != null);
    try testing.expect(std.mem.indexOf(u8, written, "./.myapp.config.toml") != null);

    config.deinitContextData(&ctx.plugins.zcli_config, alloc);
}

test "integration: no notice when no cwd config exists" {
    var a = arena();
    defer a.deinit();
    const alloc = a.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var orig_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer orig_dir.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, orig_dir) catch {};

    var aw = std.Io.Writer.Allocating.init(alloc);
    var environ = std.process.Environ.Map.init(alloc);
    const cmd_path = [_][]const u8{};
    var ctx = makeCtx(alloc, &environ, &cmd_path, &aw.writer);

    const args = zcli.ParsedArgs.init(alloc);
    _ = try config.preExecute(&ctx, args);

    try testing.expect(std.mem.indexOf(u8, aw.written(), "note:") == null);

    config.deinitContextData(&ctx.plugins.zcli_config, alloc);
}

test "integration: no notice for an explicit --config path" {
    var a = arena();
    defer a.deinit();
    const alloc = a.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "myapp.json", .data = "{\"count\": 10}" });
    const abs = try tmp.dir.realPathFileAlloc(io, "myapp.json", alloc);

    var aw = std.Io.Writer.Allocating.init(alloc);
    var environ = std.process.Environ.Map.init(alloc);
    const cmd_path = [_][]const u8{};
    var ctx = makeCtx(alloc, &environ, &cmd_path, &aw.writer);
    ctx.plugins.zcli_config.custom_path = abs;

    const args = zcli.ParsedArgs.init(alloc);
    _ = try config.preExecute(&ctx, args);

    try testing.expect(std.mem.indexOf(u8, aw.written(), "note:") == null);

    config.deinitContextData(&ctx.plugins.zcli_config, alloc);
}

test "integration: no notice for a user-level (XDG) config" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // XDG_CONFIG_HOME is POSIX-only
    var a = arena();
    defer a.deinit();
    const alloc = a.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // No cwd config here — force discovery down to the user-level path.
    try tmp.dir.createDir(io, "myapp", .default_dir);
    var app_dir = try tmp.dir.openDir(io, "myapp", .{});
    defer app_dir.close(io);
    try app_dir.writeFile(io, .{ .sub_path = "config.json", .data = "{\"count\": 10}" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const xdg_base_len = try tmp.dir.realPath(io, &path_buf);
    const xdg_base = try alloc.dupe(u8, path_buf[0..xdg_base_len]);

    var orig_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer orig_dir.close(io);
    // Run from a directory with no `.myapp.config.*` of its own, so discovery
    // must fall through to the user-level (XDG) branch.
    var empty_tmp = testing.tmpDir(.{});
    defer empty_tmp.cleanup();
    try std.process.setCurrentDir(io, empty_tmp.dir);
    defer std.process.setCurrentDir(io, orig_dir) catch {};

    var aw = std.Io.Writer.Allocating.init(alloc);
    var environ = std.process.Environ.Map.init(alloc);
    try environ.put("XDG_CONFIG_HOME", xdg_base);
    const cmd_path = [_][]const u8{};
    var ctx = makeCtx(alloc, &environ, &cmd_path, &aw.writer);

    const args = zcli.ParsedArgs.init(alloc);
    _ = try config.preExecute(&ctx, args);
    try testing.expect(ctx.plugins.zcli_config.format != null); // sanity: config was found

    try testing.expect(std.mem.indexOf(u8, aw.written(), "note:") == null);

    config.deinitContextData(&ctx.plugins.zcli_config, alloc);
}

test "integration: multiple config files warn about ambiguity" {
    var a = arena();
    defer a.deinit();
    const alloc = a.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".myapp.config.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".myapp.config.toml", .data = "" });

    var orig_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer orig_dir.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, orig_dir) catch {};

    var aw = std.Io.Writer.Allocating.init(alloc);
    var environ = std.process.Environ.Map.init(alloc);
    const cmd_path = [_][]const u8{};
    var ctx = makeCtx(alloc, &environ, &cmd_path, &aw.writer);

    const args = zcli.ParsedArgs.init(alloc);
    _ = try config.preExecute(&ctx, args);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "multiple config files") != null);

    config.deinitContextData(&ctx.plugins.zcli_config, alloc);
}
