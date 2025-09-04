const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Echo arguments back",
};

pub const Options = struct {
    uppercase: bool = false,
    @"no-newline": bool = false,
};

pub const Args = struct {
    text: []const []const u8,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    for (args.text, 0..) |word, i| {
        if (i > 0) try context.io.stdout.print(" ", .{});

        if (options.uppercase) {
            // Simple uppercase conversion
            for (word) |char| {
                const upper = if (char >= 'a' and char <= 'z') char - 32 else char;
                try context.io.stdout.print("{c}", .{upper});
            }
        } else {
            try context.io.stdout.print("{s}.d", .{word});
        }
    }

    if (!options.@"no-newline") {
        try context.io.stdout.print("\n", .{});
    }
}
