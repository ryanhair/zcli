const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Test TTY detection",
};

pub const Args = zcli.NoArgs;
pub const Options = zcli.NoOptions;

pub fn execute(_: Args, _: Options, context: *zcli.Context) !void {
    // Check if stdout is a TTY
    const is_tty = std.posix.isatty(std.io.getStdOut().handle);
    
    try context.io.stdout.print("TTY detected: {}\n", .{is_tty});
    try context.io.stdout.print("TERM env: {s}\n", .{std.posix.getenv("TERM") orelse "not set"});
    
    if (is_tty) {
        try context.io.stdout.print("Running in TTY mode - colors should work\n", .{});
    } else {
        try context.io.stdout.print("Running in pipe mode - no TTY\n", .{});
    }
}