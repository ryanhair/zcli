//! Invocation failures are classified where they arise, never by a global list
//! of error names. Results own all retained strings until deinit().
const std = @import("std");

pub const Category = enum { usage, unknown_command, application, unexpected, io };
pub const Stage = enum { initialization, startup, response_files, pre_parse, global_options, transform, routing, information, parsing, configuration, input, validation, preparation, execution, completion, rendering, flushing };
pub const Origin = union(enum) { framework, command, plugin: []const u8 };
pub const ExitCodes = struct {
    usage: u8 = 2,
    command_not_found: u8 = 3,
    command_failed: u8 = 1,
};
pub const Failure = struct {
    category: Category,
    cause: anyerror,
    stage: Stage,
    origin: Origin = .framework,
    command_path: []const []const u8 = &.{},
    id: ?[]const u8 = null,
    message: ?[]const u8 = null,
    reported: bool = false,
    /// Owned copy of Zig error return addresses, when tracing is enabled.
    trace: ?std.builtin.StackTrace = null,
    /// Structured parser diagnostic retained for custom renderers.
    diagnostic: ?@import("diagnostic_errors.zig").ZcliDiagnostic = null,
    pub fn isUsage(self: Failure) bool {
        return self.category == .usage or self.category == .unknown_command;
    }
};
pub const Description = struct {
    id: ?[]const u8 = null,
    message: ?[]const u8 = null,
    silent: bool = false,
};
/// Application-owned mapping. A null scope explicitly matches all application
/// and plugin origins. Framework misuse is never matched by error names.
pub const ErrorRule = struct {
    cause: anyerror,
    code: u8,
    /// Registered command path; aliases share their target's mapping.
    command: ?[]const u8 = null,
    plugin: ?[]const u8 = null,
    id: ?[]const u8 = null,
    message: ?[]const u8 = null,
    silent: bool = false,
};
pub const Outcome = union(enum) { success, completed, failure: Failure };
pub const InvocationResult = struct {
    outcome: Outcome,
    status: u8,
    arena: std.heap.ArenaAllocator,
    /// Diagnostic errors and cleanup errors never replace the primary failure.
    secondary_errors: []const anyerror = &.{},
    pub fn deinit(self: *InvocationResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub const Action = enum { proceed, complete };

pub fn statusFor(category: Category, codes: ExitCodes) u8 {
    return switch (category) {
        .usage => codes.usage,
        .unknown_command => codes.command_not_found,
        .application => codes.command_failed,
        .unexpected, .io => 1,
    };
}

/// Deep-copy a diagnostic's borrowed values into result-owned storage.
pub fn retain(allocator: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!@TypeOf(value) {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice) return value;
            const copy = try allocator.alloc(p.child, value.len);
            for (value, 0..) |item, i| copy[i] = try retain(allocator, item);
            return copy;
        },
        .optional => return if (value) |v| try retain(allocator, v) else null,
        .@"struct" => |info| {
            var copy = value;
            inline for (info.fields) |field| @field(copy, field.name) = try retain(allocator, @field(value, field.name));
            return copy;
        },
        .@"union" => {
            switch (value) {
                inline else => |payload, tag| return @unionInit(T, @tagName(tag), try retain(allocator, payload)),
            }
        },
        .array => {
            var copy = value;
            for (value, 0..) |item, i| copy[i] = try retain(allocator, item);
            return copy;
        },
        else => return value,
    }
}

/// Preserve the originating frames when a result is projected back to a Zig
/// error union. This is a no-op in builds without error return tracing.
pub fn restoreTrace(trace: ?std.builtin.StackTrace) void {
    const source = trace orelse return;
    const target = @errorReturnTrace() orelse return;
    const count = @min(source.instruction_addresses.len, target.instruction_addresses.len);
    @memcpy(target.instruction_addresses[0..count], source.instruction_addresses[0..count]);
    target.index = source.index;
}
