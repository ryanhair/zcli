const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "List containers",
    .usage = "container ls [OPTIONS]",
    .examples = &.{
        "container ls",
        "container ls --all",
        "container ls --filter status=running",
        "container ls --format table",
        "container ls --quiet",
    },
    .options = .{
        .all = .{ .desc = "Show all containers (default shows just running)", .short = 'a' },
        .filter = .{ .desc = "Filter output based on conditions provided" },
        .format = .{ .desc = "Pretty-print containers using a Go template or table" },
        .last = .{ .desc = "Show n last created containers (includes all states)", .short = 'n' },
        .latest = .{ .desc = "Show the latest created container (includes all states)", .short = 'l' },
        .no_trunc = .{ .desc = "Don't truncate output" },
        .quiet = .{ .desc = "Only display container IDs", .short = 'q' },
        .size = .{ .desc = "Display total file sizes", .short = 's' },
    },
};

pub const Args = struct {};

pub const Options = struct {
    all: bool = false,
    filter: []const []const u8 = &.{},
    format: ?[]const u8 = null,
    last: ?u32 = null,
    latest: bool = false,
    no_trunc: bool = false,
    quiet: bool = false,
    size: bool = false,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    _ = args;

    // Debug: print filter array info
    std.debug.print("DEBUG: filter array len = {d}\n", .{options.filter.len});
    std.debug.print("DEBUG: filter array ptr = {any}\n", .{options.filter.ptr});

    // Sample container data
    const containers = [_]struct {
        id: []const u8,
        image: []const u8,
        command: []const u8,
        created: []const u8,
        status: []const u8,
        ports: []const u8,
        names: []const u8,
        size: []const u8,
    }{
        .{
            .id = "a1b2c3d4e5f6",
            .image = "nginx:latest",
            .command = "nginx -g 'daemon off;'",
            .created = "2 hours ago",
            .status = "Up 2 hours",
            .ports = "0.0.0.0:80->80/tcp",
            .names = "web-server",
            .size = "109MB",
        },
        .{
            .id = "b2c3d4e5f6a1",
            .image = "postgres:13",
            .command = "docker-entrypoint.sh postgres",
            .created = "3 hours ago",
            .status = "Up 3 hours",
            .ports = "5432/tcp",
            .names = "database",
            .size = "314MB",
        },
        .{
            .id = "c3d4e5f6a1b2",
            .image = "redis:alpine",
            .command = "redis-server",
            .created = "1 day ago",
            .status = "Exited (0) 12 hours ago",
            .ports = "",
            .names = "cache",
            .size = "32MB",
        },
    };

    // Apply filters (simplified to avoid allocator complexity)
    var filtered_containers: [3]@TypeOf(containers[0]) = undefined;
    var filtered_count: usize = 0;

    for (containers) |container| {
        var include = true;

        // Filter by status
        if (!options.all and std.mem.indexOf(u8, container.status, "Exited") != null) {
            include = false;
        }

        // Apply custom filters
        for (options.filter) |filter| {
            if (std.mem.startsWith(u8, filter, "status=")) {
                const status = filter[7..];
                if (std.mem.indexOf(u8, container.status, status) == null) {
                    include = false;
                }
            }
        }

        if (include and filtered_count < filtered_containers.len) {
            filtered_containers[filtered_count] = container;
            filtered_count += 1;
        }
    }

    // Handle special display options
    if (options.quiet) {
        for (filtered_containers[0..filtered_count]) |container| {
            const id = if (options.no_trunc) container.id else container.id[0..@min(12, container.id.len)];
            try context.stdout().print("{s}\n", .{id});
        }
        return;
    }

    // Handle latest option
    if (options.latest and filtered_count > 0) {
        const container = filtered_containers[0];
        try printContainer(container, options, context);
        return;
    }

    // Handle last N option
    const display_count = if (options.last) |last| @min(last, filtered_count) else filtered_count;

    // Print header for table format
    if (options.format == null or std.mem.eql(u8, options.format.?, "table")) {
        try context.stdout().print("CONTAINER ID   IMAGE          COMMAND                  CREATED       STATUS                   PORTS                NAMES", .{});
        if (options.size) {
            try context.stdout().print("      SIZE", .{});
        }
        try context.stdout().print("\n", .{});
    }

    // Print containers
    for (filtered_containers[0..display_count]) |container| {
        try printContainer(container, options, context);
    }
}

fn printContainer(container: anytype, options: Options, context: *zcli.Context) !void {
    const id = if (options.no_trunc) container.id else container.id[0..@min(12, container.id.len)];
    const image = if (options.no_trunc) container.image else truncateString(container.image, 14);
    const command = if (options.no_trunc) container.command else truncateString(container.command, 24);

    try context.stdout().print("{s:<12}   {s:<14} {s:<24} {s:<13} {s:<24} {s:<20} {s}", .{ id, image, command, container.created, container.status, container.ports, container.names });

    if (options.size) {
        try context.stdout().print("   {s:>8}", .{container.size});
    }

    try context.stdout().print("\n", .{});
}

fn truncateString(str: []const u8, max_len: usize) []const u8 {
    if (str.len <= max_len) return str;
    return str[0..max_len];
}
