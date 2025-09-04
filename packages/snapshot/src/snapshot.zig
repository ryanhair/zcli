const std = @import("std");

/// Options for snapshot testing behavior
pub const SnapshotOptions = struct {
    /// Whether to mask dynamic content (UUIDs, timestamps, memory addresses)
    mask: bool = true,
    /// Whether to preserve ANSI escape codes (colors, formatting)
    ansi: bool = true,
};

/// Unified snapshot testing function with configurable options
pub fn expectSnapshot(
    actual: []const u8,
    comptime location: std.builtin.SourceLocation,
    comptime snapshot_name: []const u8,
    options: SnapshotOptions,
) !void {
    // Build snapshot file path based on test file location
    const test_file_path = location.file;
    const snapshot_dir = comptime getSnapshotDir(test_file_path);
    const snapshot_file = snapshot_dir ++ "/" ++ snapshot_name ++ ".txt";
    
    const allocator = std.heap.page_allocator;
    
    // Process the actual content based on options
    var processed_actual: []const u8 = actual;
    var should_free_actual = false;
    defer if (should_free_actual) allocator.free(processed_actual);
    
    // Apply masking if requested
    if (options.mask) {
        processed_actual = try maskDynamicContent(allocator, processed_actual);
        should_free_actual = true;
    }
    
    // Strip ANSI if not preserving
    if (!options.ansi) {
        const previous = processed_actual;
        processed_actual = try stripAnsi(allocator, processed_actual);
        if (should_free_actual) allocator.free(previous);
        should_free_actual = true;
    }
    
    // Check if we should update snapshots
    const update_mode = std.process.getEnvVarOwned(allocator, "UPDATE_SNAPSHOTS") catch null;
    defer if (update_mode) |mode| allocator.free(mode);
    
    if (update_mode != null) {
        // Update mode - create/update the snapshot
        try updateSnapshot(allocator, snapshot_dir, snapshot_name, processed_actual);
        const snapshot_type = if (options.ansi) "ANSI " else "";
        const mask_info = if (options.mask) " (masked)" else "";
        std.debug.print("✅ Updated {s}snapshot: {s}{s}\n", .{ snapshot_type, snapshot_file, mask_info });
        return;
    }
    
    // Try to read existing snapshot
    const expected = std.fs.cwd().readFileAlloc(
        allocator, 
        snapshot_file, 
        1024 * 1024
    ) catch |err| switch (err) {
        error.FileNotFound => {
            // No snapshot exists - this is a new test
            printCleanMissingSnapshotError(.{
                .test_location = location,
                .snapshot_file = snapshot_file,
                .actual = processed_actual,
                .options = options,
            });
            return error.SnapshotMissing;
        },
        else => return err,
    };
    defer allocator.free(expected);
    
    // Compare with existing snapshot
    if (!std.mem.eql(u8, expected, processed_actual)) {
        printCleanSnapshotError(.{
            .test_location = location,
            .snapshot_file = snapshot_file,
            .expected = expected,
            .actual = processed_actual,
            .options = options,
        });
        return error.SnapshotMismatch;
    }
}

fn getSnapshotDir(comptime test_file_path: []const u8) []const u8 {
    // Get filename without extension for snapshot subdirectory
    const last_slash = std.mem.lastIndexOf(u8, test_file_path, "/") orelse 0;
    const filename = if (last_slash == 0) test_file_path else test_file_path[last_slash + 1 ..];
    const dot_index = std.mem.lastIndexOf(u8, filename, ".") orelse filename.len;
    const filename_no_ext = filename[0..dot_index];
    
    // Always use tests/snapshots as the base - this matches the existing structure
    return "tests/snapshots/" ++ filename_no_ext;
}

fn updateSnapshot(allocator: std.mem.Allocator, snapshot_dir: []const u8, snapshot_name: []const u8, content: []const u8) !void {
    // Ensure snapshot directory exists
    std.fs.cwd().makePath(snapshot_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    
    // Write snapshot file
    const snapshot_file = try std.fmt.allocPrint(allocator, "{s}/{s}.txt", .{ snapshot_dir, snapshot_name });
    defer allocator.free(snapshot_file);
    
    try std.fs.cwd().writeFile(.{ .sub_path = snapshot_file, .data = content });
}

const SnapshotErrorInfo = struct {
    test_location: std.builtin.SourceLocation,
    snapshot_file: []const u8,
    expected: []const u8,
    actual: []const u8,
    options: SnapshotOptions,
};

const MissingSnapshotInfo = struct {
    test_location: std.builtin.SourceLocation,
    snapshot_file: []const u8,
    actual: []const u8,
    options: SnapshotOptions,
};

fn printCleanMissingSnapshotError(info: MissingSnapshotInfo) void {
    // Extract just the test file name (not the full path)
    const last_slash = std.mem.lastIndexOf(u8, info.test_location.file, "/") orelse 0;
    const test_file = if (last_slash == 0) info.test_location.file else info.test_location.file[last_slash + 1 ..];
    
    // Extract just the snapshot file name
    const snapshot_last_slash = std.mem.lastIndexOf(u8, info.snapshot_file, "/") orelse 0;
    const snapshot_name = if (snapshot_last_slash == 0) info.snapshot_file else info.snapshot_file[snapshot_last_slash + 1 ..];
    
    std.debug.print("\n", .{});
    const snapshot_type = if (info.options.ansi) "ANSI " else "";
    const mask_info = if (info.options.mask) " (masked)" else "";
    
    std.debug.print("┌─ {s}SNAPSHOT MISSING ──────────────────────────────────────┐\n", .{snapshot_type});
    std.debug.print("│ Test:     {s}:{d}\n", .{ test_file, info.test_location.line });
    std.debug.print("│ Snapshot: {s}{s}\n", .{ snapshot_name, mask_info });
    std.debug.print("├─────────────────────────────────────────────────────────┤\n", .{});
    std.debug.print("│ Actual output preview:\n", .{});
    
    // Show preview of actual output (first few lines)
    var lines = std.mem.splitScalar(u8, info.actual, '\n');
    var line_count: usize = 0;
    while (lines.next()) |line| {
        if (line_count >= 3) {
            std.debug.print("│ ... ({d} more lines)\n", .{countRemainingLines(&lines) + 1});
            break;
        }
        const display = if (line.len > 50) line[0..47] ++ "..." else line;
        std.debug.print("│ {s}\n", .{display});
        line_count += 1;
    }
    
    std.debug.print("├─────────────────────────────────────────────────────────┤\n", .{});
    std.debug.print("│ Run 'zig build update-snapshots' to create\n", .{});
    std.debug.print("└─────────────────────────────────────────────────────────┘\n", .{});
    std.debug.print("\n", .{});
}

fn countRemainingLines(lines: *std.mem.SplitIterator(u8, std.mem.DelimiterType.scalar)) usize {
    var count: usize = 0;
    while (lines.next()) |_| {
        count += 1;
    }
    return count;
}

fn printCleanSnapshotError(info: SnapshotErrorInfo) void {
    // Extract just the test file name (not the full path)
    const last_slash = std.mem.lastIndexOf(u8, info.test_location.file, "/") orelse 0;
    const test_file = if (last_slash == 0) info.test_location.file else info.test_location.file[last_slash + 1 ..];
    
    // Extract just the snapshot file name
    const snapshot_last_slash = std.mem.lastIndexOf(u8, info.snapshot_file, "/") orelse 0;
    const snapshot_name = if (snapshot_last_slash == 0) info.snapshot_file else info.snapshot_file[snapshot_last_slash + 1 ..];
    
    std.debug.print("\n", .{});
    const snapshot_type = if (info.options.ansi) "ANSI " else "";
    const mask_info = if (info.options.mask) " (masked)" else "";
    
    std.debug.print("┌─ {s}SNAPSHOT MISMATCH ─────────────────────────────────────┐\n", .{snapshot_type});
    std.debug.print("│ Test:     {s}:{d}\n", .{ test_file, info.test_location.line });
    std.debug.print("│ Snapshot: {s}{s}\n", .{ snapshot_name, mask_info });
    std.debug.print("├─────────────────────────────────────────────────────────┤\n", .{});
    
    // Show a concise, side-by-side diff
    printEnhancedDiff(info.expected, info.actual);
    
    std.debug.print("├─────────────────────────────────────────────────────────┤\n", .{});
    std.debug.print("│ Run 'zig build update-snapshots' to update\n", .{});
    std.debug.print("└─────────────────────────────────────────────────────────┘\n", .{});
    std.debug.print("\n", .{});
}

fn printEnhancedDiff(expected: []const u8, actual: []const u8) void {
    var exp_lines = std.mem.splitScalar(u8, expected, '\n');
    var act_lines = std.mem.splitScalar(u8, actual, '\n');
    
    var line_num: usize = 1;
    var changes_shown: usize = 0;
    const max_changes = 5; // Only show first few changes to keep output clean
    
    while (changes_shown < max_changes) {
        const exp_line = exp_lines.next();
        const act_line = act_lines.next();
        
        if (exp_line == null and act_line == null) break;
        
        const exp = exp_line orelse "";
        const act = act_line orelse "";
        
        if (!std.mem.eql(u8, exp, act)) {
            if (changes_shown == 0) {
                std.debug.print("│\n", .{});
            }
            
            if (exp.len > 0) {
                // Truncate long lines
                const exp_display = if (exp.len > 50) exp[0..47] ++ "..." else exp;
                std.debug.print("│ -{d:3}: {s}\n", .{ line_num, exp_display });
            }
            if (act.len > 0) {
                // Truncate long lines  
                const act_display = if (act.len > 50) act[0..47] ++ "..." else act;
                std.debug.print("│ +{d:3}: {s}\n", .{ line_num, act_display });
            }
            
            changes_shown += 1;
        }
        
        line_num += 1;
    }
    
    // Count remaining changes
    var remaining_changes: usize = 0;
    while (true) {
        const exp_line = exp_lines.next();
        const act_line = act_lines.next();
        
        if (exp_line == null and act_line == null) break;
        
        const exp = exp_line orelse "";
        const act = act_line orelse "";
        
        if (!std.mem.eql(u8, exp, act)) {
            remaining_changes += 1;
        }
    }
    
    if (remaining_changes > 0) {
        std.debug.print("│ ... and {d} more difference(s)\n", .{remaining_changes});
    }
    
    if (changes_shown == 0) {
        std.debug.print("│ (Files have same line content but differ in other ways)\n", .{});
    }
}

fn printSimpleDiff(expected: []const u8, actual: []const u8) void {
    var exp_lines = std.mem.splitScalar(u8, expected, '\n');
    var act_lines = std.mem.splitScalar(u8, actual, '\n');
    
    var line_num: usize = 1;
    
    std.debug.print("\n--- Diff ---\n", .{});
    
    while (true) {
        const exp_line = exp_lines.next();
        const act_line = act_lines.next();
        
        if (exp_line == null and act_line == null) break;
        
        const exp = exp_line orelse "";
        const act = act_line orelse "";
        
        if (std.mem.eql(u8, exp, act)) {
            std.debug.print("  {d:3}   {s}\n", .{ line_num, exp });
        } else {
            if (exp.len > 0) {
                std.debug.print("- {d:3}   {s}\n", .{ line_num, exp });
            }
            if (act.len > 0) {
                std.debug.print("+ {d:3}   {s}\n", .{ line_num, act });
            }
        }
        
        line_num += 1;
    }
}

/// Mask dynamic content in text for stable snapshots
pub fn maskDynamicContent(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    // Start with UUID masking
    const uuid_result = try maskUUIDs(allocator, text, "[UUID]");
    defer if (uuid_result.ptr != text.ptr) allocator.free(uuid_result);
    
    // ISO 8601 timestamps with T separator
    const timestamp_result = try maskTimestamps(allocator, uuid_result, "[TIMESTAMP]");
    defer if (timestamp_result.ptr != uuid_result.ptr) allocator.free(timestamp_result);
    
    // Memory addresses (0x followed by hex)  
    const addr_result = try maskMemoryAddresses(allocator, timestamp_result, "[MEMORY_ADDR]");
    
    return addr_result;
}

/// Mask UUID patterns
fn maskUUIDs(allocator: std.mem.Allocator, text: []const u8, replacement: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    var i: usize = 0;
    
    while (i < text.len) {
        if (i + 36 <= text.len and isUUID(text[i..i + 36])) {
            // Found a UUID, replace it
            try result.appendSlice(replacement);
            i += 36;
        } else {
            try result.append(text[i]);
            i += 1;
        }
    }
    
    return result.toOwnedSlice();
}

/// Check if a 36-character string is a UUID
fn isUUID(text: []const u8) bool {
    if (text.len != 36) return false;
    
    // UUID format: 8-4-4-4-12 (with hyphens at positions 8, 13, 18, 23)
    if (text[8] != '-' or text[13] != '-' or text[18] != '-' or text[23] != '-') return false;
    
    // Check that all other characters are hex digits
    for (text, 0..) |char, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        if (!std.ascii.isHex(char)) return false;
    }
    
    return true;
}

/// Mask ISO 8601 timestamps
fn maskTimestamps(allocator: std.mem.Allocator, text: []const u8, replacement: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    var i: usize = 0;
    
    while (i < text.len) {
        if (i + 19 <= text.len) {
            // Look for YYYY-MM-DDTHH:MM:SS pattern
            if (isTimestamp(text[i..i + 19])) {
                // Found a timestamp, replace it
                try result.appendSlice(replacement);
                i += 19;
                
                // Skip optional milliseconds and timezone
                while (i < text.len and (std.ascii.isDigit(text[i]) or text[i] == '.' or text[i] == 'Z' or text[i] == '+' or text[i] == '-' or text[i] == ':')) {
                    i += 1;
                }
                continue;
            }
        }
        
        try result.append(text[i]);
        i += 1;
    }
    
    return result.toOwnedSlice();
}

/// Check if text matches YYYY-MM-DDTHH:MM:SS
fn isTimestamp(text: []const u8) bool {
    if (text.len < 19) return false;
    
    // Check YYYY-MM-DDTHH:MM:SS pattern
    return std.ascii.isDigit(text[0]) and std.ascii.isDigit(text[1]) and 
           std.ascii.isDigit(text[2]) and std.ascii.isDigit(text[3]) and text[4] == '-' and
           std.ascii.isDigit(text[5]) and std.ascii.isDigit(text[6]) and text[7] == '-' and
           std.ascii.isDigit(text[8]) and std.ascii.isDigit(text[9]) and text[10] == 'T' and
           std.ascii.isDigit(text[11]) and std.ascii.isDigit(text[12]) and text[13] == ':' and
           std.ascii.isDigit(text[14]) and std.ascii.isDigit(text[15]) and text[16] == ':' and
           std.ascii.isDigit(text[17]) and std.ascii.isDigit(text[18]);
}

/// Mask memory addresses (0x followed by hex)
fn maskMemoryAddresses(allocator: std.mem.Allocator, text: []const u8, replacement: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    var i: usize = 0;
    
    while (i < text.len) {
        if (i + 2 < text.len and text[i] == '0' and text[i + 1] == 'x') {
            // Found 0x, find end of hex address
            var end = i + 2;
            while (end < text.len and std.ascii.isHex(text[end])) {
                end += 1;
            }
            
            if (end > i + 2) {
                // Found a valid hex address, replace it
                try result.appendSlice(replacement);
                i = end;
                continue;
            }
        }
        
        try result.append(text[i]);
        i += 1;
    }
    
    return result.toOwnedSlice();
}

/// Helper for framework testing - allows testing specific snapshot error conditions
/// by passing explicit expected data (for testing framework behavior, not CLI output)
pub fn expectSnapshotWithData(
    actual: []const u8,
    comptime location: std.builtin.SourceLocation,
    comptime snapshot_name: []const u8,
    expected_data: ?[]const u8,
) !void {
    // If no expected data provided, use normal snapshot testing
    if (expected_data == null) {
        return expectSnapshot(actual, location, snapshot_name, .{});
    }
    
    const expected = expected_data.?;
    
    // Compare directly with provided expected data (for framework error testing)
    if (!std.mem.eql(u8, expected, actual)) {
        std.debug.print("\n❌ FRAMEWORK TEST SNAPSHOT MISMATCH\n", .{});
        std.debug.print("Test: {s}:{d}\n", .{ location.file, location.line });
        
        std.debug.print("\n--- Expected ---\n{s}\n", .{expected});
        std.debug.print("--- Actual ---\n{s}\n", .{actual});
        
        // Simple diff output
        printSimpleDiff(expected, actual);
        
        return error.SnapshotMismatch;
    }
}

/// Strip ANSI escape sequences from text for clean comparison
pub fn stripAnsi(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1B and i + 1 < text.len and text[i + 1] == '[') {
            // Found ANSI escape sequence, skip until we find the end
            i += 2; // Skip ESC[
            while (i < text.len) {
                const char = text[i];
                i += 1;
                // ANSI sequences end with a letter
                if ((char >= 'A' and char <= 'Z') or (char >= 'a' and char <= 'z')) {
                    break;
                }
            }
        } else {
            try result.append(text[i]);
            i += 1;
        }
    }
    
    return result.toOwnedSlice();
}

