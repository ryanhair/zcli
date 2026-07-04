//! In-memory `zcli_secrets` backend for `zig build test`.
//!
//! `addCommandTests` wires THIS into the command-test stub Context in place of
//! the real keychain-backed plugin, so a command that calls
//! `context.plugins.zcli_secrets.<op>(...)` is unit-testable via `runCommand`
//! without touching the OS keychain (and without linking a native backend). Its
//! public surface mirrors the real plugin's `plugin_id` + `ContextData`. The
//! real plugin — and its live keychain round-trip test — are untouched.
//!
//! State lives process-globally (leaked via the page allocator), which is fine
//! for a test binary: secrets set in one `runCommand` are visible to the next.

const std = @import("std");

pub const plugin_id = "zcli_secrets";

const Entry = struct { service: []const u8, name: []const u8, value: []const u8 };
var entries: std.ArrayListUnmanaged(Entry) = .empty;
const store_alloc = std.heap.page_allocator;

fn find(service: []const u8, name: []const u8) ?usize {
    for (entries.items, 0..) |e, i| {
        if (std.mem.eql(u8, e.service, service) and std.mem.eql(u8, e.name, name)) return i;
    }
    return null;
}

/// Mirrors the real plugin's ContextData: keyed by `(context.app_name, name)`.
pub const ContextData = struct {
    pub fn get(_: *ContextData, context: anytype, name: []const u8) !?[]const u8 {
        if (find(context.app_name, name)) |i|
            return try context.allocator.dupe(u8, entries.items[i].value);
        return null;
    }

    pub fn set(_: *ContextData, context: anytype, name: []const u8, value: []const u8) !void {
        const val = try store_alloc.dupe(u8, value);
        if (find(context.app_name, name)) |i| {
            entries.items[i].value = val;
            return;
        }
        try entries.append(store_alloc, .{
            .service = try store_alloc.dupe(u8, context.app_name),
            .name = try store_alloc.dupe(u8, name),
            .value = val,
        });
    }

    pub fn delete(_: *ContextData, context: anytype, name: []const u8) !void {
        if (find(context.app_name, name)) |i| _ = entries.orderedRemove(i);
    }
};
