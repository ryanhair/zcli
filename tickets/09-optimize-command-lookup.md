# Ticket 09: Optimize Command Lookup Performance

## Priority
🟡 **Medium**

## Component
`src/registry.zig`, command routing system

## Description
The current command lookup uses O(n) linear search through all available commands, which becomes inefficient for applications with many commands. The current implementation iterates through all commands for each lookup, making it potentially slow for large CLI applications.

## Current Implementation
```zig
// Linear search through all commands (O(n))
for (context.available_commands) |cmd_parts| {
    if (std.mem.eql(u8, cmd_parts[0], attempted_command)) {
        // Found match
    }
}
```

## Performance Analysis

### Current Complexity
- **Command lookup**: O(n) where n = number of commands
- **Suggestion generation**: O(n²) due to edit distance calculation
- **Help generation**: O(n) to find subcommands

### Scaling Issues
- **10 commands**: ~10 comparisons per lookup
- **100 commands**: ~100 comparisons per lookup  
- **1000 commands**: ~1000 comparisons per lookup

### Real-World Impact
Large CLI applications (like AWS CLI with 300+ commands) would see noticeable performance degradation during:
- Command resolution
- Error message generation with suggestions
- Help text generation
- Tab completion (if implemented)

## Proposed Optimization

### 1. Compile-Time Hash Map Generation
```zig
// Generate hash map at compile time
pub fn buildCommandHashMap(comptime commands: []const CommandInfo) type {
    return struct {
        const CommandMap = std.HashMap([]const u8, *const CommandInfo, std.hash_map.StringContext, std.hash_map.default_max_load_percentage);
        
        var map: CommandMap = undefined;
        var initialized = false;
        
        pub fn init(allocator: std.mem.Allocator) !void {
            if (initialized) return;
            
            map = CommandMap.init(allocator);
            inline for (commands) |cmd| {
                try map.put(cmd.name, &cmd);
            }
            initialized = true;
        }
        
        pub fn lookup(name: []const u8) ?*const CommandInfo {
            return map.get(name);
        }
        
        pub fn getAllCommands() []const CommandInfo {
            return commands;
        }
    };
}
```

### 2. Hierarchical Command Tree
```zig
pub const CommandNode = struct {
    name: []const u8,
    command_info: ?*const CommandInfo,  // null for intermediate nodes
    children: std.HashMap([]const u8, *CommandNode, StringContext, default_max_load_percentage),
    
    pub fn lookup(self: *@This(), path: []const []const u8) ?*const CommandInfo {
        if (path.len == 0) return self.command_info;
        
        const child = self.children.get(path[0]) orelse return null;
        return child.lookup(path[1..]);
    }
    
    pub fn findSimilar(self: *@This(), name: []const u8, max_distance: usize) []const []const u8 {
        var suggestions = std.ArrayList([]const u8).init(allocator);
        defer suggestions.deinit();
        
        var iterator = self.children.iterator();
        while (iterator.next()) |entry| {
            const distance = levenshteinDistance(name, entry.key_ptr.*);
            if (distance <= max_distance) {
                try suggestions.append(entry.key_ptr.*);
            }
        }
        
        return suggestions.toOwnedSlice();
    }
};
```

### 3. Optimized Suggestion Generation
```zig
pub const SuggestionCache = struct {
    // Pre-computed similarity groups
    similarity_groups: []const []const []const u8,
    
    pub fn init(comptime commands: []const CommandInfo) @This() {
        // Group similar commands at compile time
        const groups = comptime blk: {
            var result: []const []const []const u8 = &.{};
            
            for (commands) |cmd| {
                const similar = findSimilarCommands(cmd.name, commands);
                result = result ++ .{similar};
            }
            
            break :blk result;
        };
        
        return .{ .similarity_groups = groups };
    }
    
    pub fn getSuggestions(self: @This(), name: []const u8, max_suggestions: usize) []const []const u8 {
        // O(1) lookup into pre-computed groups instead of O(n²) calculation
        const hash = std.hash_map.hashString(name);
        const group_index = hash % self.similarity_groups.len;
        const suggestions = self.similarity_groups[group_index];
        
        return suggestions[0..@min(suggestions.len, max_suggestions)];
    }
};
```

## Implementation Strategy

### Phase 1: Basic Hash Map (Week 1)
- [ ] Implement compile-time command hash map generation
- [ ] Replace linear search with hash map lookup
- [ ] Update command registration to populate hash map
- [ ] Performance testing and benchmarking

### Phase 2: Hierarchical Commands (Week 2)
- [ ] Implement command tree structure
- [ ] Support nested command lookup (e.g., `docker container ls`)
- [ ] Update help generation to use tree structure
- [ ] Add tree-based command completion support

### Phase 3: Suggestion Optimization (Week 3)
- [ ] Implement suggestion caching system
- [ ] Pre-compute similarity groups at compile time
- [ ] Optimize Levenshtein distance calculation
- [ ] Add fuzzy matching improvements

### Phase 4: Advanced Features (Week 4)
- [ ] Command aliasing support
- [ ] Partial command matching (e.g., `cont` → `container`)
- [ ] Context-aware suggestions
- [ ] Performance monitoring and metrics

## Detailed Implementation

### Compile-Time Command Map
```zig
pub fn Registry(comptime commands: []const CommandInfo, comptime plugins: []const type) type {
    return struct {
        const Self = @This();
        const CommandMap = buildCommandHashMap(commands);
        
        map: CommandMap,
        
        pub fn init(allocator: std.mem.Allocator) !Self {
            var self = Self{
                .map = undefined,
            };
            
            try CommandMap.init(allocator);
            return self;
        }
        
        pub fn findCommand(self: *Self, path: []const []const u8) ?*const CommandInfo {
            if (path.len == 0) return null;
            
            // O(1) lookup instead of O(n) scan
            return CommandMap.lookup(path[0]);
        }
        
        pub fn findSimilarCommands(self: *Self, name: []const u8) ![]const []const u8 {
            // Use optimized suggestion system
            return self.suggestion_cache.getSuggestions(name, 5);
        }
    };
}
```

### Memory-Efficient Tree Structure
```zig
// Use arena allocator for command tree to avoid fragmentation
pub const CommandTree = struct {
    arena: std.heap.ArenaAllocator,
    root: *CommandNode,
    
    pub fn init(allocator: std.mem.Allocator, commands: []const CommandInfo) !@This() {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const arena_allocator = arena.allocator();
        
        const root = try arena_allocator.create(CommandNode);
        root.* = CommandNode{
            .name = "",
            .command_info = null,
            .children = std.HashMap([]const u8, *CommandNode, StringContext, default_max_load_percentage).init(arena_allocator),
        };
        
        // Build tree from commands
        for (commands) |cmd| {
            try insertCommand(root, cmd, arena_allocator);
        }
        
        return .{
            .arena = arena,
            .root = root,
        };
    }
    
    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
    }
};
```

## Benchmarking Strategy

### Performance Test Suite
```zig
const std = @import("std");
const testing = std.testing;

test "command lookup performance" {
    const allocator = testing.allocator;
    
    // Generate large command set for testing
    const commands = try generateTestCommands(allocator, 1000);
    defer allocator.free(commands);
    
    var timer = try std.time.Timer.start();
    
    // Benchmark linear search (current)
    timer.reset();
    for (0..1000) |_| {
        _ = linearCommandLookup(commands, "test-command-500");
    }
    const linear_time = timer.read();
    
    // Benchmark hash map lookup (proposed)
    timer.reset();
    for (0..1000) |_| {
        _ = hashMapCommandLookup(commands, "test-command-500");
    }
    const hashmap_time = timer.read();
    
    std.log.info("Linear search: {}ns per lookup", .{linear_time / 1000});
    std.log.info("Hash map search: {}ns per lookup", .{hashmap_time / 1000});
    std.log.info("Speedup: {}x", .{linear_time / hashmap_time});
    
    // Hash map should be significantly faster
    try testing.expect(hashmap_time < linear_time / 2);
}
```

### Memory Usage Analysis
```zig
test "memory overhead analysis" {
    const allocator = testing.allocator;
    
    const commands = try generateTestCommands(allocator, 100);
    defer allocator.free(commands);
    
    // Measure linear approach memory
    const linear_memory = getCurrentMemoryUsage();
    const linear_registry = try createLinearRegistry(allocator, commands);
    defer linear_registry.deinit();
    const linear_overhead = getCurrentMemoryUsage() - linear_memory;
    
    // Measure hash map approach memory
    const hashmap_memory = getCurrentMemoryUsage();
    const hashmap_registry = try createHashMapRegistry(allocator, commands);
    defer hashmap_registry.deinit();
    const hashmap_overhead = getCurrentMemoryUsage() - hashmap_memory;
    
    std.log.info("Linear registry memory: {} bytes", .{linear_overhead});
    std.log.info("Hash map registry memory: {} bytes", .{hashmap_overhead});
    std.log.info("Memory overhead: {}%", .{(hashmap_overhead * 100) / linear_overhead});
    
    // Memory overhead should be reasonable (< 50% increase)
    try testing.expect(hashmap_overhead < linear_overhead * 1.5);
}
```

## Configuration Options

### Build-Time Optimization Control
```zig
// In build.zig
const cmd_registry = zcli.build(b, exe, zcli_module, .{
    .optimization = .{
        .command_lookup = .hash_map,  // or .linear, .tree
        .suggestion_caching = true,
        .max_suggestions = 10,
        .suggestion_threshold = 3,    // Max edit distance
    },
});
```

### Runtime Performance Monitoring
```zig
pub const PerformanceMetrics = struct {
    command_lookups: usize = 0,
    suggestion_generations: usize = 0,
    total_lookup_time_ns: u64 = 0,
    total_suggestion_time_ns: u64 = 0,
    
    pub fn averageLookupTime(self: @This()) f64 {
        if (self.command_lookups == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_lookup_time_ns)) / @as(f64, @floatFromInt(self.command_lookups));
    }
    
    pub fn logMetrics(self: @This()) void {
        std.log.info("Command lookup metrics:");
        std.log.info("  Lookups: {d}", .{self.command_lookups});
        std.log.info("  Avg time: {d:.2}ns", .{self.averageLookupTime()});
        std.log.info("  Suggestions: {d}", .{self.suggestion_generations});
    }
};
```

## Backward Compatibility

### API Compatibility
```zig
// Maintain existing API while adding optimizations
pub fn Registry(comptime commands: []const CommandInfo, comptime plugins: []const type) type {
    return struct {
        // ... optimized implementation
        
        // Keep old method signatures for compatibility
        pub fn findCommand(self: *@This(), path: []const []const u8) ?*const CommandInfo {
            return self.optimizedFindCommand(path);  // Delegate to optimized version
        }
    };
}
```

## Impact Assessment
- **Performance**: 10-100x improvement in command lookup (depending on command count)
- **Memory**: 20-50% increase in memory usage for hash maps
- **Compatibility**: No breaking changes to existing APIs
- **Build Time**: Slight increase due to compile-time optimization

## Acceptance Criteria
- [ ] Command lookup time scales O(1) instead of O(n)
- [ ] Suggestion generation time improved by at least 50%
- [ ] Memory overhead < 50% for typical use cases
- [ ] All existing functionality preserved
- [ ] Performance benchmarks show expected improvements
- [ ] No regression in build times

## Estimated Effort
**3-4 weeks** (1 week per phase with overlap for testing and optimization)