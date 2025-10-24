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

    // Make HTTP request
    var redirect_buffer: [4096]u8 = undefined;
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();

    try req.sendBodiless();
    var response = try req.receiveHead(&redirect_buffer);

    if (response.head.status != .ok) {
        std.log.err("HTTP request failed with status: {}", .{response.head.status});
        return error.HttpRequestFailed;
    }

    // Read body
    var transfer_buffer: [4096]u8 = undefined;
    const body = try response.reader(&transfer_buffer).allocRemaining(allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(body);

    // Parse as JSON
    return std.json.parseFromSlice(std.json.Value, allocator, body, .{});
}

pub fn printJsonPretty(_: std.mem.Allocator, value: std.json.Value, writer: anytype) !void {
    // Write pretty-printed JSON directly to writer
    try std.json.Stringify.value(value, .{ .whitespace = .indent_4 }, writer);
}

pub const meta = .{
    .description = "Get information about Star Wars characters from the SWAPI database",
    .examples = &.{
        "people          # List all people",
        "people 1        # Get Luke Skywalker",
        "people 4        # Get Darth Vader",
    },
    .args = .{
        .id = "Character ID (optional - omit to list all)",
    },
    .options = .{
        .pretty = .{ .description = "Pretty print JSON output", .short = 'p' },
    },
};

pub const Args = struct {
    id: ?u32 = null,
};

pub const Options = struct {
    pretty: bool = true,
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
        try std.json.Stringify.value(response.value, .{}, stdout);
        try stdout.writeAll("\n");
    }
}
