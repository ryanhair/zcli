# Explicit stdin sources for text options

Status: accepted (implemented)

## Context

Commands that accept prose need to support pipelines without each command
recognizing `-`, buffering stdin, and reproducing size-limit diagnostics. Reading
inside the option parser would make a pure argument operation perform blocking I/O
and make environment or config defaults unexpectedly consume a stream.

## Decision

A scalar `[]const u8` or `?[]const u8` option can declare `.stdin = true` in its
option metadata. Only an explicit final CLI value of `-` requests stdin. The parser
records a per-field bit alongside the typed values; it does not read input.

Invocation resolution applies configuration, rejects multiple final consumers,
then reads stdin once before content validation and operational preparation. A
later scalar occurrence replaces an earlier value and its source request: `--body
- --body text` never reads stdin. All long, short, attached, equals, and bundled
spellings share this behavior.

The result preserves every byte, including empty input, carriage returns, and
final newlines. The application can set `stdin_max_bytes`; its default is 16 MiB.
Exactly the configured limit is accepted. A zero limit accepts only empty input.
Multiple consumers and oversized input are usage failures; failed reads are I/O
failures. Duplicate requests are rejected before consuming any bytes.

Config, environment, and default `-` values are always literal. An option without
`.stdin = true` also receives a literal hyphen. To provide a literal hyphen to an
enabled option, pipe it: `printf '%s' '-' | app --body -`. The resolved content is
never interpreted again as another input source.

## Consequences

- Help/version return without consuming stdin. Ordinary syntax failures precede
  resolution. Content validators inspect the resolved bytes.
- Invocation tests use the production lifecycle with injected stdin. Direct
  typed command tests keep their existing purpose and receive resolved strings.
- The parser remains usable without context or streams.
- Stdin resolution returns an owned buffer with an explicit lifetime. Context's
  invocation allocator normally owns that buffer until invocation cleanup.
