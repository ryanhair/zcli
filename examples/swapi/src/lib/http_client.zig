const std = @import("std");

const SWAPI_BASE_URL = "https://swapi.tech/api";

pub const SwapiResponse = struct {
    message: []const u8,
    result: std.json.Value,

    pub fn deinit(self: *SwapiResponse, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        // JSON values are managed by the parsed value
    }
};

pub const SwapiError = error{
    HttpRequestFailed,
    InvalidResponse,
    JsonParseError,
} || std.mem.Allocator.Error || std.http.Client.RequestError || std.Uri.ParseError;

pub fn fetchFromSwapi(allocator: std.mem.Allocator, endpoint: []const u8, id: ?u32) SwapiError!std.json.Parsed(std.json.Value) {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build URL
    var url_buf: [256]u8 = undefined;
    const url = if (id) |actual_id|
        try std.fmt.bufPrint(url_buf[0..], "{s}/{s}/{d}", .{ SWAPI_BASE_URL, endpoint, actual_id })
    else
        try std.fmt.bufPrint(url_buf[0..], "{s}/{s}", .{ SWAPI_BASE_URL, endpoint });

    // Parse URI
    const uri = try std.Uri.parse(url);

    // Create headers
    var headers = std.http.Headers{ .allocator = allocator };
    defer headers.deinit();
    try headers.append("accept", "application/json");
    try headers.append("user-agent", "swapi-cli/1.0.0");

    // Make request
    var request = try client.open(.GET, uri, headers, .{});
    defer request.deinit();

    try request.send();
    try request.finish();

    // Check status code
    if (request.response.status != .ok) {
        return SwapiError.HttpRequestFailed;
    }

    // Read response body
    const body = try request.reader().readAllAlloc(allocator, 1024 * 1024); // 1MB limit
    defer allocator.free(body);

    // Parse JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    return parsed;
}

pub fn printJsonPretty(allocator: std.mem.Allocator, value: std.json.Value, writer: anytype) !void {
    // Convert to pretty-printed JSON string
    var string = std.ArrayList(u8){};
    defer string.deinit(allocator);

    try std.json.stringify(value, .{ .whitespace = .indent_4 }, string.writer(allocator));
    try writer.writeAll(string.items);
}
