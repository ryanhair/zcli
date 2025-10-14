const std = @import("std");

const VERSION = "1.0.0";

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try printHelp();
    } else if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        try printVersion();
    } else if (std.mem.eql(u8, cmd, "list")) {
        try handleList(args[2..]);
    } else if (std.mem.eql(u8, cmd, "status")) {
        try printStatus();
    } else {
        try printError(cmd);
    }
}

fn printUsage() !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    try stdout_writer.interface.writeAll("Usage: demo-cli <command> [options]\n");
    try stdout_writer.interface.writeAll("Try 'demo-cli help' for more information.\n");
}

fn printHelp() !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    // Print colored header with ANSI codes
    try stdout.print("\x1b[1;34mDemo CLI Tool v{s}\x1b[0m\n", .{VERSION});
    try stdout.print("\x1b[90m{s:=<60}\x1b[0m\n", .{""});
    try stdout.print("\n", .{});

    try stdout.print("\x1b[1mUSAGE:\x1b[0m\n", .{});
    try stdout.print("  demo-cli <command> [options]\n", .{});
    try stdout.print("\n", .{});

    try stdout.print("\x1b[1mCOMMANDS:\x1b[0m\n", .{});
    try stdout.print("  \x1b[32mhelp\x1b[0m       Show this help message\n", .{});
    try stdout.print("  \x1b[32mversion\x1b[0m    Show version information\n", .{});
    try stdout.print("  \x1b[32mlist\x1b[0m       List items (use -v for verbose)\n", .{});
    try stdout.print("  \x1b[32mstatus\x1b[0m     Show current status\n", .{});
    try stdout.print("\n", .{});

    try stdout.print("\x1b[1mOPTIONS:\x1b[0m\n", .{});
    try stdout.print("  \x1b[33m-h, --help\x1b[0m     Show help for a command\n", .{});
    try stdout.print("  \x1b[33m-v, --verbose\x1b[0m  Enable verbose output\n", .{});
    try stdout.print("\n", .{});

    try stdout.print("\x1b[1mEXAMPLES:\x1b[0m\n", .{});
    try stdout.print("  demo-cli list\n", .{});
    try stdout.print("  demo-cli list -v\n", .{});
    try stdout.print("  demo-cli status\n", .{});
}

fn printVersion() !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("demo-cli version {s}\n", .{VERSION});
    try stdout.print("Built with Zig\n", .{});
}

fn handleList(args: [][:0]u8) !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    var verbose = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        }
    }

    try stdout.print("\x1b[1mListing items:\x1b[0m\n", .{});

    // Simulate listing some items
    const items = [_][]const u8{ "config.json", "data.txt", "README.md" };

    for (items, 0..) |item, i| {
        if (verbose) {
            try stdout.print("  [{d}] \x1b[36m{s}\x1b[0m (file)\n", .{ i + 1, item });
        } else {
            try stdout.print("  {s}\n", .{item});
        }
    }

    try stdout.print("\n", .{});
    try stdout.print("Total: {d} items\n", .{items.len});
}

fn printStatus() !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    // Clear screen and move cursor home
    try stdout.print("\x1b[2J\x1b[H", .{});

    // Print status with colors and formatting
    try stdout.print("\x1b[1;35m[STATUS REPORT]\x1b[0m\n", .{});
    try stdout.print("\n", .{});

    try stdout.print("System: \x1b[32m● Online\x1b[0m\n", .{});
    try stdout.print("Database: \x1b[32m● Connected\x1b[0m\n", .{});
    try stdout.print("API: \x1b[33m● Warning\x1b[0m (high latency)\n", .{});
    try stdout.print("Cache: \x1b[31m● Error\x1b[0m (needs restart)\n", .{});

    // Move cursor to specific position
    try stdout.print("\x1b[6;1H", .{});
    try stdout.print("\n", .{});
    try stdout.print("Last updated: just now\n", .{});
}

fn printError(cmd: [:0]u8) !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    try stdout.print("\x1b[31mError:\x1b[0m Unknown command '{s}'\n", .{cmd});
    try stdout.print("Try 'demo-cli help' for a list of available commands.\n", .{});
}
