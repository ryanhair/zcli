const std = @import("std");
const options = @import("options.zig");
const registry = @import("registry.zig");

test "debug container ls options issue" {
    const allocator = std.testing.allocator;
    
    // Exact Options struct from container ls
    const ContainerLsOptions = struct {
        all: bool = false,
        filter: []const []const u8 = &.{},
        format: ?[]const u8 = null,
        last: ?u32 = null,
        latest: bool = false,
        no_trunc: bool = false,
        quiet: bool = false,
        size: bool = false,
    };
    
    // Test the exact case that causes segfault: --all only
    const args = [_][]const u8{ "--all" };
    const result = options.parseOptions(ContainerLsOptions, allocator, &args);
    if (result.isError()) {
        std.debug.print("Parse error: {any}\n", .{result.getError()});
        return error.ParseFailed;
    }
    const parsed = result.unwrap();
    defer options.cleanupOptions(ContainerLsOptions, parsed.options, allocator);
    
    // Check that the filter array is properly initialized
    std.debug.print("Parsed filter len: {d}\n", .{parsed.options.filter.len});
    std.debug.print("Parsed filter ptr: {any}\n", .{parsed.options.filter.ptr});
    
    try std.testing.expect(parsed.options.all == true);
    try std.testing.expect(parsed.options.filter.len == 0);
    
    // This should not crash
    for (parsed.options.filter) |filter| {
        std.debug.print("Filter: {s}\n", .{filter});
    }
    
    std.debug.print("Test passed - no segfault!\n", .{});
}