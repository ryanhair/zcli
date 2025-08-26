const std = @import("std");
const args_parser = @import("args.zig");
const options_parser = @import("options.zig");
const diagnostic_errors = @import("diagnostic_errors.zig");

pub const ZcliError = diagnostic_errors.ZcliError;

/// Result of parsing a complete command line with mixed arguments and options
pub fn CommandParseResult(comptime ArgsType: type, comptime OptionsType: type) type {
    return struct {
        args: ArgsType,
        options: OptionsType,
        allocator: ?std.mem.Allocator = null, // Only set if cleanup is needed
        _positional_slice: ?[]const []const u8 = null, // Keep varargs slice alive
        
        pub fn deinit(self: @This()) void {
            if (self.allocator) |allocator| {
                // Cleanup any allocated arrays in options
                options_parser.cleanupOptions(OptionsType, self.options, allocator);
                
                // Cleanup positional slice if we allocated it
                if (self._positional_slice) |slice| {
                    allocator.free(slice);
                }
            }
        }
    };
}

/// Parse a command line with mixed arguments and options in a single pass.
/// This function understands both positional arguments and options, handling them
/// in the order they appear while respecting the semantics of each.
///
/// Example:
/// ```
/// const Args = struct { file: []const u8, output: ?[]const u8 = null };
/// const Options = struct { verbose: bool = false, format: enum { json, yaml } = .json };
/// 
/// const result = try parseCommandLine(Args, Options, null, allocator, 
///     &.{"input.txt", "--verbose", "--format", "json", "output.txt"});
/// defer result.deinit();
/// 
/// // result.args.file = "input.txt"
/// // result.args.output = "output.txt" 
/// // result.options.verbose = true
/// // result.options.format = .json
/// ```
pub fn parseCommandLine(
    comptime ArgsType: type, 
    comptime OptionsType: type,
    comptime meta: anytype,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) ZcliError!CommandParseResult(ArgsType, OptionsType) {
    _ = meta; // TODO: Use meta for option customization
    
    // First pass: separate options from positional arguments
    var option_args = std.ArrayList([]const u8).init(allocator);
    defer option_args.deinit();
    var positional_args = std.ArrayList([]const u8).init(allocator);
    defer positional_args.deinit();
    
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        
        // Handle "--" separator (everything after is positional)
        if (std.mem.eql(u8, arg, "--")) {
            // Add remaining args as positional
            for (args[i + 1..]) |remaining_arg| {
                positional_args.append(remaining_arg) catch return ZcliError.SystemOutOfMemory;
            }
            break;
        }
        
        // Handle options (start with -, but not negative numbers)
        if (std.mem.startsWith(u8, arg, "-") and !isNegativeNumber(arg)) {
            option_args.append(arg) catch return ZcliError.SystemOutOfMemory;
            
            // Check if this option expects a value
            if (std.mem.startsWith(u8, arg, "--")) {
                // Long option
                if (std.mem.indexOf(u8, arg, "=")) |_| {
                    // --option=value format, no additional arg needed
                    i += 1;
                    continue;
                } else {
                    // --option format, might need next arg as value
                    const option_name = arg[2..]; // Remove "--"
                    if (needsValue(OptionsType, option_name) and i + 1 < args.len) {
                        i += 1;
                        if (i < args.len) {
                            option_args.append(args[i]) catch return ZcliError.SystemOutOfMemory;
                        }
                    }
                }
            } else {
                // Short option -x or -xyz
                const option_chars = arg[1..];
                if (option_chars.len == 1) {
                    // Single short option, might need value
                    const option_char = option_chars[0];
                    if (needsValueShort(OptionsType, option_char) and i + 1 < args.len) {
                        i += 1; 
                        if (i < args.len) {
                            option_args.append(args[i]) catch return ZcliError.SystemOutOfMemory;
                        }
                    }
                }
                // For bundled short options (-xyz), assume they're all boolean
            }
        } else {
            // Positional argument
            positional_args.append(arg) catch return ZcliError.SystemOutOfMemory;
        }
        
        i += 1;
    }
    
    // Parse options from the collected option arguments
    const options = if (option_args.items.len > 0)
        try parseOptionsFromArgs(OptionsType, allocator, option_args.items)
    else
        initializeDefaultOptions(OptionsType);
    
    // Parse positional arguments
    // Note: We need to keep positional_args.items alive for the lifetime of the result
    // because parseArgs may create references to the input slice (for varargs)
    const positional_slice = positional_args.toOwnedSlice() catch return ZcliError.SystemOutOfMemory;
    const parsed_args = args_parser.parseArgs(ArgsType, positional_slice) catch |err| {
        // If parseArgs fails, we need to clean up the slice we allocated
        allocator.free(positional_slice);
        return err;
    };
    
    const has_varargs = hasVarargsFields(ArgsType);
    const needs_cleanup = hasArrayFields(OptionsType) or has_varargs;
    return CommandParseResult(ArgsType, OptionsType){
        .args = parsed_args,
        .options = options,
        .allocator = if (needs_cleanup) allocator else null,
        ._positional_slice = if (has_varargs) positional_slice else blk: {
            // If no varargs, we don't need to keep the slice alive, so free it now
            allocator.free(positional_slice);
            break :blk null;
        },
    };
}

/// Check if a string represents a negative number
fn isNegativeNumber(arg: []const u8) bool {
    if (arg.len < 2 or arg[0] != '-') return false;
    
    // Check if the character after '-' is a digit
    return std.ascii.isDigit(arg[1]);
}

/// Check if an option field needs a value (i.e., is not a boolean)
fn needsValue(comptime OptionsType: type, option_name: []const u8) bool {
    const type_info = @typeInfo(OptionsType);
    if (type_info != .@"struct") return false;
    
    inline for (type_info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, option_name)) {
            return field.type != bool;
        }
        
        // Also check with dash conversion (field_name -> field-name)
        var dash_name_buf: [64]u8 = undefined;
        const dash_name = convertUnderscoresToDashes(field.name, &dash_name_buf);
        if (std.mem.eql(u8, dash_name, option_name)) {
            return field.type != bool;
        }
    }
    
    return false;
}

/// Check if a short option needs a value
fn needsValueShort(comptime OptionsType: type, option_char: u8) bool {
    // This is a simplified version - in a full implementation, you'd check
    // meta information for short option mappings
    _ = OptionsType;
    _ = option_char;
    return false; // For now, assume short options are boolean
}

/// Convert underscores to dashes for option names
fn convertUnderscoresToDashes(name: []const u8, buffer: []u8) []const u8 {
    var i: usize = 0;
    for (name) |c| {
        buffer[i] = if (c == '_') '-' else c;
        i += 1;
    }
    return buffer[0..name.len];
}

/// Parse options from a list of option arguments
fn parseOptionsFromArgs(comptime OptionsType: type, allocator: std.mem.Allocator, option_args: []const []const u8) ZcliError!OptionsType {
    // Delegate to the existing options parser
    const result = try options_parser.parseOptions(OptionsType, allocator, option_args);
    return result.options;
}

/// Initialize an options struct with all default values
fn initializeDefaultOptions(comptime OptionsType: type) OptionsType {
    const type_info = @typeInfo(OptionsType);
    if (type_info != .@"struct") {
        @compileError("OptionsType must be a struct");
    }
    
    var result: OptionsType = undefined;
    
    inline for (type_info.@"struct".fields) |field| {
        if (field.type == bool) {
            @field(result, field.name) = false;
        } else if (field.default_value_ptr) |default_ptr| {
            const default_value: *const field.type = @ptrCast(@alignCast(default_ptr));
            @field(result, field.name) = default_value.*;
        } else {
            // Required field without default
            @field(result, field.name) = undefined;
        }
    }
    
    return result;
}

/// Check if an options type has any array fields that need cleanup
fn hasArrayFields(comptime OptionsType: type) bool {
    const type_info = @typeInfo(OptionsType);
    if (type_info != .@"struct") return false;
    
    inline for (type_info.@"struct".fields) |field| {
        if (@typeInfo(field.type) == .pointer) {
            const ptr_info = @typeInfo(field.type).pointer;
            if (ptr_info.size == .slice) {
                return true; // Found an array/slice field
            }
        }
    }
    
    return false;
}

/// Check if an args type has varargs fields (last field is an array)
fn hasVarargsFields(comptime ArgsType: type) bool {
    const type_info = @typeInfo(ArgsType);
    if (type_info != .@"struct") return false;
    if (type_info.@"struct".fields.len == 0) return false;
    
    // Check if the last field is an array/slice
    const last_field = type_info.@"struct".fields[type_info.@"struct".fields.len - 1];
    if (@typeInfo(last_field.type) == .pointer) {
        const ptr_info = @typeInfo(last_field.type).pointer;
        return ptr_info.size == .slice;
    }
    
    return false;
}

// Tests
test "parseCommandLine basic usage" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const Args = struct {
        file: []const u8,
        output: ?[]const u8 = null,
    };
    
    const Options = struct {
        verbose: bool = false,
        format: enum { json, yaml } = .json,
    };
    
    // Test mixed args and options
    const result = try parseCommandLine(
        Args, 
        Options, 
        null, 
        allocator, 
        &.{"input.txt", "--verbose", "output.txt"}
    );
    defer result.deinit();
    
    try testing.expectEqualStrings("input.txt", result.args.file);
    try testing.expectEqualStrings("output.txt", result.args.output.?);
    try testing.expect(result.options.verbose);
    try testing.expectEqual(.json, result.options.format);
}

test "parseCommandLine options only" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const Args = struct {
        file: ?[]const u8 = null,
    };
    
    const Options = struct {
        verbose: bool = false,
        count: u32 = 1,
    };
    
    const result = try parseCommandLine(
        Args, 
        Options, 
        null, 
        allocator, 
        &.{"--verbose", "--count", "5"}
    );
    defer result.deinit();
    
    try testing.expect(result.args.file == null);
    try testing.expect(result.options.verbose);
    try testing.expectEqual(@as(u32, 5), result.options.count);
}