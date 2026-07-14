# markdown

**Configure once. Use everywhere. Zero runtime overhead.**

```zig
const md = @import("markdown");

const fmt = md.formatter(stdout, .true_color);
try fmt.write("<error>**{s}**</error> failed at <path>{s}</path>", .{test_name, file});
```

Converts **full markdown** (headers, lists, code blocks, links, etc.) and semantic tags (`<error>`, `<success>`, etc.) to ANSI codes at **compile time** while preserving format specifiers (`{s}`, `{d}`) for **runtime interpolation**.

## Features

- ✅ **Pure comptime** - No allocators at comptime, no runtime parsing
- ✅ **Zero overhead** - All markdown converted to ANSI codes at compile time
- ✅ **Full markdown support** - Headers, lists, code blocks, links, blockquotes, and more
- ✅ **Runtime interpolation** - Preserve `{s}`, `{d}` format specifiers
- ✅ **Semantic colors** - 13 built-in semantic roles (success, error, warning, etc.)
- ✅ **Composable** - Nest markdown inside semantic tags with runtime values
- ✅ **Simple API** - Just `print()` or `write()`
- ✅ **No dependencies** - Pure Zig stdlib

## Supported Markdown

### Inline Formatting

- **Bold**: `**text**` → Bold text
- **Italic**: `*text*` → Italic text
- **Dim**: `~text~` → Dimmed text
- **Inline code**: `` `code` `` → Colored code
- **Strikethrough**: `~~text~~` → Strikethrough text
- **Links**: `[text](url)` → Clickable terminal links (OSC 8)
- **Escape**: `\*not italic\*` → Literal asterisks

### Block Elements

- **Headers**: `# H1` through `###### H6` → Colored, bold headers
- **Code blocks**: ` ```lang\ncode\n``` ` → Bordered boxes with syntax labels
- **Lists**: `- item` and `1. item` → Bulleted and numbered lists (with nesting!)
- **Blockquotes**: `> quote` → Styled quotes
- **Horizontal rules**: `---`, `***`, `___` → Box drawing lines

### Format Specifiers

All format specifiers are preserved: `{s}`, `{d}`, `{d:.2}`, `{x}`, etc.

## Quick Start

````zig
const std = @import("std");
const md = @import("markdown");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    const fmt = md.formatter(stdout, .true_color);

    // Headers
    try fmt.write(
        \\# Build Report
        \\
        \\Build completed successfully
        \\
    , .{});

    // Lists with formatting
    try fmt.write(
        \\## Results
        \\
        \\- **{d}** tests passed
        \\- *{d}* tests failed
        \\
    , .{42, 3});

    // Code blocks
    try fmt.write(
        \\```bash
        \\$ zig build test
        \\```
        \\
    , .{});

    // Links
    try fmt.write("Visit [our docs](https://example.com) for more info\n", .{});

    // Semantic colors
    try fmt.write("<success>All tests passed!</success>\n", .{});

    // Writers are buffered in Zig 0.16 — flush before exit.
    try stdout.flush();
}
````

## How It Works

```zig
// At comptime, this markdown:
"# Header\n\n- Item **{d}**\n- Item *{s}*"

// Gets parsed and converted to ANSI codes with preserved format specifiers:
"\n\x1b[38;2;255;255;255m\x1b[1mHeader\x1b[0m\n\n• Item \x1b[1m{d}\x1b[0m\n• Item \x1b[3m{s}\x1b[0m\n"

// Then at runtime, std.fmt fills in {d} and {s} with actual values!
```

**The key insight:** We parse markdown at comptime (no runtime cost!), preserve format specifiers like `{s}` and `{d}`, then use `std.fmt` at runtime for value interpolation.

## API

### Recommended: Formatter API

Create a formatter once — bundling the writer and the terminal's capability —
then use it many times. The formatter pre-compiles all four capability variants
(`no_color`/`ansi_16`/`ansi_256`/`true_color`) of each format string at comptime
and selects one at runtime, so styling still costs nothing at run time and
respects `NO_COLOR`. Pass the detected capability (`.true_color` here for a
standalone example):

```zig
// With default palette
const fmt = md.formatter(stdout, .true_color);
try fmt.write("## Status: <error>**{s}**</error>", .{status});

// With custom palette
const custom_palette = md.Palette{
    .err = .{ .foreground = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } }, .bold = true },
};
const fmt = md.formatterWithPalette(stdout, .true_color, custom_palette);
try fmt.write("<error>Custom colors!</error>", .{});
```

In a zcli command, prefer `context.markdown()` — it wires stdout, the detected
capability, and the app's palette for you:

```zig
var fmt = context.markdown();
try fmt.write("<success>**{d}** tests passed</success>", .{count});
```

**Formatter Methods:**

- `fmt.write(markdown, args)` - Write formatted output to the configured writer
- `fmt.print(allocator, markdown, args)` - Return formatted string (allocates)

### Alternative: Direct Functions

If you prefer not to create a formatter:

```zig
// With default palette
try md.write(stdout, "## Error\n\n<error>Failed to load *{s}*</error>\n", .{filename});

// With custom palette
try md.writeWithPalette(stdout, "<error>text</error>", custom_palette, .{});

// Get allocated string
const msg = try md.print(allocator, "**{d}** tests passed", .{count});
defer allocator.free(msg);
```

### Low-level: Parse Only

```zig
const fmt_string = comptime md.parse("## Header\n\n**Error:** Failed to load *{s}*");
// Returns ANSI string, use with std.fmt.print() later
```

## Semantic Colors

13 built-in semantic roles with carefully chosen default colors:

- **Core:** `<success>` `<error>` `<warning>` `<info>` `<muted>`
- **CLI:** `<command>` `<flag>` `<path>` `<value>` `<code>`
- **Structure:** `<header>` `<link>` `<accent>`

**Note:** Semantic tags work with inline markdown only. For block-level documents (headers, lists, code blocks), use pure markdown.

```zig
const fmt = md.formatter(stdout, .true_color);

// Status messages (inline only)
try fmt.write("<success>Build succeeded</success>\n", .{});
try fmt.write("<warning>3 warnings found</warning>\n", .{});
try fmt.write("<error>Build failed</error>\n", .{});

// CLI elements
try fmt.write("Run <command>zig test {s}</command>\n", .{filename});
try fmt.write("Use the <flag>--verbose</flag> flag\n", .{});
try fmt.write("Loading <path>{s}</path>\n", .{config_path});

// Compose with markdown (inline)
try fmt.write("<error>**Fatal error:**</error> *{s}*\n", .{message});
```

## Markdown Examples

### Headers

```zig
try fmt.write(
    \\# Level 1 Header
    \\
    \\## Level 2 Header
    \\
    \\### Level 3 with **bold** text
    \\
, .{});
```

### Lists

```zig
// Unordered
try fmt.write(
    \\- First item with **bold**
    \\- Second item with *italic*
    \\  - Nested item
    \\  - Another nested
    \\
, .{});

// Ordered with runtime values
try fmt.write(
    \\1. Step one: **{s}**
    \\2. Step two: *{d}* items
    \\3. Step three: Done
    \\
, .{action, count});
```

### Code Blocks

````zig
try fmt.write(
    \\```zig
    \\const x = 42;
    \\const y = "hello";
    \\```
    \\
, .{});

try fmt.write(
    \\```bash
    \\$ zig build test
    \\$ zig build run
    \\```
    \\
, .{});
````

**Note:** Braces inside code blocks are escaped automatically, so `{` becomes `{{` to prevent format interpretation.

### Blockquotes

```zig
try fmt.write(
    \\> This is a **blockquote** with *formatting*
    \\> It can span multiple lines
    \\
, .{});
```

### Links

```zig
try fmt.write("Visit [our documentation](https://example.com/docs) for details\n", .{});
try fmt.write("Check out [**GitHub**](https://github.com) for source code\n", .{});
```

Links are rendered as clickable terminal links using OSC 8 escape sequences.

### Horizontal Rules

```zig
try fmt.write(
    \\Content above
    \\
    \\---
    \\
    \\Content below
    \\
, .{});
```

## Use Cases

### CLI Error Messages

```zig
const fmt = md.formatter(stderr, .true_color);

try fmt.write(
    \\<error>**Error:**</error> Failed to parse <path>{s}</path> at line ~{d}~
    \\
, .{filename, line_num});
```

### Build Reports with Markdown

```zig
const fmt = md.formatter(stdout, .true_color);

try fmt.write(
    \\# Build Report
    \\
    \\**{d}** tests passed, *{d}* failed
    \\
    \\## Failed Tests
    \\
    \\1. `auth_test.zig` - Authentication error
    \\2. `parser_test.zig` - Parse failure
    \\
    \\> **Note:** Fix these before deployment
    \\
, .{passed, failed});
```

### CLI Help Text

````zig
const fmt = md.formatter(stdout, .true_color);

try fmt.write(
    \\# myapp - A demonstration CLI
    \\
    \\## Usage
    \\
    \\```bash
    \\$ myapp [OPTIONS] <COMMAND>
    \\```
    \\
    \\## Options
    \\
    \\- `--verbose` - Enable verbose output
    \\- `--help` - Show this help message
    \\
    \\## Commands
    \\
    \\1. **build** - Build the project
    \\2. **test** - Run tests
    \\3. **run** - Run the application
    \\
    \\---
    \\
    \\Visit [our docs](https://example.com) for more information
    \\
, .{});
````

## Design Philosophy

**Problem:** Existing markdown-to-ANSI libraries either:

1. Parse markdown at runtime (slow, wastes CPU)
2. Use complex templating systems
3. Can't interpolate runtime values
4. Support only basic inline formatting

**Solution:**

- Parse **full markdown** (blocks + inline) at **comptime** (zero runtime cost)
- Preserve format specifiers for **runtime interpolation**
- Use **pure string slicing** (no allocators needed at comptime)
- Support **all common markdown features** out of the box

## Known Scope Limits

This package is **comptime-template-only by design** (ADR-0012, zero-cost
styling): `write()`/`print()`/`formatter().write()` all take
`comptime markdown: []const u8`. That means:

- **No runtime/user-supplied markdown.** The markdown text itself must be a
  compile-time known string; only the `{s}`/`{d}`/... format-specifier
  *arguments* are runtime values. If you need to render markdown that comes
  from a file, network response, or other runtime source, this package is
  the wrong tool — reach for a runtime markdown renderer instead.
- **No terminal-width wrapping.** Rendered output relies on the terminal's
  own soft-wrap; there's no hang-indent or reflow for long paragraphs,
  styled lists, or nested content at a given column width.

These are intentional trade-offs that make the zero-runtime-cost styling
model possible — not bugs. Literal, developer-authored help text and status
messages (the intended use case) are unaffected.

## Examples

Six focused, heavily-commented examples live in [`examples/`](examples/) — see
[`examples/README.md`](examples/README.md) for the full index. Each doubles as
documentation for one slice of the API.

```bash
zig build examples          # build them all (binaries in zig-out/bin/markdown-<name>)
zig build run-elements      # or: semantic, interpolation, palette,
                            #     capabilities, build_report
zig build test              # run all tests (also compile-checks every example)
```

| Example         | Shows off                                                                 |
| --------------- | ------------------------------------------------------------------------- |
| `elements`      | every block + inline element: headers, lists, code, quotes, rules, links  |
| `semantic`      | all 13 semantic roles + composing them with inline markdown + values      |
| `interpolation` | runtime `{s}`/`{d}`/`{d:.2}`/`{x}` interpolation across every context      |
| `palette`       | custom palettes + the low-level `parse` / `writeWithPalette` / `print`     |
| `capabilities`  | the same markdown at `no_color` / `ansi_16` / `ansi_256` / `true_color`   |
| `build_report`  | a realistic CLI report combining everything end-to-end                    |

## Custom Palettes

Override any semantic color:

```zig
const custom_palette = md.Palette{
    .success = .{ .foreground = .{ .rgb = .{ .r = 100, .g = 255, .b = 100 } }, .bold = true },
    .err = .{ .foreground = .{ .rgb = .{ .r = 255, .g = 50, .b = 50 } }, .bold = true },
    .code = .{ .foreground = .{ .rgb = .{ .r = 200, .g = 200, .b = 255 } } },
};

const fmt = md.formatterWithPalette(stdout, .true_color, custom_palette);
try fmt.write("<success>Custom colors!</success>", .{});
```

## Comparison to theme

This package extracts the core markdown parsing from `theme` and redesigns it to:

- Work at comptime without allocators (fixes pthread errors)
- Support runtime interpolation
- Support full markdown (blocks + inline)
- Be standalone (no dependency on theme system)
- Have a minimal, focused API

`theme` can use this package for markdown parsing while focusing on themes and colors.

## License

MIT
