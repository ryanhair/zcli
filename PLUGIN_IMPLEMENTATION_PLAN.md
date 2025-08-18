# zcli Plugin System Implementation Plan

## Overview

Implementation plan for the comptime transformer-based plugin system. This will be built incrementally, starting with core infrastructure and building up to full plugin capabilities.

## Phase 1: Core Infrastructure (Week 1)

### Day 1-2: Plugin Discovery and Build Integration

#### 1.1 Build System Updates
```zig
// src/build_utils.zig - Add plugin discovery
pub const PluginInfo = struct {
    name: []const u8,
    import_name: []const u8,
    is_local: bool,
    dependency: ?*std.Build.Dependency,
};

pub fn plugin(b: *std.Build, name: []const u8) PluginInfo {
    return PluginInfo{
        .name = name,
        .import_name = name,
        .is_local = false,
        .dependency = b.lazyDependency(name, .{}),
    };
}

pub fn scanLocalPlugins(b: *std.Build, plugins_dir: []const u8) ![]PluginInfo {
    // Scan src/plugins/ directory like we do for commands
    // Return array of local plugin info
}
```

#### 1.2 Enhanced Build Function
```zig
// src/build_utils.zig - Enhanced build with plugin support
pub const BuildConfig = struct {
    commands_dir: []const u8 = "src/commands",
    plugins_dir: ?[]const u8 = null,
    plugins: ?[]const PluginInfo = null,
    app_name: []const u8,
    version: []const u8,
};

pub fn build(b: *std.Build, exe: *std.Build.Step.Compile, config: BuildConfig) void {
    // 1. Discover local plugins
    const local_plugins = if (config.plugins_dir) |dir| 
        scanLocalPlugins(b, dir) catch &.{}
    else 
        &.{};
    
    // 2. Combine with external plugins
    const all_plugins = combinePlugins(b, local_plugins, config.plugins orelse &.{});
    
    // 3. Add plugin modules to executable
    addPluginModules(b, exe, all_plugins);
    
    // 4. Generate plugin registry
    generateRegistry(b, exe, config, all_plugins);
}
```

### Day 3-4: Basic Code Generation

#### 1.3 Registry Generator Core
```zig
// src/build_utils.zig - Registry generation
fn generateRegistry(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    config: BuildConfig,
    plugins: []const PluginInfo,
) void {
    const generated_file = b.addWriteFiles();
    
    var buffer = std.ArrayList(u8).init(b.allocator);
    const writer = buffer.writer();
    
    // Generate imports
    try generateImports(writer, plugins);
    
    // Generate Context
    try generateContext(writer, config, plugins);
    
    // Generate Commands registry  
    try generateCommands(writer, config, plugins);
    
    // Write file
    _ = generated_file.add("zcli_generated.zig", buffer.items);
    exe.root_module.addAnonymousImport("zcli_generated", .{
        .root_source_file = generated_file.files.items[0].getPath(),
    });
}
```

#### 1.4 Context Generation
```zig
fn generateContext(
    writer: anytype,
    config: BuildConfig,
    plugins: []const PluginInfo,
) !void {
    try writer.writeAll(
        \\pub const Context = struct {
        \\    allocator: std.mem.Allocator,
        \\    io: zcli.IO,
        \\    env: zcli.Environment,
        \\
    );
    
    // Generate extension fields (only for plugins that have them)
    for (plugins) |plugin| {
        try writer.print(
            \\    {s}: if (@hasDecl({s}, "ContextExtension")) {s}.ContextExtension else struct {{}},
            \\
        , .{plugin.name, plugin.import_name, plugin.import_name});
    }
    
    // Generate init function
    try generateContextInit(writer, plugins);
    
    try writer.writeAll("};\n\n");
}

fn generateContextInit(writer: anytype, plugins: []const PluginInfo) !void {
    try writer.writeAll(
        \\
        \\    pub fn init(allocator: std.mem.Allocator) !@This() {
        \\        var self = @This(){
        \\            .allocator = allocator,
        \\            .io = zcli.IO.init(),
        \\            .env = zcli.Environment.init(),
        \\
    );
    
    for (plugins) |plugin| {
        try writer.print(
            \\            .{s} = if (@hasDecl({s}, "ContextExtension")) 
            \\                try {s}.ContextExtension.init(allocator) 
            \\            else .{{}},
            \\
        , .{plugin.name, plugin.import_name, plugin.import_name});
    }
    
    try writer.writeAll(
        \\        };
        \\        return self;
        \\    }
        \\
        \\    pub fn deinit(self: *@This()) void {
        \\
    );
    
    for (plugins) |plugin| {
        try writer.print(
            \\        if (@hasDecl({s}, "ContextExtension")) {{
            \\            if (@hasDecl({s}.ContextExtension, "deinit")) {{
            \\                self.{s}.deinit();
            \\            }}
            \\        }}
            \\
        , .{plugin.import_name, plugin.import_name, plugin.name});
    }
    
    try writer.writeAll("    }\n");
}
```

### Day 5: Command Registry Integration

#### 1.5 Commands Generation
```zig
fn generateCommands(
    writer: anytype,
    config: BuildConfig,
    plugins: []const PluginInfo,
) !void {
    try writer.writeAll("pub const Commands = struct {\n");
    
    // Import native commands
    const commands = try scanCommands(config.commands_dir);
    try generateCommandImports(writer, commands);
    
    // Import plugin commands using usingnamespace
    for (plugins) |plugin| {
        try writer.print(
            \\    pub usingnamespace if (@hasDecl({s}, "commands")) {s}.commands else struct {{}};
            \\
        , .{plugin.import_name, plugin.import_name});
    }
    
    try writer.writeAll("};\n\n");
}
```

### Day 6-7: Testing and Integration

#### 1.6 Basic Integration Test
```zig
// test/plugin_basic_test.zig
const std = @import("std");
const zcli = @import("zcli");

// Simple test plugin
const TestPlugin = struct {
    pub const ContextExtension = struct {
        test_value: i32 = 42,
        
        pub fn init(allocator: std.mem.Allocator) !@This() {
            _ = allocator;
            return .{};
        }
    };
    
    pub const commands = struct {
        pub const test_cmd = struct {
            pub fn execute(ctx: anytype) !void {
                try ctx.io.stdout.print("Test: {}\n", .{ctx.test_plugin.test_value});
            }
        };
    };
};

test "basic plugin integration" {
    // Test that generated registry works with test plugin
}
```

## Phase 2: Command Pipeline Transformers (Week 2)

### Day 8-9: Pipeline Infrastructure

#### 2.1 Base Command Executor
```zig
// src/execution.zig - Base command execution
pub const BaseCommandExecutor = struct {
    pub fn execute(ctx: anytype, args: anytype) !void {
        // Core command execution logic
        const command_name = @typeName(@TypeOf(args));
        
        // Look up command in registry and execute
        try executeCommand(ctx, command_name, args);
    }
};
```

#### 2.2 Pipeline Composition Generator
```zig
fn generateCommandPipeline(writer: anytype, plugins: []const PluginInfo) !void {
    try writer.writeAll(
        \\pub const CommandPipeline = comptime blk: {{
        \\    var pipeline_type = zcli.BaseCommandExecutor;
        \\
    );
    
    // Chain transformers in reverse order (last plugin wraps first)
    for (plugins) |plugin| {
        try writer.print(
            \\    if (@hasDecl({s}, "transformCommand")) {{
            \\        pipeline_type = {s}.transformCommand(pipeline_type);
            \\    }}
            \\
        , .{plugin.import_name, plugin.import_name});
    }
    
    try writer.writeAll(
        \\    break :blk pipeline_type;
        \\}};
        \\
        \\pub const command_pipeline = CommandPipeline{{}};
        \\
    );
}
```

### Day 10-11: Error Pipeline

#### 2.3 Error Handler Pipeline
```zig
fn generateErrorPipeline(writer: anytype, plugins: []const PluginInfo) !void {
    try writer.writeAll(
        \\pub const ErrorPipeline = comptime blk: {{
        \\    var pipeline_type = zcli.BaseErrorHandler;
        \\
    );
    
    for (plugins) |plugin| {
        try writer.print(
            \\    if (@hasDecl({s}, "transformError")) {{
            \\        pipeline_type = {s}.transformError(pipeline_type);
            \\    }}
            \\
        , .{plugin.import_name, plugin.import_name});
    }
    
    try writer.writeAll(
        \\    break :blk pipeline_type;
        \\}};
        \\
        \\pub const error_pipeline = ErrorPipeline{{}};
        \\
    );
}
```

### Day 12-14: Help Pipeline and Integration

#### 2.4 Help System Pipeline
```zig
fn generateHelpPipeline(writer: anytype, plugins: []const PluginInfo) !void {
    try writer.writeAll(
        \\pub const HelpPipeline = comptime blk: {{
        \\    var pipeline_type = zcli.BaseHelpGenerator;
        \\
    );
    
    for (plugins) |plugin| {
        try writer.print(
            \\    if (@hasDecl({s}, "transformHelp")) {{
            \\        pipeline_type = {s}.transformHelp(pipeline_type);
            \\    }}
            \\
        , .{plugin.import_name, plugin.import_name});
    }
    
    try writer.writeAll(
        \\    break :blk pipeline_type;
        \\}};
        \\
        \\pub const help_pipeline = HelpPipeline{{}};
        \\
    );
}
```

## Phase 3: Essential Plugins (Week 3)

### Day 15-17: Help Plugin Extraction

#### 3.1 Create zcli-help Plugin
```zig
// zcli-help/src/plugin.zig
const std = @import("std");
const zcli = @import("zcli");

pub const commands = struct {
    pub const help = struct {
        pub const Args = struct {
            command: ?[]const u8 = null,
        };
        
        pub const meta = .{
            .description = "Show help for commands",
        };
        
        pub fn execute(ctx: anytype, args: Args) !void {
            if (args.command) |cmd| {
                try showCommandHelp(ctx, cmd);
            } else {
                try showAppHelp(ctx);
            }
        }
    };
};

pub fn transformCommand(comptime next: anytype) type {
    return struct {
        pub fn execute(ctx: anytype, args: anytype) !void {
            // Check for global --help flag
            if (hasHelpFlag(args)) {
                try showHelp(ctx, @typeName(@TypeOf(args)));
                return;
            }
            try next.execute(ctx, args);
        }
    };
}

fn showAppHelp(ctx: anytype) !void {
    // Generate and display app help
}

fn showCommandHelp(ctx: anytype, command: []const u8) !void {
    // Generate and display command-specific help
}
```

### Day 18-19: Suggestions Plugin

#### 3.2 Create zcli-suggestions Plugin
```zig
// zcli-suggestions/src/plugin.zig
const std = @import("std");
const zcli = @import("zcli");

pub fn transformError(comptime next: anytype) type {
    return struct {
        pub fn handle(err: anyerror, ctx: anytype) !void {
            switch (err) {
                error.CommandNotFound => {
                    const all_commands = comptime getAllCommands();
                    if (findBestMatch(ctx.attempted_command, all_commands)) |suggestion| {
                        try ctx.io.stderr.print(
                            "\nCommand '{s}' not found. Did you mean '{s}'?\n",
                            .{ctx.attempted_command, suggestion}
                        );
                    }
                },
                else => {},
            }
            try next.handle(err, ctx);
        }
    };
}

fn getAllCommands() []const []const u8 {
    // Extract all command names from registry at comptime
    const Commands = @import("zcli_generated").Commands;
    const info = @typeInfo(Commands);
    
    comptime var commands: []const []const u8 = &.{};
    inline for (info.Struct.decls) |decl| {
        commands = commands ++ .{decl.name};
    }
    return commands;
}

fn findBestMatch(input: []const u8, commands: []const []const u8) ?[]const u8 {
    // Levenshtein distance algorithm
    var best_match: ?[]const u8 = null;
    var best_distance: usize = std.math.maxInt(usize);
    
    for (commands) |cmd| {
        const distance = levenshteinDistance(input, cmd);
        if (distance < best_distance and distance <= 3) {
            best_distance = distance;
            best_match = cmd;
        }
    }
    
    return best_match;
}
```

### Day 20-21: Integration and Testing

#### 3.3 Update zcli Core
```zig
// src/zcli.zig - Remove help and suggestions, delegate to plugins
// This becomes much smaller - just core arg parsing and execution

pub fn main() !void {
    const generated = @import("zcli_generated");
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    var ctx = try generated.Context.init(allocator);
    defer ctx.deinit();
    
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    // Parse command
    const result = parseCommand(args);
    
    // Execute through plugin pipeline
    generated.command_pipeline.execute(ctx, result) catch |err| {
        try generated.error_pipeline.handle(err, ctx);
    };
}
```

## Phase 4: Polish and Documentation (Week 4)

### Day 22-24: Developer Experience

#### 4.1 Plugin Template Generator
```bash
# Add to zcli CLI itself
zcli new plugin my-plugin

# Generates:
my-plugin/
├── build.zig
├── build.zig.zon  
└── src/
    └── plugin.zig
```

#### 4.2 Plugin Testing Framework
```zig
// Add to zcli - testing utilities for plugins
pub const PluginTest = struct {
    pub fn mockContext(allocator: std.mem.Allocator) !TestContext {
        // Create test context for plugin testing
    }
    
    pub fn expectCommand(comptime plugin: anytype, command_name: []const u8) !void {
        // Verify plugin exports expected command
    }
};
```

### Day 25-28: Documentation and Examples

#### 4.3 Complete Documentation
- Plugin development guide
- API reference for all transformer types
- Best practices for plugin composition
- Performance considerations

#### 4.4 Example Plugin Repository
- Auth plugin (with JWT, sessions)
- Database plugin (with connection pooling)
- Metrics plugin (with telemetry)
- Config plugin (with TOML/JSON support)
- Logger plugin (with structured logging)

## Success Criteria

### Week 1 Success
- [ ] Local plugins are discovered and loaded
- [ ] External plugins can be registered in build.zig
- [ ] Basic Context with extensions generates correctly
- [ ] Simple test plugin works end-to-end

### Week 2 Success  
- [ ] Command pipeline transformers work
- [ ] Error pipeline transformers work
- [ ] Help pipeline transformers work
- [ ] Multiple plugins can compose together

### Week 3 Success
- [ ] Help functionality extracted to plugin
- [ ] Suggestions functionality extracted to plugin
- [ ] zcli core becomes minimal
- [ ] All existing functionality still works

### Week 4 Success
- [ ] Plugin development is documented
- [ ] Plugin template generator works
- [ ] Example plugins demonstrate all capabilities
- [ ] Performance benchmarks show zero overhead

## Risk Mitigation

### Technical Risks
1. **Comptime complexity** - Start simple, add complexity gradually
2. **Build time impact** - Profile and optimize code generation  
3. **Type system limits** - Have fallback patterns for edge cases

### Integration Risks
1. **Breaking existing code** - Maintain compatibility throughout
2. **Complex debugging** - Ensure generated code is readable
3. **Documentation debt** - Write docs incrementally

## Implementation Notes

- Build incrementally - each phase should produce working system
- Test extensively - plugin system needs to be rock solid
- Profile performance - must maintain zero-overhead guarantee
- Focus on DX - plugin development should be delightful
- Keep it simple - resist feature creep, maintain core vision