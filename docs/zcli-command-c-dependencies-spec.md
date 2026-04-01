# zcli Enhancement Specification: Per-Command C Dependencies

## Overview

This specification describes an enhancement to zcli to support per-command C source dependencies, enabling commands that require C libraries (like tree-sitter) to be integrated into the CLI without affecting other commands.

## Problem Statement

Currently, zcli's `shared_modules` system makes modules available to all commands. When a module uses `@cImport` to interface with C code, it requires:
1. C header files via `addIncludePath()`
2. C source files via `addCSourceFile()` or `addCSourceFiles()`
3. `linkLibC()` to be called

If these dependencies are only added to the main executable (as currently required), then making the module a shared_module causes compilation failures because the module code tries to import C headers that aren't available during module compilation.

### Current Workaround Limitations

The current workaround requires:
- Not making C-dependent modules shared modules
- Each command importing the module independently
- Duplicating C dependency configuration across multiple command files

This breaks the encapsulation and reusability that shared_modules provides.

## Proposed Solution

Add support for per-command module configurations that include C dependencies, allowing commands to declare both their module dependencies AND the C dependencies those modules require.

## API Design

### New Types

```zig
/// Per-command module configuration with optional C dependencies
pub const CommandModule = struct {
    /// Module name for import
    name: []const u8,

    /// The module itself
    module: *std.Build.Module,

    /// Optional C source files needed by this module
    c_sources: ?[]const []const u8 = null,

    /// Optional C compiler flags
    c_flags: ?[]const []const u8 = null,

    /// Optional include paths for C headers
    include_paths: ?[]const []const u8 = null,

    /// Whether to link libc (default: true if any C dependencies specified)
    link_libc: ?bool = null,
};

/// Configuration for a specific command
pub const CommandConfig = struct {
    /// Name of the command (matches filename without .zig)
    command_name: []const u8,

    /// Modules specific to this command with their C dependencies
    modules: []const CommandModule = &.{},
};
```

### Updated GenerateOptions

```zig
pub const GenerateOptions = struct {
    commands_dir: []const u8 = "src/commands",
    shared_modules: []const SharedModule = &.{},

    /// NEW: Per-command module configurations
    command_configs: []const CommandConfig = &.{},

    plugins: []const Plugin = &.{},
    app_name: []const u8,
    app_description: []const u8,
};
```

## Usage Example

```zig
// In build.zig

// Create discovery module (uses tree-sitter C library)
const discovery_module = b.createModule(.{
    .root_source_file = b.path("src/discovery.zig"),
    .imports = &.{
        // Other dependencies...
    },
});

// Generate command registry with per-command C dependencies
const cmd_registry = zcli.generate(b, exe, zcli_dep, zcli_module, .{
    .commands_dir = "src/commands",
    .shared_modules = &[_]zcli.SharedModule{
        .{ .name = "yaml", .module = yaml_module },
        .{ .name = "sources", .module = sources_module },
        // Note: discovery is NOT a shared module
    },

    // NEW: Configure discover command with C dependencies
    .command_configs = &[_]zcli.CommandConfig{
        .{
            .command_name = "discover",
            .modules = &[_]zcli.CommandModule{
                .{
                    .name = "discovery",
                    .module = discovery_module,
                    .c_sources = &.{
                        "vendor/tree-sitter/lib/src/lib.c",
                        "vendor/tree-sitter-javascript/src/parser.c",
                        "vendor/tree-sitter-javascript/src/scanner.c",
                        "vendor/tree-sitter-python/src/parser.c",
                        "vendor/tree-sitter-python/src/scanner.c",
                    },
                    .c_flags = &.{"-std=c11"},
                    .include_paths = &.{"vendor/tree-sitter/lib/include"},
                    .link_libc = true,
                },
            },
        },
    },

    .plugins = &.{ /* ... */ },
    .app_name = "configflow",
    .app_description = "Type-safe configuration management",
});
```

## Implementation Details

### 1. Command Module Compilation

When zcli generates a command module wrapper, it should:

```zig
// For each command in command_configs
for (options.command_configs) |cmd_config| {
    const cmd_module = b.createModule(.{
        .root_source_file = generated_command_file,
        .target = target,
        .optimize = optimize,
        .imports = &imports, // Includes shared_modules + command-specific modules
    });

    // Apply C dependencies for this command's modules
    for (cmd_config.modules) |module_config| {
        if (module_config.link_libc) |should_link| {
            if (should_link) cmd_module.linkLibC();
        } else if (module_config.c_sources != null or
                   module_config.include_paths != null) {
            cmd_module.linkLibC();
        }

        if (module_config.include_paths) |paths| {
            for (paths) |path| {
                cmd_module.addIncludePath(b.path(path));
            }
        }

        if (module_config.c_sources) |sources| {
            const flags = module_config.c_flags orelse &.{};
            for (sources) |source| {
                cmd_module.addCSourceFile(.{
                    .file = b.path(source),
                    .flags = flags,
                });
            }
        }
    }
}
```

### 2. Module Import Generation

The generated command module should include both shared modules and command-specific modules:

```zig
// Generated src/commands/__generated__/discover.zig
const std = @import("std");
const zcli = @import("zcli");
const discover = @import("../../discover.zig");

// Shared modules available to all commands
const yaml = @import("yaml");
const sources = @import("sources");

// Command-specific modules
const discovery = @import("discovery");

pub fn execute(context: *zcli.Context) !void {
    return discover.execute(
        context.args,
        context.options,
        context,
    );
}
```

### 3. Main Executable Coordination

The main executable should NOT need C dependencies for commands that use them. Each command module is independently compiled with its own dependencies.

However, if command modules need to be linked into the final executable, the main executable build step should aggregate all C dependencies from command_configs:

```zig
// Collect all unique C dependencies from command configs
var all_c_sources = std.StringArrayHashMap(void).init(allocator);
var all_include_paths = std.StringArrayHashMap(void).init(allocator);
var needs_libc = false;

for (options.command_configs) |cmd_config| {
    for (cmd_config.modules) |module_config| {
        if (module_config.link_libc orelse false) {
            needs_libc = true;
        }
        if (module_config.c_sources) |sources| {
            for (sources) |src| try all_c_sources.put(src, {});
        }
        if (module_config.include_paths) |paths| {
            for (paths) |path| try all_include_paths.put(path, {});
        }
    }
}

if (needs_libc) exe.linkLibC();
// Apply aggregated dependencies to exe...
```

## Edge Cases and Considerations

### 1. Conflicting C Dependencies

If multiple commands require different versions of the same C library, this is a build system limitation. The specification should document:
- All C dependencies are linked into the final executable
- Version conflicts must be resolved at the project level
- Consider using different library names or prefixes for conflicting libraries

### 2. Command Module Caching

Zig's build system may cache compiled modules. Ensure that:
- Module cache keys include C dependency information
- Changing C sources triggers module recompilation

### 3. Cross-Compilation

C dependencies may have platform-specific requirements:
- Support platform-conditional C sources in CommandModule
- Document that users are responsible for cross-platform C compatibility

### 4. Performance Impact

Adding C dependencies increases compilation time:
- Only commands that import C-dependent modules pay the cost
- Consider lazy compilation strategies if zcli supports them

## Testing Strategy

### Unit Tests

1. **Basic C dependency integration**
   - Create test command with simple C source
   - Verify it compiles and runs
   - Verify other commands are unaffected

2. **Multiple C sources**
   - Test command with multiple C files
   - Verify include paths work correctly
   - Test with different C flags

3. **Mixed commands**
   - CLI with both C-dependent and pure Zig commands
   - Verify isolation between command dependencies

### Integration Tests

1. **Real tree-sitter integration**
   - Use actual tree-sitter library as test case
   - Verify parsing functionality works
   - Verify no impact on other commands

2. **Build system validation**
   - Test incremental builds
   - Test clean builds
   - Verify caching behavior

## Migration Path

### Phase 1: Add API (Non-Breaking)
- Add `CommandModule` and `CommandConfig` types
- Add `command_configs` to `GenerateOptions`
- Implement C dependency handling in generate()
- Existing code continues working (empty command_configs)

### Phase 2: Documentation
- Document new API in zcli README
- Provide migration examples
- Document limitations and edge cases

### Phase 3: Adoption
- Update existing projects to use new API
- Gather feedback and iterate

## Alternative Approaches Considered

### Alternative 1: Global C Dependencies
**Approach**: Add C dependencies to all commands globally
**Rejected**: Causes unnecessary dependencies for commands that don't need them, increases build time

### Alternative 2: Command-Level Build Hooks
**Approach**: Let commands define custom build hooks
**Rejected**: Too flexible, breaks zcli's declarative model, harder to maintain

### Alternative 3: C Library Modules
**Approach**: Wrap C libraries in separate Zig modules with their own build.zig
**Rejected**: More complex for users, doesn't solve the sharing problem

## Open Questions

1. Should `CommandModule` support system library linking (e.g., `-lsqlite3`)?
   - **Recommendation**: Yes, add optional `system_libs: ?[]const []const u8` field

2. Should C dependencies be automatically deduped across commands?
   - **Recommendation**: Yes, but document that flags must match

3. How to handle C++ sources (`.cpp`, `.cc`)?
   - **Recommendation**: Add optional `cpp_sources` field and `cpp_flags`

## Documentation Requirements

The following documentation should be added to zcli:

1. **README section**: "Commands with C Dependencies"
2. **API reference**: Full documentation of `CommandModule` and `CommandConfig`
3. **Example**: Complete working example using tree-sitter or similar C library
4. **Migration guide**: For projects that currently work around this limitation
5. **Troubleshooting**: Common issues with C dependencies and include paths

## Success Criteria

This feature is considered successful when:

1. Commands can declare C dependencies without affecting other commands
2. ConfigFlow's discover command can be integrated using this API
3. Build times for non-C commands remain unchanged
4. Documentation is clear and includes working examples
5. No breaking changes to existing zcli API

## Implementation Checklist

- [ ] Add `CommandModule` and `CommandConfig` types to zcli
- [ ] Update `GenerateOptions` with `command_configs` field
- [ ] Implement C dependency application in command module generation
- [ ] Add C dependency aggregation for main executable
- [ ] Write unit tests for C dependency handling
- [ ] Write integration test with real C library (tree-sitter)
- [ ] Document new API in README
- [ ] Create example project demonstrating usage
- [ ] Update ConfigFlow to use new API
- [ ] Validate no performance regression for existing projects

## References

- **Zig Build System**: https://ziglang.org/documentation/master/#Build-System
- **Tree-sitter**: https://tree-sitter.github.io/tree-sitter/
- **ConfigFlow Issue**: Context from this debugging session
- **zcli Repository**: [Add link when available]
