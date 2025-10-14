const std = @import("std");

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    if (args.len < 2) {
        try showHelp();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "help")) {
        try showHelp();
    } else if (std.mem.eql(u8, command, "colors")) {
        try showColors();
    } else if (std.mem.eql(u8, command, "dynamic")) {
        try showDynamicContent();
    } else if (std.mem.eql(u8, command, "json")) {
        try showJson();
    } else if (std.mem.eql(u8, command, "table")) {
        try showTable();
    } else if (std.mem.eql(u8, command, "logs")) {
        try showLogs();
    } else {
        try showError("Unknown command");
        std.process.exit(1);
    }
}

fn showHelp() !void {
    const help_text =
        \\snapshot-demo - Showcase for snapshot testing
        \\
        \\USAGE:
        \\    snapshot-demo <command>
        \\
        \\COMMANDS:
        \\    help        Show this help message
        \\    colors      Display colored output
        \\    dynamic     Show output with dynamic content (UUIDs, timestamps)
        \\    json        Output structured JSON data
        \\    table       Display a formatted table
        \\    logs        Show log messages with timestamps
        \\
        \\EXAMPLES:
        \\    snapshot-demo colors     # Test ANSI color handling
        \\    snapshot-demo dynamic    # Test dynamic content masking
        \\
    ;

    var stderr_writer = std.fs.File.stderr().writer(&.{});
    try stderr_writer.interface.writeAll(help_text);
}

fn showColors() !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    try stdout.print("\x1b[32m✅ SUCCESS:\x1b[0m Operation completed successfully\n", .{});
    try stdout.print("\x1b[31m❌ ERROR:\x1b[0m Something went wrong\n", .{});
    try stdout.print("\x1b[33m⚠️  WARNING:\x1b[0m This is a warning\n", .{});
    try stdout.print("\x1b[34m🔍 INFO:\x1b[0m Informational message\n", .{});
    try stdout.print("\x1b[35m🎨 STYLE:\x1b[0m \x1b[1mBold\x1b[0m \x1b[4mUnderline\x1b[0m \x1b[3mItalic\x1b[0m\n", .{});
    try stdout.print("\x1b[36mCyan text\x1b[0m with \x1b[91mbright red\x1b[0m mixed in\n", .{});
}

fn showDynamicContent() !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    // Generate some UUIDs and timestamps
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    // Mock UUID generation
    try stdout.print("User ID: {x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}\n", .{ random.int(u32), random.int(u16), random.int(u16), random.int(u16), random.int(u48) });

    // Current timestamp
    const timestamp = std.time.timestamp();
    try stdout.print("Timestamp: {d}\n", .{timestamp});
    try stdout.print("ISO Time: 2024-01-15T10:30:45.123Z\n", .{});

    // Memory addresses (simulated)
    try stdout.print("Memory address: 0x{x}\n", .{random.int(u64)});
    try stdout.print("Pointer: 0x{x}\n", .{random.int(usize)});

    // Session tokens
    try stdout.print("Session: sess_{x:0>16}\n", .{random.int(u64)});
    try stdout.print("Request ID: req_{x:0>8}\n", .{random.int(u32)});
}

fn showJson() !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    const json_output =
        \\{
        \\  "name": "snapshot-demo",
        \\  "version": "1.0.0",
        \\  "status": "active",
        \\  "features": [
        \\    "snapshot-testing",
        \\    "ansi-colors",
        \\    "dynamic-masking"
        \\  ],
        \\  "config": {
        \\    "debug": false,
        \\    "verbose": true,
        \\    "output_format": "json"
        \\  },
        \\  "stats": {
        \\    "tests_run": 42,
        \\    "snapshots_created": 15,
        \\    "success_rate": 98.5
        \\  }
        \\}
    ;

    try stdout.writeAll(json_output);
    try stdout.writeAll("\n");
}

fn showTable() !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("╭─────────────────┬──────────┬──────────┬─────────────╮\n");
    try stdout.writeAll("│ Feature         │ Status   │ Coverage │ Last Update │\n");
    try stdout.writeAll("├─────────────────┼──────────┼──────────┼─────────────┤\n");
    try stdout.writeAll("│ Basic Snapshots │ \x1b[32m✅ Ready\x1b[0m  │   100%   │ 2024-01-15  │\n");
    try stdout.writeAll("│ ANSI Colors     │ \x1b[32m✅ Ready\x1b[0m  │    95%   │ 2024-01-14  │\n");
    try stdout.writeAll("│ Dynamic Masking │ \x1b[32m✅ Ready\x1b[0m  │    88%   │ 2024-01-13  │\n");
    try stdout.writeAll("│ Error Reporting │ \x1b[33m⚠️  Beta\x1b[0m   │    75%   │ 2024-01-12  │\n");
    try stdout.writeAll("│ Performance     │ \x1b[31m❌ Todo\x1b[0m  │     0%   │     N/A     │\n");
    try stdout.writeAll("╰─────────────────┴──────────┴──────────┴─────────────╯\n");
}

fn showLogs() !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    // Simulate log entries with timestamps
    try stdout.print("[2024-01-15T10:30:45.123Z] INFO  Starting snapshot demo application\n", .{});
    try stdout.print("[2024-01-15T10:30:45.124Z] DEBUG Loading configuration from config.json\n", .{});
    try stdout.print("[2024-01-15T10:30:45.125Z] INFO  User login: user_550e8400-e29b-41d4-a716-446655440000\n", .{});
    try stdout.print("[2024-01-15T10:30:45.126Z] WARN  Rate limit approaching: 95/100 requests\n", .{});
    try stdout.print("[2024-01-15T10:30:45.127Z] ERROR Database connection failed: timeout after 5s\n", .{});
    try stdout.print("[2024-01-15T10:30:45.128Z] INFO  Retrying with backup database...\n", .{});
    try stdout.print("[2024-01-15T10:30:45.129Z] INFO  Connection established at 0x7fff5fbff710\n", .{});
}

fn showError(comptime msg: []const u8) !void {
    var stderr_writer = std.fs.File.stderr().writer(&.{});
    const stderr = &stderr_writer.interface;
    try stderr.print("\x1b[31mError:\x1b[0m {s}\n\n", .{msg});
    try stderr.writeAll("Run 'snapshot-demo help' for usage information.\n");
}
