const std = @import("std");

const VERSION = "1.0.0";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        try printUsage(io);
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try printHelp(io);
    } else if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        try printVersion(io);
    } else if (std.mem.eql(u8, cmd, "list")) {
        try handleList(io, args[2..]);
    } else if (std.mem.eql(u8, cmd, "status")) {
        try printStatus(io);
    } else {
        try printError(io, cmd);
    }
}

fn printUsage(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io, "Usage: demo-cli <command> [options]\n");
    try std.Io.File.stdout().writeStreamingAll(io, "Try 'demo-cli help' for more information.\n");
}

fn printHelp(io: std.Io) !void {
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, "\x1b[1;34mDemo CLI Tool v" ++ VERSION ++ "\x1b[0m\n");
    try stdout.writeStreamingAll(io, "\n");
    try stdout.writeStreamingAll(io, "\x1b[1mUSAGE:\x1b[0m\n");
    try stdout.writeStreamingAll(io, "  demo-cli <command> [options]\n");
    try stdout.writeStreamingAll(io, "\n");
    try stdout.writeStreamingAll(io, "\x1b[1mCOMMANDS:\x1b[0m\n");
    try stdout.writeStreamingAll(io, "  \x1b[32mhelp\x1b[0m       Show this help message\n");
    try stdout.writeStreamingAll(io, "  \x1b[32mversion\x1b[0m    Show version information\n");
    try stdout.writeStreamingAll(io, "  \x1b[32mlist\x1b[0m       List items (use -v for verbose)\n");
    try stdout.writeStreamingAll(io, "  \x1b[32mstatus\x1b[0m     Show current status\n");
    try stdout.writeStreamingAll(io, "\n");
    try stdout.writeStreamingAll(io, "\x1b[1mOPTIONS:\x1b[0m\n");
    try stdout.writeStreamingAll(io, "  \x1b[33m-h, --help\x1b[0m     Show help for a command\n");
    try stdout.writeStreamingAll(io, "  \x1b[33m-v, --verbose\x1b[0m  Enable verbose output\n");
}

fn printVersion(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io, "demo-cli version " ++ VERSION ++ "\n");
    try std.Io.File.stdout().writeStreamingAll(io, "Built with Zig\n");
}

fn handleList(io: std.Io, args: []const [:0]const u8) !void {
    const stdout = std.Io.File.stdout();

    var verbose = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        }
    }

    try stdout.writeStreamingAll(io, "\x1b[1mListing items:\x1b[0m\n");

    const items = [_][]const u8{ "config.json", "data.txt", "README.md" };

    for (items, 0..) |item, i| {
        _ = i;
        if (verbose) {
            try stdout.writeStreamingAll(io, "  ");
            try stdout.writeStreamingAll(io, item);
            try stdout.writeStreamingAll(io, " (file)\n");
        } else {
            try stdout.writeStreamingAll(io, "  ");
            try stdout.writeStreamingAll(io, item);
            try stdout.writeStreamingAll(io, "\n");
        }
    }

    try stdout.writeStreamingAll(io, "\nTotal: 3 items\n");
}

fn printStatus(io: std.Io) !void {
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, "\x1b[1;35m[STATUS REPORT]\x1b[0m\n\n");
    try stdout.writeStreamingAll(io, "System: \x1b[32m● Online\x1b[0m\n");
    try stdout.writeStreamingAll(io, "Database: \x1b[32m● Connected\x1b[0m\n");
    try stdout.writeStreamingAll(io, "API: \x1b[33m● Warning\x1b[0m (high latency)\n");
    try stdout.writeStreamingAll(io, "Cache: \x1b[31m● Error\x1b[0m (needs restart)\n");
    try stdout.writeStreamingAll(io, "\nLast updated: just now\n");
}

fn printError(io: std.Io, cmd: [:0]const u8) !void {
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, "\x1b[31mError:\x1b[0m Unknown command '");
    try stdout.writeStreamingAll(io, cmd);
    try stdout.writeStreamingAll(io, "'\n");
    try stdout.writeStreamingAll(io, "Try 'demo-cli help' for a list of available commands.\n");
}
