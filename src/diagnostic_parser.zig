const std = @import("std");
const diagnostic_errors = @import("diagnostic_errors.zig");
const logging = @import("logging.zig");
const utils = @import("options/utils.zig");

pub const ZcliError = diagnostic_errors.ZcliError;
pub const ZcliDiagnostic = diagnostic_errors.ZcliDiagnostic;

/// Parser with diagnostic support for zcli argument and option parsing
/// This follows the Zig idiom of standard error handling with optional rich diagnostics
pub const Parser = struct {
    allocator: std.mem.Allocator,
    diagnostic: ?*ZcliDiagnostic = null,

    // Context state for diagnostic information
    current_option: ?[]const u8 = null,
    current_option_is_short: bool = false,
    current_field: ?[]const u8 = null,
    current_position: usize = 0,
    current_expected_type: ?[]const u8 = null,
    current_provided_value: ?[]const u8 = null,
    current_args_len: usize = 0,
    current_arg_index: usize = 0,

    // Command context for better error reporting
    command_path: []const []const u8 = &.{},
    available_options: []const []const u8 = &.{},
    available_commands: []const []const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) @This() {
        return @This(){
            .allocator = allocator,
        };
    }

    pub fn initWithDiagnostic(allocator: std.mem.Allocator, diagnostic: *ZcliDiagnostic) @This() {
        return @This(){
            .allocator = allocator,
            .diagnostic = diagnostic,
        };
    }

    /// Parse positional arguments using the diagnostic pattern
    pub fn parseArgs(self: *@This(), comptime T: type, args: []const []const u8) ZcliError!T {
        return self.parseArgsImpl(T, args) catch |err| {
            if (self.diagnostic) |diag| {
                diag.* = self.createDiagnostic(err);
            }
            return err;
        };
    }

    /// Parse options using the diagnostic pattern
    pub fn parseOptions(self: *@This(), comptime T: type, args: []const []const u8) ZcliError!T {
        return self.parseOptionsImpl(T, args) catch |err| {
            if (self.diagnostic) |diag| {
                diag.* = self.createDiagnostic(err);
            }
            return err;
        };
    }

    /// Internal implementation of parseArgs
    fn parseArgsImpl(self: *@This(), comptime T: type, args: []const []const u8) ZcliError!T {
        var result: T = undefined;
        const type_info = @typeInfo(T);

        if (type_info != .@"struct") {
            @compileError("Args type must be a struct");
        }

        const fields = type_info.@"struct".fields;
        var current_arg_index: usize = 0;

        // Store args context for better diagnostics
        self.current_args_len = args.len;
        self.current_arg_index = current_arg_index;

        // Process each field in the struct
        inline for (fields, 0..) |field, field_index| {
            self.current_field = field.name;
            self.current_position = field_index;
            self.current_expected_type = @typeName(field.type);

            const field_type_info = @typeInfo(field.type);

            // Handle varargs ([]const []const u8 or [][]const u8)
            if (field_type_info == .pointer and field_type_info.pointer.size == .slice) {
                const child_info = @typeInfo(field_type_info.pointer.child);
                if (child_info == .pointer and child_info.pointer.child == u8) {
                    // This is []const []const u8 or [][]const u8 - varargs
                    const remaining_args = args[current_arg_index..];

                    // Check if we need @constCast based on the field type
                    if (field_type_info.pointer.is_const) {
                        // Field type is []const []const u8 - no cast needed
                        @field(result, field.name) = remaining_args;
                    } else {
                        // Field type is [][]const u8 - need to remove outer const
                        @field(result, field.name) = @constCast(remaining_args);
                    }
                    return result; // Varargs consumes all remaining arguments
                }
            }

            // Handle regular fields
            if (current_arg_index >= args.len) {
                return ZcliError.ArgumentMissingRequired;
            }

            const arg_value = args[current_arg_index];
            self.current_provided_value = arg_value;

            // Parse the argument value
            @field(result, field.name) = self.parseValue(field.type, arg_value) catch {
                return ZcliError.ArgumentInvalidValue;
            };

            current_arg_index += 1;
        }

        // Check for too many arguments
        if (current_arg_index < args.len) {
            self.current_arg_index = args.len; // Update for diagnostic
            return ZcliError.ArgumentTooMany;
        }

        return result;
    }

    /// Internal implementation of parseOptions
    fn parseOptionsImpl(self: *@This(), comptime T: type, args: []const []const u8) ZcliError!T {
        var result: T = undefined;
        const type_info = @typeInfo(T);

        if (type_info != .@"struct") {
            @compileError("Options type must be a struct");
        }

        // Initialize all fields to their default values
        // Note: For the diagnostic parser, we use simple defaults since struct field
        // default values require more complex handling in comptime contexts
        inline for (type_info.@"struct".fields) |field| {
            if (@typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
            } else if (field.type == bool) {
                @field(result, field.name) = false;
            } else {
                @field(result, field.name) = std.mem.zeroes(field.type);
            }
        }

        var i: usize = 0;
        while (i < args.len) {
            const arg = args[i];

            // Skip non-option arguments
            if (!std.mem.startsWith(u8, arg, "-") or utils.isNegativeNumber(arg)) {
                i += 1;
                continue;
            }

            // Parse option
            if (std.mem.startsWith(u8, arg, "--")) {
                // Long option
                const option_part = arg[2..];
                self.current_option = option_part;
                self.current_option_is_short = false;

                i = try self.parseLongOption(T, &result, option_part, args, i);
            } else {
                // Short option(s)
                const option_chars = arg[1..];
                i = try self.parseShortOptions(T, &result, option_chars, args, i);
            }
        }

        return result;
    }

    /// Parse a long option (--option or --option=value)
    fn parseLongOption(self: *@This(), comptime T: type, result: *T, option_part: []const u8, args: []const []const u8, current_index: usize) ZcliError!usize {
        var option_name = option_part;
        var option_value: ?[]const u8 = null;

        // Check for --option=value format
        if (std.mem.indexOf(u8, option_part, "=")) |eq_pos| {
            option_name = option_part[0..eq_pos];
            option_value = option_part[eq_pos + 1 ..];
        }

        self.current_option = option_name;

        // Convert dashes to underscores for field lookup
        var field_name_buf: [256]u8 = undefined;
        const field_name = utils.dashesToUnderscores(&field_name_buf, option_name) catch {
            return ZcliError.OptionUnknown;
        };

        // Find matching field
        const type_info = @typeInfo(T);
        inline for (type_info.@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, field_name)) {
                return try self.setOptionField(T, result, field, option_value, args, current_index);
            }
        }

        return ZcliError.OptionUnknown;
    }

    /// Parse short option(s) (-o or -abc)
    fn parseShortOptions(self: *@This(), comptime T: type, result: *T, option_chars: []const u8, args: []const []const u8, current_index: usize) ZcliError!usize {
        // For now, implement simple single short option parsing
        // TODO: Implement bundled short options (-abc = -a -b -c) carefully with proper field matching
        if (option_chars.len != 1) {
            self.current_option = option_chars;
            self.current_option_is_short = true;
            return ZcliError.OptionUnknown;
        }

        const option_char = option_chars[0];
        self.current_option = option_chars;
        self.current_option_is_short = true;

        // Find field with matching short option
        const type_info = @typeInfo(T);
        inline for (type_info.@"struct".fields) |field| {
            // TODO: Add support for field attributes to specify short options
            // For now, assume first letter of field name, but only for boolean fields to avoid conflicts
            if (field.name.len > 0 and field.name[0] == option_char and utils.isBooleanType(field.type)) {
                return try self.setOptionField(T, result, field, null, args, current_index);
            }
        }

        return ZcliError.OptionUnknown;
    }

    /// Set a field value for an option
    fn setOptionField(self: *@This(), comptime T: type, result: *T, comptime field: std.builtin.Type.StructField, option_value: ?[]const u8, args: []const []const u8, current_index: usize) ZcliError!usize {
        self.current_expected_type = @typeName(field.type);

        if (utils.isBooleanType(field.type)) {
            if (option_value) |value| {
                self.current_provided_value = value;
                return ZcliError.OptionBooleanWithValue;
            }

            // Set the boolean field to true
            switch (@typeInfo(field.type)) {
                .bool => {
                    @field(result.*, field.name) = true;
                },
                else => unreachable,
            }
            return current_index + 1;
        } else {
            // Non-boolean option requires a value
            const value = option_value orelse blk: {
                if (current_index + 1 >= args.len) {
                    return ZcliError.OptionMissingValue;
                }
                break :blk args[current_index + 1];
            };

            self.current_provided_value = value;

            @field(result.*, field.name) = self.parseValue(field.type, value) catch {
                return ZcliError.OptionInvalidValue;
            };

            return if (option_value) |_| current_index + 1 else current_index + 2;
        }
    }

    /// Parse a string value into the specified type (for arguments, not options)
    fn parseValue(self: *@This(), comptime T: type, value: []const u8) !T {
        _ = self; // unused for now

        // For arguments, we only support string and integer types for now
        const type_info = @typeInfo(T);
        return switch (type_info) {
            .pointer => |ptr_info| blk: {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    break :blk value;
                } else {
                    return error.InvalidOptionValue;
                }
            },
            .int => std.fmt.parseInt(T, value, 10) catch error.InvalidOptionValue,
            .float => std.fmt.parseFloat(T, value) catch error.InvalidOptionValue,
            else => error.InvalidOptionValue,
        };
    }

    /// Create diagnostic information for an error
    fn createDiagnostic(self: *@This(), err: ZcliError) ZcliDiagnostic {
        return switch (err) {
            ZcliError.ArgumentMissingRequired => ZcliDiagnostic{
                .ArgumentMissingRequired = .{
                    .field_name = self.current_field orelse "unknown",
                    .position = self.current_position,
                    .expected_type = self.current_expected_type orelse "unknown",
                },
            },
            ZcliError.ArgumentInvalidValue => ZcliDiagnostic{
                .ArgumentInvalidValue = .{
                    .field_name = self.current_field orelse "unknown",
                    .position = self.current_position,
                    .provided_value = self.current_provided_value orelse "unknown",
                    .expected_type = self.current_expected_type orelse "unknown",
                },
            },
            ZcliError.ArgumentTooMany => ZcliDiagnostic{
                .ArgumentTooMany = .{
                    .expected_count = self.current_position, // Number of fields that need args
                    .actual_count = self.current_args_len, // Total args provided
                },
            },
            ZcliError.OptionUnknown => ZcliDiagnostic{
                .OptionUnknown = .{
                    .option_name = self.current_option orelse "unknown",
                    .is_short = self.current_option_is_short,
                    .suggestions = self.findSimilarOptions(),
                },
            },
            ZcliError.OptionMissingValue => ZcliDiagnostic{
                .OptionMissingValue = .{
                    .option_name = self.current_option orelse "unknown",
                    .is_short = self.current_option_is_short,
                    .expected_type = self.current_expected_type orelse "unknown",
                },
            },
            ZcliError.OptionInvalidValue => ZcliDiagnostic{
                .OptionInvalidValue = .{
                    .option_name = self.current_option orelse "unknown",
                    .is_short = self.current_option_is_short,
                    .provided_value = self.current_provided_value orelse "unknown",
                    .expected_type = self.current_expected_type orelse "unknown",
                },
            },
            ZcliError.OptionBooleanWithValue => ZcliDiagnostic{
                .OptionBooleanWithValue = .{
                    .option_name = self.current_option orelse "unknown",
                    .is_short = self.current_option_is_short,
                    .provided_value = self.current_provided_value orelse "unknown",
                },
            },
            ZcliError.OptionDuplicate => ZcliDiagnostic{
                .OptionDuplicate = .{
                    .option_name = self.current_option orelse "unknown",
                    .is_short = self.current_option_is_short,
                },
            },
            ZcliError.CommandNotFound => ZcliDiagnostic{
                .CommandNotFound = .{
                    .attempted_command = "unknown",
                    .command_path = self.command_path,
                    .suggestions = &.{},
                },
            },
            ZcliError.SubcommandNotFound => ZcliDiagnostic{
                .SubcommandNotFound = .{
                    .subcommand_name = "unknown",
                    .parent_path = self.command_path,
                    .suggestions = &.{},
                },
            },
            ZcliError.BuildCommandDiscoveryFailed => ZcliDiagnostic{
                .BuildCommandDiscoveryFailed = .{
                    .file_path = "unknown",
                    .details = "Command discovery failed",
                    .suggestion = null,
                },
            },
            ZcliError.BuildRegistryGenerationFailed => ZcliDiagnostic{
                .BuildRegistryGenerationFailed = .{
                    .details = "Registry generation failed",
                    .suggestion = null,
                },
            },
            ZcliError.BuildOutOfMemory => ZcliDiagnostic{
                .BuildOutOfMemory = .{
                    .operation = "unknown",
                    .details = "Out of memory during build operation",
                },
            },
            ZcliError.SystemFileNotFound => ZcliDiagnostic{
                .SystemFileNotFound = .{
                    .file_path = "unknown",
                },
            },
            ZcliError.SystemAccessDenied => ZcliDiagnostic{
                .SystemAccessDenied = .{
                    .file_path = "unknown",
                },
            },
            ZcliError.HelpRequested => ZcliDiagnostic{ .HelpRequested = {} },
            ZcliError.VersionRequested => ZcliDiagnostic{ .VersionRequested = {} },
            ZcliError.ResourceLimitExceeded => ZcliDiagnostic{
                .ResourceLimitExceeded = .{
                    .limit_type = "unknown",
                    .limit_value = 0,
                    .actual_value = 0,
                    .suggestion = null,
                },
            },
            ZcliError.SystemOutOfMemory => ZcliDiagnostic{ .SystemOutOfMemory = {} },
        };
    }

    /// Find similar options for suggestion (placeholder implementation)
    fn findSimilarOptions(self: *@This()) []const []const u8 {
        _ = self;
        return &.{};
    }

    /// Find similar commands for suggestion (placeholder implementation)
    fn findSimilarCommands(self: *@This()) []const []const u8 {
        _ = self;
        return &.{};
    }

    /// Find similar subcommands for suggestion (placeholder implementation)
    fn findSimilarSubcommands(self: *@This()) []const []const u8 {
        _ = self;
        return &.{};
    }
};

// Convenience functions for backward compatibility and simple usage

/// Simple parseArgs without diagnostic support (for compatibility)
pub fn parseArgs(comptime T: type, allocator: std.mem.Allocator, args: []const []const u8) ZcliError!T {
    var parser = Parser.init(allocator);
    return parser.parseArgs(T, args);
}

/// parseArgs with diagnostic support
pub fn parseArgsWithDiagnostic(comptime T: type, allocator: std.mem.Allocator, args: []const []const u8, diagnostic: *ZcliDiagnostic) ZcliError!T {
    var parser = Parser.initWithDiagnostic(allocator, diagnostic);
    return parser.parseArgs(T, args);
}

/// Simple parseOptions without diagnostic support (for compatibility)
pub fn parseOptions(comptime T: type, allocator: std.mem.Allocator, args: []const []const u8) ZcliError!T {
    var parser = Parser.init(allocator);
    return parser.parseOptions(T, args);
}

/// parseOptions with diagnostic support
pub fn parseOptionsWithDiagnostic(comptime T: type, allocator: std.mem.Allocator, args: []const []const u8, diagnostic: *ZcliDiagnostic) ZcliError!T {
    var parser = Parser.initWithDiagnostic(allocator, diagnostic);
    return parser.parseOptions(T, args);
}

// Basic tests to verify the parser works
test "parseArgs basic functionality" {
    const Args = struct {
        name: []const u8,
        count: i32,
    };

    const args = [_][]const u8{ "test", "42" };
    const allocator = std.testing.allocator;

    const result = try parseArgs(Args, allocator, &args);
    try std.testing.expectEqualStrings("test", result.name);
    try std.testing.expectEqual(@as(i32, 42), result.count);
}

test "parseArgs with diagnostic" {
    const Args = struct {
        name: []const u8,
        count: i32,
    };

    const args = [_][]const u8{"test"}; // Missing count argument
    const allocator = std.testing.allocator;
    var diagnostic: ZcliDiagnostic = undefined;

    const result = parseArgsWithDiagnostic(Args, allocator, &args, &diagnostic);
    try std.testing.expectError(ZcliError.ArgumentMissingRequired, result);

    try std.testing.expectEqualStrings("count", diagnostic.ArgumentMissingRequired.field_name);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.ArgumentMissingRequired.position);
}

test "parseOptions basic functionality" {
    const Options = struct {
        count: i32,
    };

    const args = [_][]const u8{ "--count", "42" };
    const allocator = std.testing.allocator;

    const result = try parseOptions(Options, allocator, &args);
    try std.testing.expectEqual(@as(i32, 42), result.count);
}

test "parseOptions with diagnostic" {
    const Options = struct {
        count: i32,
    };

    const args = [_][]const u8{"--unknown-option"};
    const allocator = std.testing.allocator;
    var diagnostic: ZcliDiagnostic = undefined;

    const result = parseOptionsWithDiagnostic(Options, allocator, &args, &diagnostic);
    try std.testing.expectError(ZcliError.OptionUnknown, result);

    try std.testing.expectEqualStrings("unknown-option", diagnostic.OptionUnknown.option_name);
    try std.testing.expectEqual(false, diagnostic.OptionUnknown.is_short);
}
