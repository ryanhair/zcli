const std = @import("std");
const zcli = @import("zcli");

/// zcli-output Plugin
///
/// Provides configurable output format handling for CLI applications.
/// Handles --output/-o global option for structured output (json, table, plain).
///
/// ## Usage in commands
/// ```zig
/// const zcli_output = @import("zcli_output");
///
/// pub fn execute(_: Args, _: Options, context: anytype) !void {
///     const mode = zcli_output.getOutputMode(context);
///     switch (mode) {
///         .json => try zcli_output.outputJson(context.stdout(), data),
///         .table => { var t = zcli_output.Table.init(...); ... },
///         .plain => try zcli_output.outputPlain(context.stdout(), text),
///     }
/// }
/// ```
/// Unique identifier for this plugin (required for type-safe context data)
pub const plugin_id = "zcli_output";

/// Output format modes supported by the plugin
pub const OutputMode = enum {
    json,
    table,
    plain,

    /// Convert from string value to enum
    pub fn fromString(str: []const u8) ?OutputMode {
        if (std.mem.eql(u8, str, "json")) return .json;
        if (std.mem.eql(u8, str, "table")) return .table;
        if (std.mem.eql(u8, str, "plain")) return .plain;
        return null;
    }

    /// Convert to string for display
    pub fn toString(self: OutputMode) []const u8 {
        return switch (self) {
            .json => "json",
            .table => "table",
            .plain => "plain",
        };
    }
};

/// Plugin-specific context data (type-safe, stored in computed Context)
pub const ContextData = struct {
    output_mode: OutputMode = .table,
    invalid_mode_warning: ?[]const u8 = null,
};

/// Global options provided by this plugin
pub const global_options = [_]zcli.GlobalOption{
    zcli.option("output", []const u8, .{
        .short = 'o',
        .default = "table",
        .description = "Output format (json, table, plain)",
    }),
};

/// Handle global options - specifically the --output flag
pub fn handleGlobalOption(
    context: anytype,
    option_name: []const u8,
    value: anytype,
) !void {
    if (std.mem.eql(u8, option_name, "output")) {
        const str_val: []const u8 = switch (@TypeOf(value)) {
            []const u8 => value,
            else => "table",
        };

        const data = &context.plugins.zcli_output;

        // Validate the format
        if (OutputMode.fromString(str_val)) |mode| {
            data.output_mode = mode;
        } else {
            // Invalid format, set default and store warning
            data.output_mode = .table;
            data.invalid_mode_warning = str_val;
        }
    }
}

/// Pre-execute hook to validate output format
pub fn preExecute(
    context: anytype,
    args: zcli.ParsedArgs,
) !?zcli.ParsedArgs {
    const data = context.plugins.zcli_output;

    // Check if an invalid output mode was specified
    if (data.invalid_mode_warning) |invalid| {
        const stderr = context.stderr();
        try stderr.print("Warning: Unknown output format '{s}'. Using 'table' instead.\n", .{invalid});
        try stderr.print("Valid formats: json, table, plain\n\n", .{});
    }

    // Continue normal execution
    return args;
}

/// Get the current output mode from context
/// Public API for other plugins/commands
pub fn getOutputMode(context: anytype) OutputMode {
    return context.plugins.zcli_output.output_mode;
}

/// Check if output should be machine-readable (json, plain)
/// Useful for determining whether to use colors, progress bars, etc.
pub fn isMachineReadable(context: anytype) bool {
    const mode = getOutputMode(context);
    return switch (mode) {
        .json, .plain => true,
        .table => false,
    };
}

/// Check if output should be human-readable (table format)
pub fn isHumanReadable(context: anytype) bool {
    return !isMachineReadable(context);
}

// ============================================================================
// Output Helpers
// ============================================================================

/// Helper to output data as JSON
/// Accepts any type that can be stringified by std.json
pub fn outputJson(writer: anytype, value: anytype) !void {
    try std.json.stringify(value, .{ .whitespace = .indent_2 }, writer);
    try writer.writeAll("\n");
}

/// Helper to output a simple value as plain text
pub fn outputPlain(writer: anytype, value: []const u8) !void {
    try writer.print("{s}\n", .{value});
}

/// Table formatting helpers
pub const Table = struct {
    headers: []const []const u8,
    rows: std.ArrayList([]const []const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, headers: []const []const u8) Table {
        return .{
            .headers = headers,
            .rows = std.ArrayList([]const []const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Table) void {
        self.rows.deinit();
    }

    pub fn addRow(self: *Table, row: []const []const u8) !void {
        try self.rows.append(row);
    }

    /// Render the table to a writer
    pub fn render(self: *Table, writer: anytype) !void {
        // Calculate column widths
        var widths = try self.allocator.alloc(usize, self.headers.len);
        defer self.allocator.free(widths);

        for (self.headers, 0..) |header, i| {
            widths[i] = header.len;
        }

        for (self.rows.items) |row| {
            for (row, 0..) |cell, i| {
                if (i < widths.len) {
                    widths[i] = @max(widths[i], cell.len);
                }
            }
        }

        // Render header
        for (self.headers, 0..) |header, i| {
            try writer.print("{s}", .{header});
            if (i < self.headers.len - 1) {
                const padding = widths[i] - header.len + 2;
                for (0..padding) |_| {
                    try writer.writeByte(' ');
                }
            }
        }
        try writer.writeByte('\n');

        // Render separator
        for (widths, 0..) |width, i| {
            for (0..width) |_| {
                try writer.writeByte('-');
            }
            if (i < widths.len - 1) {
                try writer.writeAll("  ");
            }
        }
        try writer.writeByte('\n');

        // Render rows
        for (self.rows.items) |row| {
            for (row, 0..) |cell, i| {
                if (i < widths.len) {
                    try writer.print("{s}", .{cell});
                    if (i < row.len - 1) {
                        const padding = widths[i] - cell.len + 2;
                        for (0..padding) |_| {
                            try writer.writeByte(' ');
                        }
                    }
                }
            }
            try writer.writeByte('\n');
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "OutputMode fromString" {
    try std.testing.expect(OutputMode.fromString("json") == .json);
    try std.testing.expect(OutputMode.fromString("table") == .table);
    try std.testing.expect(OutputMode.fromString("plain") == .plain);
    try std.testing.expect(OutputMode.fromString("yaml") == null);
    try std.testing.expect(OutputMode.fromString("invalid") == null);
}

test "OutputMode toString" {
    try std.testing.expectEqualStrings("json", OutputMode.json.toString());
    try std.testing.expectEqualStrings("table", OutputMode.table.toString());
    try std.testing.expectEqualStrings("plain", OutputMode.plain.toString());
}

test "output plugin structure" {
    try std.testing.expect(@hasDecl(@This(), "global_options"));
    try std.testing.expect(@hasDecl(@This(), "handleGlobalOption"));
    try std.testing.expect(@hasDecl(@This(), "preExecute"));
    try std.testing.expect(@hasDecl(@This(), "getOutputMode"));
    try std.testing.expect(@hasDecl(@This(), "ContextData"));
}

// Note: Integration tests for handleGlobalOption and getOutputMode
// require a compiled registry with this plugin registered. See integration tests.

test "Table rendering" {
    const allocator = std.testing.allocator;

    var table = Table.init(allocator, &.{ "NAME", "AGE", "CITY" });
    defer table.deinit();

    try table.addRow(&.{ "Alice", "30", "NYC" });
    try table.addRow(&.{ "Bob", "25", "LA" });

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    try table.render(output.writer());

    const result = output.items;
    try std.testing.expect(std.mem.indexOf(u8, result, "NAME") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Bob") != null);
}

test "outputJson" {
    const allocator = std.testing.allocator;

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    const data = .{ .name = "test", .value = 42 };
    try outputJson(output.writer(), data);

    const result = output.items;
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "42") != null);
}
