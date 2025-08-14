const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Upload files",
    .options = .{
        .files = .{ .name = "file" },
    },
};

pub const Args = struct {};

pub const Options = struct {
    files: [][]const u8,
};

pub fn execute(_: Args, options: Options, context: *zcli.Context) !void {
    for (options.files) |file| {
        try context.stdout().print("Uploading file: {s}\n", .{file});
    }
}
