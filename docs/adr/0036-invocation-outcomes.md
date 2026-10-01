# Invocation outcomes, failure policy, and plugin lifecycle

Status: accepted

A command or plugin returns an ordinary Zig error. That error alone does not say
whether the user supplied invalid arguments, a domain operation failed, or an
unexpected implementation error occurred. Nor does printing an explanation turn a
failed operation into a successful one.

The former registry mixed these decisions. It classified framework failures by
error name, printed some diagnostics before plugins could select a renderer, and
used an `onError` boolean both for successful help handling and failed operations
whose explanation had been rendered. Application plugins consequently used
`context.exit()` to preserve their failure status, skipping normal unwinding.
Several setup hooks bypassed the error hook entirely. `preExecute` also ran before
typed command validation, allowing an invalid invocation to start services.

## Decision

### One engine, explicit outcomes

The registry owns one invocation engine. An invocation returns success,
informational completion, or a structured failure. A failure records its category,
underlying error, lifecycle stage, origin, diagnostic, and application explanation.
The category is assigned where the failure is discovered; a command returning
`error.OptionUnknown` does not thereby become a framework parsing failure.

The non-exiting invocation interface is the production interface used by integration
tests. The process entry point translates its result into an exit status. Existing
error-returning execution interfaces project the same result back into an error
union; they do not implement another lifecycle.

The returned result owns retained invocation storage and must be deinitialized.
Context and plugin cleanup finishes before the result is returned. Diagnostic data
borrowed from argv or environment is retained safely rather than pointing into a
destroyed context. No stack-owned context, stream, or error-trace pointer may escape
through the result. This extends the arena-per-invocation ownership in ADR-0001.

### Describe, assign status, render

These are separate operations:

1. Describe a failure with an optional stable identity, explanation, and details.
2. Apply the application's numeric exit policy.
3. Render once using the selected renderer, falling back to human diagnostics.

Framework defaults remain usage 2, unknown command 3, and reported application
failure 1. Applications can change those categories without duplicating an internal
error list. Error mappings can be scoped by origin; a deliberately global mapping
is an application decision. Plugins may describe their failures, but the application
owns process-wide numeric policy. Framework provenance outranks broad error-name
rules, and ambiguous mappings must not depend on declaration order.

`context.fail()` records an explanation and returns an error. It does not print
immediately. Rendering or deliberately suppressing output never changes a failure
into success. Successful short-circuiting, including help and version, has an
explicit informational outcome. Arbitrary recovery and resumption of a failed
lifecycle stage is not part of this decision.

Renderer failure must not append a fallback explanation to a partially emitted
structured document. Description, completion, and rendering failures cannot hide
the primary failure. Classified statuses retain precedence over failed diagnostic
writes; otherwise broken-pipe and final-flush integrity retain their established
behavior.

### Separate input work from operational work

The lifecycle distinguishes argument transformation, global handling, routing,
informational handling, typed parsing, input configuration/resolution, validation,
operational preparation, execution, and finalization. These are internal stages,
not a requirement for a public hook at every step.

Help and version complete before application configuration, stdin resolution, or
operational preparation. Configuration supplying option values runs before resolved
validation. Authentication, service connections, and daemon startup belong after
validation. Raw-argument mutation belongs to transformation hooks, not preparation.

All fallible stages enter the common failure path. Completion continues after an
individual completion hook fails. Such a failure becomes primary only if there was
no previous failure. Resource teardown remains unconditional and safe on default
plugin state. Hooks requiring initialized plugin state must not run against an
unsafe partially initialized value.

The input configuration stage preserves ADR-0022's supplied-value constraints,
ADR-0025's resolved-value validation, and ADR-0032's config precedence and
`no_config` enforcement.

Command-scoped status rules use the canonical registered command path. Aliases
therefore share the target's failure policy, while retained diagnostics keep the
invoked path. Completion and reporting hooks cannot retarget an existing failure
by changing context routing fields.

### Global output selection has a defined availability point

Global option conversion precedes global handler dispatch. Application rendering
based on global state is available after global handling succeeds. Earlier failures
use the default renderer. This avoids output changing merely because `--json`
appeared before or after another malformed global option.

Guaranteeing JSON for failures before global parsing would require a separate
output-mode input or a dedicated early parsing contract. An informal second argv
scan is not part of this design.

### Test the actual invocation

The typed `runCommand` harness remains a command-body test. A separate invocation
harness accepts argv, environment, and stdin, captures output, and returns the
production outcome and status. Process tests verify the final exit boundary; PTY
tests verify interactions requiring a terminal. Tests do not reimplement routing,
resolution, hook sequencing, or error classification.

## Migration and consequences

This is a minor-release breaking change. Legacy `onError` suppression cannot be
silently redefined to mean rendering. Built-in help/version, config, not-found, and
upgrade handling migrate with the registry. Plugin authors receive explicit
migration instructions for informational completion, input loading, preparation,
and failure description/rendering.

`context.exit()` remains an immediate escape hatch and cannot promise normal
cleanup or in-process interception. Normal framework-owned paths return outcomes
instead. Application commands continue to use ordinary Zig errors and do not need
to construct registry outcomes themselves.
