const std = @import("std");
const zcli = @import("zcli");

const SWAPI_BASE_URL = "https://swapi.tech/api";

pub fn fetchFromSwapi(allocator: std.mem.Allocator, endpoint: []const u8, id: ?u32) !std.json.Parsed(std.json.Value) {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build URL
    var url_buf: [256]u8 = undefined;
    const url = if (id) |actual_id|
        try std.fmt.bufPrint(url_buf[0..], "{s}/{s}/{d}", .{ SWAPI_BASE_URL, endpoint, actual_id })
    else
        try std.fmt.bufPrint(url_buf[0..], "{s}/{s}", .{ SWAPI_BASE_URL, endpoint });

    const uri = std.Uri.parse(url) catch return error.InvalidUri;

    const header_buffer = try allocator.alloc(u8, 1024);
    defer allocator.free(header_buffer);

    var req = client.open(.GET, uri, .{
        .server_header_buffer = header_buffer,
    }) catch |err| {
        return err;
    };
    defer req.deinit();

    try req.send();
    try req.finish();
    try req.wait();

    if (req.response.status != .ok) {
        return error.HttpRequestFailed;
    }

    const body = try req.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(body);

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
    .description = "Get information about Star Wars films",
    .long_description =
    \\Retrieve information about Star Wars films from the SWAPI database.
    \\
    \\Examples:
    \\  swapi films           # List all films
    \\  swapi films 1         # Get A New Hope
    \\  swapi films 2         # Get The Empire Strikes Back
    ,
    .args = .{
        .id = "Film ID (optional - omit to list all)",
    },
    .options = .{
        .pretty = .{ .desc = "Pretty print JSON output", .short = 'p' },
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
    const response = fetchFromSwapi(allocator, "films", args.id) catch |err| {
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
