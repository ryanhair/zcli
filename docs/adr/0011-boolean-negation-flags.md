# Boolean negation flags (`--no-<flag>`) and optional-bool guardrails

Status: accepted

zcli parses a command's flags from its `Options` struct: a `bool` field is a flag
set by presence (`--verbose` → `true`). Two things about booleans were quietly
broken.

1. **`false` was unreachable for a flag.** A `bool` could only be set `true`; there
   was no way to say "off". A `bool = true` default couldn't be turned off from the
   command line at all — and worse, the option initializer hardcoded `bool → false`
   *before* reading the declared default, so `bool = true` silently initialized to
   `false`.
2. **`?bool` was a value option pretending to be a flag.** Because `isBooleanType`
   is `T == bool` (false for `?bool`), `?bool` fell through to the value path: it
   parsed as `--verbose <true|false>` and bare `--verbose` was
   `error.MissingOptionValue`. So the one type that *looks* like a three-state flag
   was the most confusing of all — `--verbose true` worked, `--verbose` didn't.

The motivating question was simply "how do I set `verbose: ?bool` to `false`?" — and
the honest answer was a mess.

## Decision

**Treat `bool` and `?bool` as the same thing — a boolean *flag* — and give every
boolean flag an auto-generated `--no-<flag>` negation.**

- `--flag` sets `true`; the auto-generated `--no-flag` sets `false`; an absent flag
  keeps its default (`false`, a declared `true`, or `null` for `?bool`). `?bool`
  becomes a genuine three-state flag: absent → `null`, `--flag` → `true`,
  `--no-flag` → `false`.
- Negation is **long-form only** (`--no-flag`); short flags have no negation.
  `--no-flag=value` is rejected like `--flag=value`. Negation is built from the
  option's *effective* name, so it respects a custom `meta.options.<field>.name`.
- `--no-flag` is **accepted but hidden from `--help`** and from generated shell
  completions. Help and completions iterate the declared struct fields; negation is
  synthesized only in the parser and never materialized as a field, so it is
  invisible by construction, not by a suppression flag.
- **A boolean may appear at most once.** Repeating it — `--flag --flag`,
  `--no-flag --no-flag`, or the contradictory `--flag --no-flag` (which share the
  field's occurrence count) — is `OptionDuplicate`. There is no meaningful reason to
  pass a boolean twice, and the contradiction should fail loudly rather than
  silently last-win. Value options and accumulating arrays are unchanged.

**Two compile-time guards keep this coherent:**

- **A boolean field's effective flag name may not start with `no-`.** A `no_verbose`
  flag would collide with (and read as) some other flag's `--no-` negation. The
  positively-named alternative is always available: `color: bool = true` + `--no-color`.
- **An optional field (`?T`, any T) must default to `null`.** The initializer sets
  optionals to `null` *before* reading any default, so a non-null default was
  silently discarded. `null` is the "not passed" state that config/env fill in; a
  guaranteed value belongs on a non-optional field with a default.

## Consequences

- **This is a behavior change, not just an addition.** `?bool` stops being a value
  option: `--verbose true` no longer consumes `true` (it becomes a positional).
  `bool = true` defaults now actually hold. Per project policy (cleanest choice, no
  backwards-compatibility shims) this is the intended trade.
- The mechanism is one predicate, `isBooleanFlag(T) == (T == bool or T == ?bool)`,
  replacing the nine `T == bool` flag-vs-value decision sites in the parser and
  classifier. The initializer and env-fallback paths keep `== bool` (a `?bool`
  initializes to `null`, and env values apply to the unwrapped child).
- `--no-color` — a near-universal flag — is now expressed as `color: bool = true`
  and disabled with the auto-generated `--no-color`, rather than a hand-rolled
  `no_color: bool` (which the first guard now forbids).
- `OptionDuplicate` existed in the error set and diagnostics all along but was never
  emitted; it is now wired up for booleans.

Documented in `docs/COMMANDS.md` and `docs/DESIGN.md`.
