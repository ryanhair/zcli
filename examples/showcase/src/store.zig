const std = @import("std");

pub const Status = enum {
    todo,
    in_progress,
    done,

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .todo => "todo",
            .in_progress => "in progress",
            .done => "done",
        };
    }

    pub fn color(self: Status) []const u8 {
        return switch (self) {
            .todo => "\x1b[37m",
            .in_progress => "\x1b[33m",
            .done => "\x1b[32m",
        };
    }
};

pub const Priority = enum {
    low,
    medium,
    high,
    critical,

    pub fn label(self: Priority) []const u8 {
        return switch (self) {
            .low => "low",
            .medium => "medium",
            .high => "high",
            .critical => "critical",
        };
    }

    pub fn badge(self: Priority) []const u8 {
        return switch (self) {
            .low => "\x1b[2mlow\x1b[0m",
            .medium => "medium",
            .high => "\x1b[33mhigh\x1b[0m",
            .critical => "\x1b[31mcritical\x1b[0m",
        };
    }
};

pub const Task = struct {
    id: u32,
    title: []const u8,
    description: []const u8 = "",
    status: Status = .todo,
    priority: Priority = .medium,
    points: ?u32 = null,
    sprint: ?[]const u8 = null,
};

pub const ProjectData = struct {
    name: []const u8 = "My Project",
    description: []const u8 = "",
    next_id: u32 = 1,
    tasks: []Task = &.{},
    sprints: [][]const u8 = &.{},
};

const FILENAME = "tasks.json";

pub const LoadResult = struct {
    value: ProjectData,
    _parsed: ?std.json.Parsed(ProjectData),

    pub fn deinit(self: *LoadResult) void {
        if (self._parsed) |*p| p.deinit();
    }
};

pub fn load(allocator: std.mem.Allocator) !LoadResult {
    const file = std.fs.cwd().openFile(FILENAME, .{}) catch {
        return .{ .value = .{}, ._parsed = null };
    };
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);
    if (content.len == 0) return .{ .value = .{}, ._parsed = null };
    const parsed = std.json.parseFromSlice(ProjectData, allocator, content, .{
        .allocate = .alloc_always,
    }) catch return .{ .value = .{}, ._parsed = null };
    return .{ .value = parsed.value, ._parsed = parsed };
}

pub fn save(_: std.mem.Allocator, data: ProjectData) !void {
    const file = try std.fs.cwd().createFile(FILENAME, .{});
    defer file.close();
    var fw = file.writer(&.{});
    try fw.interface.print("{f}", .{std.json.fmt(data, .{ .whitespace = .indent_2 })});
}

pub fn findById(tasks: []const Task, id: u32) ?*const Task {
    for (tasks) |*task| {
        if (task.id == id) return task;
    }
    return null;
}

pub fn statusFromString(s: []const u8) ?Status {
    if (std.mem.eql(u8, s, "todo")) return .todo;
    if (std.mem.eql(u8, s, "in_progress") or std.mem.eql(u8, s, "in-progress")) return .in_progress;
    if (std.mem.eql(u8, s, "done")) return .done;
    return null;
}

pub fn priorityFromString(s: []const u8) ?Priority {
    if (std.mem.eql(u8, s, "low")) return .low;
    if (std.mem.eql(u8, s, "medium")) return .medium;
    if (std.mem.eql(u8, s, "high")) return .high;
    if (std.mem.eql(u8, s, "critical")) return .critical;
    return null;
}
