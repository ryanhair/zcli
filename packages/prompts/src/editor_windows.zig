//! Console-only editor launcher. Zig 0.16's SpawnOptions.file reopens handles
//! with NtCreateFile, which cannot reopen Win32 console handles. Pass the
//! handles directly to CreateProcessW without changing the parent's stdio.
const std = @import("std");
const windows = std.os.windows;

const StartupInfo = extern struct {
    base: windows.STARTUPINFOW,
    attributes: ?*anyopaque,
};
extern "kernel32" fn InitializeProcThreadAttributeList(?*anyopaque, u32, u32, *usize) callconv(.winapi) c_int;
extern "kernel32" fn UpdateProcThreadAttribute(*anyopaque, u32, usize, *anyopaque, usize, ?*anyopaque, ?*usize) callconv(.winapi) c_int;
extern "kernel32" fn DeleteProcThreadAttributeList(*anyopaque) callconv(.winapi) void;
extern "kernel32" fn DuplicateHandle(windows.HANDLE, windows.HANDLE, windows.HANDLE, *windows.HANDLE, u32, c_int, u32) callconv(.winapi) c_int;
extern "kernel32" fn CreateProcessW(?[*:0]const u16, ?[*:0]u16, ?*anyopaque, ?*anyopaque, c_int, u32, ?*anyopaque, ?[*:0]const u16, *windows.STARTUPINFOW, *windows.PROCESS.INFORMATION) callconv(.winapi) c_int;

pub fn spawn(allocator: std.mem.Allocator, argv: []const []const u8, environ: ?*const std.process.Environ.Map, input: windows.HANDLE, output: windows.HANDLE) !std.process.Child {
    const command = try commandLine(allocator, argv);
    defer allocator.free(command);
    const environment = if (environ) |map| try map.createWindowsBlock(allocator, .{}) else null;
    defer if (environment) |block| block.deinit(allocator);

    // Limit inheritance to the two console handles, including when another
    // thread has an unrelated inheritable file open. Never mutate std handles.
    var handles = [_]windows.HANDLE{ try inheritable(input), undefined };
    defer windows.CloseHandle(handles[0]);
    handles[1] = try inheritable(output);
    defer windows.CloseHandle(handles[1]);
    var bytes: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &bytes);
    const storage = try allocator.alloc(usize, std.math.divCeil(usize, bytes, @sizeOf(usize)) catch unreachable);
    defer allocator.free(storage);
    const attributes: *anyopaque = @ptrCast(storage.ptr);
    if (InitializeProcThreadAttributeList(attributes, 1, 0, &bytes) == 0) return error.EditorProcessAttributesFailed;
    defer DeleteProcThreadAttributeList(attributes);
    // PROC_THREAD_ATTRIBUTE_HANDLE_LIST
    if (UpdateProcThreadAttribute(attributes, 0, 0x00020002, &handles, @sizeOf(@TypeOf(handles)), null, null) == 0)
        return error.EditorProcessAttributesFailed;
    var startup: StartupInfo = .{ .base = std.mem.zeroes(windows.STARTUPINFOW), .attributes = attributes };
    startup.base.cb = @sizeOf(StartupInfo);
    startup.base.dwFlags = windows.STARTF_USESTDHANDLES;
    startup.base.hStdInput = handles[0];
    startup.base.hStdOutput = handles[1];
    startup.base.hStdError = handles[1];
    var child: windows.PROCESS.INFORMATION = undefined;
    // EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT. The command's
    // first word retains CreateProcess's executable lookup when no env is given.
    if (CreateProcessW(null, command.ptr, null, null, 1, 0x00080400, if (environment) |block| @ptrCast(@constCast(block.slice.ptr)) else null, null, &startup.base, &child) == 0)
        return switch (windows.GetLastError()) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
            .ACCESS_DENIED => error.AccessDenied,
            .NOT_ENOUGH_MEMORY, .OUTOFMEMORY => error.OutOfMemory,
            else => error.EditorProcessCreationFailed,
        };
    return .{ .id = child.hProcess, .thread_handle = child.hThread, .stdin = null, .stdout = null, .stderr = null, .request_resource_usage_statistics = false };
}

fn inheritable(handle: windows.HANDLE) !windows.HANDLE {
    var copy: windows.HANDLE = undefined;
    const process = windows.GetCurrentProcess();
    if (DuplicateHandle(process, handle, process, &copy, 0, 1, 2) == 0) return error.EditorConsoleDuplicationFailed;
    return copy;
}

// Windows argv[0] uses different quoting from subsequent arguments. Quote
// every argument, doubling backslashes only before quotes and closing quotes.
fn commandLine(allocator: std.mem.Allocator, argv: []const []const u8) ![:0]u16 {
    if (argv.len == 0 or argv[0].len == 0 or std.mem.indexOfAny(u8, argv[0], "\"\x00") != null) return error.InvalidEditorCommand;
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    try text.writer.print("\"{s}\"", .{argv[0]});
    for (argv[1..]) |arg| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidEditorCommand;
        try text.writer.writeAll(" \"");
        var slashes: usize = 0;
        for (arg) |byte| {
            if (byte == '\\') {
                slashes += 1;
                continue;
            }
            try text.writer.splatByteAll('\\', slashes * (if (byte == '"') @as(usize, 2) else 1) + @intFromBool(byte == '"'));
            try text.writer.writeByte(byte);
            slashes = 0;
        }
        try text.writer.splatByteAll('\\', slashes * 2);
        try text.writer.writeByte('"');
    }
    return std.unicode.wtf8ToWtf16LeAllocZ(allocator, text.written());
}

test "Windows editor argv round trips spaces quotes empty values and backslashes" {
    const argv = [_][]const u8{ "C:\\Program Files\\editor.exe", "", "a b", "say \"hello\"", "C:\\folder with spaces\\", "\\\"", "日本語.txt" };
    const command = try commandLine(std.testing.allocator, &argv);
    defer std.testing.allocator.free(command);
    var args = try std.process.Args.Iterator.Windows.init(std.testing.allocator, command);
    defer args.deinit();
    for (argv) |expected| try std.testing.expectEqualStrings(expected, args.next().?);
    try std.testing.expect(args.next() == null);
}
