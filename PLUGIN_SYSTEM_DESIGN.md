# zcli Plugin System - Simplified Design

## Core Insight

Plugins are just modules that export well-known declarations. The build system generates a single struct that combines all plugins. No runtime dispatch, no type erasure, just comptime composition.

## The Entire Plugin API

```zig
// A plugin is just a Zig module with optional exports:

// 1. Modify command execution pipeline
pub fn transformCommand(comptime next: anytype) type {
    return struct {
        pub fn execute(ctx: anytype, args: anytype) !void {
            // Do something before
            log.debug("Executing command", .{});
            
            // Call next in chain
            try next.execute(ctx, args);
            
            // Do something after
            log.debug("Command completed", .{});
        }
    };
}

// 2. Provide new commands
pub const commands = struct {
    pub const help = @import("help_command.zig");
};

// 3. Extend context (static, no type erasure!)
pub const ContextExtension = struct {
    db_pool: *DatabasePool,
    
    pub fn init(allocator: Allocator) !@This() {
        return .{ .db_pool = try DatabasePool.init(allocator) };
    }
};

// 4. Transform error handling
pub fn transformError(comptime next: anytype) type {
    return struct {
        pub fn handle(err: anyerror, ctx: anytype) !void {
            // "Did you mean?" suggestions
            if (err == error.CommandNotFound) {
                const suggestion = findSimilarCommand(ctx.attempted_command);
                try ctx.stderr().print("Did you mean '{s}'?\n", .{suggestion});
            }
            try next.handle(err, ctx);
        }
    };
}

// 5. Transform help generation
pub fn transformHelp(comptime next: anytype) type {
    return struct {
        pub fn generate(ctx: anytype, command: []const u8) ![]const u8 {
            var help = try next.generate(ctx, command);
            // Add plugin-specific help
            return try std.fmt.allocPrint(ctx.allocator, 
                "{s}\n\nPlugin Commands:\n  {s}\n", 
                .{help, "auth login - Login to service"}
            );
        }
    };
}
```

## Build-Time Composition

```zig
// Generated code combines all plugins into a single type
// NO RUNTIME DISPATCH - everything resolved at comptime

// zcli_generated.zig
const plugin_auth = @import("zcli-auth");
const plugin_help = @import("zcli-help");  
const plugin_suggestions = @import("zcli-suggestions");
const local_logger = @import("plugins/logger.zig");

// Compose context extensions statically
pub const Context = struct {
    allocator: Allocator,
    io: IO,
    env: Environment,
    
    // Plugin extensions are FIELDS, not dynamic!
    auth: if (@hasDecl(plugin_auth, "ContextExtension")) 
        plugin_auth.ContextExtension else void,
    logger: if (@hasDecl(local_logger, "ContextExtension")) 
        local_logger.ContextExtension else void,
    
    pub fn init(allocator: Allocator) !@This() {
        var self = Context{
            .allocator = allocator,
            .io = .{...},
            .env = .{...},
            .auth = undefined,
            .logger = undefined,
        };
        
        // Initialize extensions
        if (@hasDecl(plugin_auth, "ContextExtension")) {
            self.auth = try plugin_auth.ContextExtension.init(allocator);
        }
        if (@hasDecl(local_logger, "ContextExtension")) {
            self.logger = try local_logger.ContextExtension.init(allocator);
        }
        
        return self;
    }
};

// Compose command pipeline at comptime
pub const CommandPipeline = comptime blk: {
    var pipeline = BaseCommandExecutor;
    
    // Chain transformers in reverse order (last wraps first)
    if (@hasDecl(local_logger, "transformCommand")) {
        pipeline = local_logger.transformCommand(pipeline);
    }
    if (@hasDecl(plugin_auth, "transformCommand")) {
        pipeline = plugin_auth.transformCommand(pipeline);
    }
    
    break :blk pipeline;
};

// Compose error handler pipeline
pub const ErrorPipeline = comptime blk: {
    var pipeline = BaseErrorHandler;
    
    if (@hasDecl(plugin_suggestions, "transformError")) {
        pipeline = plugin_suggestions.transformError(pipeline);
    }
    
    break :blk pipeline;
};

// Merge commands from all plugins
pub const Commands = struct {
    // Native commands
    pub const hello = @import("commands/hello.zig");
    
    // Plugin commands merged in
    pub usingnamespace if (@hasDecl(plugin_auth, "commands")) 
        plugin_auth.commands else struct {};
    pub usingnamespace if (@hasDecl(plugin_help, "commands")) 
        plugin_help.commands else struct {};
};
```

## Real Plugin Examples

### Help Plugin (Extracted from Core)
```zig
// zcli-help plugin - Provides help command and generation
pub const commands = struct {
    pub const help = struct {
        pub const Args = struct {
            command: ?[]const u8 = null,
        };
        
        pub fn execute(ctx: Context, args: Args) !void {
            const help_text = if (args.command) |cmd|
                try generateCommandHelp(cmd)
            else
                try generateAppHelp();
                
            try ctx.stdout().print("{s}\n", .{help_text});
        }
    };
};

pub fn transformCommand(comptime next: anytype) type {
    return struct {
        pub fn execute(ctx: anytype, args: anytype) !void {
            // Intercept --help flag
            if (ctx.hasFlag("help")) {
                try showHelp(ctx, @typeName(@TypeOf(args)));
                return;
            }
            try next.execute(ctx, args);
        }
    };
}
```

### Suggestions Plugin (Did You Mean?)
```zig
// zcli-suggestions plugin - Provides command suggestions
const levenshtein = @import("levenshtein.zig");

pub fn transformError(comptime next: anytype) type {
    return struct {
        pub fn handle(err: anyerror, ctx: anytype) !void {
            if (err == error.CommandNotFound) {
                // Get all available commands at comptime
                const all_commands = comptime getAllCommands();
                
                const best_match = findBestMatch(
                    ctx.attempted_command, 
                    all_commands
                );
                
                if (best_match) |match| {
                    try ctx.stderr().print(
                        "\nCommand '{s}' not found. Did you mean '{s}'?\n", 
                        .{ctx.attempted_command, match}
                    );
                }
            }
            
            try next.handle(err, ctx);
        }
    };
}

fn getAllCommands() []const []const u8 {
    // Use @typeInfo to extract all commands from registry
    const Commands = @import("zcli_generated").Commands;
    const info = @typeInfo(Commands);
    
    var commands: []const []const u8 = &.{};
    inline for (info.Struct.decls) |decl| {
        commands = commands ++ .{decl.name};
    }
    return commands;
}
```

### Auth Plugin with Context Extension
```zig
// zcli-auth plugin
pub const ContextExtension = struct {
    token: ?[]const u8,
    user: ?User,
    
    pub fn init(allocator: Allocator) !@This() {
        return .{
            .token = try loadStoredToken(allocator),
            .user = null,
        };
    }
    
    pub fn requireAuth(self: *@This()) !void {
        if (self.token == null) {
            return error.NotAuthenticated;
        }
        if (self.user == null) {
            self.user = try fetchUser(self.token.?);
        }
    }
};

pub fn transformCommand(comptime next: anytype) type {
    return struct {
        pub fn execute(ctx: anytype, args: anytype) !void {
            // Skip auth for certain commands
            const cmd_name = @typeName(@TypeOf(args));
            if (!std.mem.endsWith(u8, cmd_name, ".login")) {
                try ctx.auth.requireAuth();
            }
            
            try next.execute(ctx, args);
        }
    };
}

pub const commands = struct {
    pub const login = struct {
        pub const Args = struct { username: []const u8 };
        
        pub fn execute(ctx: anytype, args: Args) !void {
            const token = try authenticate(args.username);
            ctx.auth.token = token;
            try saveToken(token);
        }
    };
};
```

## Why This is Better

### 1. **Everything is Static**
- No runtime type checking
- No dynamic dispatch
- All plugin composition happens at comptime
- Context extensions are typed fields, not void pointers

### 2. **Infinitely Flexible**
- Plugins can transform ANY part of the system
- Not limited to predefined hooks
- Can modify help, errors, parsing, execution, anything

### 3. **Zero Overhead**
- No HashMaps for extensions
- No function pointer arrays for hooks
- Everything inlines and optimizes perfectly

### 4. **Simple Mental Model**
- A plugin is just a module with exports
- Transformers are just functions that return types
- Extensions are just struct fields

### 5. **Composable**
- Plugins wrap each other like middleware
- Order matters and is explicit
- Each plugin sees the full type information

## Build Configuration

```zig
// build.zig - Still simple!
const zcli = @import("zcli");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "my-cli",
        .root_source_file = b.path("src/main.zig"),
    });
    
    zcli.build(b, exe, .{
        .commands_dir = "src/commands",
        .plugins_dir = "src/plugins",
        .plugins = &.{
            zcli.plugin(b, "zcli-help"),        // Provides help command
            zcli.plugin(b, "zcli-suggestions"), // Provides "did you mean"
            zcli.plugin(b, "zcli-auth"),        // Adds auth
        },
    });
}
```

## The Magic: Build-Time Code Generation

```zig
// build_utils.zig - generates the composition
pub fn generatePluginComposition(
    writer: anytype, 
    plugins: []const PluginInfo,
) !void {
    // Generate Context with all extensions
    try writer.writeAll("pub const Context = struct {\n");
    try writer.writeAll("    allocator: Allocator,\n");
    
    for (plugins) |plugin| {
        try writer.print(
            \\    {s}: if (@hasDecl({s}, "ContextExtension")) 
            \\        {s}.ContextExtension else void,
            \\
        , .{plugin.name, plugin.import, plugin.import});
    }
    
    // Generate pipeline composition
    try writer.writeAll(
        \\
        \\pub const CommandPipeline = comptime blk: {
        \\    var pipeline = BaseExecutor;
        \\
    );
    
    // Chain transformers
    for (plugins) |plugin| {
        try writer.print(
            \\    if (@hasDecl({s}, "transformCommand"))
            \\        pipeline = {s}.transformCommand(pipeline);
            \\
        , .{plugin.import, plugin.import});
    }
    
    try writer.writeAll("    break :blk pipeline;\n};\n");
}
```

## Plugin Directory Structure

### Local Plugins
```
src/
├── main.zig
├── commands/
│   ├── hello.zig
│   └── users/
│       └── list.zig
└── plugins/              # Auto-discovered like commands
    ├── logger.zig        # Simple single-file plugin
    └── metrics/          # Multi-file plugin
        ├── plugin.zig    # Entry point
        └── collector.zig
```

### External Plugin Package
```
zcli-auth/
├── build.zig
├── build.zig.zon
└── src/
    ├── plugin.zig        # Main plugin exports
    ├── commands/
    │   ├── login.zig
    │   └── logout.zig
    └── auth.zig
```

## Implementation Roadmap

### Phase 1: Core Plugin System (Week 1)
- [ ] Comptime pipeline composition
- [ ] Context extension generation
- [ ] Command merging from plugins
- [ ] Local plugin discovery

### Phase 2: Essential Plugins (Week 2)
- [ ] Extract help into `zcli-help` plugin
- [ ] Extract suggestions into `zcli-suggestions` plugin
- [ ] Create example auth plugin
- [ ] Create example metrics plugin

### Phase 3: Developer Experience (Week 3)
- [ ] Plugin template generator
- [ ] Plugin testing framework
- [ ] Documentation generator
- [ ] Example plugins repository

## Conclusion

This design:
- **Eliminates runtime complexity** - Everything is comptime
- **Uses Zig's strengths** - Comptime code generation, not runtime reflection
- **Supports all requirements** - Help and suggestions as plugins
- **Stays simple** - ~100 lines of core code vs 1000s
- **Remains powerful** - Plugins can transform anything

The key insight: **Plugins are comptime transformers, not runtime hooks**. This is the Zig way.