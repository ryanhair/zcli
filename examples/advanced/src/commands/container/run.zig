const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Run a command in a new container",
    .usage = "container run [OPTIONS] IMAGE [COMMAND] [ARG...]",
    .examples = &.{
        "container run ubuntu",
        "container run -it ubuntu bash",
        "container run --name my-app --env PORT=3000 -p 3000:3000 node:16 npm start",
        "container run --rm --volume $(pwd):/app -w /app node:16 npm test",
    },
    .args = .{
        .image = "Container image to run",
        .command = "Command to run in container (optional)",
        .args = "Arguments to pass to the command (optional)",
    },
    .options = .{
        .detach = .{ .desc = "Run container in background", .short = 'd' },
        .interactive = .{ .desc = "Keep STDIN open", .short = 'i' },
        .tty = .{ .desc = "Allocate a pseudo-TTY", .short = 't' },
        .name = .{ .desc = "Assign a name to the container" },
        .env = .{ .desc = "Set environment variables (can be used multiple times)", .short = 'e' },
        .publish = .{ .desc = "Publish container ports to host (can be used multiple times)", .short = 'p' },
        .volume = .{ .desc = "Bind mount a volume (can be used multiple times)", .short = 'v' },
        .workdir = .{ .desc = "Working directory inside the container", .short = 'w' },
        .rm = .{ .desc = "Automatically remove the container when it exits" },
        .restart = .{ .desc = "Restart policy (no, on-failure, always, unless-stopped)" },
        .memory = .{ .desc = "Memory limit (e.g., 512m, 2g)", .short = 'm' },
        .cpus = .{ .desc = "Number of CPUs" },
    },
};

pub const Args = struct {
    image: []const u8,
    command: ?[]const u8 = null,
    args: []const []const u8 = &.{},
};

pub const Options = struct {
    detach: bool = false,
    interactive: bool = false,
    tty: bool = false,
    name: ?[]const u8 = null,
    env: []const []const u8 = &.{},
    publish: []const []const u8 = &.{},
    volume: []const []const u8 = &.{},
    workdir: ?[]const u8 = null,
    rm: bool = false,
    restart: enum { no, @"on-failure", always, @"unless-stopped" } = .no,
    memory: ?[]const u8 = null,
    cpus: ?f32 = null,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    // Show what would be executed
    try context.stdout().print("Running container from image: {s}\n", .{args.image});
    
    if (options.name) |name| {
        try context.stdout().print("Container name: {s}\n", .{name});
    }
    
    if (options.detach) {
        try context.stdout().print("Running in detached mode\n", .{});
    }
    
    if (options.interactive and options.tty) {
        try context.stdout().print("Running in interactive mode with TTY\n", .{});
    }
    
    if (options.env.len > 0) {
        try context.stdout().print("Environment variables:\n", .{});
        for (options.env) |env_var| {
            try context.stdout().print("  {s}\n", .{env_var});
        }
    }
    
    if (options.publish.len > 0) {
        try context.stdout().print("Port mappings:\n", .{});
        for (options.publish) |port| {
            try context.stdout().print("  {s}\n", .{port});
        }
    }
    
    if (options.volume.len > 0) {
        try context.stdout().print("Volume mounts:\n", .{});
        for (options.volume) |vol| {
            try context.stdout().print("  {s}\n", .{vol});
        }
    }
    
    if (options.workdir) |workdir| {
        try context.stdout().print("Working directory: {s}\n", .{workdir});
    }
    
    if (options.memory) |memory| {
        try context.stdout().print("Memory limit: {s}\n", .{memory});
    }
    
    if (options.cpus) |cpus| {
        try context.stdout().print("CPU limit: {d}\n", .{cpus});
    }
    
    if (args.command) |command| {
        try context.stdout().print("Command: {s}", .{command});
        if (args.args.len > 0) {
            for (args.args) |arg| {
                try context.stdout().print(" {s}", .{arg});
            }
        }
        try context.stdout().print("\n", .{});
    }
    
    // Simulate container ID
    try context.stdout().print("Container ID: abc123def456\n", .{});
    
    if (options.rm) {
        try context.stdout().print("Container will be automatically removed when it exits\n", .{});
    }
}