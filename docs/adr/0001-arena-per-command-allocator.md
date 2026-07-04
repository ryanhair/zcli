# Arena-per-command allocator for `execute()`

Status: accepted

To make AI-authored business logic safe by construction, each command's `execute()` will receive an allocator backed by an arena that is dropped wholesale when the command returns, rather than today's raw pass-through `std.mem.Allocator` (see `packages/core/src/zcli.zig` `Context.allocator`). CLIs are the textbook arena case: a command runs once and exits, so there is essentially no long-lived intra-command state needing fine-grained `free`. The idiom becomes *"never call `free`; the arena reclaims everything at command end,"* which neutralizes the one failure mode of AI-generated Zig that is simultaneously silent, undebuggable by our non-Zig-fluent wedge user, and specific to Zig's manual-memory model: leaks and use-after-free. The other failure modes have owners (compiler for non-compiling code, tests for wrong behavior, shipped context/lint for non-idiomatic code); memory had none until this decision.

## Considered Options

- **Raw pass-through allocator (status quo)** — maximal control, but every `execute()` must manually free; AI-written bodies leak or use-after-free in ways that compile clean and pass happy-path tests. Rejected: pushes the scariest failure onto the user.
- **Arena-per-command (chosen)** — safe by default, "no frees" idiom.

## Consequences

- Long-running commands (`watch`/`dev`-style loops) would grow the arena unbounded; the idiom must document a child-arena-per-iteration pattern for that advanced case.
- Does not stop deliberate `free` misuse (covered by idiom/lint) or logic-level pointer bugs (rare in CLI work).
- Hard to reverse once command authors rely on the "no free" contract — every generated and hand-written command assumes it.
