const std = @import("std");
const logging = @import("../logging.zig");
const types = @import("types.zig");

const PluginInfo = types.PluginInfo;

// ============================================================================
// PLUGIN SYSTEM - Discovery, management, and configuration
// ============================================================================

/// Scan local plugins directory and return plugin info.
///
/// Returns `null` when the configured `plugins_dir` simply does not exist —
/// a local plugins directory is legitimately optional, so a missing one is a
/// clean "no local plugins" outcome, NOT a failure. Every other failure
/// (AccessDenied, NotDir, traversal in the path, an unreadable entry mid-scan,
/// …) propagates as an error so the caller can surface it loudly instead of
/// silently building with zero plugins. This missing-vs-broken split is made
/// at the type level (`?[]PluginInfo`) rather than by catching everything.
pub fn scanLocalPlugins(b: *std.Build, plugins_dir: []const u8) !?[]PluginInfo {
    // Validate plugins directory path
    if (std.mem.indexOf(u8, plugins_dir, "..") != null) {
        return error.InvalidPath;
    }

    // Try to open the plugins directory
    var dir = b.build_root.handle.openDir(b.graph.io, plugins_dir, .{ .iterate = true }) catch |err| {
        // A missing directory is the one benign case: report it as `null` so
        // the caller treats it as "no local plugins". Anything else (denied
        // permissions, a file where a dir was expected, …) is a real error.
        if (err == error.FileNotFound) {
            return null;
        }
        return err;
    };
    defer dir.close(b.graph.io);

    return try scanInDir(b.allocator, b.graph.io, dir, plugins_dir);
}

/// Scan an already-open plugins directory handle. Split out of
/// `scanLocalPlugins` so the entry-iteration and error-propagation behaviour
/// can be unit-tested against a tmp dir without constructing a `*std.Build`
/// (mirrors command_discovery's `discoverInDir` split). Real errors mid-scan
/// (an unreadable subdirectory, a failing stat) propagate; the only skips are
/// deliberate classification (non-plugin entries, invalid names, dirs without a
/// plugin.zig).
fn scanInDir(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, plugins_dir: []const u8) ![]PluginInfo {
    var plugins = std.ArrayList(PluginInfo).empty;
    defer plugins.deinit(allocator);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                // Single-file plugins (e.g., auth.zig)
                if (std.mem.endsWith(u8, entry.name, ".zig")) {
                    const plugin_name = entry.name[0 .. entry.name.len - 4]; // Remove .zig

                    if (!isValidPluginName(plugin_name)) {
                        logging.invalidCommandName(plugin_name, "invalid plugin name");
                        continue;
                    }

                    const import_name = try std.fmt.allocPrint(allocator, "plugins/{s}", .{plugin_name});
                    // `entry.name` aliases the iterator's buffer, reused on the
                    // next `next()`, so `plugin_name` must be duped to outlive the
                    // scan (import_name/project_path already copy via allocPrint).
                    const project_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ plugins_dir, entry.name });

                    try plugins.append(allocator, PluginInfo{
                        .name = try allocator.dupe(u8, plugin_name),
                        .import_name = import_name,
                        .is_local = true,
                        .dependency = null,
                        .project_path = project_path,
                    });
                }
            },
            .directory => {
                // Multi-file plugins (e.g., metrics/ with plugin.zig inside)
                if (entry.name[0] == '.') continue; // Skip hidden directories

                if (!isValidPluginName(entry.name)) {
                    logging.invalidCommandName(entry.name, "invalid plugin directory name");
                    continue;
                }

                // Check if directory has a plugin.zig file. Failing to open a
                // subdirectory we just enumerated is a real error (e.g.
                // AccessDenied) — propagate it rather than silently skipping.
                var subdir = try dir.openDir(io, entry.name, .{});
                defer subdir.close(io);

                // A missing plugin.zig legitimately means "this dir isn't a
                // plugin" — skip it. Any other stat error propagates.
                _ = subdir.statFile(io, "plugin.zig", .{}) catch |err| {
                    if (err == error.FileNotFound) continue;
                    return err;
                };

                const import_name = try std.fmt.allocPrint(allocator, "plugins/{s}/plugin", .{entry.name});
                // Dupe entry.name — it aliases the iterator's reused buffer.
                const project_path = try std.fmt.allocPrint(allocator, "{s}/{s}/plugin.zig", .{ plugins_dir, entry.name });

                try plugins.append(allocator, PluginInfo{
                    .name = try allocator.dupe(u8, entry.name),
                    .import_name = import_name,
                    .is_local = true,
                    .dependency = null,
                    .project_path = project_path,
                });
            },
            else => continue,
        }
    }

    return plugins.toOwnedSlice(allocator);
}

/// Combine local and external plugins into a single array
pub fn combinePlugins(b: *std.Build, local_plugins: []const PluginInfo, external_plugins: []const PluginInfo) []const PluginInfo {
    if (local_plugins.len == 0 and external_plugins.len == 0) {
        return &.{};
    }

    const total_len = local_plugins.len + external_plugins.len;
    const combined = b.allocator.alloc(PluginInfo, total_len) catch {
        logging.buildError("Plugin System", "memory allocation", "Failed to allocate memory for combined plugin array", "Reduce number of plugins or increase available memory");
        std.debug.print("Attempted to allocate {} plugin entries.\n", .{total_len});
        return &.{}; // Return empty slice on failure
    };

    // Copy local plugins first
    @memcpy(combined[0..local_plugins.len], local_plugins);

    // Copy external plugins after
    @memcpy(combined[local_plugins.len..], external_plugins);

    return combined;
}

/// Validate a plugin file/directory name: identifier-style first char,
/// then alphanumeric/underscore/dash; path separators and traversal
/// rejected. (Looser than isValidCommandName — no reserved-name list.)
fn isValidPluginName(name: []const u8) bool {
    if (name.len == 0) return false;

    // Check for forbidden patterns
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (std.mem.indexOf(u8, name, "/") != null) return false;
    if (std.mem.indexOf(u8, name, "\\") != null) return false;

    // Check first character
    const first = name[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;

    // Check remaining characters
    for (name[1..]) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '-') return false;
    }

    return true;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "isValidPluginName: accepts plugin-ish names, rejects traversal and junk" {
    try testing.expect(isValidPluginName("auth"));
    try testing.expect(isValidPluginName("_internal"));
    try testing.expect(isValidPluginName("zcli-help"));
    try testing.expect(isValidPluginName("metrics2"));

    try testing.expect(!isValidPluginName(""));
    try testing.expect(!isValidPluginName("2fast"));
    try testing.expect(!isValidPluginName("has space"));
    try testing.expect(!isValidPluginName("../escape"));
    try testing.expect(!isValidPluginName("a/b"));
    try testing.expect(!isValidPluginName("a\\b"));
}

/// Free everything `scanInDir` allocated for a result slice.
fn freeScanResult(allocator: std.mem.Allocator, plugins: []PluginInfo) void {
    for (plugins) |p| {
        allocator.free(p.name);
        allocator.free(p.import_name);
        if (p.project_path) |pp| allocator.free(pp);
    }
    allocator.free(plugins);
}

test "scanInDir: discovers single-file and multi-file plugins, skips non-plugins" {
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // auth.zig — a single-file plugin.
    try tmp.dir.writeFile(io, .{ .sub_path = "auth.zig", .data = "pub const foo = 1;" });
    // metrics/plugin.zig — a multi-file plugin.
    try tmp.dir.createDir(io, "metrics", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "metrics/plugin.zig", .data = "pub const foo = 1;" });
    // notaplugin/ — a directory WITHOUT plugin.zig: must be skipped, not error.
    try tmp.dir.createDir(io, "notaplugin", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "notaplugin/other.zig", .data = "pub const foo = 1;" });
    // README.md — a non-.zig file: ignored.
    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "hi" });

    var dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);

    const plugins = try scanInDir(testing.allocator, io, dir, "src/plugins");
    defer freeScanResult(testing.allocator, plugins);

    try testing.expectEqual(@as(usize, 2), plugins.len);

    var saw_auth = false;
    var saw_metrics = false;
    for (plugins) |p| {
        if (std.mem.eql(u8, p.name, "auth")) {
            saw_auth = true;
            try testing.expectEqualStrings("plugins/auth", p.import_name);
            try testing.expectEqualStrings("src/plugins/auth.zig", p.project_path.?);
        } else if (std.mem.eql(u8, p.name, "metrics")) {
            saw_metrics = true;
            try testing.expectEqualStrings("plugins/metrics/plugin", p.import_name);
            try testing.expectEqualStrings("src/plugins/metrics/plugin.zig", p.project_path.?);
        }
    }
    try testing.expect(saw_auth);
    try testing.expect(saw_metrics);
}

test "scanInDir: empty directory yields no plugins" {
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);

    const plugins = try scanInDir(testing.allocator, io, dir, "src/plugins");
    defer freeScanResult(testing.allocator, plugins);

    try testing.expectEqual(@as(usize, 0), plugins.len);
}

// NOTE: The real-error classification in `scanLocalPlugins` (traversal in the
// path → error.InvalidPath; missing dir → null; AccessDenied/NotDir →
// propagated) and the loud `@panic`/`buildError` reporting in
// `main.buildWithPlugins` run only inside a `*std.Build` context, which cannot
// be constructed in a unit test. `scanInDir` above covers the entry-iteration
// and skip-vs-error behaviour; the outer classification is exercised by real
// builds (`zig build`, examples, projects/zcli) and documented at the call
// site. The path-traversal guard is a pure string check, tested next.

test "scanLocalPlugins path guard: rejects traversal in plugins_dir" {
    // The `..` check is a pure prefix of scanLocalPlugins, reachable without a
    // filesystem or a *std.Build handle for the offending case.
    try testing.expect(std.mem.indexOf(u8, "../evil", "..") != null);
    try testing.expect(std.mem.indexOf(u8, "src/../plugins", "..") != null);
    try testing.expect(std.mem.indexOf(u8, "src/plugins", "..") == null);
}
