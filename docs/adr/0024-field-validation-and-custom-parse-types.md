# Field validation and custom parse types

Status: accepted (both increments shipped)

zcli derives a command's inputs from its `Args`/`Options` structs: a field's type
drives parsing, its enum variants are the valid choices, `?T`/default decide
required-ness. `meta` is the escape hatch for what a single field's type *can't*
express — descriptions, custom flag names, `.env` fallback, and the cross-field
constraints of ADR-0022 (`exclusive`, `requires`).

What was missing is *per-field value* checking beyond "does it parse as the
type": a `u16` port that must be 1–65535, a non-empty name, a string that is only
meaningful once turned into a `Duration`. Today an author hand-writes those checks
at the top of `execute`, with an ad-hoc message and exit path.

The question was whether to add one mechanism or two — and specifically whether a
validation *function* and a custom *type* are "two ways to do one thing".

## Decision

Two complementary features, because they are two different jobs:

- **Validation** — *the field's type is already right; the value needs checking.*
  A `validate` hook in `meta` refines an existing type. No new type, no ceremony.
  This is the common case (ranges, non-empty, length). **Shipped here.**

- **Custom parse types** — *producing the value from text needs your code.* A
  user-defined type declares `pub fn parse`, so a string that doesn't map to a
  native scalar (`"5m30s"` → `Duration`, `"4GiB"` → `ByteSize`, `Email`) becomes a
  typed, valid-by-construction value. Parsing validates as it builds. **Shipped as
  the second increment.**

They are not redundant: a `validate` fn *cannot* do a custom parse (declare the
field `u64` and `"5m30s"` fails at parse before validate runs; declare it
`[]const u8` and you've thrown away the value), and no one mints a type to
range-check a `u16`. The only overlap is refining a plain scalar, where `validate`
is the recommended lighter tool — the same soft overlap `enum` already has with
"string + validate" for a fixed choice set. They compose: a custom-typed field may
also carry a `validate` hook.

**Teachable boundary:**
> Does the string map straight to a type zcli already parses (int/float/enum/
> string)? Declare that type; add `validate` for extra rules.
> Does turning the string into your value need your own logic (or you want a
> distinct domain type)? Make a custom type with `parse`.

### The `validate` contract

```zig
pub const Options = struct { port: u16 = 8080 };

pub const meta = .{
    .options = .{ .port = .{ .validate = validatePort } },
};

fn validatePort(port: u16) ?[]const u8 {
    return if (port == 0) "must be between 1 and 65535" else null;
}
```

- Signature `fn(Base) ?[]const u8`, where `Base` is the field type with one
  optional level removed. `null` means valid; a returned string is the reason
  shown to the user. Verified at comptime, like every other `meta` contract.
- Works identically on `meta.args.<field>` (struct form, ADR after #225) and
  `meta.options.<field>`.
- Runs on the **final resolved value from any source** — CLI, env, config, or
  default — after required/requires/exclusive, so no source can inject an invalid
  value. A `?T` field is validated only when a value is present.
- Reported through the ADR-#206 diagnostic path, so a validation failure reads
  like any other bad-input error and carries the same usage hint:
  `Error: Invalid value '0' for option '--port': must be between 1 and 65535.`

### Why a reason string, not an error or `context.fail`

A validation failure is a bad-*input* error — a sibling of "invalid enum value",
not a business-logic failure. #206 gives that whole family one uniform treatment
(`Invalid value 'X' for option '--Y'`, humanized type, usage hint, `onError`
introspection), and validation is its natural extension.

- Returning a bare `error` would surface `@errorName` (camelCase — the un-humane
  output #206 removed) unless we add a mapping layer.
- `context.fail(...)` is the *business-failure* idiom from `execute`: freeform,
  no usage hint, and it bypasses the structured diagnostic. Using it here would
  make `--port 0` behave inconsistently with `--level xyz`.
- A reason *string* keeps the hook pure and context-free — trivially testable,
  reusable across commands, side-effect-free — and `?[]const u8` (null = ok) *is*
  "error-or-not, with the reason attached". Environment-dependent checks (a file
  must exist) deliberately don't belong in a value hook; they are execute-time
  logic (TOCTOU).

By contrast, `parse` *constructs* and composes with `try` over sub-parsers, so it
returns an error union — the asymmetry mirrors what each function actually does.

### The `parse` contract

```zig
const Duration = struct {
    secs: u64,
    pub const hint = "a duration like 5m30s";
    pub fn parse(s: []const u8) error{ BadFormat, TooLong }!Duration { … }
    pub fn describe(err: error{ BadFormat, TooLong }) []const u8 {
        return switch (err) {
            error.BadFormat => "use a form like 5m30s",
            error.TooLong => "must be under an hour",
        };
    }
};

pub const Options = struct { timeout: Duration = .{ .secs = 30 } };
```

- A field type is *custom-parsed* when — after unwrapping one optional level — it
  is a struct/union/enum declaring `pub fn parse(s: []const u8) E!@This()`. The
  error union is idiomatic Zig, composes with `try`, and matches zcli's own
  `parseOptionValue`. The signature is checked at comptime with a friendly message.
- Optional companions: `pub const hint` (the "Expected …" phrase and help
  placeholder; defaults to the type name) and `pub fn describe(err)` (a humane
  message per failure variant).
- Every source constructs the type the same way — CLI and env parse the string
  through `parse`; config does too when the value is a string. Because the field
  *is* the domain type, `execute` receives a value that is valid by construction.
- A parse failure reuses the existing `OptionInvalidValue`/`ArgumentInvalidValue`
  diagnostics: the specific error collapses to the canonical reported error (clean
  exit), while the humane reason is recovered at the diagnostic site — `describe`'s
  message when present, else the hint:
  `Invalid value 'nope' for option '--timeout': use a form like 5m30s.`
  We deliberately never render `@errorName` (camelCase would break the #206 tone).
- env and config are *lenient*, exactly as they already are for every scalar: an
  unparseable value is ignored and the default stays, so no source can inject an
  *invalid* value (there simply is no value), preserving valid-by-construction.

## Consequences

- One way to constrain an existing type (`validate`) and one way to parse a new
  one (`parse`); no DSL, nothing added to a field's type for the former.
- Validation is a single post-resolution sweep beside the ADR-0022 constraint
  walks, reusing the provided-set/config-snapshot machinery — no new state through
  parsing, and no changes to the parse sites or config (the field type is
  unchanged). Two diagnostics join the structured set: `OptionValidationFailed`
  and `ArgumentValidationFailed`.
- Fixed a latent gap found alongside this work: the ADR-0022 constraint errors
  (`OptionMutuallyExclusive`, `OptionMissingDependency`) were absent from the
  clean-exit set, so a violation printed its message *and then* a raw error trace.
  They now exit cleanly like every other reported parse error.
- Custom `parse` types reuse the invalid-value diagnostics (a `reason` field was
  added to `OptionInvalidValue`/`ArgumentInvalidValue`) and extend the three
  string→value sites (`parseOptionValue`, args `parseValue`, `applyEnvValue`) plus
  the config deserializer to construct a type from its string. `expectedTypeName`
  returns a custom type's `hint`. No new diagnostic variant.
- Detection/construction helpers live in `custom_type.zig`, re-exported as
  `zcli.custom_type` so the config plugin (which imports only "zcli") can build a
  custom-typed field the same way the parser does.
