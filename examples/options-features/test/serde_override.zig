// A forwarding application module makes the override observably different
// from the bundled module, even when both use the same upstream package hash.
const std = @import("std");
const upstream = @import("upstream");

pub const toml = struct {
    pub const Table = upstream.toml.Table;
    pub const Value = upstream.toml.Value;
    pub var calls: usize = 0;
    pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Table {
        calls += 1;
        return upstream.toml.parse(allocator, content);
    }
};
pub const yaml = struct {
    pub const Value = upstream.yaml.Value;
    pub var calls: usize = 0;
    pub fn parseValue(allocator: std.mem.Allocator, content: []const u8) !Value {
        calls += 1;
        return upstream.yaml.parseValue(allocator, content);
    }
};
