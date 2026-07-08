# theme

A CLI design system for Zig. Define a `Theme` once — a palette mapping
semantic roles to styles, plus component tokens — and every render path
(help output, prompts, progress, your own commands) follows it, degrading
gracefully from true color down to plain text.

## Features

- **Semantic roles**: style by meaning — `.success()`, `.command()`, `.err()` —
  and let the active palette decide what that looks like
- **One theme, applied everywhere**: a zcli app declares `pub const zcli_theme`
  in its root file; help, prompts, and progress pick it up automatically
- **Component tokens**: prompt cursor, selection highlight, spinner color —
  all reference palette roles by default, all individually overridable
- **Terminal capability detection**: NO_COLOR, COLORTERM, TERM, and platform
  signals; colors degrade true color → 256 → 16 → plain automatically
- **Fluent API**: `styled("text").red().bold().underline()`
- **Cross-platform**: Windows, macOS, and Linux terminal detection

## Theming a zcli app

Declare a theme in your app's root source file (next to `main`), the same way
`std_options` works:

```zig
const zcli = @import("zcli");

pub const zcli_theme: zcli.Theme = .{
    .palette = .{
        // Brand your CLI: command names in help, highlights, etc.
        .command = .{ .foreground = .{ .rgb = .{ .r = 255, .g = 179, .b = 71 } } },
        .accent = .{ .foreground = .{ .rgb = .{ .r = 255, .g = 179, .b = 71 } } },
    },
};
```

That's the whole integration: `--help` renders command names in your color,
and every semantic style in your commands resolves through your palette.
Inside a command, the ready-to-use handle is `context.theme`:

```zig
const styled = zcli.theme.styled;

pub fn execute(args: Args, options: Options, context: *Context) !void {
    const out = context.stdout();
    try styled("deploy complete").success().render(out, &context.theme);
    try styled(args.host).value().render(out, &context.theme);
}
```

## The pieces

### Palette: role → style

Every semantic role maps to a full `Style` — color *and* attributes. The
defaults are accessible colors on a dark background; `header` is
attribute-only (bold) so it reads on any background.

| Role | Default | | Role | Default |
|------|---------|-|------|---------|
| `success` | green, bold | | `command` | turquoise |
| `err` | coral, bold | | `flag` | orchid |
| `warning` | amber, bold | | `path` | light cyan |
| `info` | blue, bold | | `value` | lawn green |
| `muted` | gray, dim | | `code` | purple |
| `header` | bold (no color) | | `link` | sky blue, italic |
| `accent` | cyan | | | |

### Component tokens

`Theme.prompts` and `Theme.progress` hold `StyleRef` tokens — each is either a
role reference (the default) or a literal style:

```zig
pub const zcli_theme: zcli.Theme = .{
    .palette = .{ .accent = .{ .foreground = .cyan } },
    .prompts = .{
        // Defaults shown: cursor/selected follow accent, marker follows
        // success, hint follows muted. Pin any one independently:
        .selected = .{ .style = .{ .foreground = .yellow, .bold = true } },
    },
};
```

### ThemeContext: what render paths consume

`ThemeContext` pairs the theme with detected terminal capabilities. zcli
builds it for you as `context.theme`; standalone users build their own:

```zig
const theme = @import("theme");

const caps = theme.Capabilities.init(&environ_map, io);
const ctx = theme.ThemeContext{ .caps = caps }; // default theme
try theme.styled("ok").success().render(writer, &ctx);
```

`Capabilities.init` honors `NO_COLOR`, `COLORTERM`, `TERM`, TTY-ness, and
platform-specific signals (Windows Terminal, iTerm, Apple Terminal, VS Code).

## Fluent styling

```zig
const styled = theme.styled;

// Colors and attributes
try styled("Error").red().bold().render(w, &ctx);
try styled("Custom").rgb(255, 100, 50).underline().render(w, &ctx);
try styled("Warning").onYellow().black().render(w, &ctx);

// Semantic roles — resolved through ctx's palette at render time
try styled("Build passed").success().render(w, &ctx);
try styled("git commit").command().render(w, &ctx);

// Roles and explicit settings compose; explicit wins
try styled("important").err().underline().render(w, &ctx);

// Any content type
try styled(@as(u32, 42)).value().render(w, &ctx);
```

Semantic methods only *tag* the value with a role; the role is resolved
against the active palette when `render` runs. That's what lets one theme
restyle code that was written long before the theme existed.

## Degradation

A palette color is emitted at the terminal's actual capability:

| Capability | `rgb(255, 105, 97)` renders as |
|------------|--------------------------------|
| `true_color` | `38;2;255;105;97` (exact) |
| `ansi_256` | nearest 256-palette index |
| `ansi_16` | nearest of the 16 ANSI colors |
| `no_color` | nothing (plain text) |

## Standalone installation

The package is self-contained (it ships inside zcli but has no dependency on
it). Add it to `build.zig.zon` and import module `theme`:

```zig
.dependencies = .{
    .theme = .{ .path = "path/to/packages/theme" },
},
```

## Design notes

See `docs/adr/0012-theme-system.md` in the repository root for the full
rationale: the token hierarchy, the root-declaration idiom, why the theme is
comptime-known (zero-cost themed help), and what's deliberately deferred
(runtime theme switching, light/dark adaptation).
