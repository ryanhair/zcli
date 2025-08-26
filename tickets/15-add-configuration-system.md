# Ticket 15: Add Configuration File System

## Priority
🟢 **Low**

## Component
Configuration management, file I/O, user preferences

## Description
Implement a flexible configuration system that allows users to set default values for global options, command-specific settings, and application preferences through configuration files. Support multiple formats (TOML, JSON, YAML) and hierarchical configuration loading.

## Current State
- ❌ No configuration file support
- ❌ Users must specify options every time
- ❌ No way to set application defaults
- ❌ No profile or environment-specific settings

## Proposed Configuration System

### 1. Configuration File Structure
```toml
# ~/.myapp/config.toml (TOML format - recommended)
[global]
verbose = true
output_format = "json"
api_endpoint = "https://api.example.com"

[profiles.development]
verbose = true
debug = true
api_endpoint = "https://dev-api.example.com"

[profiles.production]
verbose = false
debug = false
api_endpoint = "https://api.example.com"

[commands.deploy]
region = "us-west-2"
instance_type = "t3.micro"
dry_run = false

[commands.users.list]
format = "table"
limit = 50
sort_by = "created_at"
```

```json
// Alternative JSON format
{
  "global": {
    "verbose": true,
    "output_format": "json",
    "api_endpoint": "https://api.example.com"
  },
  "profiles": {
    "development": {
      "verbose": true,
      "debug": true,
      "api_endpoint": "https://dev-api.example.com"
    }
  },
  "commands": {
    "deploy": {
      "region": "us-west-2",
      "instance_type": "t3.micro"
    }
  }
}
```

### 2. Configuration Loading System
```zig
const ConfigSystem = struct {
    const ConfigValue = union(enum) {
        string: []const u8,
        boolean: bool,
        integer: i64,
        float: f64,
        array: []const ConfigValue,
        
        pub fn toString(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
            return switch (self) {
                .string => |s| try allocator.dupe(u8, s),
                .boolean => |b| if (b) "true" else "false",
                .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
                .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
                .array => error.UnsupportedConversion,
            };
        }
        
        pub fn toBool(self: @This()) !bool {
            return switch (self) {
                .boolean => |b| b,
                .string => |s| std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1"),
                .integer => |i| i != 0,
                else => error.InvalidConversion,
            };
        }
        
        pub fn toInteger(self: @This(), comptime T: type) !T {
            return switch (self) {
                .integer => |i| @as(T, @intCast(i)),
                .string => |s| try std.fmt.parseInt(T, s, 10),
                else => error.InvalidConversion,
            };
        }
    };
    
    allocator: std.mem.Allocator,
    config_data: std.StringHashMap(ConfigValue),
    current_profile: ?[]const u8,
    
    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .config_data = std.StringHashMap(ConfigValue).init(allocator),
            .current_profile = null,
        };
    }
    
    pub fn deinit(self: *@This()) void {
        self.config_data.deinit();
    }
    
    pub fn loadFromFile(self: *@This(), file_path: []const u8) !void {
        const file_content = try std.fs.cwd().readFileAlloc(self.allocator, file_path, 1024 * 1024);
        defer self.allocator.free(file_content);
        
        const file_ext = std.fs.path.extension(file_path);
        
        if (std.mem.eql(u8, file_ext, ".toml")) {
            try self.parseToml(file_content);
        } else if (std.mem.eql(u8, file_ext, ".json")) {
            try self.parseJson(file_content);
        } else if (std.mem.eql(u8, file_ext, ".yaml") or std.mem.eql(u8, file_ext, ".yml")) {
            try self.parseYaml(file_content);
        } else {
            return error.UnsupportedConfigFormat;
        }
    }
    
    pub fn getValue(self: @This(), key: []const u8) ?ConfigValue {
        // Try profile-specific value first
        if (self.current_profile) |profile| {
            const profile_key = try std.fmt.allocPrint(self.allocator, "profiles.{s}.{s}", .{ profile, key });
            defer self.allocator.free(profile_key);
            
            if (self.config_data.get(profile_key)) |value| {
                return value;
            }
        }
        
        // Fallback to global value
        const global_key = try std.fmt.allocPrint(self.allocator, "global.{s}", .{key});
        defer self.allocator.free(global_key);
        
        return self.config_data.get(global_key);
    }
    
    pub fn getCommandValue(self: @This(), command_path: []const []const u8, option: []const u8) ?ConfigValue {
        const command_key = try std.mem.join(self.allocator, ".", command_path);
        defer self.allocator.free(command_key);
        
        const full_key = try std.fmt.allocPrint(self.allocator, "commands.{s}.{s}", .{ command_key, option });
        defer self.allocator.free(full_key);
        
        return self.config_data.get(full_key);
    }
    
    pub fn setProfile(self: *@This(), profile: []const u8) void {
        self.current_profile = profile;
    }
};
```

### 3. Configuration Discovery
```zig
const ConfigDiscovery = struct {
    pub const ConfigPaths = struct {
        system: []const []const u8,
        user: []const []const u8,
        project: []const []const u8,
        
        pub fn init(app_name: []const u8, allocator: std.mem.Allocator) !@This() {
            const home_dir = std.posix.getenv("HOME") orelse ".";
            const config_dir = std.posix.getenv("XDG_CONFIG_HOME") orelse 
                try std.fmt.allocPrint(allocator, "{}/.config", .{home_dir});
            
            return .{
                .system = &.{
                    try std.fmt.allocPrint(allocator, "/etc/{s}/config.toml", .{app_name}),
                    try std.fmt.allocPrint(allocator, "/usr/local/etc/{s}/config.toml", .{app_name}),
                },
                .user = &.{
                    try std.fmt.allocPrint(allocator, "{s}/{s}/config.toml", .{ config_dir, app_name }),
                    try std.fmt.allocPrint(allocator, "{s}/.{s}.toml", .{ home_dir, app_name }),
                    try std.fmt.allocPrint(allocator, "{s}/.{s}/config.toml", .{ home_dir, app_name }),
                },
                .project = &.{
                    ".myapp.toml",
                    "myapp.config.toml",
                    "config/myapp.toml",
                },
            };
        }
    };
    
    pub fn loadConfigurations(app_name: []const u8, allocator: std.mem.Allocator) !ConfigSystem {
        var config = ConfigSystem.init(allocator);
        
        const paths = try ConfigPaths.init(app_name, allocator);
        
        // Load configurations in order of precedence (system -> user -> project)
        const all_paths = paths.system ++ paths.user ++ paths.project;
        
        for (all_paths) |config_path| {
            std.fs.cwd().access(config_path, .{}) catch continue;  // Skip if not exists
            
            std.log.debug("Loading config from: {s}", .{config_path});
            config.loadFromFile(config_path) catch |err| {
                std.log.warn("Failed to load config from {s}: {}", .{ config_path, err });
                continue;
            };
        }
        
        // Set profile from environment variable
        if (std.posix.getenv("MYAPP_PROFILE")) |profile| {
            config.setProfile(profile);
        }
        
        return config;
    }
};
```

### 4. Integration with Option Parsing
```zig
const ConfigIntegration = struct {
    pub fn applyConfigDefaults(
        config: *ConfigSystem,
        comptime OptionsType: type,
        command_path: []const []const u8
    ) OptionsType {
        var options: OptionsType = .{};  // Start with struct defaults
        
        // Apply configuration values
        inline for (@typeInfo(OptionsType).Struct.fields) |field| {
            // Try command-specific config first
            if (config.getCommandValue(command_path, field.name)) |config_value| {
                @field(options, field.name) = convertConfigValue(field.type, config_value) catch continue;
            }
            // Fallback to global config
            else if (config.getValue(field.name)) |config_value| {
                @field(options, field.name) = convertConfigValue(field.type, config_value) catch continue;
            }
        }
        
        return options;
    }
    
    fn convertConfigValue(comptime T: type, config_value: ConfigSystem.ConfigValue) !T {
        return switch (@typeInfo(T)) {
            .Bool => try config_value.toBool(),
            .Int => try config_value.toInteger(T),
            .Float => @as(T, @floatCast(switch (config_value) {
                .float => |f| f,
                .integer => |i| @as(f64, @floatFromInt(i)),
                else => return error.InvalidConversion,
            })),
            .Pointer => |ptr_info| {
                if (ptr_info.size == .Slice and ptr_info.child == u8) {
                    return try config_value.toString(std.heap.page_allocator);
                } else {
                    return error.UnsupportedType;
                }
            },
            .Optional => |opt_info| {
                return convertConfigValue(opt_info.child, config_value);
            },
            .Enum => |enum_info| {
                const str_value = try config_value.toString(std.heap.page_allocator);
                defer std.heap.page_allocator.free(str_value);
                
                inline for (enum_info.fields) |enum_field| {
                    if (std.mem.eql(u8, str_value, enum_field.name)) {
                        return @field(T, enum_field.name);
                    }
                }
                return error.InvalidEnumValue;
            },
            else => error.UnsupportedType,
        };
    }
};
```

### 5. Configuration Generation and Management
```zig
const ConfigManager = struct {
    pub fn generateDefaultConfig(app_name: []const u8, commands: []const CommandInfo) ![]const u8 {
        var output = std.ArrayList(u8).init(std.heap.page_allocator);
        defer output.deinit();
        
        const writer = output.writer();
        
        try writer.print("# {s} Configuration File\n", .{app_name});
        try writer.print("# Generated on {}\n\n", .{std.time.timestamp()});
        
        // Global section
        try writer.print("[global]\n");
        try writer.print("# Global options that apply to all commands\n");
        try writer.print("# verbose = false\n");
        try writer.print("# output_format = \"json\"\n");
        try writer.print("\n");
        
        // Profiles section
        try writer.print("[profiles.development]\n");
        try writer.print("# Development profile settings\n");
        try writer.print("# verbose = true\n");
        try writer.print("# debug = true\n");
        try writer.print("\n");
        
        try writer.print("[profiles.production]\n");
        try writer.print("# Production profile settings\n");
        try writer.print("# verbose = false\n");
        try writer.print("# debug = false\n");
        try writer.print("\n");
        
        // Command-specific sections
        for (commands) |command| {
            const command_section = try std.mem.replaceOwned(u8, std.heap.page_allocator, command.path, " ", ".");
            defer std.heap.page_allocator.free(command_section);
            
            try writer.print("[commands.{}]\n", .{command_section});
            try writer.print("# Options specific to the '{}' command\n", .{command.path});
            
            // Generate example options based on command definition
            if (command.options) |options| {
                try generateExampleOptions(writer, options);
            }
            
            try writer.print("\n");
        }
        
        return output.toOwnedSlice();
    }
    
    pub fn initializeUserConfig(app_name: []const u8, commands: []const CommandInfo) !void {
        const home_dir = std.posix.getenv("HOME") orelse ".";
        const config_dir = try std.fmt.allocPrint(std.heap.page_allocator, "{}/.config/{s}", .{ home_dir, app_name });
        defer std.heap.page_allocator.free(config_dir);
        
        // Create config directory
        std.fs.cwd().makePath(config_dir) catch {};
        
        const config_file_path = try std.fmt.allocPrint(std.heap.page_allocator, "{}/config.toml", .{config_dir});
        defer std.heap.page_allocator.free(config_file_path);
        
        // Check if config already exists
        std.fs.cwd().access(config_file_path, .{}) catch {
            // Generate and write default config
            const default_config = try generateDefaultConfig(app_name, commands);
            defer std.heap.page_allocator.free(default_config);
            
            try std.fs.cwd().writeFile(.{ .sub_path = config_file_path, .data = default_config });
            
            std.log.info("Created default configuration file: {s}", .{config_file_path});
            return;
        };
        
        std.log.info("Configuration file already exists: {s}", .{config_file_path});
    }
};
```

### 6. Command-Line Integration
```zig
// Integration with the main CLI system
pub fn executeWithConfig(
    comptime Command: type,
    raw_args: []const []const u8,
    config: *ConfigSystem,
    command_path: []const []const u8,
    context: *zcli.Context
) !void {
    // Parse command-line arguments first
    const cli_result = parseOptions(Command.Options, raw_args);
    
    // Apply configuration defaults
    var final_options = ConfigIntegration.applyConfigDefaults(config, Command.Options, command_path);
    
    // Override with CLI values (CLI takes precedence)
    switch (cli_result) {
        .success => |cli_options| {
            final_options = mergeOptions(Command.Options, final_options, cli_options);
        },
        .error => |err| return err,
    }
    
    // Parse arguments
    const args_result = parseArgs(Command.Args, raw_args);
    const final_args = switch (args_result) {
        .success => |args| args,
        .error => |err| return err,
    };
    
    // Execute command with merged configuration
    try Command.execute(final_args, final_options, context);
}

fn mergeOptions(comptime T: type, config_options: T, cli_options: T) T {
    var result = config_options;
    
    // Override config values with CLI values (where provided)
    inline for (@typeInfo(T).Struct.fields) |field| {
        const cli_value = @field(cli_options, field.name);
        
        // Check if CLI provided a non-default value
        if (!isDefaultValue(field.type, cli_value)) {
            @field(result, field.name) = cli_value;
        }
    }
    
    return result;
}
```

### 7. Configuration Validation
```zig
const ConfigValidator = struct {
    pub fn validateConfig(config: *ConfigSystem, app_schema: ConfigSchema) ![]const ValidationError {
        var errors = std.ArrayList(ValidationError).init(std.heap.page_allocator);
        
        // Validate global options
        for (app_schema.global_options) |option| {
            if (config.getValue(option.name)) |value| {
                validateValue(value, option.type, option.constraints) catch |err| {
                    try errors.append(.{
                        .path = try std.fmt.allocPrint(std.heap.page_allocator, "global.{s}", .{option.name}),
                        .error_type = err,
                        .message = try std.fmt.allocPrint(std.heap.page_allocator, 
                            "Invalid value for global option '{s}'", .{option.name}),
                    });
                };
            }
        }
        
        // Validate command-specific options
        for (app_schema.commands) |command| {
            for (command.options) |option| {
                const command_path_str = try std.mem.join(std.heap.page_allocator, ".", command.path);
                defer std.heap.page_allocator.free(command_path_str);
                
                if (config.getCommandValue(command.path, option.name)) |value| {
                    validateValue(value, option.type, option.constraints) catch |err| {
                        try errors.append(.{
                            .path = try std.fmt.allocPrint(std.heap.page_allocator, 
                                "commands.{s}.{s}", .{ command_path_str, option.name }),
                            .error_type = err,
                            .message = try std.fmt.allocPrint(std.heap.page_allocator,
                                "Invalid value for command option '{s}' in '{s}'", .{ option.name, command_path_str }),
                        });
                    };
                }
            }
        }
        
        return errors.toOwnedSlice();
    }
    
    const ValidationError = struct {
        path: []const u8,
        error_type: anyerror,
        message: []const u8,
    };
};
```

### 8. User-Friendly Configuration Commands
```zig
// Built-in configuration management commands
pub const ConfigCommands = struct {
    // myapp config init
    pub const InitCommand = struct {
        pub const Args = struct {};
        pub const Options = struct {
            force: bool = false,
        };
        
        pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
            _ = args;
            
            const app_name = context.app_name;
            
            if (!options.force) {
                // Check if config exists
                const config_path = try getDefaultConfigPath(app_name, context.allocator);
                defer context.allocator.free(config_path);
                
                std.fs.cwd().access(config_path, .{}) catch {
                    // Config doesn't exist, safe to create
                };
                
                // Config exists, ask for confirmation
                try context.stdout().print("Configuration file already exists at {s}\n", .{config_path});
                try context.stdout().print("Use --force to overwrite.\n", .{});
                return;
            }
            
            // Initialize configuration
            try ConfigManager.initializeUserConfig(app_name, getAvailableCommands());
        }
    };
    
    // myapp config get <key>
    pub const GetCommand = struct {
        pub const Args = struct {
            key: []const u8,
        };
        pub const Options = struct {};
        
        pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
            _ = options;
            
            var config = try ConfigDiscovery.loadConfigurations(context.app_name, context.allocator);
            defer config.deinit();
            
            if (config.getValue(args.key)) |value| {
                const str_value = try value.toString(context.allocator);
                defer context.allocator.free(str_value);
                try context.stdout().print("{s}\n", .{str_value});
            } else {
                try context.stdout().print("Configuration key '{s}' not found\n", .{args.key});
            }
        }
    };
    
    // myapp config set <key> <value>
    pub const SetCommand = struct {
        pub const Args = struct {
            key: []const u8,
            value: []const u8,
        };
        pub const Options = struct {};
        
        pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
            _ = options;
            
            // Implementation would update the user's config file
            try context.stdout().print("Set {s} = {s}\n", .{ args.key, args.value });
        }
    };
    
    // myapp config validate
    pub const ValidateCommand = struct {
        pub const Args = struct {};
        pub const Options = struct {};
        
        pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
            _ = args;
            _ = options;
            
            var config = try ConfigDiscovery.loadConfigurations(context.app_name, context.allocator);
            defer config.deinit();
            
            const schema = getAppConfigSchema();
            const errors = try ConfigValidator.validateConfig(&config, schema);
            defer context.allocator.free(errors);
            
            if (errors.len == 0) {
                try context.stdout().print("✅ Configuration is valid\n", .{});
            } else {
                try context.stdout().print("❌ Configuration has {} error(s):\n", .{errors.len});
                for (errors) |error_info| {
                    try context.stdout().print("  {s}: {s}\n", .{ error_info.path, error_info.message });
                }
            }
        }
    };
};
```

## Usage Examples

### User Workflow
```bash
# Initialize configuration
myapp config init

# View/edit the config file
$EDITOR ~/.config/myapp/config.toml

# Test configuration
myapp config validate

# View specific setting
myapp config get verbose

# Update setting
myapp config set global.verbose true

# Use different profile
MYAPP_PROFILE=development myapp deploy

# Override config with CLI options
myapp deploy --region us-east-1  # Overrides config value
```

### Configuration File Examples
```toml
# ~/.config/myapp/config.toml
[global]
verbose = true
output_format = "json"
api_timeout = 30

[profiles.dev]
api_endpoint = "https://dev-api.example.com"
debug = true

[profiles.prod]
api_endpoint = "https://api.example.com"
debug = false

[commands.deploy]
region = "us-west-2"
instance_type = "t3.micro"
confirm = false  # Skip confirmation prompts

[commands.users.list]
format = "table"
page_size = 25
```

## Testing Strategy

### Configuration Loading Tests
```zig
test "configuration loading precedence" {
    // Create temporary config files
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    // System config
    try tmp_dir.dir.writeFile(.{ .sub_path = "system.toml", .data = 
        \\[global]
        \\verbose = false
        \\timeout = 10
    });
    
    // User config (should override system)
    try tmp_dir.dir.writeFile(.{ .sub_path = "user.toml", .data = 
        \\[global]
        \\verbose = true
        \\api_key = "user-key"
    });
    
    // Project config (should override user)
    try tmp_dir.dir.writeFile(.{ .sub_path = "project.toml", .data = 
        \\[global]
        \\api_key = "project-key"
    });
    
    // Load configurations in order
    var config = ConfigSystem.init(std.testing.allocator);
    defer config.deinit();
    
    try config.loadFromFile("system.toml");
    try config.loadFromFile("user.toml");
    try config.loadFromFile("project.toml");
    
    // Test precedence
    try testing.expect(try config.getValue("verbose").?.toBool() == true);     // From user config
    try testing.expect(try config.getValue("timeout").?.toInteger(u32) == 10); // From system config  
    try testing.expectEqualSlices(u8, "project-key", try config.getValue("api_key").?.toString(std.testing.allocator)); // From project config
}

test "profile-specific configuration" {
    var config = ConfigSystem.init(std.testing.allocator);
    defer config.deinit();
    
    try config.loadFromString(
        \\[global]
        \\verbose = false
        \\
        \\[profiles.dev]
        \\verbose = true
        \\debug = true
    );
    
    // Without profile
    try testing.expect(try config.getValue("verbose").?.toBool() == false);
    try testing.expect(config.getValue("debug") == null);
    
    // With dev profile
    config.setProfile("dev");
    try testing.expect(try config.getValue("verbose").?.toBool() == true);  // Profile overrides global
    try testing.expect(try config.getValue("debug").?.toBool() == true);    // Profile-specific value
}
```

## Integration with Build System

### Build-time Configuration
```zig
// build.zig integration
pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_source_file = .{ .path = "src/main.zig" },
    });
    
    // Enable configuration system
    const enable_config = b.option(bool, "config", "Enable configuration file support") orelse true;
    
    if (enable_config) {
        const config_formats = [_][]const u8{ "toml", "json", "yaml" };
        const selected_formats = b.option([]const []const u8, "config-formats", "Supported config formats") orelse &config_formats;
        
        const options = b.addOptions();
        options.addOption(bool, "enable_config", true);
        options.addOption([]const []const u8, "config_formats", selected_formats);
        
        exe.root_module.addOptions("config", options);
    }
}
```

## Performance Considerations

### Lazy Configuration Loading
```zig
const LazyConfig = struct {
    loaded: bool = false,
    config_system: ?ConfigSystem = null,
    
    pub fn getConfig(self: *@This(), allocator: std.mem.Allocator) !*ConfigSystem {
        if (!self.loaded) {
            self.config_system = try ConfigDiscovery.loadConfigurations("myapp", allocator);
            self.loaded = true;
        }
        
        return &self.config_system.?;
    }
};
```

### Configuration Caching
```zig
// Cache parsed configuration to avoid repeated parsing
var config_cache: ?ConfigSystem = null;
var config_cache_mtime: i128 = 0;

pub fn getCachedConfig(allocator: std.mem.Allocator) !*ConfigSystem {
    const config_path = try getDefaultConfigPath("myapp", allocator);
    defer allocator.free(config_path);
    
    const current_mtime = blk: {
        const file = std.fs.cwd().openFile(config_path, .{}) catch break :blk 0;
        defer file.close();
        const stat = file.stat() catch break :blk 0;
        break :blk stat.mtime;
    };
    
    if (config_cache == null or current_mtime > config_cache_mtime) {
        if (config_cache) |*cache| {
            cache.deinit();
        }
        
        config_cache = try ConfigDiscovery.loadConfigurations("myapp", allocator);
        config_cache_mtime = current_mtime;
    }
    
    return &config_cache.?;
}
```

## Acceptance Criteria
- [ ] Support TOML, JSON, and YAML configuration formats
- [ ] Hierarchical configuration loading (system -> user -> project)
- [ ] Profile-based configuration switching
- [ ] Command-specific configuration sections
- [ ] Configuration validation with helpful error messages
- [ ] Built-in configuration management commands (init, get, set, validate)
- [ ] Integration with existing option parsing system
- [ ] CLI options override configuration values
- [ ] Configuration file generation with examples
- [ ] Performance optimized with caching and lazy loading

## Estimated Effort
**3-4 weeks** (1 week for core configuration system, 1 week for file format parsers, 1 week for CLI integration, 1 week for management commands and testing)