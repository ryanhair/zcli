# zcli-suggestions Plugin

An intelligent command suggestion plugin for zcli applications that provides helpful command suggestions when users make typos or enter unknown commands.

## Features

- **Smart Suggestions**: Uses Levenshtein distance algorithm to find similar commands
- **Configurable Thresholds**: Adjust suggestion sensitivity and limits
- **Error Enhancement**: Transforms error messages to include helpful suggestions
- **Subcommand Support**: Works with both top-level commands and subcommands
- **Performance Optimized**: Efficient distance calculation with configurable limits

## Algorithm

The plugin uses the **Levenshtein distance** algorithm to calculate the minimum number of single-character edits (insertions, deletions, or substitutions) required to change one word into another. This provides accurate similarity matching for command names.

## Commands

### `suggestions show`
Display current suggestion configuration.

```bash
myapp suggestions show
```

### `suggestions configure`
Configure suggestion settings.

```bash
myapp suggestions configure --max-suggestions=5
myapp suggestions configure --max-distance=2
myapp suggestions configure --show-all=false
```

**Options:**
- `--max-suggestions <N>`: Maximum number of suggestions to show (default: 3)
- `--max-distance <N>`: Maximum edit distance for suggestions (default: 3)
- `--show-all <bool>`: Whether to show all available commands (default: true)

### `suggestions test`
Test the suggestion algorithm with sample data.

```bash
myapp suggestions test
```

## Plugin Features

### Error Transformer
Intercepts command not found errors and enhances them with suggestions:

```zig
pub fn transformError(comptime next: anytype) type {
    // Wraps error handling to add intelligent suggestions
}
```

### Context Extension
Stores suggestion-related configuration:

```zig
pub const ContextExtension = struct {
    max_suggestions: usize,
    max_distance: usize,
    show_all_commands: bool,
};
```

## Example Output

**Before (without plugin):**
```
Error: Unknown command 'serach'
Available commands:
    list
    search
    create
    delete
```

**After (with plugin):**
```
Error: Unknown command 'serach'

Did you mean 'search'?

Available commands:
    list
    search
    create
    delete

Run 'myapp --help' to see all available commands.
```

## Usage in zcli Applications

### 1. Add as External Plugin

In your `build.zig`:

```zig
const zcli = @import("zcli");

pub fn build(b: *std.Build) void {
    // ... your build setup ...
    
    zcli.build(b, exe, .{
        .commands_dir = "src/commands",
        .plugins = &.{
            zcli.plugin(b, "zcli-suggestions"),
        },
        .app_name = "myapp",
        .app_version = "1.0.0", 
        .app_description = "My CLI application",
    });
}
```

### 2. Add to build.zig.zon

```zig
.dependencies = .{
    .@"zcli-suggestions" = .{
        .url = "https://github.com/example/zcli-suggestions/archive/v1.0.0.tar.gz",
        .hash = "...",
    },
},
```

### 3. Configuration

The plugin automatically provides intelligent suggestions for command errors. You can configure the behavior using the `suggestions` command or by setting context extension values.

## API Reference

### Core Functions

- `editDistance(a: []const u8, b: []const u8) usize` - Calculate Levenshtein distance
- `findSimilarCommands(input, candidates, allocator) ![][]const u8` - Basic similarity search
- `findSimilarCommandsWithConfig(input, candidates, allocator, max_distance, max_suggestions) ![][]const u8` - Advanced similarity search

### Error Transformers

- `transformError(comptime next: anytype) type` - Error handling wrapper with suggestions

### Context Extension

Provides suggestion-specific configuration and state management.

## Algorithm Details

The Levenshtein distance algorithm:

1. **Matrix Initialization**: Creates a 2D matrix to store distance calculations
2. **Dynamic Programming**: Fills the matrix using optimal substructure
3. **Cost Calculation**: 
   - Deletion: +1
   - Insertion: +1  
   - Substitution: +1 (or 0 if characters match)
4. **Result**: Bottom-right cell contains the final edit distance

**Time Complexity**: O(m×n) where m and n are string lengths  
**Space Complexity**: O(m×n) with current implementation

## Testing

```bash
cd plugins/zcli-suggestions
zig build test
```

Tests cover:
- Levenshtein distance calculation accuracy
- Suggestion generation with various thresholds
- Plugin structure and API contracts
- Edge cases and error handling

## Performance Considerations

- **Maximum String Length**: Limited to 62 characters to prevent excessive memory usage
- **Suggestion Limits**: Configurable to prevent overwhelming output
- **Distance Thresholds**: Tunable to balance accuracy vs. performance
- **Memory Management**: Proper cleanup of allocated suggestion arrays

## License

Same as zcli framework.