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
        const expected = [_][]const u8{ "", "a b", "say \"hello\"", "C:\\folder with spaces\\" };
        if (args.len != expected.len + 3) return error.EditorArgumentsLost;
        for (expected, args[2 .. args.len - 1]) |want, actual| {
            if (!std.mem.eql(u8, want, actual)) return error.EditorArgumentsChanged;
        }
        if (!std.mem.eql(u8, init.environ_map.get("ZCLI_EDITOR_FIXTURE") orelse "", "threaded")) return error.EditorEnvironmentLost;
        var buf: [256]u8 = undefined;
        var output = std.Io.File.stdout().writer(init.io, &buf);
        try output.interface.writeAll("EDITOR_UI\n");
        try output.interface.flush();
        const file = try std.Io.Dir.cwd().createFile(init.io, args[args.len - 1], .{});
        defer file.close(init.io);
        try file.writeStreamingAll(init.io, "saved\n");
        return;
    }
    const self_path = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[0], allocator);
    const editor_argv = &.{ self_path, "child-edit", "", "a b", "say \"hello\"", "C:\\folder with spaces\\" };
    var environment = try init.environ_map.clone(allocator);
    defer environment.deinit();
    try environment.put("ZCLI_EDITOR_FIXTURE", "threaded");
    // A pipe-only control exercises the same executable lookup and file edit
    // without console attachment, isolating launch errors from ConPTY setup.
    if (args.len > 1 and std.mem.eql(u8, args[1], "inherit")) {
        var reader: std.Io.Reader = .fixed("");
        var buffer: [256]u8 = undefined;
        var writer = std.Io.File.stdout().writer(init.io, &buffer);
        const p: Prompts = .{ .allocator = allocator, .reader = &reader, .writer = &writer.interface };
        var result = try p.edit(.{ .io = init.io, .argv = editor_argv, .environ = &environment, .attachment = .inherit });
        defer result.deinit(allocator);
        try requireEdited(result);
        try std.Io.File.stdout().writeStreamingAll(init.io, result.edited);
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
    if (no_terminal) {
        var result = try p.edit(.{ .io = init.io, .argv = editor_argv, .environ = &environment });
        defer result.deinit(allocator);
        if (result != .failed or result.failed.phase != .terminal) return error.ExpectedTerminalFailure;
        try output.interface.writeAll("NO_TERMINAL\n");
    } else {
        if (prompt_immediate) {
            const content = try p.editor(.{ .message = "Invitation must be skipped", .immediate = true, .io = init.io, .argv = editor_argv, .environ = &environment });
            try output.interface.writeAll(content);
        } else {
            var result = try p.edit(.{ .io = init.io, .argv = editor_argv, .environ = &environment });
            defer result.deinit(allocator);
            try requireEdited(result);
            try output.interface.writeAll(result.edited);
        }
        var error_buf: [64]u8 = undefined;
        var error_output = std.Io.File.stderr().writer(init.io, &error_buf);
        try error_output.interface.writeAll("DONE\n");
        try error_output.interface.flush();
    }
    try output.interface.flush();
}

fn requireEdited(result: Prompts.EditResult) !void {
    if (result == .failed) {
        std.debug.print("Editor failed: phase={s}, cause={s}\n", .{
            @tagName(result.failed.phase),
            if (result.failed.cause) |cause| @errorName(cause) else "none",
        });
        return error.EditorOperationFailed;
    }
}
