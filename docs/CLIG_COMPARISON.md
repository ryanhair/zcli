# zcli vs clig.dev Guidelines Comparison

This document compares zcli against the [Command Line Interface Guidelines](https://clig.dev/) and outlines improvements to increase compliance.

## Summary

| Category | Supported | Partial | Not Supported |
|----------|-----------|---------|---------------|
| **The Basics** | 3 | 0 | 0 |
| **Help System** | 4 | 2 | 3 |
| **Output** | 1 | 1 | 6 |
| **Error Handling** | 2 | 1 | 2 |
| **Arguments & Flags** | 8 | 2 | 4 |
| **Interactivity** | 0 | 0 | 4 |
| **Subcommands** | 3 | 0 | 0 |
| **Robustness** | 2 | 1 | 4 |
| **Configuration** | 1 | 1 | 3 |
| **Environment Variables** | 1 | 0 | 2 |
| **Future-Proofing** | 2 | 0 | 2 |
| **Signals** | 0 | 0 | 2 |
| **Distribution** | 1 | 0 | 0 |

**Overall: 28 Supported, 8 Partial, 32 Not Supported (~41% full coverage)**

---

## Detailed Comparison

### THE BASICS

| Guideline | Status | Notes |
|-----------|--------|-------|
| Use argument parsing library | ✅ Supported | zcli provides type-safe parsing via `Args`/`Options` structs |
| Exit 0 for success, non-zero for failure | ✅ Supported | Standard Zig error handling propagates to exit codes |
| Send output to stdout, errors to stderr | ✅ Supported | `context.stdout()` and `context.stderr()` provided |

### HELP SYSTEM

| Guideline | Status | Notes |
|-----------|--------|-------|
| Display help on `-h`/`--help` | ✅ Supported | `zcli-help` plugin provides this |
| Support help for subcommands | ✅ Supported | Per-command help works |
| Show brief help when args missing | ✅ Supported | Help displayed on argument errors |
| Include examples in help | ✅ Supported | `meta.examples` array supported |
| Suggest corrections on typos | ✅ Supported | `zcli-not-found` plugin with Levenshtein distance |
| Link to web docs | ⚠️ Partial | Can include in description, no dedicated field |
| Display commonly-used flags first | ⚠️ Partial | Order follows struct definition |
| Provide man pages | ❌ Not Supported | No man page generation |
| Provide web documentation | ❌ Not Supported | Framework doesn't generate docs |
| Use formatting (bold, sections) | ❌ Not Supported | Plain text help only |

### OUTPUT

| Guideline | Status | Notes |
|-----------|--------|-------|
| Provide stdout/stderr writers | ✅ Supported | `context.stdout()`, `context.stderr()` |
| Detect TTY for formatting | ⚠️ Partial | Can check manually, no framework helper |
| Support `--json` for structured output | ❌ Not Supported | No built-in JSON mode |
| Support `--plain` for machine output | ❌ Not Supported | No built-in plain mode |
| Support `NO_COLOR` env var | ❌ Not Supported | No color support at all |
| Use colors intentionally | ❌ Not Supported | No ANSI color helpers |
| Show progress for long operations | ❌ Not Supported | No progress bar/spinner |
| Use pagers for long output | ❌ Not Supported | No pager integration |

### ERROR HANDLING

| Guideline | Status | Notes |
|-----------|--------|-------|
| Catch errors and rewrite clearly | ✅ Supported | Diagnostic error system with clear messages |
| Suggest next steps on errors | ✅ Supported | "Did you mean?" suggestions via plugin |
| Group similar errors | ⚠️ Partial | Individual errors, no grouping |
| Include debug/traceback for unexpected errors | ❌ Not Supported | Standard Zig errors only |
| Easy bug reporting | ❌ Not Supported | No built-in issue submission |

### ARGUMENTS & FLAGS

| Guideline | Status | Notes |
|-----------|--------|-------|
| Favor flags over args for clarity | ✅ Supported | Both supported, user choice |
| Provide long form for all flags | ✅ Supported | All options have long form |
| Short flags for common options | ✅ Supported | `meta.options.X.short = 'x'` |
| Standard flag `-h`/`--help` | ✅ Supported | Reserved by help plugin |
| Standard flag `--version` | ✅ Supported | Via `zcli-version` plugin |
| Support `--` to stop option parsing | ✅ Supported | Implemented in parser |
| Multiple arguments (varargs) | ✅ Supported | `[]const []const u8` field type |
| Default values | ✅ Supported | Struct field defaults |
| Accept `-` for stdin/stdout | ⚠️ Partial | User must implement, no helper |
| Flags order-independent | ⚠️ Partial | Mostly works, some edge cases |
| Support `--no-input` mode | ❌ Not Supported | No interactive prompt system |
| Confirm dangerous operations | ❌ Not Supported | No confirmation helpers |
| Never accept secrets via flags | ❌ Not Supported | No guidance/enforcement |
| Support `--dry-run` | ❌ Not Supported | User must implement manually |

### INTERACTIVITY

| Guideline | Status | Notes |
|-----------|--------|-------|
| Prompt when stdin is TTY | ❌ Not Supported | No prompt system |
| Respect `--no-input` flag | ❌ Not Supported | No flag convention |
| Hide password input | ❌ Not Supported | No password input helper |
| Make Ctrl-C work reliably | ❌ Not Supported | No signal handling helpers |

### SUBCOMMANDS

| Guideline | Status | Notes |
|-----------|--------|-------|
| Consistent flag names across subcommands | ✅ Supported | Global options via plugins |
| Consistent output formatting | ✅ Supported | User controls, framework neutral |
| Clear multi-level structure | ✅ Supported | Directory structure = command structure |

### ROBUSTNESS

| Guideline | Status | Notes |
|-----------|--------|-------|
| Validate user input | ✅ Supported | Type validation at parse time |
| Check early, exit before damage | ✅ Supported | Parse errors before execute |
| Show something within 100ms | ⚠️ Partial | Zig is fast, but no framework guidance |
| Show progress for long operations | ❌ Not Supported | No progress indicators |
| Implement timeouts | ❌ Not Supported | No timeout helpers |
| Design for resumability | ❌ Not Supported | No idempotency helpers |
| Crash-only design | ❌ Not Supported | No cleanup/recovery helpers |

### CONFIGURATION

| Guideline | Status | Notes |
|-----------|--------|-------|
| Support env vars | ✅ Supported | `context.environment.get()` |
| Follow XDG Base Directory spec | ⚠️ Partial | User must implement |
| Support config files | ❌ Not Supported | No config file parsing |
| Config precedence (flags > env > config) | ❌ Not Supported | No built-in precedence |
| Support `.env` files | ❌ Not Supported | No .env parsing |

### ENVIRONMENT VARIABLES

| Guideline | Status | Notes |
|-----------|--------|-------|
| Access to env vars | ✅ Supported | Via `context.environment` |
| Respect `NO_COLOR` | ❌ Not Supported | No color system |
| Respect standard vars (EDITOR, PAGER, etc.) | ❌ Not Supported | No built-in handling |

### FUTURE-PROOFING

| Guideline | Status | Notes |
|-----------|--------|-------|
| Avoid breaking changes | ✅ Supported | Compile-time catches changes |
| Explicit aliases only | ✅ Supported | `meta.aliases` is explicit |
| Show deprecation warnings | ❌ Not Supported | No deprecation system |
| Don't allow prefix abbreviations | ❌ Not Supported | Could be added |

### SIGNALS

| Guideline | Status | Notes |
|-----------|--------|-------|
| Exit quickly on Ctrl-C | ❌ Not Supported | No signal handling |
| Graceful degradation on second Ctrl-C | ❌ Not Supported | No signal handling |

### DISTRIBUTION

| Guideline | Status | Notes |
|-----------|--------|-------|
| Single binary | ✅ Supported | Zig produces single static binary |

---

## Roadmap for Improvement

### High Priority

1. **Expose ztheme through context** - Wrap existing color/TTY/capability detection in context API
2. **Add progress indicator helpers** - Spinners and progress bars with auto-TTY detection
3. **Add `--output` format plugin** - Configurable output modes (json, table, plain)
4. **Add environment variable binding** - `meta.options.verbose.env = "MYAPP_VERBOSE"`

### Medium Priority

5. **Add config file support** - TOML config for global flags only
6. **Add interactive prompt helpers** - confirm, prompt, promptSecret, select
7. **Add signal handling** - Clean Ctrl-C handling with cleanup hooks

### Lower Priority

8. **Add man page generation** - Build-time generation from metadata
9. **Add deprecation system** - Warnings for deprecated commands/options
10. **Add `--dry-run` convention** - Plugin with `context.isDryRun()` check

---

## What zcli Does Well

- **Type-safe argument parsing** - Compile-time validation catches errors early
- **Subcommand structure** - File-based routing is intuitive and scales well
- **Help system** - Automatic help with examples and suggestions
- **Error messages** - Clear diagnostic errors with suggestions
- **Plugin architecture** - Extensible for adding missing features
- **Single binary** - Zig produces optimal distribution format
- **Exit codes** - Standard error propagation works correctly

## Conclusion

zcli covers ~41% of clig.dev guidelines fully, with another ~12% partially covered. The main gaps are in output formatting, interactivity, configuration, and signal handling - all addressable through new plugins or core framework additions.
