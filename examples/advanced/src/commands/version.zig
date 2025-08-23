const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Show the Docker version information",
    .usage = "version [OPTIONS]",
    .examples = &.{
        "version",
        "version --format json",
    },
    .options = .{
        .format = .{ .desc = "Format the output using the given Go template", .short = 'f' },
    },
};

pub const Args = struct {};

pub const Options = struct {
    format: ?[]const u8 = null,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    _ = args;

    if (options.format) |format| {
        if (std.mem.eql(u8, format, "json")) {
            try context.stdout().print(
                \\{{
                \\  "Client": {{
                \\    "Version": "20.10.17",
                \\    "API version": "1.41",
                \\    "Go version": "go1.17.11",
                \\    "Git commit": "100c701",
                \\    "Built": "Mon Jun  6 22:04:33 2022",
                \\    "OS/Arch": "darwin/amd64"
                \\  }},
                \\  "Server": {{
                \\    "Engine": {{
                \\      "Version": "20.10.17",
                \\      "API version": "1.41",
                \\      "Go version": "go1.17.11",
                \\      "Git commit": "a89b842",
                \\      "Built": "Mon Jun  6 22:05:33 2022",
                \\      "OS/Arch": "linux/amd64"
                \\    }}
                \\  }}
                \\}}
                \\
            , .{});
        } else {
            try context.stderr().print("Error: Unsupported format: {s}\n", .{format});
        }
    } else {
        try context.stdout().print("Client: Dockr CLI 0.1.0\n", .{});
        try context.stdout().print(" Version:           0.1.0\n", .{});
        try context.stdout().print(" API version:       1.41\n", .{});
        try context.stdout().print(" Go version:        go1.17.11\n", .{});
        try context.stdout().print(" Git commit:        abc123d\n", .{});
        try context.stdout().print(" Built:             Mon Aug 19 10:00:00 2025\n", .{});
        try context.stdout().print(" OS/Arch:           darwin/amd64\n", .{});
        try context.stdout().print("\n", .{});
        try context.stdout().print("Server: Docker Engine - Community\n", .{});
        try context.stdout().print(" Engine:\n", .{});
        try context.stdout().print("  Version:          20.10.17\n", .{});
        try context.stdout().print("  API version:      1.41 (minimum version 1.12)\n", .{});
        try context.stdout().print("  Go version:       go1.17.11\n", .{});
        try context.stdout().print("  Git commit:       a89b842\n", .{});
        try context.stdout().print("  Built:            Mon Jun  6 22:05:33 2022\n", .{});
        try context.stdout().print("  OS/Arch:          linux/amd64\n", .{});
        try context.stdout().print("  Experimental:     false\n", .{});
    }
}
