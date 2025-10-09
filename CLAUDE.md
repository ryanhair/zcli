# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# Zig standards

Don't add a line like `_ = some_param` for unused parameters, just set the unused parameter to `_` directly in the function declaration.

Unit tests should always be in the source file that most relates to what is being tested. Integration and e2e tests can be an exception, when the concerns of the tests cross boundaries.

## Development Commands

```bash
# Build the zcli library
zig build

# Run tests
zig build test
```
