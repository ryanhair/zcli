## Project Overview

zcli is a framework for creating CLI applications in Zig. It uses compile-time introspection to automatically discover and wire commands based on folder structure, providing type-safe command handling with zero runtime overhead.

Key features:

- Automatic command discovery from folder structure
- Type-safe argument and option parsing
- Auto-generated help text
- Smart error handling with suggestions
- Global options support
- Build-time code generation for minimal runtime

## Architecture

The framework follows these key principles:

1. **Convention over Configuration**: Commands map directly to file structure

   - `commands/users/list.zig` → `myapp users list`

2. **Build-Time Processing**: A build step scans the commands directory and makes command structure available to comptime

   - No runtime reflection or discovery
   - All routing is static and type-safe

3. **Type-Driven Design**: Command interfaces are defined through Zig types

   - Separate `Args` struct for positional arguments
   - `Options` struct for flags/options
   - Automatic parsing based on types

4. **One Way to Do Things**: Strict conventions to ensure consistency
   - No alternative patterns for the same functionality
   - Compile errors for deviations from conventions

See DESIGN.md for the complete design specification.
