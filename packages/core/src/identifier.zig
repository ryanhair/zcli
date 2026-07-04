//! The single identifier-sanitization rule for user-supplied names that
//! become Zig identifiers: plugin ids → `context.plugins.<field>` (applied at
//! comptime by context.pluginFieldName) and plugin/command names → generated
//! registry module names (applied by build_utils/module_names.zig). One rule,
//! two call sites — if they disagreed, generated field/module access would
//! break obscurely.

const std = @import("std");

/// Every byte that is not alphanumeric or '_' becomes '_'.
pub fn sanitizeChar(c: u8) u8 {
    return if (std.ascii.isAlphanumeric(c) or c == '_') c else '_';
}

/// Sanitize a whole name. Caller owns the returned slice.
pub fn sanitize(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| out[i] = sanitizeChar(c);
    return out;
}

test "sanitize maps every non-identifier byte to underscore" {
    const allocator = std.testing.allocator;
    const out = try sanitize(allocator, "my-plugin.v2 beta");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("my_plugin_v2_beta", out);
}

test "sanitizeChar is usable at comptime" {
    comptime {
        std.debug.assert(sanitizeChar('-') == '_');
        std.debug.assert(sanitizeChar('a') == 'a');
        std.debug.assert(sanitizeChar('_') == '_');
    }
}
