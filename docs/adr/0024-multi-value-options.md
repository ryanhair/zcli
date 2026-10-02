# Multi-value options: literal repetition with explicit delimiters

Status: amended (implemented)

## Context

Array options collect repeated values. Originally every value split on comma.
That silently changed quoted prose such as `--ac "Clear on blur, not on change"`
into two values. Shell quoting already establishes the intended boundary.

## Decision

Each option occurrence contributes one element by default, for every supported
array element type. Commands can explicitly declare `.delimiter = ','` (or
another non-whitespace, non-NUL byte) in per-option metadata to enable list syntax.

```zig
pub const meta = .{ .options = .{
    .tags = .{ .delimiter = ',', .short = 't' },
} };
```

For a literal repeatable option:

```
--ac "a, b" --ac c   → ["a, b", "c"]
--ac=                → [""]
```

For an explicitly delimited option:

```
--tags a,b --tags c  → ["a", "b", "c"]
--tags=a,b -t c,d    → ["a", "b", "c", "d"]
--tags a,,b         → value error (also ,a and a,)
```

Long, short, attached, equals, and bundled forms have equivalent behavior.
Delimiters do not trim whitespace or implement CSV quoting or escaping. Types
control element conversion; metadata controls token splitting. Structured config
arrays retain their supplied element boundaries. Help marks array options
repeatable and explicitly shows their delimiter when declared.

Greedy space-separated consumption remains unsupported. In zcli's interleaved
syntax, `--tags a file.txt` must leave `file.txt` available as a positional; an
array flag cannot consume an arbitrary number of following tokens.
