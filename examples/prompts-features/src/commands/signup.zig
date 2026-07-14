const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Create an account (demonstrates the password and multi_select prompts)",
    .examples = &.{"signup"},
};

pub const Args = struct {};
pub const Options = struct {};

const interests = [_][]const u8{ "Announcements", "Product updates", "Security bulletins", "Community events" };

pub fn execute(_: Args, _: Options, context: *Context) !void {
    const allocator = context.allocator;
    const stdout = context.stdout();
    const p = context.prompts();

    const username = p.text(.{
        .message = "Username:",
    }) catch |err| switch (err) {
        error.EndOfStream => return context.fail("signup requires an interactive terminal (stdin closed).", .{}),
        else => return err,
    };
    defer allocator.free(username);

    // Masked input: typed characters render as `*` and the value never
    // echoes to the terminal.
    const password = p.password(.{
        .message = "Password:",
    }) catch |err| switch (err) {
        error.EndOfStream => return context.fail("signup requires an interactive terminal (stdin closed).", .{}),
        else => return err,
    };
    defer allocator.free(password);

    if (password.len < 8) {
        return context.fail("password must be at least 8 characters.", .{});
    }

    // Toggle-selection with space, confirm with enter; returns the chosen
    // indices into `choices`.
    const selected = p.multiSelect(.{
        .message = "Subscribe to:",
        .choices = &interests,
        .defaults = &.{ true, false, true, false },
    }) catch |err| switch (err) {
        error.EndOfStream => return context.fail("signup requires an interactive terminal (stdin closed).", .{}),
        else => return err,
    };
    defer allocator.free(selected);

    try stdout.print("Account created for {s}.\n", .{username});
    if (selected.len == 0) {
        try stdout.writeAll("Subscribed to: nothing\n");
    } else {
        try stdout.writeAll("Subscribed to:\n");
        for (selected) |idx| {
            try stdout.print("  - {s}\n", .{interests[idx]});
        }
    }
}
