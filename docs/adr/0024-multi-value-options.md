# Multi-value options: comma-separated, not greedy space-separated

Status: accepted (implemented)

An array-typed option (`tags: [][]const u8`, `nums: []u32`, …) collects several
values. Until now the only spelling was **repetition** — `--tag a --tag b`. Users
coming from other CLIs asked for a way to pass several values without repeating the
flag. Two spellings were on the table:

- **Comma-separated** — `--tag a,b`
- **Greedy space-separated** — `--tag a b` (one flag consuming consecutive tokens)

## Decision

Add **comma-separated** values and keep repetition. The two compose. Deliberately
**reject** greedy space-separated.

Every value token of an array-typed option is split on `,`:

```
--tag a,b          →  [a, b]
--tag=a,b   -t a,b →  [a, b]        (equals and short forms too)
--tag a,b --tag c  →  [a, b, c]     (composes with repetition)
--tag a,,b         →  value error   (empty segment rejected: also ,a and a,)
```

A literal comma is therefore always a separator for array options — it cannot
appear inside an element. Scalar (non-array) options are untouched: a comma stays a
literal character in their single value. `--help` marks array options `(repeatable)`.

## Why not greedy space-separated

Greedy consumption is fundamentally **ambiguous with zcli's interleaved
positionals.** zcli is GNU-style: options and positionals may appear in any order
(`packages/core/src/options/parser.zig`). A greedy array option would swallow any
following non-flag token — including intended positionals. For a command with both
`tags: [][]const u8` and a positional `file`, `--tags a file.txt` means
`tags=[a], file="file.txt"` today; greedy would silently change it to
`tags=[a, "file.txt"]`. So greedy is **not additive** — it changes the meaning of
existing command lines — whereas comma is additive (only a literal comma in a value
changes meaning).

This is not a zcli-specific worry. Every framework that offers greedy multi-value
documents the hazard: Rust `clap`'s `num_args(1..)` is opt-in with an explicit
"does not get along with trailing positionals/subcommands" warning (clap #1721), and
Python `argparse`'s `nargs='+'` is the canonical source of "my positional
disappeared" bugs. The dominant server/cloud ecosystem (Go `pflag` →
kubectl/docker/helm/Hashicorp) settled on exactly **comma + repetition** and does not
do greedy space. We follow that convention.

## Consequences

- **Purely additive parse change.** Splitting happens inside the array value-append
  path (`options/array_utils.zig`); the two-layer parse (the `command_parser.zig`
  pre-split, then `options/parser.zig`) still routes exactly one value token per
  option occurrence, so the layers stay in agreement with no change to either's
  boundary logic, `--` handling, negative-number handling, or positional parsing.
- **The comma-in-value tradeoff.** A value that must contain a literal comma cannot
  use this syntax. This mirrors pflag `StringSlice` and is acceptable: comma-bearing
  values are rare, and repetition remains available for any single value (though its
  tokens are split too — the rule is uniform).
- **No scaffold change.** `zcli add option --multiple` already emits array fields;
  comma parsing is a parse-time capability of any array option.
