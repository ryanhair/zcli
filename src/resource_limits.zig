const std = @import("std");

/// Resource limits to prevent DoS attacks and resource exhaustion
pub const ResourceLimits = struct {
    /// Maximum number of elements in any option array (e.g., --files a.txt b.txt ...)
    max_option_array_elements: usize = 1000,

    /// Maximum length of option names to prevent buffer overflow attacks
    max_option_name_length: usize = 256,

    /// Maximum total number of options that can be provided
    max_total_options: usize = 100,

    /// Maximum number of positional arguments
    max_argument_count: usize = 1000,

    /// Maximum command nesting depth (e.g., cmd sub1 sub2 sub3 ...)
    max_command_depth: usize = 10,

    /// Maximum number of suggestions to generate for unknown commands
    max_suggestions: usize = 10,

    /// Timeout for suggestion generation in milliseconds
    suggestion_timeout_ms: u64 = 100,

    pub fn getDefault() @This() {
        return .{};
    }

    pub fn restrictive() @This() {
        return .{
            .max_option_array_elements = 100,
            .max_total_options = 20,
            .max_argument_count = 100,
            .max_command_depth = 5,
            .max_suggestions = 5,
            .suggestion_timeout_ms = 50,
        };
    }

    pub fn permissive() @This() {
        return .{
            .max_option_array_elements = 10000,
            .max_option_name_length = 1024,
            .max_total_options = 1000,
            .max_argument_count = 10000,
            .max_command_depth = 20,
            .max_suggestions = 50,
            .suggestion_timeout_ms = 1000,
        };
    }
};

/// Error types for resource limit violations
pub const ResourceLimitError = error{
    OptionArrayTooLarge,
    OptionNameTooLong,
    TooManyOptions,
    TooManyArguments,
    CommandNestingTooDeep,
    SuggestionTimeout,
};

/// Context for tracking resource usage during parsing
pub const ResourceTracker = struct {
    limits: ResourceLimits,
    option_count: usize = 0,
    max_array_size: usize = 0,
    command_depth: usize = 0,

    pub fn init(limits: ResourceLimits) @This() {
        return .{ .limits = limits };
    }

    pub fn checkOptionCount(self: *@This()) !void {
        self.option_count += 1;
        if (self.option_count > self.limits.max_total_options) {
            return ResourceLimitError.TooManyOptions;
        }
    }

    pub fn checkArraySize(self: *@This(), size: usize) !void {
        if (size > self.limits.max_option_array_elements) {
            return ResourceLimitError.OptionArrayTooLarge;
        }
        self.max_array_size = @max(self.max_array_size, size);
    }

    pub fn checkOptionNameLength(self: @This(), name: []const u8) !void {
        if (name.len > self.limits.max_option_name_length) {
            return ResourceLimitError.OptionNameTooLong;
        }
    }

    pub fn checkArgumentCount(self: @This(), count: usize) !void {
        if (count > self.limits.max_argument_count) {
            return ResourceLimitError.TooManyArguments;
        }
    }

    pub fn checkCommandDepth(self: *@This(), depth: usize) !void {
        self.command_depth = depth;
        if (depth > self.limits.max_command_depth) {
            return ResourceLimitError.CommandNestingTooDeep;
        }
    }
};

test "ResourceLimits default values" {
    const limits = ResourceLimits.getDefault();
    try std.testing.expectEqual(@as(usize, 1000), limits.max_option_array_elements);
    try std.testing.expectEqual(@as(usize, 256), limits.max_option_name_length);
    try std.testing.expectEqual(@as(usize, 100), limits.max_total_options);
}

test "ResourceTracker option counting" {
    var tracker = ResourceTracker.init(ResourceLimits{ .max_total_options = 2 });

    try tracker.checkOptionCount(); // 1st option - OK
    try tracker.checkOptionCount(); // 2nd option - OK

    try std.testing.expectError(ResourceLimitError.TooManyOptions, tracker.checkOptionCount()); // 3rd option - should fail
}

test "ResourceTracker array size checking" {
    var tracker = ResourceTracker.init(ResourceLimits{ .max_option_array_elements = 5 });

    try tracker.checkArraySize(3); // OK
    try tracker.checkArraySize(5); // OK (at limit)

    try std.testing.expectError(ResourceLimitError.OptionArrayTooLarge, tracker.checkArraySize(6)); // Should fail
}

test "ResourceTracker option name length checking" {
    const tracker = ResourceTracker.init(ResourceLimits{ .max_option_name_length = 10 });

    try tracker.checkOptionNameLength("short"); // OK
    try tracker.checkOptionNameLength("exactly10c"); // OK (exactly at limit)

    try std.testing.expectError(ResourceLimitError.OptionNameTooLong, tracker.checkOptionNameLength("this-is-too-long")); // Should fail
}
