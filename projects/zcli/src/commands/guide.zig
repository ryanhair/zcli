const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;

// Canonical example sources, embedded at build time (see guide_examples.zig).
const examples = @import("guide_examples");

pub const meta = .{
    .description = "Version-matched reference and worked examples for building with zcli",
    .examples = &.{
        "guide",
        "guide http",
        "guide arena",
    },
    .args = .{
        .topic = "The topic to show (omit to list all topics)",
    },
};

pub const Args = struct {
    topic: ?[]const u8 = null,
};

pub const Options = struct {};

pub fn execute(args: Args, _: Options, context: *Context) !void {
    const stdout = context.stdout();

    const requested = args.topic orelse {
        try printOverview(stdout);
        return;
    };

    for (topics) |t| {
        if (std.mem.eql(u8, t.name, requested)) {
            try stdout.writeAll(t.body);
            return;
        }
    }

    const stderr = context.stderr();
    try stderr.print("Unknown guide topic: '{s}'\n\n", .{requested});
    try printTopicList(stderr);
    // A mistyped topic is a plain user error — exit non-zero without dumping a
    // Zig stack trace (which returning the error would).
    context.exit(1);
}

fn printOverview(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\zcli guide — a version-matched reference for building CLIs with zcli.
        \\Everything here matches the exact zcli you're compiling against.
        \\
        \\The loop:
        \\  read    what exists   → zcli tree --show-options
        \\  change  structure     → zcli add / rm / mv   (never edit structure by hand)
        \\  write   logic          → freeform code in each command's execute() body
        \\  verify  it works       → zig build && zig build test
        \\
        \\
    );
    try printTopicList(w);
}

fn printTopicList(w: *std.Io.Writer) !void {
    try w.writeAll("Topics (zcli guide <topic>):\n");
    for (topics) |t| {
        try w.print("  {s: <10}{s}\n", .{ t.name, t.summary });
    }
}

const Topic = struct {
    name: []const u8,
    summary: []const u8,
    body: []const u8,
};

const topics = [_]Topic{
    .{
        .name = "structure",
        .summary = "files, commands, groups, plugins",
        .body =
        \\structure — a zcli project is its files
        \\
        \\File path = command path:
        \\  src/commands/deploy.zig        → app deploy
        \\  src/commands/users/create.zig  → app users create
        \\  src/commands/users/index.zig   → the "users" group landing (empty Args)
        \\  src/plugins/<name>.zig         → an auto-discovered plugin
        \\
        \\A command file declares `meta`, `Args`, `Options`, and `execute`. Change
        \\structure with the scaffolder — it does the multi-site edits (struct field +
        \\meta entry + arg ordering) correctly — not by hand:
        \\
        \\  zcli add command <path>        zcli rm command <path>       zcli mv <from> <to>
        \\  zcli add arg <cmd> <name>      zcli add option <cmd> <name>
        \\  zcli rm arg <cmd> <name...>    zcli rm option <cmd> <name...>
        \\  zcli add group <path>          zcli add plugin <name>
        \\
        \\Read the current shape any time with `zcli tree --show-options`.
        \\
        ,
    },
    .{
        .name = "arena",
        .summary = "the per-command allocator (never free)",
        .body =
        \\arena — the per-command allocator
        \\
        \\`context.allocator` is an arena scoped to this one command run. Allocate
        \\freely and NEVER free/deinit memory you take from it — the whole arena is
        \\reclaimed when execute() returns (ADR-0001). This removes the most common
        \\class of CLI memory bug.
        \\
        \\  pub fn execute(args: Args, options: Options, context: *Context) !void {
        \\      const arena = context.allocator;
        \\      const line = try std.fmt.allocPrint(arena, "hi {s}", .{args.name});
        \\      try context.stdout().writeAll(line); // no free — arena owns it
        \\  }
        \\
        \\Non-memory resources are different: still `defer x.deinit()` files, sockets,
        \\and the http.Client — those hold OS handles, not just arena bytes.
        \\
        ,
    },
    .{
        .name = "output",
        .summary = "printing and color",
        .body =
        \\output — print through the context
        \\
        \\Never use std.debug.print or a raw stdout handle. Use:
        \\  context.stdout() *std.Io.Writer   program output (results)
        \\  context.stderr() *std.Io.Writer   errors, progress, notes
        \\Both are buffered and flushed for you when the command returns.
        \\
        \\  try context.stdout().print("created {s}\n", .{name});
        \\
        \\Color/styles via ztheme — it auto-disables on non-TTY and honors NO_COLOR,
        \\so output stays clean when piped or captured:
        \\  const ztheme = zcli.ztheme;
        \\  const theme = &context.theme;
        \\  try ztheme.theme("done").success().render(context.stdout(), theme);
        \\  try ztheme.theme(title).bold().render(context.stdout(), theme);
        \\
        ,
    },
    .{
        .name = "prompts",
        .summary = "interactive input",
        .body =
        \\prompts — interactive input with zinput (bundled)
        \\
        \\Each prompt takes the stdout writer and stdin reader; `text` also takes an
        \\allocator. On non-interactive stdin, handle the piped case yourself (e.g.
        \\fall back to a flag) rather than blocking.
        \\
        \\  const zinput = zcli.zinput;
        \\  const w = context.stdout();
        \\  const r = context.stdin();
        \\
        \\  const name = try zinput.text(w, r, context.allocator, .{ .message = "Name:" });
        \\  const ok   = try zinput.confirm(w, r, .{ .message = "Proceed?", .default = true });
        \\  const idx  = try zinput.select(w, r, .{ .message = "Pick:", .choices = &.{ "a", "b" } });
        \\  const pw   = try zinput.password(w, r, context.allocator, .{ .message = "Token:" }); // hidden
        \\
        \\Progress bars/spinners: `zcli.zprogress`.
        \\
        ,
    },
    .{
        .name = "http",
        .summary = "HTTP requests with safe defaults",
        .body =
        \\http — zcli.http.Client
        \\
        \\Wraps std.http.Client with safe defaults: TLS verification on, a request
        \\timeout, and a bounded response body. Credential headers (Authorization,
        \\Cookie) are stripped if a redirect leaves the original origin.
        \\
        \\  var client = zcli.http.Client.init(context.allocator, context.io, .{});
        \\  defer client.deinit();
        \\
        \\  var res = try client.get("https://api.example.com/thing");
        \\  // or: client.request(.GET, url, .{ .headers = &.{ ... }, .body = ... })
        \\  // or: client.postJson(url, value)
        \\  defer res.deinit();
        \\
        \\  if (res.status != .ok) return error.RequestFailed;
        \\  const parsed = try res.json(MyStruct, context.allocator); // unknown fields ignored
        \\  const value = parsed.value;
        \\
        \\Worked example — examples/repostat/src/commands/repo.zig:
        \\
        ++ "\n" ++ examples.repostat_repo,
    },
    .{
        .name = "secrets",
        .summary = "storing credentials (opt-in)",
        .body =
        \\secrets — zcli_secrets (opt-in)
        \\
        \\Enable it in build.zig with `zcli.builtin(.secrets, .{})` (this links the OS
        \\keychain backend — Keychain / Secret Service / Credential Manager). Then
        \\store, read, and delete an opaque credential — never a plaintext file — via
        \\the context, no import:
        \\
        \\  try context.plugins.zcli_secrets.set(context, "token", token);
        \\  if (try context.plugins.zcli_secrets.get(context, "token")) |token| {
        \\      // token is arena-owned — no free
        \\  }
        \\  try context.plugins.zcli_secrets.delete(context, "token"); // no-op if absent
        \\
        \\The plugin only stores/reads the credential. The auth FLOW that produces it
        \\(reading an env var, an OAuth device-code exchange, ...) is your own command
        \\code (ADR-0003).
        \\
        \\Worked example — examples/ghauth/src/commands/login.zig:
        \\
        ++ "\n" ++ examples.ghauth_login ++
            \\
            \\Worked example — examples/ghauth/src/commands/whoami.zig:
            \\
        ++ "\n" ++ examples.ghauth_whoami,
    },
    .{
        .name = "plugins",
        .summary = "cross-cutting hooks",
        .body =
        \\plugins — cross-cutting hooks
        \\
        \\A plugin (src/plugins/<name>.zig, auto-discovered) observes or shapes the
        \\whole execution pipeline. Declare only the hooks you need — each is
        \\@hasDecl-gated, so a plugin can be as small as one function:
        \\
        \\  preParse         rewrite raw argv
        \\  transformArgs    rewrite args after global options are parsed
        \\  postParse        inspect/replace parsed positionals
        \\  preExecute       run before a command (return null to halt)
        \\  postExecute      run after (gets success: bool)
        \\  onError          handle an error (return true if handled)
        \\  global_options + handleGlobalOption    add a --flag and react to it
        \\
        \\Scaffold one with `zcli add plugin <name>` — the generated stub wires one
        \\working hook and comments the full catalog with exact signatures.
        \\
        ,
    },
    .{
        .name = "testing",
        .summary = "unit-testing a command",
        .body =
        \\testing — run a command in-process
        \\
        \\`zcli add command` scaffolds a co-located placeholder test, and `zig build
        \\test` discovers and runs the test block in every command file. Exercise a
        \\command with zcli-testing's runCommand — no subprocess, captured I/O:
        \\
        \\  test "greet: says hello" {
        \\      const zcli_testing = @import("zcli-testing");
        \\      var r = try zcli_testing.runCommand(@This(), &.{}, .{ .args = .{ .name = "Ada" } });
        \\      defer r.deinit();
        \\      try std.testing.expect(r.success);
        \\      try std.testing.expectEqualStrings("Hello, Ada!\n", r.stdout);
        \\  }
        \\
        \\`r` also exposes `.stderr`, `.err`, and `.term` (a virtual terminal for
        \\asserting on rendered color/layout). Pass plugin types as the second arg to
        \\populate context.plugins.
        \\
        ,
    },
};
