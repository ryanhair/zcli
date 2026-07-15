//! Windows ConPTY backend for the interactive e2e harness.
//!
//! This is the "outside of the terminal" role: allocate a pseudoconsole, spawn a
//! child into it, and drive the child's stdin/stdout from the parent — the
//! Windows analogue of the POSIX PTY path in e2e.zig. The child side needs no
//! special handling: ConPTY presents a normal VT console, which the terminal
//! stack's Windows backend already speaks.
//!
//! Shape difference from POSIX that this module hides behind its method surface:
//! a POSIX PTY has ONE bidirectional master fd; ConPTY has TWO half-duplex pipe
//! handles (input_write, output_read). `ConPtySession` exposes the same
//! pollRead/writeAll/resize/signalTerm/waitExit surface the shared step loop
//! calls on the POSIX session, so runInteractive's driver is platform-neutral.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const BOOL = c_int; // Win32 BOOL is a 32-bit int; windows.BOOL is a non-comparable wrapper
const HRESULT = i32; // Win32 HRESULT is a LONG
const STARTUPINFOW = windows.STARTUPINFOW;
const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;

/// Opaque pseudoconsole handle.
const HPCON = *anyopaque;

const COORD = extern struct { X: i16, Y: i16 };

const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x00000400;
const STARTF_USESTDHANDLES: DWORD = 0x00000100;
const WAIT_OBJECT_0: DWORD = 0;

/// STARTUPINFOW + attribute-list pointer. Not in std.os.windows.
const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

/// Not exported by std.os.windows.
const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

// ── Win32 externs. The three ConPTY calls and the two attribute-list calls are
// the genuinely-new symbols; the rest overlap with windows.kernel32 but are
// declared here so this backend owns its full ABI surface in one place. ───────
extern "kernel32" fn CreatePseudoConsole(size: COORD, hInput: HANDLE, hOutput: HANDLE, dwFlags: DWORD, phPC: *HPCON) callconv(.winapi) HRESULT;
extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: COORD) callconv(.winapi) HRESULT;
extern "kernel32" fn InitializeProcThreadAttributeList(lpAttributeList: ?*anyopaque, dwAttributeCount: DWORD, dwFlags: DWORD, lpSize: *usize) callconv(.winapi) BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(lpAttributeList: *anyopaque, dwFlags: DWORD, Attribute: usize, lpValue: *anyopaque, cbSize: usize, lpPreviousValue: ?*anyopaque, lpReturnSize: ?*usize) callconv(.winapi) BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(lpAttributeList: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn CreatePipe(hReadPipe: *HANDLE, hWritePipe: *HANDLE, lpPipeAttributes: ?*SECURITY_ATTRIBUTES, nSize: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;
extern "kernel32" fn PeekNamedPipe(hNamedPipe: HANDLE, lpBuffer: ?*anyopaque, nBufferSize: DWORD, lpBytesRead: ?*DWORD, lpTotalBytesAvail: ?*DWORD, lpBytesLeftThisMessage: ?*DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: *DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: *DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: c_uint) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;

pub const ConPtyError = error{
    PipeFailed,
    ConPtyFailed,
    AttrListFailed,
    AttrUpdateFailed,
    SpawnFailed,
    BadCommandLine,
} || std.mem.Allocator.Error;

pub const ConPtySession = struct {
    hpc: HPCON,
    input_write: HANDLE, // parent writes -> child stdin
    output_read: HANDLE, // parent reads  <- child stdout+stderr (merged, like a console)
    process: HANDLE,
    attr_words: []usize, // usize-aligned backing store for the opaque attribute list
    input_closed: bool = false,

    /// Allocate a pseudoconsole and spawn `argv` into it. `env`, when non-null,
    /// replaces the child environment; `cwd`, when non-null, sets its working
    /// directory. `rows`/`cols` seed the console size.
    pub fn spawn(
        alloc: std.mem.Allocator,
        argv: []const []const u8,
        env: ?*const std.process.Environ.Map,
        cwd: ?[]const u8,
        rows: u16,
        cols: u16,
    ) ConPtyError!ConPtySession {
        // Command line + optional cwd/env, all UTF-16.
        const cmdline = try buildCommandLineW(alloc, argv);
        defer alloc.free(cmdline);
        const cwd_w: ?[:0]u16 = if (cwd) |c| try utf8ToUtf16Z(alloc, c) else null;
        defer if (cwd_w) |w| alloc.free(w);
        const env_block: ?[]u16 = if (env) |e| try buildEnvBlockW(alloc, e) else null;
        defer if (env_block) |b| alloc.free(b);

        var input_read: HANDLE = undefined;
        var input_write: HANDLE = undefined;
        var output_read: HANDLE = undefined;
        var output_write: HANDLE = undefined;
        if (CreatePipe(&input_read, &input_write, null, 0) == 0) return error.PipeFailed;
        errdefer _ = CloseHandle(input_write);
        if (CreatePipe(&output_read, &output_write, null, 0) == 0) return error.PipeFailed;
        errdefer _ = CloseHandle(output_read);

        var hpc: HPCON = undefined;
        const size = COORD{ .X = @intCast(cols), .Y = @intCast(rows) };
        if (CreatePseudoConsole(size, input_read, output_write, 0, &hpc) != 0) return error.ConPtyFailed;
        errdefer ClosePseudoConsole(hpc);

        // The pseudoconsole owns the child ends now; the parent keeps only
        // input_write + output_read.
        _ = CloseHandle(input_read);
        _ = CloseHandle(output_write);

        // Attribute list: probe size (call fails with ERROR_INSUFFICIENT_BUFFER,
        // filling `bytes`), allocate usize-aligned backing, init for real.
        var bytes: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &bytes);
        const words = try alloc.alloc(usize, (bytes + @sizeOf(usize) - 1) / @sizeOf(usize));
        errdefer alloc.free(words);
        const attr: *anyopaque = @ptrCast(words.ptr);
        if (InitializeProcThreadAttributeList(attr, 1, 0, &bytes) == 0) return error.AttrListFailed;
        errdefer DeleteProcThreadAttributeList(attr);
        if (UpdateProcThreadAttribute(attr, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, @sizeOf(HPCON), null, null) == 0)
            return error.AttrUpdateFailed;

        var si = std.mem.zeroes(STARTUPINFOEXW);
        si.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
        si.lpAttributeList = attr;
        // Load-bearing when the parent's own stdio is redirected (e.g. the test
        // runner pipes our stdout): without STARTF_USESTDHANDLES, Windows has a
        // legacy hack that duplicates the parent's redirected handles into a
        // console child even with bInheritHandles=FALSE, so the child's stdin
        // becomes our pipe instead of the pseudoconsole and GetConsoleMode (its
        // isatty) fails. Setting the flag with the hStd* handles left null
        // suppresses that and lets the pseudoconsole's handles win.
        // See microsoft/terminal discussion #15814.
        si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;

        const env_ptr: ?*anyopaque = if (env_block) |b| @ptrCast(b.ptr) else null;
        const cwd_ptr: ?[*:0]const u16 = if (cwd_w) |w| w.ptr else null;

        var pi = std.mem.zeroes(PROCESS_INFORMATION);
        // bInheritHandles = FALSE: ConPTY passes stdio via the attribute, not inheritance.
        if (CreateProcessW(
            null,
            cmdline.ptr,
            null,
            null,
            0,
            EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
            env_ptr,
            cwd_ptr,
            &si.StartupInfo,
            &pi,
        ) == 0) return error.SpawnFailed;
        _ = CloseHandle(pi.hThread);

        return .{
            .hpc = hpc,
            .input_write = input_write,
            .output_read = output_read,
            .process = pi.hProcess,
            .attr_words = words,
        };
    }

    /// Non-blocking read with a timeout — the ConPTY analogue of the POSIX
    /// pollRead (poll + read). Pipe handles can't be poll()'d, so this spins
    /// PeekNamedPipe. Returns 0 on timeout OR broken pipe (child gone / EOF).
    pub fn pollRead(self: *ConPtySession, buf: []u8, timeout_ms: i32) usize {
        var waited: i32 = 0;
        while (true) {
            var avail: DWORD = 0;
            if (PeekNamedPipe(self.output_read, null, 0, null, &avail, null) == 0) return 0;
            if (avail > 0) {
                var got: DWORD = 0;
                const want: DWORD = @intCast(@min(buf.len, avail));
                if (ReadFile(self.output_read, buf.ptr, want, &got, null) == 0) return 0;
                return got;
            }
            if (waited >= timeout_ms) return 0;
            Sleep(10);
            waited += 10;
        }
    }

    pub fn writeAll(self: *ConPtySession, bytes: []const u8) error{WriteFailed}!void {
        var off: usize = 0;
        while (off < bytes.len) {
            var wrote: DWORD = 0;
            if (WriteFile(self.input_write, bytes.ptr + off, @intCast(bytes.len - off), &wrote, null) == 0)
                return error.WriteFailed;
            if (wrote == 0) return error.WriteFailed;
            off += wrote;
        }
    }

    pub fn resize(self: *ConPtySession, rows: u16, cols: u16) void {
        _ = ResizePseudoConsole(self.hpc, .{ .X = @intCast(cols), .Y = @intCast(rows) });
    }

    /// Force-terminate the child (the Windows analogue of SIGTERM/SIGKILL).
    pub fn signalTerm(self: *ConPtySession) void {
        _ = TerminateProcess(self.process, 1);
    }

    /// Signal EOF on the child's stdin by closing the write side.
    pub fn closeInput(self: *ConPtySession) void {
        if (!self.input_closed) {
            _ = CloseHandle(self.input_write);
            self.input_closed = true;
        }
    }

    /// Wait up to `timeout_ms` for the child to exit; returns its exit code
    /// (truncated to u8, matching the POSIX path) or null on timeout.
    pub fn waitExit(self: *ConPtySession, timeout_ms: DWORD) ?u8 {
        if (WaitForSingleObject(self.process, timeout_ms) != WAIT_OBJECT_0) return null;
        var code: DWORD = 0;
        if (GetExitCodeProcess(self.process, &code) == 0) return null;
        return @truncate(code);
    }

    pub fn deinit(self: *ConPtySession, alloc: std.mem.Allocator) void {
        // ClosePseudoConsole can block until pending output is drained, so close
        // the input and drain the output first (the caller normally drains via
        // pollRead already; this is a backstop). Mirrors the POSIX drainUntilHup
        // ordering concern.
        self.closeInput();
        var scratch: [512]u8 = undefined;
        while (self.pollRead(&scratch, 50) > 0) {}
        ClosePseudoConsole(self.hpc);
        _ = CloseHandle(self.output_read);
        _ = CloseHandle(self.process);
        const attr: *anyopaque = @ptrCast(self.attr_words.ptr);
        DeleteProcThreadAttributeList(attr);
        alloc.free(self.attr_words);
    }
};

fn utf8ToUtf16Z(alloc: std.mem.Allocator, s: []const u8) ConPtyError![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, s) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadCommandLine,
    };
}

/// Build a Windows command line from argv, applying the standard
/// CommandLineToArgvW quoting rules, then encode it as UTF-16.
fn buildCommandLineW(alloc: std.mem.Allocator, argv: []const []const u8) ConPtyError![:0]u16 {
    var utf8: std.ArrayList(u8) = .empty;
    defer utf8.deinit(alloc);
    for (argv, 0..) |arg, i| {
        if (i != 0) try utf8.append(alloc, ' ');
        try appendQuotedArg(alloc, &utf8, arg);
    }
    return utf8ToUtf16Z(alloc, utf8.items);
}

/// Append one argument to a command line, quoting per the rules
/// CommandLineToArgvW uses to parse it back (backslashes are only special
/// before a quote).
fn appendQuotedArg(alloc: std.mem.Allocator, out: *std.ArrayList(u8), arg: []const u8) ConPtyError!void {
    const needs_quote = arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t\"") != null;
    if (!needs_quote) {
        try out.appendSlice(alloc, arg);
        return;
    }
    try out.append(alloc, '"');
    var backslashes: usize = 0;
    for (arg) |c| {
        switch (c) {
            '\\' => backslashes += 1,
            '"' => {
                // Escape all pending backslashes (they precede a quote) and the quote.
                try out.appendNTimes(alloc, '\\', backslashes * 2 + 1);
                try out.append(alloc, '"');
                backslashes = 0;
            },
            else => {
                try out.appendNTimes(alloc, '\\', backslashes);
                backslashes = 0;
                try out.append(alloc, c);
            },
        }
    }
    // Trailing backslashes precede the closing quote → double them.
    try out.appendNTimes(alloc, '\\', backslashes * 2);
    try out.append(alloc, '"');
}

/// Build a UTF-16 environment block: KEY=VALUE\0 entries, double-null terminated.
fn buildEnvBlockW(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) ConPtyError![]u16 {
    var utf8: std.ArrayList(u8) = .empty;
    defer utf8.deinit(alloc);
    var it = env.iterator();
    while (it.next()) |entry| {
        try utf8.appendSlice(alloc, entry.key_ptr.*);
        try utf8.append(alloc, '=');
        try utf8.appendSlice(alloc, entry.value_ptr.*);
        try utf8.append(alloc, 0);
    }
    try utf8.append(alloc, 0); // final terminator for the block

    const block = std.unicode.utf8ToUtf16LeAlloc(alloc, utf8.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadCommandLine,
    };
    return block;
}

test "command-line quoting follows the CommandLineToArgvW rules" {
    // appendQuotedArg is pure (no Windows API), so this runs on every host.
    const alloc = std.testing.allocator;
    const cases = [_]struct { arg: []const u8, expected: []const u8 }{
        .{ .arg = "plain", .expected = "plain" },
        .{ .arg = "", .expected = "\"\"" },
        .{ .arg = "has space", .expected = "\"has space\"" },
        .{ .arg = "tab\there", .expected = "\"tab\there\"" },
        // A quote is escaped; backslashes are only special before a quote.
        .{ .arg = "say \"hi\"", .expected = "\"say \\\"hi\\\"\"" },
        .{ .arg = "C:\\Program Files\\x", .expected = "\"C:\\Program Files\\x\"" },
        // Trailing backslashes before the closing quote double.
        .{ .arg = "trail\\ ", .expected = "\"trail\\ \"" },
        .{ .arg = "end\\\"", .expected = "\"end\\\\\\\"\"" },
    };
    for (cases) |case| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try appendQuotedArg(alloc, &out, case.arg);
        try std.testing.expectEqualStrings(case.expected, out.items);
    }
}

test "buildCommandLineW joins argv with spaces and NUL-terminates" {
    const alloc = std.testing.allocator;
    const cmdline = try buildCommandLineW(alloc, &.{ "cmd.exe", "/c", "echo hi" });
    defer alloc.free(cmdline);
    const expected = try std.unicode.utf8ToUtf16LeAlloc(alloc, "cmd.exe /c \"echo hi\"");
    defer alloc.free(expected);
    try std.testing.expectEqualSlices(u16, expected, cmdline[0..cmdline.len]);
    try std.testing.expectEqual(@as(u16, 0), cmdline[cmdline.len]);
}

test "ConPTY smoke: spawn, read output, clean exit (#404)" {
    // The only coverage ConPTY gets outside the full interactive e2e tier —
    // bugs here previously surfaced only in CI, never on a dev box.
    if (builtin.os.tag != .windows) return;
    const alloc = std.testing.allocator;

    var session = try ConPtySession.spawn(alloc, &.{ "cmd.exe", "/c", "echo conpty-smoke" }, null, null, 24, 80);
    defer session.deinit(alloc);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var buf: [1024]u8 = undefined;
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        const n = session.pollRead(&buf, 100);
        if (n > 0) try out.appendSlice(alloc, buf[0..n]);
        if (std.mem.indexOf(u8, out.items, "conpty-smoke") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, out.items, "conpty-smoke") != null);
    try std.testing.expectEqual(@as(?u8, 0), session.waitExit(5000));
}
