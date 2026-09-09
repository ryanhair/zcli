//! Executable resolution for `process.zig`.
//!
//! This module turns a process.Program-shaped value into one owned absolute
//! path. It contains all PATH and Windows image-selection policy; spawning only
//! receives the resolved result.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const is_windows = builtin.os.tag == .windows;
const path_sep = if (is_windows) ';' else ':';
const windows_exts = [_][]const u8{ ".bat", ".cmd", ".com", ".exe" };

pub const PolicyError = error{
    ProgramNotFound,
    UnsafeSearchPath,
    UnsafeProgramName,
    BatchScriptRefused,
    AmbiguousProgram,
    UnsupportedProgramExtension,
};
pub const Error = PolicyError || Allocator.Error;

pub const Resolved = struct { path: []u8 };

fn eqlIgnoreCaseAscii(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

fn supportedExtension(path: []const u8) ?std.process.WindowsExtension {
    for (windows_exts, 0..) |ext, i| {
        if (path.len > ext.len and eqlIgnoreCaseAscii(path[path.len - ext.len ..], ext)) {
            return @enumFromInt(i);
        }
    }
    return null;
}

fn isScriptExtension(ext: std.process.WindowsExtension) bool {
    return ext == .bat or ext == .cmd;
}

fn validBasename(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
    if (is_windows and (std.mem.indexOfScalar(u8, name, '\\') != null or
        std.mem.indexOfScalar(u8, name, ':') != null)) return false;
    return true;
}

fn classifyWindowsTarget(path: []const u8, allow_script: bool, sibling_exists: bool) Error!void {
    const ext = supportedExtension(path) orelse return error.UnsupportedProgramExtension;
    if (isScriptExtension(ext) and !allow_script) return error.BatchScriptRefused;
    if (sibling_exists) return error.AmbiguousProgram;
}

fn checkWindowsTarget(io: Io, allocator: Allocator, path: []const u8, allow_script: bool) Error!void {
    if (!is_windows) return;
    var sibling_exists = false;
    for (windows_exts) |sibling_ext| {
        const candidate = try std.fmt.allocPrint(allocator, "{s}{s}", .{ path, sibling_ext });
        defer allocator.free(candidate);
        Io.Dir.accessAbsolute(io, candidate, .{}) catch continue;
        sibling_exists = true;
        break;
    }
    return classifyWindowsTarget(path, allow_script, sibling_exists);
}

fn windowsPathExt(env: *const std.process.Environ.Map, out: *[windows_exts.len][]const u8) []const []const u8 {
    var n: usize = 0;
    const raw = env.get("PATHEXT") orelse ".COM;.EXE;.BAT;.CMD";
    var it = std.mem.splitScalar(u8, raw, ';');
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        for (windows_exts) |ext| {
            if (!eqlIgnoreCaseAscii(entry, ext)) continue;
            var seen = false;
            for (out[0..n]) |already| if (std.mem.eql(u8, already, ext)) {
                seen = true;
            };
            if (!seen) {
                out[n] = ext;
                n += 1;
            }
        }
    }
    if (n == 0) {
        out[0] = ".exe";
        n = 1;
    }
    return out[0..n];
}

fn searchDirs(
    io: Io,
    allocator: Allocator,
    name: []const u8,
    dirs: []const []const u8,
    child_env: *const std.process.Environ.Map,
) Error![]u8 {
    if (!validBasename(name)) return error.UnsafeProgramName;
    var ext_storage: [windows_exts.len][]const u8 = undefined;
    const exts: []const []const u8 = if (is_windows)
        (if (supportedExtension(name) != null) &.{""} else windowsPathExt(child_env, &ext_storage))
    else
        &.{""};

    for (dirs) |dir| {
        if (!std.fs.path.isAbsolute(dir)) return error.UnsafeSearchPath;
        for (exts) |ext| {
            const candidate = try std.fmt.allocPrint(allocator, "{s}{c}{s}{s}", .{
                std.mem.trimEnd(u8, dir, if (is_windows) "\\/" else "/"),
                std.fs.path.sep,
                name,
                ext,
            });
            errdefer allocator.free(candidate);
            Io.Dir.accessAbsolute(io, candidate, .{ .execute = true }) catch {
                allocator.free(candidate);
                continue;
            };
            return candidate;
        }
    }
    return error.ProgramNotFound;
}

fn searchPath(io: Io, allocator: Allocator, name: []const u8, child_env: *const std.process.Environ.Map) Error![]u8 {
    if (!validBasename(name)) return error.UnsafeProgramName;
    const raw = child_env.get("PATH") orelse return error.ProgramNotFound;
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(allocator);
    var it = std.mem.splitScalar(u8, raw, path_sep);
    while (it.next()) |entry| {
        if (entry.len == 0 or !std.fs.path.isAbsolute(entry)) continue;
        try dirs.append(allocator, entry);
    }
    return searchDirs(io, allocator, name, dirs.items, child_env);
}

pub fn resolve(
    io: Io,
    allocator: Allocator,
    program: anytype,
    child_env: *const std.process.Environ.Map,
    allow_script: bool,
) Error!Resolved {
    const path: []u8 = switch (program) {
        .path => |p| blk: {
            const abs = Io.Dir.cwd().realPathFileAlloc(io, p, allocator) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ProgramNotFound,
            };
            break :blk try dupeAndFreeSentinel(allocator, abs);
        },
        .at => |at| blk: {
            const abs = at.dir.realPathFileAlloc(io, at.path, allocator) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ProgramNotFound,
            };
            break :blk try dupeAndFreeSentinel(allocator, abs);
        },
        .in_dirs => |d| try searchDirs(io, allocator, d.name, d.dirs, child_env),
        .search_path => |name| try searchPath(io, allocator, name, child_env),
    };
    errdefer allocator.free(path);
    try checkWindowsTarget(io, allocator, path, allow_script);
    return .{ .path = path };
}

fn dupeAndFreeSentinel(allocator: Allocator, value: [:0]u8) Allocator.Error![]u8 {
    defer allocator.free(value);
    return allocator.dupe(u8, value);
}

pub fn testTargetRules() !void {
    const t = std.testing;
    try t.expect(validBasename("gh"));
    try t.expect(validBasename("secret-tool"));
    for ([_][]const u8{ "", ".", "..", "sub/tool", "../../bin/sh" }) |name| try t.expect(!validBasename(name));
    if (is_windows) for ([_][]const u8{ "..\\x", "C:tool", "tool:stream" }) |name| try t.expect(!validBasename(name));

    try t.expectEqual(std.process.WindowsExtension.exe, supportedExtension("C:\\d\\gh.exe").?);
    try t.expectEqual(std.process.WindowsExtension.bat, supportedExtension("C:\\d\\gh.BAT").?);
    try t.expectEqual(std.process.WindowsExtension.cmd, supportedExtension("C:\\d\\gh.Cmd").?);
    try t.expectEqual(std.process.WindowsExtension.com, supportedExtension("x.COM").?);
    try t.expect(supportedExtension("C:\\d\\gh") == null);
    try t.expect(supportedExtension("C:\\d\\gh.ps1") == null);
    try t.expect(supportedExtension(".exe") == null);
    try t.expect(isScriptExtension(.bat));
    try t.expect(isScriptExtension(.cmd));
    try t.expect(!isScriptExtension(.exe));
    try t.expect(!isScriptExtension(.com));
    try classifyWindowsTarget("C:\\d\\gh.exe", false, false);
    try classifyWindowsTarget("C:\\d\\gh.COM", false, false);
    try t.expectError(error.UnsupportedProgramExtension, classifyWindowsTarget("C:\\d\\gh", false, false));
    try t.expectError(error.UnsupportedProgramExtension, classifyWindowsTarget("C:\\d\\gh.ps1", false, false));
    try t.expectError(error.BatchScriptRefused, classifyWindowsTarget("C:\\d\\gh.cmd", false, false));
    try t.expectError(error.BatchScriptRefused, classifyWindowsTarget("C:\\d\\gh.BAT", false, false));
    try classifyWindowsTarget("C:\\d\\gh.cmd", true, false);
    try t.expectError(error.AmbiguousProgram, classifyWindowsTarget("C:\\d\\gh.exe", false, true));
    try t.expectError(error.AmbiguousProgram, classifyWindowsTarget("C:\\d\\gh.exe", true, true));
    try t.expectError(error.BatchScriptRefused, classifyWindowsTarget("C:\\d\\gh.cmd", false, true));
}

pub fn testPathExt() !void {
    const a = std.testing.allocator;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var storage: [windows_exts.len][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), windowsPathExt(&env, &storage).len);
    try env.put("PATHEXT", ".PS1;.EXE;.CMD;.EXE");
    const got = windowsPathExt(&env, &storage);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings(".exe", got[0]);
    try std.testing.expectEqualStrings(".cmd", got[1]);
    try env.put("PATHEXT", ".PS1;.VBS");
    const fallback = windowsPathExt(&env, &storage);
    try std.testing.expectEqual(@as(usize, 1), fallback.len);
    try std.testing.expectEqualStrings(".exe", fallback[0]);
}

pub fn testSearchPolicy() !void {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try std.testing.expectError(error.UnsafeSearchPath, searchDirs(io, a, "sh", &.{"relative/dir"}, &env));
    try std.testing.expectError(error.UnsafeProgramName, searchDirs(io, a, "../../bin/sh", &.{"/usr/bin"}, &env));
    try std.testing.expectError(error.UnsafeProgramName, searchPath(io, a, "sub/tool", &env));
    if (is_windows) return error.SkipZigTest;
    try env.put("PATH", ":relative/bin:");
    try std.testing.expectError(error.ProgramNotFound, searchPath(io, a, "sh", &env));
    try env.put("PATH", ":relative/bin:/bin");
    const found = searchPath(io, a, "sh", &env) catch return error.SkipZigTest;
    defer a.free(found);
    try std.testing.expect(std.fs.path.isAbsolute(found));
    try std.testing.expectEqualStrings("/bin/sh", found);
}

pub fn testResolution(comptime ProgramType: type) !void {
    if (is_windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("PATH", "/bin:/usr/bin");
    for ([_]ProgramType{
        .{ .path = "/bin/sh" },
        .{ .in_dirs = .{ .name = "sh", .dirs = &.{"/bin"} } },
        .{ .search_path = "sh" },
    }) |program| {
        const result = resolve(io, a, program, &env, false) catch continue;
        defer a.free(result.path);
        try std.testing.expect(std.fs.path.isAbsolute(result.path));
    }
    try std.testing.expectError(error.ProgramNotFound, resolve(io, a, ProgramType{
        .search_path = "zcli-no-such-program-anywhere",
    }, &env, false));
    try std.testing.expectError(error.ProgramNotFound, resolve(io, a, ProgramType{
        .path = "/nonexistent/zcli-no-such-program",
    }, &env, false));
}
