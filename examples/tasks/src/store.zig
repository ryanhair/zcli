const std = @import("std");
const ztheme = @import("ztheme");

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

    /// Wrap `text` in this status's semantic color. Render with
    /// `.render(writer, &context.theme)` so it adapts to terminal capability.
    pub fn themed(self: Status, text: []const u8) ztheme.Themed([]const u8) {
        return switch (self) {
            .todo => ztheme.theme(text).muted(),
            .in_progress => ztheme.theme(text).warning(),
            .done => ztheme.theme(text).success(),
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

    /// Wrap `text` in this priority's semantic color (medium is left unstyled).
    pub fn themed(self: Priority, text: []const u8) ztheme.Themed([]const u8) {
        return switch (self) {
            .low => ztheme.theme(text).muted(),
            .medium => ztheme.theme(text),
            .high => ztheme.theme(text).warning(),
            .critical => ztheme.theme(text).err(),
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

pub fn load(allocator: std.mem.Allocator, io: std.Io) !LoadResult {
    const cwd = std.Io.Dir.cwd();
    const content = cwd.readFileAlloc(io, FILENAME, allocator, .limited(1024 * 1024)) catch {
        return .{ .value = .{}, ._parsed = null };
    };
    defer allocator.free(content);
    if (content.len == 0) return .{ .value = .{}, ._parsed = null };
    const parsed = std.json.parseFromSlice(ProjectData, allocator, content, .{
        .allocate = .alloc_always,
    }) catch return .{ .value = .{}, ._parsed = null };
    return .{ .value = parsed.value, ._parsed = parsed };
}

pub fn save(_: std.mem.Allocator, io: std.Io, data: ProjectData) !void {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, FILENAME, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    try fw.interface.print("{f}", .{std.json.fmt(data, .{ .whitespace = .indent_2 })});
    try fw.interface.flush();
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
