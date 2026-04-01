# Ideas for zcli

## High-Impact

### 1. Interactive prompts / input collection

The biggest gap for a "batteries-included" CLI framework. Output is well covered (zprogress, ztheme, markdown_fmt, zcli-output), but there's no input story beyond args/options. Features to consider:

- Text prompts with defaults
- Confirmation (y/n)
- Selection lists (single + multi)
- Password/masked input

Frameworks like Cobra+Survey (Go), Clap+Dialoguer (Rust), and Inquirer (Node) all pair a parser with an interactive prompt library. This would make zcli viable for `init`-style wizards and interactive workflows — which are exactly the kind of commands people build with CLI frameworks.

The terminal capabilities already exist via ztheme. A `zinput` or `zprompt` package that builds on top of it would be a natural addition.

### 2. Shell completion that "just works"

zcli-completions generates bash/zsh/fish scripts, but fish is incomplete (TODO at `fish.zig:219`). More importantly, the current approach requires users to run `completions install`. The modern expectation (especially from Rust CLI tools) is that completions are generated at build time and can be dropped into package managers. Consider:

- Finish fish support
- Add a build-time step that emits completion files to `zig-out/share/` so package maintainers can include them
- Dynamic completions (completing values, not just flags) — this is where frameworks really differentiate

### 3. Config file loading

The pattern of "CLI flags override config file values override env vars override defaults" is so universal that having it built in would save every zcli user from implementing it themselves.

A `zcli-config` plugin that:
- Loads from `~/.config/appname/config.toml` (or `.appnamerc`)
- Merges with env vars and CLI options (with clear precedence)
- Exposes values through context

...would be a strong differentiator. Most Zig CLI libraries don't touch this.

### 4. Testing utilities for command authors

There are good internal tests, but there's no story for users testing *their own* commands. A testing harness like:

```zig
const result = try zcli.testing.run(MyCommand, .{
    .args = &.{"arg1"},
    .options = .{ .verbose = true },
});
try std.testing.expectEqualStrings("expected output\n", result.stdout);
try std.testing.expectEqual(@as(u8, 0), result.exit_code);
```

This would make zcli significantly more attractive for production CLI tools where people actually write tests.

### 5. Man page / markdown doc generation

All the metadata already exists at build time (descriptions, args, options, examples). Generating man pages, markdown reference docs, or even a static site from that metadata is low-hanging fruit and very appealing for open-source CLI tools. A build step that emits `zig-out/share/man/man1/appname.1` would be valuable.

### 6. Environment variable binding for options

The pattern of `--database-url` automatically checking `DATABASE_URL` is table stakes for 12-factor apps. There is already some env var support in the option parser — making this a first-class, documented feature with clear precedence rules would be worthwhile.

---

## Speculative

- **Middleware/interceptor pattern**: Beyond pre/post execute hooks, letting users compose middleware (auth checks, rate limiting, telemetry) in a stack would appeal to teams building internal CLIs.
- **Subcommand aliasing**: `git co` → `git checkout`. There is some alias support in the registry already — making this user-configurable (via config file) would be nice.
- **`zcli doctor`**: A diagnostic command that checks the user's environment, validates dependencies, and reports issues. Useful for complex CLIs.

---

## Non-goals

- **Dynamic/runtime command registration** — the comptime approach is zcli's identity. Leaning into it is the right call.
- **GUI/TUI frameworks** — stay in the lane. The terminal output libraries (ztheme, zprogress) are the right level of abstraction.
- **Cross-language bindings** — keep it Zig-native. That's the audience.

---

## Strategic positioning

The Zig CLI space is still early. The main competitors are `zig-clap` (focused purely on arg parsing) and raw `std.process`. zcli's advantage is being a *framework* — build system integration, plugins, code generation, the whole stack. Leaning into the "Rails for CLIs" positioning (convention over configuration, batteries included, great defaults) is the way to go. The interactive prompts + config file + testing utilities trifecta would cement that.
