const std = @import("std");
const testing = std.testing;
const registry = @import("registry.zig");
const zcli = @import("zcli.zig");

// ============================================================================
// PURE COMMAND GROUP TESTS
// Tests for the new command group architecture where pure command groups
// (directories without index.zig) always show help and never execute.
// ============================================================================

// Test command modules
const NetworkLs = struct {
    pub const meta = .{
        .description = "List networks",
    };
    pub const Args = struct {};
    pub const Options = struct {};
    pub fn execute(_: Args, _: Options, context: *zcli.Context) !void {
        try context.stdout().print("listing networks...\n", .{});
    }
};

const TestHelpPlugin = struct {
    pub const priority = 100;
    
    var help_shown = false;
    var command_found_error = false;
    
    pub fn reset() void {
        help_shown = false;
        command_found_error = false;
    }
    
    pub fn onError(context: *zcli.Context, err: anyerror) !bool {
        _ = context;
        if (err == error.CommandNotFound) {
            command_found_error = true;
            help_shown = true;
            return true; // Handle the error - this simulates help plugin behavior
        }
        return false;
    }
};

// Create a test registry that simulates pure command groups
fn createTestRegistry() type {
    // Only register leaf commands - pure command groups are NOT registered
    return registry.Registry.init(.{
        .app_name = "test-cli",
        .app_version = "1.0.0", 
        .app_description = "Test CLI with pure command groups",
    })
    .register("network ls", NetworkLs) // Only the leaf command is registered
    .registerPlugin(TestHelpPlugin)
    .build();
}

test "pure command group behavior: always shows help without error" {
    const TestApp = createTestRegistry();
    var app = TestApp.init();
    
    const allocator = testing.allocator;
    
    // Test 1: Pure command group without --help should show help and succeed
    TestHelpPlugin.reset();
    try app.run_with_args(allocator, &.{"network"});
    
    // Should have triggered CommandNotFound -> help showing -> error handled
    try testing.expect(TestHelpPlugin.help_shown);
    try testing.expect(TestHelpPlugin.command_found_error);
    
    // Test 2: Pure command group with --help should also show help and succeed  
    TestHelpPlugin.reset();
    try app.run_with_args(allocator, &.{"network", "--help"});
    
    // Should have triggered help showing (same behavior regardless of --help)
    try testing.expect(TestHelpPlugin.help_shown);
}

test "pure command group: subcommands execute normally" {
    const TestApp = createTestRegistry();
    var app = TestApp.init();
    
    const allocator = testing.allocator;
    
    // Subcommand should execute normally without help plugin intervention
    TestHelpPlugin.reset();
    try app.run_with_args(allocator, &.{"network", "ls"});
    try testing.expect(!TestHelpPlugin.command_found_error); // Should not hit CommandNotFound
}

test "error handling: plugin returns true prevents error propagation" {
    const TestApp = createTestRegistry();
    var app = TestApp.init();
    
    const allocator = testing.allocator;
    
    // This tests the fix - when a plugin handles CommandNotFound by returning true,
    // the registry should not propagate the error
    TestHelpPlugin.reset();
    try app.run_with_args(allocator, &.{"nonexistent"});
    
    // Plugin should have handled the error
    try testing.expect(TestHelpPlugin.command_found_error);
    try testing.expect(TestHelpPlugin.help_shown);
}