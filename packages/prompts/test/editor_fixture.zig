//! Child fixture for real terminal attachment, immediate opening and redirects.
const std = @import("std");
const builtin = @import("builtin");
const Prompts = @import("prompts");
pub const panic = Prompts.panic;
pub const debug = Prompts.debug;

extern "kernel32" fn SetStdHandle(which: u32, handle: std.os.windows.HANDLE) callconv(.winapi) c_int;
extern "kernel32" fn FreeConsole() callconv(.winapi) c_int;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len >= 3 and std.mem.eql(u8, args[1], "child-edit")) {
        var buf: [256]u8 = undefined;
        var output = std.Io.File.stdout().writer(init.io, &buf);
        try output.interface.writeAll("EDITOR_UI\n");
        try output.interface.flush();
        const file = try std.Io.Dir.cwd().createFile(init.io, args[2], .{});
        defer file.close(init.io);
        try file.writeStreamingAll(init.io, "saved\n");
        return;
    }
    const no_terminal = args.len > 1 and std.mem.eql(u8, args[1], "no-terminal");
    const prompt_immediate = args.len > 1 and std.mem.eql(u8, args[1], "prompt-immediate");
    if (builtin.os.tag == .windows) {
        if (no_terminal) _ = FreeConsole();
    } else {
        if (std.posix.errno(std.posix.system.setsid()) != .SUCCESS) return error.SessionFailed;
        if (!no_terminal) {
            const request = if (builtin.os.tag == .macos) 0x20007461 else 0x540e; // TIOCSCTTY
            if (std.posix.errno(std.posix.system.ioctl(std.Io.File.stdin().handle, request, @as(usize, 0))) != .SUCCESS)
                return error.ControllingTerminalFailed;
        }
    }

    var redirected: ?std.Io.File = null;
    defer if (redirected) |file| file.close(init.io);
    if (!no_terminal and !prompt_immediate) {
        if (args.len < 2) return error.MissingOutputPath;
        redirected = try std.Io.Dir.cwd().createFile(init.io, args[1], .{});
        if (builtin.os.tag == .windows) {
            if (SetStdHandle(0xfffffff5, redirected.?.handle) == 0) return error.RedirectFailed; // STD_OUTPUT_HANDLE
        } else {
            if (std.posix.errno(std.posix.system.dup2(redirected.?.handle, std.Io.File.stdout().handle)) != .SUCCESS)
                return error.RedirectFailed;
        }
    }
    var buf: [256]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buf);
    var reader: std.Io.Reader = .fixed("");
    const p: Prompts = .{ .allocator = allocator, .writer = &output.interface, .reader = &reader };
    // Direct edit is independent of redirected prompt streams. A separate
    // interactive case tests the prompt immediate invitation opt-out.
    const self_path = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[0], allocator);
    if (no_terminal) {
        var result = try p.edit(.{ .io = init.io, .argv = &.{ self_path, "child-edit" } });
        defer result.deinit(allocator);
        if (result != .failed or result.failed.phase != .terminal) return error.ExpectedTerminalFailure;
        try output.interface.writeAll("NO_TERMINAL\n");
    } else {
        if (prompt_immediate) {
            const content = try p.editor(.{ .message = "Invitation must be skipped", .immediate = true, .io = init.io, .argv = &.{ self_path, "child-edit" } });
            try output.interface.writeAll(content);
        } else {
            var result = try p.edit(.{ .io = init.io, .argv = &.{ self_path, "child-edit" } });
            defer result.deinit(allocator);
            if (result != .edited) return error.EditorOperationFailed;
            try output.interface.writeAll(result.edited);
        }
        var error_buf: [64]u8 = undefined;
        var error_output = std.Io.File.stderr().writer(init.io, &error_buf);
        try error_output.interface.writeAll("DONE\n");
        try error_output.interface.flush();
    }
    try output.interface.flush();
}
