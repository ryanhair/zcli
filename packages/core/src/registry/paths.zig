const std = @import("std");

/// Split a path string into components at compile time
pub fn splitPath(comptime path: []const u8) []const []const u8 {
    comptime {
        var components: []const []const u8 = &.{};
        var it = std.mem.splitSequence(u8, path, " ");
        while (it.next()) |component| {
            if (component.len > 0) {
                components = components ++ [_][]const u8{component};
            }
        }
        return components;
    }
}

/// Join a command path with spaces at compile time, for `@compileError`
/// messages — no allocator exists there, so `std.mem.join` cannot be used.
pub fn comptimeJoinPath(comptime path: []const []const u8) []const u8 {
    comptime {
        var result: []const u8 = "";
        for (path, 0..) |component, i| {
            if (i != 0) result = result ++ " ";
            result = result ++ component;
        }
        return result;
    }
}

/// Sort command entries by path length (descending) at compile time, so
/// routing tries the most specific path first. The loop condition is
/// `i + 1 < len` rather than `len - 1`: a plugin-only registry has zero
/// commands, and `0 - 1` underflows usize at comptime.
pub fn sortedByPathLengthDesc(comptime commands: anytype) @TypeOf(commands[0..commands.len].*) {
    var cmds = commands[0..commands.len].*;
    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = 0;
        while (i + 1 < cmds.len) : (i += 1) {
            if (cmds[i].path.len < cmds[i + 1].path.len) {
                const temp = cmds[i];
                cmds[i] = cmds[i + 1];
                cmds[i + 1] = temp;
                changed = true;
            }
        }
    }
    return cmds;
}

/// Build an alias path by replacing the last component with the alias name
pub fn buildAliasPath(comptime original_path: []const []const u8, comptime alias: []const u8) []const []const u8 {
    comptime {
        if (original_path.len == 0) return &[_][]const u8{alias};
        if (original_path.len == 1) return &[_][]const u8{alias};
        var result: []const []const u8 = &.{};
        for (original_path[0 .. original_path.len - 1]) |component| {
            result = result ++ &[_][]const u8{component};
        }
        result = result ++ &[_][]const u8{alias};
        return result;
    }
}

/// Check if two paths are equal at compile time
pub fn pathsEqual(comptime path1: []const []const u8, comptime path2: []const []const u8) bool {
    if (path1.len != path2.len) return false;
    inline for (path1, path2) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}
