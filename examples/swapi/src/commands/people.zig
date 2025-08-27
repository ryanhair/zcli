const std = @import("std");
const zcli = @import("zcli");

const SWAPI_BASE_URL = "https://swapi.tech/api";

pub fn fetchFromSwapi(allocator: std.mem.Allocator, endpoint: []const u8, id: ?u32) !std.json.Parsed(std.json.Value) {
    // Use a much simpler approach - fetch without all the extra options
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build URL
    var url_buf: [256]u8 = undefined;
    const url = if (id) |actual_id|
        try std.fmt.bufPrint(url_buf[0..], "{s}/{s}/{d}", .{ SWAPI_BASE_URL, endpoint, actual_id })
    else
        try std.fmt.bufPrint(url_buf[0..], "{s}/{s}", .{ SWAPI_BASE_URL, endpoint });

    const uri = std.Uri.parse(url) catch return error.InvalidUri;
    
    // Try the most basic request possible
    const header_buffer = try allocator.alloc(u8, 1024);
    defer allocator.free(header_buffer);
    
    var req = client.open(.GET, uri, .{
        .server_header_buffer = header_buffer,
    }) catch |err| {
        std.log.err("Failed to open request: {}", .{err});
        return err;
    };
    defer req.deinit();

    req.send() catch |err| {
        std.log.err("Failed to send: {}", .{err});
        return err;
    };
    
    req.finish() catch |err| {
        std.log.err("Failed to finish: {}", .{err});
        return err;
    };
    
    req.wait() catch |err| {
        std.log.err("Failed to wait: {}", .{err});
        return err;
    };

    if (req.response.status != .ok) {
        std.log.err("HTTP request failed with status: {}", .{req.response.status});
        return error.HttpRequestFailed;
    }
    
    // Read body
    const body = req.reader().readAllAlloc(allocator, 1024 * 1024) catch |err| {
        std.log.err("Failed to read body: {}", .{err});
        return err;
    };
    defer allocator.free(body);

    // Parse as JSON
    return std.json.parseFromSlice(std.json.Value, allocator, body, .{});
}

pub fn printJsonPretty(allocator: std.mem.Allocator, value: std.json.Value, writer: anytype) !void {
    // Convert to pretty-printed JSON string
    var string = std.ArrayList(u8).init(allocator);
    defer string.deinit();

    try std.json.stringify(value, .{ .whitespace = .indent_4 }, string.writer());
    try writer.writeAll(string.items);
}

pub const meta = .{
    .description = "Get information about Star Wars characters",
    .long_description = 
        \\Retrieve information about Star Wars characters from the SWAPI database.
        \\
        \\Examples:
        \\  swapi people          # List all people 
        \\  swapi people 1        # Get Luke Skywalker
        \\  swapi people 4        # Get Darth Vader
    ,
};

pub const Args = struct {
    id: ?u32 = null,

    pub const __meta__ = .{
        .id = .{
            .description = "Character ID (optional - omit to list all)",
        },
    };
};

pub const Options = struct {
    @"pretty": bool = true,

    pub const __meta__ = .{
        .@"pretty" = .{
            .description = "Pretty print JSON output",
            .short = 'p',
        },
    };
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    const allocator = context.allocator;
    const stdout = context.stdout();

    // Make API request
    const response = fetchFromSwapi(allocator, "people", args.id) catch |err| {
        try context.stderr().print("Error fetching data: {}\n", .{err});
        return;
    };
    defer response.deinit();

    // Print result
    if (options.pretty) {
        try printJsonPretty(allocator, response.value, stdout);
        try stdout.writeAll("\n");
    } else {
        try std.json.stringify(response.value, .{}, stdout);
        try stdout.writeAll("\n");
    }
}