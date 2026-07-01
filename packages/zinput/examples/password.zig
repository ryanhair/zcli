//! `zinput.password` — masked input; the typed characters are never echoed.

const std = @import("std");
const zinput = @import("zinput");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var t: common.Io = .{};
    t.init(init.io);
    defer t.flush();

    const secret = zinput.password(t.w(), t.r(), init.gpa, .{
        .message = "Enter a password:",
        .mask = '*',
    }) catch |err| {
        try t.w().print("\n({s})\n", .{@errorName(err)});
        return;
    };
    defer init.gpa.free(secret);

    // Don't print the secret back — just prove we captured it.
    try t.w().print("\nGot a password of {d} character(s).\n", .{secret.len});
}
