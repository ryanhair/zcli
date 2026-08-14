//! Integration tests for the zcli_config plugin: a real config file on disk,
//! driven end-to-end through `preExecute` (discovery + read) and
//! `applyConfigDefaults` (coercion + precedence), via a minimal duck-typed
//! context — the shape the registry passes. Complements the in-file unit tests
//! (which drive the apply functions directly).

const std = @import("std");
const zcli = @import("zcli");
const config = @import("plugins/zcli_config/plugin.zig");
const testing = std.testing;

// NOTE on module boundaries: this file may NOT relatively import framework
// internals (`command_parser.zig`, …). It imports the config plugin's source,
// which imports the "zcli" MODULE, so this test target is built with that module
// — and `zcli.zig` already contains `command_parser.zig`. Reaching it relatively
// as well puts one file in two modules, which Zig rejects outright:
// "file exists in modules 'root' and 'zcli'".
//
// That is why the `no_config` split below is what it is: source precedence,
// locked-field restoration, and resolved-value checks are tested through the
// deep interfaces in command_validation.zig. They need fake adapters, not the
// real plugin — and so no "zcli" module. What belongs HERE is the other half:
// the real plugin, reading a real file, honoring the masked bitset the registry
// hands it.

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

    pub fn fail(self: *@This(), comptime fmt: []const u8, args: anytype) error{CommandFailed} {
        self.stderr_writer.print(fmt ++ "\n", args) catch {};
        return error.CommandFailed;
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
    var applied = [_]bool{false} ** @typeInfo(Opts).@"struct".fields.len;
    config.applyConfigDefaults(&ctx, Opts, &opts, &provided, &applied);

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
    var applied = [_]bool{false} ** @typeInfo(Opts).@"struct".fields.len;
    config.applyConfigDefaults(&ctx, Opts, &opts, &provided, &applied);
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
    var applied = [_]bool{false} ** @typeInfo(Opts).@"struct".fields.len;
    config.applyConfigDefaults(&ctx, Opts, &opts, &result.options_provided, &applied);

    // Config filled it and reported so in `applied` — exactly what the
    // registry's required-option check treats as "supplied".
    try testing.expectEqualStrings("secret123", opts.token);
    try testing.expect(applied[0]);

    config.deinitContextData(&ctx.plugins.zcli_config, alloc);
}

test "integration: YAML quoted command keys decode through the config pipeline" {
    var a = arena();
    defer a.deinit();
    const alloc = a.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "myapp.yaml",
        // serde.zig <= 1.0.3 treated a quoted scalar in a nested mapping as a
        // value instead of recognizing the following ':' as a mapping key.
        .data = "list:\n  \"output\": table\n  'all': true\n",
    });
    const abs = try tmp.dir.realPathFileAlloc(io, "myapp.yaml", alloc);

    var environ = std.process.Environ.Map.init(alloc);
    const cmd_path = [_][]const u8{"list"};
    var ctx = makeCtx(alloc, &environ, &cmd_path, &discard.writer);
    ctx.plugins.zcli_config.custom_path = abs;

    const args = zcli.ParsedArgs.init(alloc);
    _ = try config.preExecute(&ctx, args);

    const Opts = struct {
        output: []const u8 = "text",
        all: bool = false,
    };
    var opts = Opts{};
    const provided = [_]bool{false} ** @typeInfo(Opts).@"struct".fields.len;
    var applied = [_]bool{false} ** @typeInfo(Opts).@"struct".fields.len;
    config.applyConfigDefaults(&ctx, Opts, &opts, &provided, &applied);

    try testing.expectEqualStrings("table", opts.output);
    try testing.expect(opts.all);
    try testing.expectEqualSlices(bool, &.{ true, true }, &applied);

    config.deinitContextData(&ctx.plugins.zcli_config, alloc);
}

test "integration: a no_config field is not set from a config file that supplies it (ADR-0032)" {
    var a = arena();
    defer a.deinit();
    const alloc = a.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // The threat this marker exists for: a config file that arrived with a
    // cloned repo tries to turn off signature verification, and to prove the
    // lock is per-field rather than per-file, sets an ordinary option too.
    try tmp.dir.writeFile(io, .{
        .sub_path = "myapp.toml",
        .data = "skip_verification = true\nregistry = \"https://evil.example\"\ncount = 9\n",
    });
    const abs = try tmp.dir.realPathFileAlloc(io, "myapp.toml", alloc);

    var environ = std.process.Environ.Map.init(alloc);
    const cmd_path = [_][]const u8{};
    var ctx = makeCtx(alloc, &environ, &cmd_path, &discard.writer);
    ctx.plugins.zcli_config.custom_path = abs;
    const args = zcli.ParsedArgs.init(alloc);
    _ = try config.preExecute(&ctx, args);

    const Opts = struct {
        skip_verification: bool = false,
        registry: []const u8 = "https://trusted.example",
        count: u32 = 1,
    };
    const meta = .{ .options = .{
        .skip_verification = .{ .no_config = true },
        .registry = .{ .no_config = true },
    } };

    const result = try zcli.parseCommandLine(struct {}, Opts, meta, alloc, &environ, &.{}, null);
    defer result.deinit();

    var opts = result.options;
    var applied = [_]bool{false} ** @typeInfo(Opts).@"struct".fields.len;

    // The bitset the registry hands the hook: nothing was supplied by CLI/env,
    // but the two marked fields read as provided. This is precisely what
    // the resolved-input policy hands adapters — asserted through
    // `command_validation.applyConfigAdapters` in that module's own tests (see
    // the module note at the top of this file for why it cannot be called here).
    // What this test pins is the half that is genuinely the plugin's: given that
    // bitset, and a file that names all three keys, the real plugin must not
    // write the marked fields.
    for (result.options_provided) |p| try testing.expect(!p);
    const hook_provided = [_]bool{ true, true, false };

    config.applyConfigDefaults(&ctx, Opts, &opts, &hook_provided, &applied);

    // Both marked fields keep their struct defaults even though the file names
    // them, and neither counts as supplied — so a marked *required* option would
    // correctly report "missing" rather than silently take the file's value
    // (pinned through command_validation.validateResolved).
    try testing.expectEqual(false, opts.skip_verification);
    try testing.expectEqualStrings("https://trusted.example", opts.registry);
    try testing.expect(!applied[0]);
    try testing.expect(!applied[1]);

    // The lock is per-field: the unmarked option still loads normally, so this
    // is a targeted policy rather than "ignore the config file".
    try testing.expectEqual(@as(u32, 9), opts.count);
    try testing.expect(applied[2]);

    config.deinitContextData(&ctx.plugins.zcli_config, alloc);
}

test "integration: no_config does not block the CLI or env from setting the field" {
    var a = arena();
    defer a.deinit();
    const alloc = a.allocator();

    var environ = std.process.Environ.Map.init(alloc);
    try environ.put("MYAPP_REGISTRY", "https://from-env.example");

    const Opts = struct {
        skip_verification: bool = false,
        registry: []const u8 = "https://trusted.example",
    };
    const meta = .{ .options = .{
        .skip_verification = .{ .no_config = true },
        .registry = .{ .no_config = true, .env = "MYAPP_REGISTRY" },
    } };

    // No config plugin in play at all — the marker governs file-sourced values
    // only, and must leave the two sources the user genuinely controls alone.
    const result = try zcli.parseCommandLine(struct {}, Opts, meta, alloc, &environ, &.{"--skip-verification"}, null);
    defer result.deinit();

    const opts = result.options;

    // Both marked, both still set — from the CLI and from env respectively — and
    // both flagged provided, which is what makes them satisfy a required option
    // and what makes config skip them.
    try testing.expectEqual(true, opts.skip_verification);
    try testing.expectEqualStrings("https://from-env.example", opts.registry);
    try testing.expect(result.options_provided[0]);
    try testing.expect(result.options_provided[1]);
}

test "integration: a no_config REQUIRED option is left unset by the real plugin" {
    var a = arena();
    defer a.deinit();
    const alloc = a.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // The subtlest interaction in the feature: config supplies the required
    // option, and must NOT count. Two required options so the "unmarked one is
    // still satisfied" half is proven by the same run. That the registry then
    // REPORTS it missing is pinned through validateResolved in
    // command_validation.zig; what this proves is that the plugin leaves it unset
    // and, crucially, does not mark it applied.
    try tmp.dir.writeFile(io, .{
        .sub_path = "myapp.yaml",
        .data = "signing_key: attacker-key\nproject: acme\n",
    });
    const abs = try tmp.dir.realPathFileAlloc(io, "myapp.yaml", alloc);

    var environ = std.process.Environ.Map.init(alloc);
    const cmd_path = [_][]const u8{};
    var ctx = makeCtx(alloc, &environ, &cmd_path, &discard.writer);
    ctx.plugins.zcli_config.custom_path = abs;
    const args = zcli.ParsedArgs.init(alloc);
    _ = try config.preExecute(&ctx, args);

    // Both required (no default, non-optional, non-bool, non-array).
    const Opts = struct {
        signing_key: []const u8,
        project: []const u8,
    };
    const meta = .{ .options = .{ .signing_key = .{ .no_config = true } } };

    const result = try zcli.parseCommandLine(struct {}, Opts, meta, alloc, &environ, &.{}, null);
    defer result.deinit();

    var opts = result.options;
    var applied = [_]bool{false} ** @typeInfo(Opts).@"struct".fields.len;

    const hook_provided = [_]bool{ true, false }; // signing_key masked by the registry
    config.applyConfigDefaults(&ctx, Opts, &opts, &hook_provided, &applied);

    // The unmarked required option is satisfied by the file, as always.
    try testing.expectEqualStrings("acme", opts.project);
    try testing.expect(applied[1]);

    // The marked one is not, and is not marked applied — which is exactly the
    // input that makes the registry's required-option check report it missing
    // rather than silently running with a value a directory chose.
    try testing.expect(!applied[0]);

    config.deinitContextData(&ctx.plugins.zcli_config, alloc);
}

test "integration: a no_config multi-value option is not filled from a config list" {
    var a = arena();
    defer a.deinit();
    const alloc = a.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "myapp.json",
        .data = "{\"trusted_hosts\": [\"evil.example\", \"evil2.example\"], \"tags\": [\"a\", \"b\"]}",
    });
    const abs = try tmp.dir.realPathFileAlloc(io, "myapp.json", alloc);

    var environ = std.process.Environ.Map.init(alloc);
    const cmd_path = [_][]const u8{};
    var ctx = makeCtx(alloc, &environ, &cmd_path, &discard.writer);
    ctx.plugins.zcli_config.custom_path = abs;
    const args = zcli.ParsedArgs.init(alloc);
    _ = try config.preExecute(&ctx, args);

    // Arrays are the case where a config write ALLOCATES, so they are where the
    // marker has to hold at the coercion path rather than at a scalar store.
    const Opts = struct {
        trusted_hosts: []const []const u8 = &.{},
        tags: []const []const u8 = &.{},
    };
    const meta = .{ .options = .{ .trusted_hosts = .{ .no_config = true } } };

    // Routed through the real parser so the marker itself is exercised: an
    // unknown key in `meta.options.<field>` is a @compileError, so this failing
    // to build is how a renamed or dropped marker would surface here.
    const result = try zcli.parseCommandLine(struct {}, Opts, meta, alloc, &environ, &.{}, null);
    defer result.deinit();

    var opts = result.options;
    var applied = [_]bool{false} ** @typeInfo(Opts).@"struct".fields.len;
    const hook_provided = [_]bool{ true, false }; // trusted_hosts masked by the registry

    config.applyConfigDefaults(&ctx, Opts, &opts, &hook_provided, &applied);

    // Marked: still the empty default. Because the mask made the plugin skip the
    // field, the element buffer is never allocated in the first place — there is
    // nothing for the registry's restore to undo, which is the cheap path by
    // construction and the reason a locked array cannot leak.
    try testing.expectEqual(@as(usize, 0), opts.trusted_hosts.len);
    try testing.expect(!applied[0]);

    // Unmarked: the list loads normally, so the lock is per-field here too.
    try testing.expectEqual(@as(usize, 2), opts.tags.len);
    try testing.expectEqualStrings("a", opts.tags[0]);
    try testing.expect(applied[1]);

    config.deinitContextData(&ctx.plugins.zcli_config, alloc);
}

test "integration: required option satisfied by a placeholder-equal config value (#388)" {
    var a = arena();
    defer a.deinit();
    const alloc = a.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // 0 for the u32 and the FIRST enum variant — both equal the required-option
    // placeholder, the exact values the old value-diff check misread as missing.
    try tmp.dir.writeFile(io, .{ .sub_path = "myapp.json", .data = "{\"offset\": 0, \"format\": \"json\"}" });
    const abs = try tmp.dir.realPathFileAlloc(io, "myapp.json", alloc);

    var environ = std.process.Environ.Map.init(alloc);
    const cmd_path = [_][]const u8{};
    var ctx = makeCtx(alloc, &environ, &cmd_path, &discard.writer);
    ctx.plugins.zcli_config.custom_path = abs;
    const args = zcli.ParsedArgs.init(alloc);
    _ = try config.preExecute(&ctx, args);

    const Opts = struct { offset: u32, format: enum { json, yaml } };
    const result = try zcli.parseCommandLine(struct {}, Opts, null, alloc, &environ, &.{}, null);
    defer result.deinit();

    var opts = result.options;
    var applied = [_]bool{false} ** @typeInfo(Opts).@"struct".fields.len;
    config.applyConfigDefaults(&ctx, Opts, &opts, &result.options_provided, &applied);

    try testing.expectEqual(@as(u32, 0), opts.offset);
    try testing.expect(opts.format == .json);
    // The registry's required-option check reads exactly these flags
    // (validateResolved consumes these exact bitsets — unit-tested in
    // command_validation.zig), so both fields count as supplied.
    try testing.expect(applied[0]);
    try testing.expect(applied[1]);

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
    var applied = [_]bool{false} ** @typeInfo(Opts).@"struct".fields.len;
    config.applyConfigDefaults(&ctx, Opts, &opts, &result.options_provided, &applied);
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
    var applied = [_]bool{false} ** @typeInfo(Opts).@"struct".fields.len;
    config.applyConfigDefaults(&ctx, Opts, &opts, &result.options_provided, &applied);
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
