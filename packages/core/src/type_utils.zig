const std = @import("std");

// ============================================================================
// SHARED TYPE UTILITIES - Common type introspection functions
// ============================================================================

/// Check if a struct field has a default value
pub fn hasDefaultValue(comptime T: type, comptime field_name: []const u8) bool {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") return false;

    inline for (type_info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) {
            return field.default_value_ptr != null;
        }
    }
    return false;
}

// ============================================================================
// TESTS
// ============================================================================

test "hasDefaultValue" {
    const TestStruct = struct {
        field_with_default: i32 = 42,
        field_without_default: []const u8,
    };

    try std.testing.expect(hasDefaultValue(TestStruct, "field_with_default"));
    try std.testing.expect(!hasDefaultValue(TestStruct, "field_without_default"));
    try std.testing.expect(!hasDefaultValue(TestStruct, "nonexistent_field"));
}
