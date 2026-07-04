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
    // We've already printed the full topic list as guidance, so exit non-zero
    // cleanly here rather than returning an error on top of that help.
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
        \\A command file declares `meta`, `Args`, `Options`, and `execute`. `execute`
        \\returns `!void`, so returning an error fails the command with a non-zero
        \\exit. For a failure the user should read, `return context.fail("no note:
        \\{s}", .{name})` — it prints your message and exits cleanly (no `error:
        \\Name`, no stack trace). A plain `return error.X` is for unexpected bugs:
        \\its name and Debug-only trace aid debugging. Change structure with the
        \\scaffolder — it does the multi-site edits (struct field + meta entry + arg
        \\ordering) correctly — not by hand:
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
        .name = "sharing",
        .summary = "reuse a helper module across commands",
        .body =
        \\sharing — reuse code across commands
        \\
        \\When two or more commands need the same helper (a `store.zig`, an API
        \\client, shared types), put it in its own module and register it once. This
        \\is build wiring you edit by hand — unlike command structure, there is no
        \\`zcli add` for it.
        \\
        \\1. Write the helper, e.g. `src/store.zig`.
        \\2. In build.zig, create a module for it and add it to `shared_modules`:
        \\
        \\  const store_module = b.createModule(.{
        \\      .root_source_file = b.path("src/store.zig"),
        \\      .target = target,
        \\      .optimize = optimize,
        \\  });
        \\
        \\  const shared_modules = [_]zcli.SharedModule{
        \\      .{ .name = "store", .module = store_module },
        \\  };
        \\
        \\3. Pass `shared_modules` to BOTH `zcli.generate(...)` and
        \\   `zcli.addCommandTests(...)` — a generated project already wires the one
        \\   list into both. If a module reaches `generate` but not the tests, `zig
        \\   build` is green while `zig build test` fails with "no module named
        \\   'store'". One list, two call sites.
        \\
        \\4. Import it from any command (or its test) by the registered name:
        \\
        \\  const store = @import("store");
        \\
        \\A shared module can itself import zcli packages — e.g.
        \\`store_module.addImport("ztheme", zcli_dep.module("ztheme"));`. For a
        \\complete shared module that persists data, see `zcli guide storage`.
        \\
        ,
    },
    .{
        .name = "storage",
        .summary = "save and load data (JSON files)",
        .body =
        \\storage — save and load data (JSON files)
        \\
        \\Commands persist state by reading and writing files themselves — there is
        \\no zcli storage API, just the standard library. `context.io` is a `std.Io`;
        \\pass it to `std.Io.Dir` to touch the filesystem:
        \\
        \\  const cwd = std.Io.Dir.cwd();
        \\  const bytes = try cwd.readFileAlloc(context.io, "data.json", context.allocator, .limited(1 << 20));
        \\  try cwd.writeFile(context.io, .{ .sub_path = "data.json", .data = bytes });
        \\
        \\For structured data, let `std.json` carry it both ways — a typed struct
        \\decodes from bytes, and any value re-encodes through the `{f}` specifier;
        \\no walking a generic tree, no hand-written string building:
        \\
        \\  const parsed = try std.json.parseFromSlice(MyData, arena, bytes, .{ .allocate = .alloc_always });
        \\  const data = parsed.value;                                     // bytes  -> struct
        \\  const json = std.json.fmt(data, .{ .whitespace = .indent_2 });  // struct -> JSON, print with "{f}"
        \\
        \\Load into `context.allocator` (the arena) and never free — the data lives
        \\until the command ends (see `zcli guide arena`). Paths are relative to the
        \\working directory, so a command reads and writes where the user ran it;
        \\a test that drives such a command touches real files (see `zcli guide
        \\testing`).
        \\
        \\Worked example — examples/notes/src/store.zig, a persistence helper shared
        \\by every command (see `zcli guide sharing`):
        \\
        ++ "\n" ++ examples.notes_store,
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
        \\asserting on rendered color/layout). A command that reads a plugin's state
        \\via `context.plugins.<id>` is testable directly — set that state with
        \\`.plugins` (the project's plugins are already in scope; pass `&.{}`):
        \\
        \\  var r = try zcli_testing.runCommand(@This(), &.{}, .{
        \\      .args = .{ .name = "Ada" },
        \\      .plugins = .{ .verbose = .{ .enabled = true } },
        \\  });
        \\
        \\A command that fails with `context.fail(...)` is assertable too —
        \\`!r.success`, `r.err.? == error.CommandFailed`, and the message in
        \\`r.stderr` — because it returns an error instead of exiting.
        \\
        \\runCommand runs execute() in-process against the real filesystem and the
        \\real cwd — it captures I/O, not the disk. A command that reads or writes
        \\files touches actual files during `zig build test`, so a leftover file can
        \\make the next run behave differently. Delete the file around such a test —
        \\`io` in a test is `std.testing.io`:
        \\
        \\  test "add: persists a task" {
        \\      const io = std.testing.io;
        \\      std.Io.Dir.cwd().deleteFile(io, "tasks.json") catch {};        // start clean
        \\      defer std.Io.Dir.cwd().deleteFile(io, "tasks.json") catch {};  // and don't leak it
        \\      var r = try zcli_testing.runCommand(@This(), &.{}, .{ .args = .{ .title = "Buy milk" } });
        \\      defer r.deinit();
        \\      try std.testing.expect(r.success);
        \\  }
        \\
        \\For I/O you drive directly (say a store module that takes a dir), hand it a
        \\scratch dir instead: `var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();`
        \\— `tmp.dir` is a `std.Io.Dir`.
        \\
        ,
    },
};
