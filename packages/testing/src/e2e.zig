const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const conpty = @import("conpty.zig");
const vterm = @import("vterm");
const snapshot = @import("snapshot.zig");

/// Interactive testing support for CLIs that require user input.
///
/// This module is fully libc-free: every OS interaction goes through std.posix /
/// std.os.linux syscalls (Linux) or std.c via std.posix (macOS, which always
/// links libSystem). The PTY master/slave pair is created with raw ioctls
/// (grantpt/unlockpt/ptsname have no syscall equivalent), and processes are
/// spawned with std.process.spawn pointing their stdio at the slave PTY — no
/// manual fork/exec, no execvpeZ, no ambient environ.

// ============================================================================
// Low-level helpers (libc-free)
// ============================================================================

// Create a pipe — std.posix.pipe was removed in 0.16.
fn makePipe() error{PipeFailed}![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    if (posix.system.pipe(&fds) != 0) return error.PipeFailed;
    // CLOEXEC both ends: the child must not inherit the harness's copies
    // (spawn dup2s the ones it needs onto stdio, which clears CLOEXEC).
    // A leaked write end in the child would keep the stream open after the
    // harness closes its own, defeating EOF detection.
    for (fds) |fd| {
        _ = posix.system.fcntl(fd, @as(c_int, posix.F.SETFD), @as(c_int, posix.FD_CLOEXEC));
    }
    return fds;
}

fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

// Wrap a raw fd as a blocking std.Io.File (0.16 File requires explicit flags).
fn fileFromFd(fd: posix.fd_t) std.Io.File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

// A descriptor is a TTY iff its termios can be read — a libc-free isatty.
fn isFdTty(fd: posix.fd_t) bool {
    _ = posix.tcgetattr(fd) catch return false;
    return true;
}

// std.posix normalizes termios to packed structs with identical POSIX field
// names on Linux and macOS, so the termios code below is one cross-platform path.
const Termios = posix.termios;

// cfmakeraw()-equivalent applied in place (no libc cfmakeraw).
fn applyRawMode(t: *Termios) void {
    t.iflag.BRKINT = false;
    t.iflag.ICRNL = false;
    t.iflag.INPCK = false;
    t.iflag.ISTRIP = false;
    t.iflag.IXON = false;
    t.oflag.OPOST = false;
    t.lflag.ECHO = false;
    t.lflag.ICANON = false;
    t.lflag.IEXTEN = false;
    t.lflag.ISIG = false;
    t.cflag.PARENB = false;
    t.cflag.CSIZE = .CS8;
    t.cc[@intFromEnum(posix.V.MIN)] = 1;
    t.cc[@intFromEnum(posix.V.TIME)] = 0;
}

// ioctl request numbers. std.posix.T is inconsistent across OSes (macOS lacks
// IOCSWINSZ, etc.), so we name the stable kernel ABI values directly. Linux PTY
// values are from <asm-generic/ioctls.h>; macOS from <sys/ttycom.h>.
const is_linux = builtin.os.tag == .linux;
const TIOCGWINSZ: u32 = if (is_linux) 0x5413 else 0x40087468;
const TIOCSWINSZ: u32 = if (is_linux) 0x5414 else 0x80087467;
const TIOCSPTLCK: u32 = 0x40045431; // Linux: lock/unlock the slave pty
const TIOCGPTN: u32 = 0x80045430; // Linux: get the slave pty number
const TIOCPTYGNAME: u32 = 0x40807453; // macOS: get the slave name
const TIOCPTYGRANT: u32 = 0x20007454; // macOS: grant access to the slave
const TIOCPTYUNLK: u32 = 0x20007452; // macOS: unlock the slave

const Winsize = posix.winsize;

// ioctl with a usize argument (a pointer via @intFromPtr, or a small integer).
// system.ioctl's signature differs by OS (Linux: u32 request, usize arg; macOS:
// c_int request, variadic), so the call is split. Returns whether it succeeded.
fn doIoctl(fd: posix.fd_t, request: u32, arg: usize) bool {
    const rc = switch (builtin.os.tag) {
        .linux => posix.system.ioctl(fd, request, arg),
        else => posix.system.ioctl(fd, @as(c_int, @bitCast(request)), arg),
    };
    return posix.errno(rc) == .SUCCESS;
}

// Monotonic milliseconds (libc-free, io-based — std.time.milliTimestamp is gone).
fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

fn sleepMs(io: std.Io, ms: u64) void {
    io.sleep(std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

// Append a formatted line to a transcript buffer (ArrayList(u8) lost .writer in 0.16).
fn transcriptPrint(tb: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const line = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(line);
    try tb.appendSlice(allocator, line);
}

/// Terminal capability detection results
pub const TerminalCapabilities = struct {
    has_pty: bool = false,
    supports_window_size: bool = false,
    supports_termios: bool = false,
    supports_raw_mode: bool = false,
    supports_echo_control: bool = false,
    supports_line_buffering: bool = false,

    pub fn format(self: TerminalCapabilities, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("TerminalCapabilities{{ pty: {any}, window_size: {any}, termios: {any}, raw_mode: {any}, echo: {any}, line_buf: {any} }}", .{ self.has_pty, self.supports_window_size, self.supports_termios, self.supports_raw_mode, self.supports_echo_control, self.supports_line_buffering });
    }
};

/// Pseudo-terminal management for true interactive testing
pub const PtyManager = struct {
    master_fd: posix.fd_t = -1,
    slave_fd: posix.fd_t = -1,
    slave_name: ?[]const u8 = null,
    allocator: std.mem.Allocator,
    original_termios: ?Termios = null,
    window_size: ?Winsize = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        var self = Self{
            .allocator = allocator,
        };

        switch (builtin.os.tag) {
            .linux, .macos => {
                // Try to create a real PTY
                const pty_result = createPty(allocator) catch |err| {
                    std.log.warn("Failed to create PTY: {any}, falling back to pipes", .{err});
                    // Fallback to pipes
                    const pipe_fds = try makePipe();
                    self.master_fd = pipe_fds[1];
                    self.slave_fd = pipe_fds[0];
                    return self;
                };

                self.master_fd = pty_result.master;
                self.slave_fd = pty_result.slave;
                self.slave_name = pty_result.slave_name;
            },
            .windows => {
                // Windows doesn't have standard PTY support, use pipes
                const pipe_fds = try makePipe();
                self.master_fd = pipe_fds[1];
                self.slave_fd = pipe_fds[0];
            },
            else => {
                return error.UnsupportedPlatform;
            },
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.master_fd != -1) {
            closeFd(self.master_fd);
            self.master_fd = -1;
        }
        if (self.slave_fd != -1) {
            closeFd(self.slave_fd);
            self.slave_fd = -1;
        }
        if (self.slave_name) |name| {
            self.allocator.free(name);
            self.slave_name = null;
        }
    }

    pub fn getMasterFile(self: Self) std.Io.File {
        return fileFromFd(self.master_fd);
    }

    pub fn getSlaveFile(self: Self) std.Io.File {
        return fileFromFd(self.slave_fd);
    }

    /// Save current terminal settings.
    pub fn saveTerminalSettings(self: *Self) !void {
        if (self.master_fd == -1) return;
        self.original_termios = posix.tcgetattr(self.master_fd) catch |err| return switch (err) {
            error.NotATerminal => error.NotATerminal,
            else => error.TerminalSettingsError,
        };
    }

    /// Restore original terminal settings.
    pub fn restoreTerminalSettings(self: *Self) void {
        if (self.original_termios) |termios| {
            if (self.master_fd != -1) {
                posix.tcsetattr(self.master_fd, .FLUSH, termios) catch {};
            }
        }
    }

    /// Set terminal to raw mode (character-by-character input)
    pub fn setRawMode(self: *Self) !void {
        if (self.master_fd == -1) return;

        if (self.original_termios == null) {
            try self.saveTerminalSettings();
        }

        var raw_termios = self.original_termios.?;
        applyRawMode(&raw_termios);
        posix.tcsetattr(self.master_fd, .FLUSH, raw_termios) catch return error.TerminalSettingsError;
    }

    /// Set terminal to cooked mode (line-buffered input)
    pub fn setCookedMode(self: *Self) !void {
        const termios = self.original_termios orelse return error.NoSavedSettings;
        posix.tcsetattr(self.master_fd, .FLUSH, termios) catch return error.TerminalSettingsError;
    }

    /// Set terminal echo on/off (for password input)
    pub fn setEcho(self: *Self, enabled: bool) !void {
        if (self.master_fd == -1) return;
        var termios = posix.tcgetattr(self.master_fd) catch return error.TerminalSettingsError;
        termios.lflag.ECHO = enabled;
        posix.tcsetattr(self.master_fd, .FLUSH, termios) catch return error.TerminalSettingsError;
    }

    /// Set line buffering (canonical) mode
    pub fn setLineBuffering(self: *Self, enabled: bool) !void {
        if (self.master_fd == -1) return;
        var termios = posix.tcgetattr(self.master_fd) catch return error.TerminalSettingsError;
        termios.lflag.ICANON = enabled;
        if (!enabled) {
            termios.cc[@intFromEnum(posix.V.MIN)] = 1;
            termios.cc[@intFromEnum(posix.V.TIME)] = 0;
        }
        posix.tcsetattr(self.master_fd, .FLUSH, termios) catch return error.TerminalSettingsError;
    }

    /// Get current window size
    pub fn getWindowSize(self: *Self) !Winsize {
        if (self.master_fd == -1) return error.NoPty;
        var size: Winsize = undefined;
        if (!doIoctl(self.master_fd, TIOCGWINSZ, @intFromPtr(&size))) return error.WindowSizeError;
        return size;
    }

    /// Set window size
    pub fn setWindowSize(self: *Self, rows: u16, cols: u16) !void {
        if (self.master_fd == -1) return;
        var size = Winsize{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        if (!doIoctl(self.master_fd, TIOCSWINSZ, @intFromPtr(&size))) return error.WindowSizeError;
        self.window_size = size;
    }

    /// Signal forwarding for comprehensive process control
    pub fn forwardSignal(self: *Self, child_pid: posix.pid_t, signal: Signal) !void {
        _ = self;
        if (child_pid <= 0) return error.InvalidPid;
        posix.kill(child_pid, toPosixSig(signal)) catch |err| return switch (err) {
            error.ProcessNotFound => error.ProcessNotFound,
            error.PermissionDenied => error.PermissionDenied,
            else => error.SignalDeliveryFailed,
        };
    }

    /// Setup signal forwarding from parent to child (placeholder; forwarding is
    /// driven inline by runInteractive where the lifecycle is controlled).
    pub fn setupSignalForwarding(self: *Self, child_pid: posix.pid_t) !void {
        _ = self;
        _ = child_pid;
    }

    /// Handle window size changes (SIGWINCH) with verification
    pub fn synchronizeWindowSize(self: *Self, child_pid: posix.pid_t) !void {
        if (self.window_size) |size| {
            try self.setWindowSize(size.row, size.col);

            const actual_size = try self.getWindowSize();
            if (actual_size.row != size.row or actual_size.col != size.col) {
                std.log.warn("Window size sync mismatch: expected {d}x{d}, got {d}x{d}", .{ size.row, size.col, actual_size.row, actual_size.col });
            }

            try self.forwardSignal(child_pid, .SIGWINCH);
        }
    }

    /// Detect terminal capabilities and features
    pub fn detectTerminalCapabilities(self: *Self) TerminalCapabilities {
        var caps = TerminalCapabilities{};

        if (self.master_fd == -1) {
            caps.has_pty = false;
            return caps;
        }

        caps.has_pty = true;
        caps.supports_window_size = (self.getWindowSize() catch null) != null;

        caps.supports_termios = true;
        self.saveTerminalSettings() catch {
            caps.supports_termios = false;
        };

        if (caps.supports_termios) {
            if (builtin.is_test) {
                caps.supports_raw_mode = true;
                caps.supports_echo_control = true;
                caps.supports_line_buffering = true;
            } else {
                if (self.setRawMode()) {
                    caps.supports_raw_mode = true;
                    self.restoreTerminalSettings();
                } else |_| {
                    caps.supports_raw_mode = false;
                }

                caps.supports_echo_control = if (self.setEcho(false)) |_| true else |_| false;
                if (caps.supports_echo_control) {
                    _ = self.setEcho(true) catch {};
                }

                caps.supports_line_buffering = if (self.setLineBuffering(false)) |_| true else |_| false;
                if (caps.supports_line_buffering) {
                    _ = self.setLineBuffering(true) catch {};
                }
            }
        }

        return caps;
    }

    /// Auto-adjust window size to match parent terminal
    pub fn autoAdjustWindowSize(self: *Self) !void {
        if (self.master_fd == -1) return;

        var size: Winsize = undefined;
        if (doIoctl(0, TIOCGWINSZ, @intFromPtr(&size))) { // stdin fd = 0
            try self.setWindowSize(size.row, size.col);
            std.log.info("Auto-adjusted PTY window size to {d}x{d}", .{ size.row, size.col });
        } else {
            try self.setWindowSize(24, 80);
            std.log.info("Using default window size 24x80", .{});
        }
    }
};

const PtyResult = struct {
    master: posix.fd_t,
    slave: posix.fd_t,
    slave_name: []const u8,
};

/// Create a real pseudo-terminal pair, falling back to pipes on failure.
fn createPty(allocator: std.mem.Allocator) !PtyResult {
    switch (builtin.os.tag) {
        .linux, .macos => {
            return createRealPty(allocator) catch |err| {
                std.log.warn("Real PTY creation failed: {any}, falling back to pipes", .{err});
                return createPtyFallback(allocator);
            };
        },
        else => return error.UnsupportedPlatform,
    }
}

/// Create a real PTY using raw syscalls/ioctls (no libc grantpt/unlockpt/ptsname).
fn createRealPty(allocator: std.mem.Allocator) !PtyResult {
    // CLOEXEC is load-bearing: without it the child inherits a copy of the
    // MASTER fd across exec. Then closing the harness's master doesn't close
    // the master side, so a child blocked writing into a full PTY buffer
    // never gets EIO and never exits — deadlocked against child.wait().
    const master_fd = posix.openat(posix.AT.FDCWD, "/dev/ptmx", .{
        .ACCMODE = .RDWR,
        .NOCTTY = true,
        .CLOEXEC = true,
    }, 0) catch |err| {
        std.log.warn("Failed to open /dev/ptmx: {any}", .{err});
        return err;
    };
    errdefer closeFd(master_fd);

    const slave_name = switch (builtin.os.tag) {
        .linux => blk: {
            // Unlock the slave (TIOCSPTLCK with a 0 argument).
            var unlock: c_int = 0;
            if (!doIoctl(master_fd, TIOCSPTLCK, @intFromPtr(&unlock))) return error.PtyAllocationFailed;
            // Get the pts number (TIOCGPTN) → /dev/pts/N.
            var ptn: c_uint = 0;
            if (!doIoctl(master_fd, TIOCGPTN, @intFromPtr(&ptn))) return error.PtyAllocationFailed;
            break :blk try std.fmt.allocPrint(allocator, "/dev/pts/{d}", .{ptn});
        },
        .macos => blk: {
            // grantpt/unlockpt are ioctls on Darwin; failures are non-fatal here.
            _ = doIoctl(master_fd, TIOCPTYGRANT, 0);
            _ = doIoctl(master_fd, TIOCPTYUNLK, 0);
            var namebuf: [128]u8 = undefined;
            if (!doIoctl(master_fd, TIOCPTYGNAME, @intFromPtr(&namebuf))) return error.PtyAllocationFailed;
            break :blk try allocator.dupe(u8, std.mem.sliceTo(&namebuf, 0));
        },
        else => return error.UnsupportedPlatform,
    };
    errdefer allocator.free(slave_name);

    // CLOEXEC here too: spawn dup2s this onto the child's stdio (dup2 copies
    // don't carry CLOEXEC), so the child keeps exactly its stdio slave fds
    // and no stray extra copy of ours.
    const slave_fd = posix.openat(posix.AT.FDCWD, slave_name, .{
        .ACCMODE = .RDWR,
        .NOCTTY = true,
        .CLOEXEC = true,
    }, 0) catch |err| {
        std.log.warn("Failed to open slave {s}: {any}", .{ slave_name, err });
        return err;
    };

    std.log.info("Real PTY created: master_fd={d}, slave={s}", .{ master_fd, slave_name });

    return PtyResult{
        .master = master_fd,
        .slave = slave_fd,
        .slave_name = slave_name,
    };
}

/// Fallback PTY creation using pipes
fn createPtyFallback(allocator: std.mem.Allocator) !PtyResult {
    const pipe_fds = try makePipe();
    const slave_name = try allocator.dupe(u8, "/dev/pts/fake");

    std.log.info("PTY creation using pipe fallback", .{});

    return PtyResult{
        .master = pipe_fds[1], // write end
        .slave = pipe_fds[0], // read end
        .slave_name = slave_name,
    };
}

/// Types of input that can be sent to interactive processes
pub const InputType = enum {
    /// Regular visible text input
    text,
    /// Hidden input (passwords, sensitive data)
    hidden,
    /// Control sequences (Ctrl+C, Enter, etc.)
    control,
    /// Raw bytes (for testing binary protocols)
    raw,
};

/// Control sequences that can be sent
pub const ControlSequence = enum {
    enter,
    ctrl_c,
    ctrl_d,
    escape,
    tab,
    up_arrow,
    down_arrow,
    left_arrow,
    right_arrow,

    pub fn toBytes(self: ControlSequence) []const u8 {
        return switch (self) {
            .enter => "\n",
            .ctrl_c => "\x03",
            .ctrl_d => "\x04",
            .escape => "\x1b",
            .tab => "\t",
            .up_arrow => "\x1b[A",
            .down_arrow => "\x1b[B",
            .left_arrow => "\x1b[D",
            .right_arrow => "\x1b[C",
        };
    }
};

/// An interaction step in the script
pub const InteractionStep = struct {
    /// What we expect to see in the output
    expect: ?[]const u8 = null,
    /// What we should send as input
    send: ?[]const u8 = null,
    /// Type of input to send
    input_type: InputType = .text,
    /// Control sequence to send (if input_type is .control)
    control: ?ControlSequence = null,
    /// Signal to send to the process
    signal: ?Signal = null,
    /// Timeout for this step (milliseconds)
    timeout_ms: u32 = 5000,
    /// Whether to match the expected output exactly or just contain it
    exact_match: bool = false,
    /// Whether this step is optional (won't fail if not matched)
    optional: bool = false,
    /// A callback to run at this point in the script — for driving a process
    /// through something other than its stdin (e.g. mutating a watched file to
    /// trigger `zcli dev`'s rebuild). Runs synchronously on the harness thread,
    /// so any preceding `expect` has already matched: the effect is ordered
    /// after the state that step proved.
    action: ?*const fn (context: ?*anyopaque) void = null,
    /// Opaque context passed to `action` (a pointer to test-owned state).
    action_context: ?*anyopaque = null,
    /// A frame (rendered-screen) assertion to evaluate at this point. Set by the
    /// `expectFrame*` builders; asserted against the VTerm the driver feeds the
    /// child's output through — i.e. against the SCREEN as a terminal would draw
    /// it, not the raw byte stream. `null` when the step is not a frame step.
    frame: ?FrameAssertion = null,
    /// How long (ms) the output stream must stay idle before a `snapshot` frame
    /// is considered settled and compared. `null` falls back to
    /// `InteractiveConfig.frame_settle_ms`. Widen it (via `.withSettle`) for a
    /// slow render that pauses mid-frame on a loaded runner, so the golden is
    /// never captured mid-paint. Ignored once the child has exited — a dead
    /// child can't paint again, so that settles the frame immediately.
    settle_ms: ?u32 = null,
};

/// A rendered-screen assertion. Unlike `expect`, which greps the raw byte soup
/// (so a cursor-movement regression that leaves the text *somewhere* in the
/// stream still passes), these assert on the VTerm screen after the bytes are
/// rendered — the text must actually be visible at the right place.
pub const FrameAssertion = union(enum) {
    /// The text must appear contiguously on one row at its rendered position
    /// (VTerm.containsText — wraps at the row edge, unlike a stream substring).
    contains: []const u8,
    /// A specific row must render exactly `expected` (trailing spaces trimmed).
    row: struct { index: u16, expected: []const u8 },
    /// The whole rendered screen must match a golden snapshot. Integrates with
    /// snapshot.zig (masking + `-Dupdate-snapshots`); `name` is the snapshot
    /// file stem under `tests/snapshots/<test-file>/`.
    snapshot: []const u8,
};

/// Builder for creating interactive test scripts
pub const InteractiveScript = struct {
    steps: std.ArrayList(InteractionStep),
    allocator: std.mem.Allocator,

    /// Create a new interactive script builder
    pub fn init(allocator: std.mem.Allocator) InteractiveScript {
        return InteractiveScript{
            .steps = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *InteractiveScript) void {
        self.steps.deinit(self.allocator);
    }

    /// Expect to see specific text in the output
    pub fn expect(self: *InteractiveScript, text: []const u8) *InteractiveScript {
        self.steps.append(self.allocator, .{
            .expect = text,
        }) catch @panic("OOM");
        return self;
    }

    /// Expect exact text match (no partial matching)
    pub fn expectExact(self: *InteractiveScript, text: []const u8) *InteractiveScript {
        self.steps.append(self.allocator, .{
            .expect = text,
            .exact_match = true,
        }) catch @panic("OOM");
        return self;
    }

    /// Send text input
    pub fn send(self: *InteractiveScript, text: []const u8) *InteractiveScript {
        self.steps.append(self.allocator, .{
            .send = text,
            .input_type = .text,
        }) catch @panic("OOM");
        return self;
    }

    /// Send hidden input (passwords, etc.)
    pub fn sendHidden(self: *InteractiveScript, text: []const u8) *InteractiveScript {
        self.steps.append(self.allocator, .{
            .send = text,
            .input_type = .hidden,
        }) catch @panic("OOM");
        return self;
    }

    /// Send a control sequence
    pub fn sendControl(self: *InteractiveScript, control: ControlSequence) *InteractiveScript {
        self.steps.append(self.allocator, .{
            .send = control.toBytes(),
            .input_type = .control,
            .control = control,
        }) catch @panic("OOM");
        return self;
    }

    /// Send raw bytes
    pub fn sendRaw(self: *InteractiveScript, bytes: []const u8) *InteractiveScript {
        self.steps.append(self.allocator, .{
            .send = bytes,
            .input_type = .raw,
        }) catch @panic("OOM");
        return self;
    }

    /// Send a signal to the process
    pub fn sendSignal(self: *InteractiveScript, sig: Signal) *InteractiveScript {
        self.steps.append(self.allocator, .{
            .signal = sig,
        }) catch @panic("OOM");
        return self;
    }

    /// Expect and send in one step (common pattern)
    pub fn expectAndSend(self: *InteractiveScript, expect_text: []const u8, send_text: []const u8) *InteractiveScript {
        return self.expect(expect_text).send(send_text);
    }

    /// Expect prompt and send password
    pub fn expectAndSendPassword(self: *InteractiveScript, prompt: []const u8, password: []const u8) *InteractiveScript {
        return self.expect(prompt).sendHidden(password);
    }

    /// Run a callback at this point in the script. Use it to drive a process
    /// through a side channel — e.g. touch a file that a watcher is watching —
    /// between `expect`/`send` steps. `context` is passed back to the callback.
    pub fn action(self: *InteractiveScript, callback: *const fn (context: ?*anyopaque) void, context: ?*anyopaque) *InteractiveScript {
        self.steps.append(self.allocator, .{
            .action = callback,
            .action_context = context,
        }) catch @panic("OOM");
        return self;
    }

    /// Assert `text` is visible on the RENDERED screen at this point — on one
    /// row at its drawn position, not merely somewhere in the byte stream. The
    /// driver polls (feeding new output into the VTerm) until the frame matches
    /// or the step timeout elapses, so it composes with expect/send sequencing
    /// after the terminal has settled.
    pub fn expectFrameContains(self: *InteractiveScript, text: []const u8) *InteractiveScript {
        self.steps.append(self.allocator, .{
            .frame = .{ .contains = text },
        }) catch @panic("OOM");
        return self;
    }

    /// Assert that rendered row `index` equals `expected` (trailing spaces
    /// trimmed), polling until it matches or the step times out. Catches
    /// off-by-one row regressions a stream substring can't see.
    pub fn expectRow(self: *InteractiveScript, index: u16, expected: []const u8) *InteractiveScript {
        self.steps.append(self.allocator, .{
            .frame = .{ .row = .{ .index = index, .expected = expected } },
        }) catch @panic("OOM");
        return self;
    }

    /// Assert the whole rendered screen matches the golden snapshot `name`
    /// (stem under `tests/snapshots/<test-file>/`). Requires `snapshot_root` in
    /// the config; honors `.update_snapshots` (wire it to `-Dupdate-snapshots`).
    /// The frame is settled first — the moment the child exits, or once output
    /// has been idle for the settle window (`config.frame_settle_ms`, overridable
    /// per-step via `.withSettle`) — so the snapshot captures a stable screen.
    pub fn expectFrame(self: *InteractiveScript, name: []const u8) *InteractiveScript {
        self.steps.append(self.allocator, .{
            .frame = .{ .snapshot = name },
        }) catch @panic("OOM");
        return self;
    }

    /// Add a delay (for testing timing-sensitive interactions)
    pub fn delay(self: *InteractiveScript, ms: u32) *InteractiveScript {
        self.steps.append(self.allocator, .{
            .timeout_ms = ms,
        }) catch @panic("OOM");
        return self;
    }

    /// Set timeout for the next step
    pub fn withTimeout(self: *InteractiveScript, ms: u32) *InteractiveScript {
        if (self.steps.items.len > 0) {
            self.steps.items[self.steps.items.len - 1].timeout_ms = ms;
        }
        return self;
    }

    /// Widen (or narrow) the idle window the preceding `expectFrame` waits for
    /// before capturing the golden. Use it for a slow screen that can pause
    /// longer than the default mid-render on a loaded CI runner. No effect on a
    /// non-snapshot step.
    pub fn withSettle(self: *InteractiveScript, ms: u32) *InteractiveScript {
        if (self.steps.items.len > 0) {
            self.steps.items[self.steps.items.len - 1].settle_ms = ms;
        }
        return self;
    }

    /// Make the last step optional (won't fail if not matched)
    pub fn optional(self: *InteractiveScript) *InteractiveScript {
        if (self.steps.items.len > 0) {
            self.steps.items[self.steps.items.len - 1].optional = true;
        }
        return self;
    }
};

/// Configuration for interactive test execution
pub const InteractiveConfig = struct {
    /// Working directory for the command
    cwd: ?[]const u8 = null,
    /// Environment variables to set
    env: ?std.process.Environ.Map = null,
    /// Whether to allocate a pseudo-terminal (TTY)
    allocate_pty: bool = true,
    /// Buffer size for output capture
    buffer_size: usize = 64 * 1024, // 64KB default
    /// Global timeout for the entire interaction (milliseconds)
    total_timeout_ms: u32 = 30000, // 30 seconds
    /// Whether to echo sent input in test output (for debugging)
    echo_input: bool = false,
    /// Whether to save interaction transcript for debugging
    save_transcript: bool = false,
    /// Path to save transcript (if save_transcript is true)
    transcript_path: ?[]const u8 = null,

    // Terminal settings
    /// Initial terminal mode (raw, cooked, or inherit from parent)
    terminal_mode: TerminalMode = .cooked,
    /// Terminal dimensions (rows, cols) - null means inherit from parent
    terminal_size: ?struct { rows: u16, cols: u16 } = null,
    /// Whether to disable echo (useful for password prompts)
    disable_echo: bool = false,

    // Signal handling
    /// Whether to forward signals to child process
    forward_signals: bool = false,
    /// Which signals to forward (null means all common signals)
    signals_to_forward: ?[]const Signal = null,

    // Frame assertions (rendered-screen expects)
    /// Root directory `expectFrame` snapshots resolve against (the same
    /// `tests/snapshots/<test-file>/` layout snapshot.zig uses). Required only
    /// if the script uses `expectFrame`; pass `std.Io.Dir.cwd()` in a normal
    /// suite. `expectFrameContains`/`expectRow` don't need it.
    snapshot_root: ?std.Io.Dir = null,
    /// When true, `expectFrame` writes (or overwrites) the snapshot instead of
    /// comparing. Thread this from a `-Dupdate-snapshots` build option.
    update_snapshots: bool = false,
    /// Default idle window (ms) an `expectFrame` snapshot waits for before it
    /// treats the screen as settled and compares it — unless the child exits
    /// first, which settles immediately. Kept comfortably above a single poll
    /// window so a normal render is never snapshotted mid-frame; a per-step
    /// `.withSettle` overrides it for a known-slow path.
    frame_settle_ms: u32 = 150,
};

/// Terminal modes for PTY configuration
pub const TerminalMode = enum {
    /// Normal line-buffered mode with echo
    cooked,
    /// Raw mode for character-by-character input
    raw,
    /// Inherit settings from parent terminal
    inherit,
};

/// Common signals that can be sent/forwarded
pub const Signal = enum(c_int) {
    SIGINT = 2, // Interrupt (Ctrl+C)
    SIGQUIT = 3, // Quit
    SIGTERM = 15, // Terminate
    SIGTSTP = 20, // Terminal stop (Ctrl+Z)
    SIGCONT = 18, // Continue
    SIGWINCH = 28, // Window size change
    SIGHUP = 1, // Hangup
    SIGUSR1 = 10, // User-defined signal 1
    SIGUSR2 = 12, // User-defined signal 2

    pub fn toInt(self: Signal) c_int {
        return @intFromEnum(self);
    }
};

/// Map our portable Signal to std.posix.SIG (used by posix.kill).
fn toPosixSig(s: Signal) posix.SIG {
    return switch (s) {
        .SIGINT => .INT,
        .SIGQUIT => .QUIT,
        .SIGTERM => .TERM,
        .SIGTSTP => .TSTP,
        .SIGCONT => .CONT,
        .SIGWINCH => .WINCH,
        .SIGHUP => .HUP,
        .SIGUSR1 => .USR1,
        .SIGUSR2 => .USR2,
    };
}

/// Result of an interactive test execution
pub const InteractiveResult = struct {
    /// Final exit code of the process
    exit_code: u8,
    /// Complete output captured during interaction
    output: []const u8,
    /// Complete input sent during interaction (for debugging)
    input: []const u8,
    /// Whether all interaction steps completed successfully
    success: bool,
    /// Number of steps that were executed
    steps_executed: usize,
    /// Total duration of the interaction
    duration_ms: u64,
    /// Transcript of the interaction (if enabled)
    transcript: ?[]const u8 = null,
    /// The PTY's line-discipline termios sampled after the child exited, just
    /// before the master was closed (POSIX + PTY runs only; `null` on pipes or
    /// Windows). A prompt's raw mode is applied to this shared termios, so this
    /// captures whether the child left the terminal cooked (its restore ran) or
    /// raw (it died mid-prompt without restoring). Lets a test assert the
    /// signal/panic restore guard actually fired.
    final_termios: ?posix.termios = null,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *InteractiveResult) void {
        self.allocator.free(self.output);
        self.allocator.free(self.input);
        if (self.transcript) |transcript| {
            self.allocator.free(transcript);
        }
    }

    /// True when `final_termios` shows a cooked terminal (canonical mode and
    /// echo on) — i.e. the child restored the terminal it put in raw mode.
    /// Returns `null` when no termios was captured (pipes / Windows), so a test
    /// can skip rather than assert on a platform that can't observe it.
    pub fn rawModeRestored(self: InteractiveResult) ?bool {
        const t = self.final_termios orelse return null;
        return t.lflag.ICANON and t.lflag.ECHO;
    }
};

/// Errors that can occur during interactive testing
pub const InteractiveError = error{
    /// Failed to start the process
    ProcessStartFailed,
    /// Failed to fork process for PTY
    ForkFailed,
    /// Timeout waiting for expected output
    ExpectationTimeout,
    /// Expected output never appeared
    ExpectationNotMet,
    /// Failed to send input to process
    InputSendFailed,
    /// Process crashed unexpectedly
    ProcessCrashed,
    /// Failed to allocate pseudo-terminal
    PtyAllocationFailed,
    /// Output buffer overflow
    BufferOverflow,
    /// Invalid interaction script
    InvalidScript,
    /// Terminal settings error
    TerminalSettingsError,
    /// Window size error
    WindowSizeError,
    /// PTY not available
    NoPty,
    /// Bad file descriptor
    BadFileDescriptor,
    /// Not a terminal
    NotATerminal,
    /// Platform not supported
    UnsupportedPlatform,
    /// No saved terminal settings
    NoSavedSettings,
} || std.mem.Allocator.Error;

/// Whether the environment demands that the interactive (PTY) tier actually
/// run — set by CI so a sandbox that can't allocate a PTY turns from a silent
/// skip into a hard build failure. Replaces grepping the job log for
/// `runInteractive unavailable`, which only proved the wording was still
/// there, not that the harness could have caught a real regression in it.
///
/// Read via the threaded environ (`std.testing.environ`, populated by the
/// 0.16 test runner from `std.process.Init`) rather than libc getenv — this
/// runs inside `zig build test`/`zig build e2e` test binaries, which have no
/// ambient ENV access of their own.
pub fn interactiveRequired() bool {
    return std.process.Environ.containsUnemptyConstant(std.testing.environ, "ZCLI_REQUIRE_INTERACTIVE");
}

/// Why a script step stopped the run — carried out of `driveScriptSteps` so the
/// driver can print a single loud diagnostic (which step, what kind, and the
/// rendered screen) instead of letting the failure surface only as a nonzero
/// child exit code. `.none` means every step passed.
const StepFailure = union(enum) {
    none,
    expect: []const u8,
    frame: FrameAssertion,
    send: []const u8,
    total_timeout,
};

/// Outcome of running the script's steps, before teardown.
const ScriptOutcome = struct {
    success: bool,
    steps_executed: usize,
    /// Which step (0-based) broke the run, when `!success`.
    failed_step: usize = 0,
    /// Why it broke, for the diagnostic dump.
    failure: StepFailure = .none,
};

/// POSIX session the step driver talks to: the PTY/pipe fds plus the child pid,
/// behind the same pollRead/writeAll/sendSignal surface the Windows session
/// exposes. Keeps `driveScriptSteps` platform-neutral.
const PosixSession = struct {
    read_fd: posix.fd_t,
    write_fd: posix.fd_t,
    child_id: ?posix.pid_t,

    // Bare `pollRead`/`writeAll` resolve to the file-scope helpers, not these
    // methods (methods are only reachable through `self.`/the type name).
    fn pollRead(self: *PosixSession, buf: []u8, timeout_ms: i32) usize {
        return pollFd(self.read_fd, buf, timeout_ms);
    }
    fn writeAll(self: *PosixSession, bytes: []const u8) error{WriteFailed}!void {
        return writeFd(self.write_fd, bytes);
    }
    fn sendSignal(self: *PosixSession, sig: Signal) void {
        if (self.child_id) |pid| {
            posix.kill(pid, toPosixSig(sig)) catch |err| {
                std.log.warn("Failed to send signal {any} to process: {any}", .{ sig, err });
            };
        }
    }
    /// Non-destructively report whether the child has hung up: a zero-timeout
    /// poll for HUP/ERR on the read fd (the PTY master or pipe reports it once
    /// the child's last write end closes on exit). Never consumes pending data —
    /// HUP/ERR land in `revents` regardless of the requested `events` — so the
    /// settle path can drain first, then ask "is anything more coming?"
    fn hasExited(self: *PosixSession) bool {
        var fds = [_]posix.pollfd{.{ .fd = self.read_fd, .events = 0, .revents = 0 }};
        const ready = posix.poll(&fds, 0) catch return false;
        if (ready == 0) return false;
        return fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0;
    }
};

/// Windows session: wraps a conpty.ConPtySession and maps the harness's Signal
/// enum onto ConPTY operations. conpty.zig stays free of e2e types (it can't
/// import this file), so the mapping lives here.
const WindowsSession = struct {
    inner: *conpty.ConPtySession,

    fn pollRead(self: *WindowsSession, buf: []u8, timeout_ms: i32) usize {
        return self.inner.pollRead(buf, timeout_ms);
    }
    fn writeAll(self: *WindowsSession, bytes: []const u8) error{WriteFailed}!void {
        return self.inner.writeAll(bytes);
    }
    fn sendSignal(self: *WindowsSession, sig: Signal) void {
        switch (sig) {
            // Windows has no real SIGINT, and a host-injected Ctrl+C (`\x03`
            // written into the ConPTY input) only becomes a CTRL_C_EVENT for a
            // child that reads console input — a child blocked elsewhere (e.g.
            // `zcli dev` waiting on its watcher) never consumes the byte and so
            // never sees the interrupt. Every signal a test sends here means
            // "stop this process now, I've captured what I need," so map them
            // all to a forced terminate, which is deterministic regardless of
            // what the child is doing.
            .SIGINT, .SIGTERM, .SIGQUIT, .SIGHUP => self.inner.signalTerm(),
            else => {}, // SIGWINCH/SIGTSTP/... have no ConPTY analogue here
        }
    }
    /// Whether the child has already exited — a zero-timeout wait on its process
    /// handle. Lets the settle path stop the moment no more paint can arrive.
    fn hasExited(self: *WindowsSession) bool {
        return self.inner.waitExit(0) != null;
    }
};

/// Run the script's expect/send/signal/action steps against `session`. Shared
/// by the POSIX and Windows drivers, which differ only in how they spawn the
/// child and tear it down. `start_time` is the driver's overall start, so the
/// total-timeout budget spans spawn + steps consistently on both platforms.
fn driveScriptSteps(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: anytype,
    script: InteractiveScript,
    config: InteractiveConfig,
    start_time: i64,
    output_buffer: *std.ArrayList(u8),
    input_buffer: *std.ArrayList(u8),
    transcript_buffer: ?*std.ArrayList(u8),
    /// The virtual terminal every read is fed through, sized to the session's
    /// winsize. `null` when the harness could not allocate one (no VTerm ⇒ any
    /// frame step is a loud, explicit failure rather than a false pass).
    screen: ?*vterm.VTerm,
) InteractiveError!ScriptOutcome {
    var steps_executed: usize = 0;
    var script_success = true;
    var failed_step: usize = 0;
    var failure: StepFailure = .none;

    for (script.steps.items, 0..) |step, step_index| {
        if (transcript_buffer) |tb| {
            try transcriptPrint(tb, allocator, "[Step {d}] ", .{step_index + 1});
        }

        if (step.expect) |expected| {
            const found = try waitForOutput(
                allocator,
                io,
                session,
                expected,
                step.timeout_ms,
                step.exact_match,
                output_buffer,
                transcript_buffer,
                screen,
            );

            if (!found and !step.optional) {
                script_success = false;
                failed_step = step_index;
                failure = .{ .expect = expected };
                break;
            }

            if (transcript_buffer) |tb| {
                if (found) {
                    try transcriptPrint(tb, allocator, "\u{2713} Expected: \"{s}\"\n", .{expected});
                } else {
                    try transcriptPrint(tb, allocator, "\u{2717} Expected: \"{s}\" (optional: {any})\n", .{ expected, step.optional });
                }
            }
        }

        if (step.send) |input| {
            const ok = sendInput(
                allocator,
                session,
                input,
                step.input_type,
                input_buffer,
                transcript_buffer,
                config.echo_input,
            ) catch false;

            if (!ok) {
                script_success = false;
                failed_step = step_index;
                failure = .{ .send = input };
                break;
            }
        }

        if (step.signal) |sig| {
            session.sendSignal(sig);
            if (transcript_buffer) |tb| {
                try transcriptPrint(tb, allocator, "Sent signal: {any}\n", .{sig});
            }
            sleepMs(io, 100);
        }

        if (step.action) |callback| {
            callback(step.action_context);
            if (transcript_buffer) |tb| {
                try transcriptPrint(tb, allocator, "Ran action\n", .{});
            }
        }

        if (step.frame) |assertion| {
            const term = screen orelse {
                // No VTerm to render into: refuse to silently pass. Frame
                // assertions exist precisely to close the gap a raw substring
                // leaves, so a missing terminal is a hard failure, not a skip.
                std.log.err("frame assertion requested but no VTerm is available (allocate_pty must be true)", .{});
                return InteractiveError.NoPty;
            };
            const ok = try waitForFrame(
                allocator,
                io,
                session,
                assertion,
                step.timeout_ms,
                step.settle_ms orelse config.frame_settle_ms,
                config,
                output_buffer,
                transcript_buffer,
                term,
            );
            if (!ok and !step.optional) {
                script_success = false;
                failed_step = step_index;
                failure = .{ .frame = assertion };
                break;
            }
        }

        // Pure delay steps (an action step carries the default timeout_ms but is
        // not a delay — don't sleep on it).
        if (step.expect == null and step.send == null and step.signal == null and step.action == null and step.frame == null and step.timeout_ms > 0) {
            sleepMs(io, step.timeout_ms);
        }

        steps_executed += 1;

        const elapsed = nowMs(io) - start_time;
        if (elapsed > config.total_timeout_ms) {
            script_success = false;
            failed_step = step_index;
            failure = .total_timeout;
            break;
        }
    }

    return .{
        .success = script_success,
        .steps_executed = steps_executed,
        .failed_step = failed_step,
        .failure = failure,
    };
}

/// Determine the VTerm geometry for a PTY run and allocate the terminal. Prefer
/// the PTY's actual winsize (what the child sees via TIOCGWINSZ), falling back
/// to the configured size, then a 24x80 default. Returns null on allocation
/// failure so the caller degrades to "no frame assertions" rather than crashing.
fn vtermForPty(allocator: std.mem.Allocator, pty_manager: ?PtyManager, config: InteractiveConfig) ?vterm.VTerm {
    var rows: u16 = 24;
    var cols: u16 = 80;
    if (config.terminal_size) |s| {
        rows = s.rows;
        cols = s.cols;
    }
    if (pty_manager) |pty| {
        var mgr = pty;
        if (mgr.getWindowSize()) |ws| {
            if (ws.row != 0 and ws.col != 0) {
                rows = ws.row;
                cols = ws.col;
            }
        } else |_| {}
    }
    return vterm.VTerm.init(allocator, cols, rows) catch null;
}

/// Run an interactive test script against a command.
///
/// `io` is required for spawning the child and waiting on it; the byte-level I/O
/// with the child polls with timeouts (posix.poll/read/write on POSIX,
/// PeekNamedPipe/ReadFile/WriteFile through the ConPTY session on Windows).
///
/// A comptime switch picks the platform driver so each one's OS-specific spawn
/// and teardown is only analyzed where it applies.
pub fn runInteractive(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: []const []const u8,
    script: InteractiveScript,
    config: InteractiveConfig,
) InteractiveError!InteractiveResult {
    return switch (builtin.os.tag) {
        .windows => runInteractiveWindows(allocator, io, command, script, config),
        else => runInteractivePosix(allocator, io, command, script, config),
    };
}

fn runInteractivePosix(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: []const []const u8,
    script: InteractiveScript,
    config: InteractiveConfig,
) InteractiveError!InteractiveResult {
    if (command.len == 0) return InteractiveError.InvalidScript;

    const start_time = nowMs(io);

    var output_buffer: std.ArrayList(u8) = .empty;
    defer output_buffer.deinit(allocator);
    try output_buffer.ensureTotalCapacity(allocator, config.buffer_size);

    var input_buffer: std.ArrayList(u8) = .empty;
    defer input_buffer.deinit(allocator);

    var transcript_buffer: ?std.ArrayList(u8) = if (config.save_transcript) .empty else null;
    defer if (transcript_buffer) |*tb| tb.deinit(allocator);

    // Allocate a PTY if requested.
    var pty_manager: ?PtyManager = null;
    if (config.allocate_pty) {
        if (PtyManager.init(allocator)) |pty| {
            pty_manager = pty;
        } else |err| {
            std.log.warn("Failed to allocate PTY, falling back to pipes: {any}", .{err});
            pty_manager = null;
        }
    }
    defer if (pty_manager) |*pty| {
        pty.restoreTerminalSettings();
        pty.deinit();
    };

    // The child environment, threaded through explicitly (no ambient environ).
    var env_copy = config.env;
    const environ_map: ?*const std.process.Environ.Map = if (env_copy) |*e| e else null;
    const cwd: std.process.Child.Cwd = if (config.cwd) |c| .{ .path = c } else .inherit;

    // Spawn the child with its stdio pointed at the PTY slave (or pipes).
    var child: std.process.Child = undefined;
    if (pty_manager) |*pty| {
        if (config.terminal_size) |size| {
            try pty.setWindowSize(size.rows, size.cols);
        } else {
            pty.autoAdjustWindowSize() catch {};
        }

        const slave = fileFromFd(pty.slave_fd);
        child = std.process.spawn(io, .{
            .argv = command,
            .stdin = .{ .file = slave },
            .stdout = .{ .file = slave },
            .stderr = .{ .file = slave },
            .cwd = cwd,
            .environ_map = environ_map,
        }) catch return InteractiveError.ProcessStartFailed;

        // Parent no longer needs the slave; the child owns its copy.
        closeFd(pty.slave_fd);
        pty.slave_fd = -1;

        switch (config.terminal_mode) {
            .raw => pty.setRawMode() catch {},
            .cooked, .inherit => {},
        }
        if (config.disable_echo) pty.setEcho(false) catch {};
    } else {
        child = std.process.spawn(io, .{
            .argv = command,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .cwd = cwd,
            .environ_map = environ_map,
        }) catch return InteractiveError.ProcessStartFailed;
    }

    const using_pty = pty_manager != null;
    // For a PTY, both directions share the master fd; for pipes, use the child's.
    const read_fd: posix.fd_t = if (pty_manager) |*pty| pty.master_fd else child.stdout.?.handle;
    const write_fd: posix.fd_t = if (pty_manager) |*pty| pty.master_fd else child.stdin.?.handle;

    // A virtual terminal mirroring the child's output, sized to the PTY winsize
    // so a frame assertion sees the screen exactly as the child rendered it.
    // Only allocated for a PTY run — frame assertions need a real terminal. If
    // allocation fails, `screen` stays null and any frame step fails loudly.
    var screen_storage: ?vterm.VTerm = if (using_pty) vtermForPty(allocator, pty_manager, config) else null;
    defer if (screen_storage) |*s| s.deinit();
    const screen: ?*vterm.VTerm = if (screen_storage) |*s| s else null;

    var session = PosixSession{ .read_fd = read_fd, .write_fd = write_fd, .child_id = child.id };
    const outcome = try driveScriptSteps(
        allocator,
        io,
        &session,
        script,
        config,
        start_time,
        &output_buffer,
        &input_buffer,
        if (transcript_buffer) |*tb| tb else null,
        screen,
    );
    var script_success = outcome.success;
    const steps_executed = outcome.steps_executed;

    // Close the write side to signal EOF to the child.
    if (!using_pty) {
        if (child.stdin) |stdin| {
            closeFd(stdin.handle);
            child.stdin = null;
        }
    }

    // If the script didn't complete (an `expect` timed out), the child is almost
    // certainly still blocked on a prompt — `child.wait` would hang forever.
    // Terminate it so the test fails fast instead of deadlocking the suite.
    if (!script_success) {
        if (child.id) |pid| posix.kill(pid, toPosixSig(.SIGTERM)) catch {};
    }

    // Drain remaining output. For a PTY this must run until the child has
    // actually exited (the master reports HUP once the last slave fd closes),
    // not for a fixed idle window: the kernel PTY buffer is small (4 KiB on
    // macOS), so a child still printing after an idle-window drain stopped
    // reading blocks in write() forever — deadlocked against child.wait().
    if (using_pty) {
        const elapsed_ms: u64 = @intCast(nowMs(io) - start_time);
        const remaining: u64 = if (config.total_timeout_ms > elapsed_ms)
            config.total_timeout_ms - elapsed_ms
        else
            0;
        const child_exited = drainUntilHup(allocator, io, read_fd, &output_buffer, @max(remaining, 1000)) catch false;
        if (!child_exited) {
            // Deadline passed with the child still alive: kill it so wait()
            // below returns, and record the run as failed.
            script_success = false;
            if (child.id) |pid| posix.kill(pid, toPosixSig(.SIGTERM)) catch {};
            drainOutput(allocator, io, read_fd, &output_buffer, 500) catch {};
        }
    } else {
        drainOutput(allocator, io, read_fd, &output_buffer, 1000) catch {};
    }

    // For a PTY, close the master after draining so a child that reads until
    // end-of-input gets EOF/SIGHUP and exits — otherwise `child.wait` could block
    // on it. (The pipe path already closed stdin above for the same reason.)
    // Sample the shared line-discipline termios first: the drain above ran until
    // the child's slave closed (it exited), so any restore the child made — the
    // signal/panic guard's `tcsetattr` included — has already landed on this
    // fd. This is the only window it's observable (the master is about to go).
    var final_termios: ?posix.termios = null;
    if (using_pty) {
        if (pty_manager) |*pty| {
            if (pty.master_fd != -1) {
                final_termios = posix.tcgetattr(pty.master_fd) catch null;
                closeFd(pty.master_fd);
                pty.master_fd = -1;
            }
        }
    }

    const term = child.wait(io) catch return InteractiveError.ProcessCrashed;
    const exit_code: u8 = switch (term) {
        .exited => |code| code,
        else => 1,
    };

    // A step that broke the run left the child blocked mid-prompt (we killed it
    // above), so the only visible symptom in the test would be a nonzero exit
    // code. Print the full diagnostic now — which step, the rendered screen, the
    // raw tail — so CI shows exactly what the child drew.
    if (!outcome.success) dumpScriptFailure(allocator, outcome, screen, output_buffer.items);

    const duration_ms: u64 = @intCast(nowMs(io) - start_time);

    if (config.save_transcript and config.transcript_path != null) {
        if (transcript_buffer) |*tb| {
            if (std.Io.Dir.cwd().createFile(io, config.transcript_path.?, .{})) |file| {
                var f = file;
                defer f.close(io);
                f.writeStreamingAll(io, tb.items) catch {};
            } else |err| {
                std.log.warn("Failed to save transcript: {any}", .{err});
            }
        }
    }

    return InteractiveResult{
        .exit_code = exit_code,
        .output = try output_buffer.toOwnedSlice(allocator),
        .input = try input_buffer.toOwnedSlice(allocator),
        .success = script_success and exit_code == 0,
        .steps_executed = steps_executed,
        .duration_ms = duration_ms,
        .transcript = if (transcript_buffer) |*tb| try tb.toOwnedSlice(allocator) else null,
        .final_termios = final_termios,
        .allocator = allocator,
    };
}

/// Windows driver: spawn the command into a ConPTY and drive the same script
/// through the shared step loop. Only the spawn and teardown differ from the
/// POSIX path. Pipe mode (allocate_pty = false) isn't wired up here yet, since
/// the interactive e2e tiers all drive real terminals.
fn runInteractiveWindows(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: []const []const u8,
    script: InteractiveScript,
    config: InteractiveConfig,
) InteractiveError!InteractiveResult {
    if (command.len == 0) return InteractiveError.InvalidScript;
    if (!config.allocate_pty) return InteractiveError.UnsupportedPlatform;

    const start_time = nowMs(io);

    var output_buffer: std.ArrayList(u8) = .empty;
    defer output_buffer.deinit(allocator);
    try output_buffer.ensureTotalCapacity(allocator, config.buffer_size);

    var input_buffer: std.ArrayList(u8) = .empty;
    defer input_buffer.deinit(allocator);

    var transcript_buffer: ?std.ArrayList(u8) = if (config.save_transcript) .empty else null;
    defer if (transcript_buffer) |*tb| tb.deinit(allocator);

    const rows: u16 = if (config.terminal_size) |s| s.rows else 24;
    const cols: u16 = if (config.terminal_size) |s| s.cols else 80;

    var env_copy = config.env;
    const environ_map: ?*const std.process.Environ.Map = if (env_copy) |*e| e else null;

    var cp = conpty.ConPtySession.spawn(allocator, command, environ_map, config.cwd, rows, cols) catch |err| {
        std.log.warn("ConPTY spawn failed: {any}", .{err});
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => InteractiveError.PtyAllocationFailed,
        };
    };
    defer cp.deinit(allocator);

    // VTerm sized to the ConPTY window, fed the same VT byte stream frame
    // assertions render against. ConPTY emits standard VT sequences, so the
    // same parser drives both backends. Null on OOM ⇒ frame steps fail loudly.
    var screen_storage: ?vterm.VTerm = vterm.VTerm.init(allocator, cols, rows) catch null;
    defer if (screen_storage) |*s| s.deinit();
    const screen: ?*vterm.VTerm = if (screen_storage) |*s| s else null;

    var session = WindowsSession{ .inner = &cp };
    const outcome = try driveScriptSteps(
        allocator,
        io,
        &session,
        script,
        config,
        start_time,
        &output_buffer,
        &input_buffer,
        if (transcript_buffer) |*tb| tb else null,
        screen,
    );
    var script_success = outcome.success;
    const steps_executed = outcome.steps_executed;

    // Kill a still-blocked child if the script itself failed.
    if (!script_success) cp.signalTerm();

    // Drain output until the child exits on its own or the deadline passes —
    // the ConPTY analogue of the POSIX drainUntilHup, and like it we keep the
    // input open throughout. A wizard's exit sequence can still read from the
    // terminal (e.g. a cursor-position report, which ConPTY answers on the
    // input channel); closing input early would wedge that read and the child
    // would never finish. deinit() closes the input as final cleanup. Read all
    // available bytes before honoring exit so a final burst isn't lost.
    var exit_code: u8 = 1;
    var temp_buffer: [4096]u8 = undefined;
    while (true) {
        const n = cp.pollRead(&temp_buffer, 50);
        if (n > 0) {
            try output_buffer.appendSlice(allocator, temp_buffer[0..n]);
            continue;
        }
        if (cp.waitExit(0)) |code| {
            exit_code = code;
            // The process object has signaled, but ConPTY's conhost renders the
            // child's console on its own thread and may still be flushing a final
            // burst of VT into the output pipe. waitExit reports the process, not
            // the pipe, and a single empty 50ms pollRead window above is not proof
            // the pipe is drained. Keep reading until a full window elapses with
            // nothing available (PeekNamedPipe reporting 0 / broken pipe) so a
            // trailing write is never dropped — the ConPTY analogue of the POSIX
            // drain-to-HUP edge.
            while (true) {
                const remaining = cp.pollRead(&temp_buffer, 50);
                if (remaining == 0) break;
                try output_buffer.appendSlice(allocator, temp_buffer[0..remaining]);
            }
            break;
        }
        const elapsed: u64 = @intCast(nowMs(io) - start_time);
        if (elapsed > config.total_timeout_ms) {
            script_success = false;
            cp.signalTerm();
            exit_code = cp.waitExit(2000) orelse 1;
            break;
        }
    }

    if (!outcome.success) dumpScriptFailure(allocator, outcome, screen, output_buffer.items);

    const duration_ms: u64 = @intCast(nowMs(io) - start_time);

    if (config.save_transcript and config.transcript_path != null) {
        if (transcript_buffer) |*tb| {
            if (std.Io.Dir.cwd().createFile(io, config.transcript_path.?, .{})) |file| {
                var f = file;
                defer f.close(io);
                f.writeStreamingAll(io, tb.items) catch {};
            } else |err| {
                std.log.warn("Failed to save transcript: {any}", .{err});
            }
        }
    }

    return InteractiveResult{
        .exit_code = exit_code,
        .output = try output_buffer.toOwnedSlice(allocator),
        .input = try input_buffer.toOwnedSlice(allocator),
        .success = script_success and exit_code == 0,
        .steps_executed = steps_executed,
        .duration_ms = duration_ms,
        .transcript = if (transcript_buffer) |*tb| try tb.toOwnedSlice(allocator) else null,
        .allocator = allocator,
    };
}

/// Read once from `fd` with a poll timeout. Returns the number of bytes read,
/// 0 on EOF/timeout/closed-PTY. Never blocks longer than `timeout_ms`.
fn pollFd(fd: posix.fd_t, buf: []u8, timeout_ms: i32) usize {
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const ready = posix.poll(&fds, timeout_ms) catch return 0;
    if (ready == 0) return 0; // timeout
    return posix.read(fd, buf) catch |err| switch (err) {
        // A closed PTY slave surfaces as EIO on the master; treat as EOF.
        error.InputOutput => 0,
        error.WouldBlock => 0,
        else => 0,
    };
}

/// Wait for specific output to appear, with timeout. Every byte read is also
/// fed into `screen` (when present) so the VTerm stays a faithful mirror of the
/// stream for any following frame assertion — the terminal is rendered
/// continuously, not re-parsed from scratch at each frame step.
fn waitForOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: anytype,
    expected: []const u8,
    timeout_ms: u32,
    exact_match: bool,
    output_buffer: *std.ArrayList(u8),
    transcript_buffer: ?*std.ArrayList(u8),
    screen: ?*vterm.VTerm,
) InteractiveError!bool {
    const start_time = nowMs(io);
    var temp_buffer: [4096]u8 = undefined;

    while (true) {
        const elapsed = nowMs(io) - start_time;
        if (elapsed > timeout_ms) return false;

        const remaining: i32 = @intCast(@max(@as(i64, 0), @as(i64, timeout_ms) - elapsed));
        const bytes_read = session.pollRead(&temp_buffer, @min(remaining, 50));
        if (bytes_read == 0) continue;

        try output_buffer.appendSlice(allocator, temp_buffer[0..bytes_read]);
        if (screen) |term| term.write(temp_buffer[0..bytes_read]);

        if (transcript_buffer) |tb| {
            try transcriptPrint(tb, allocator, "Received: \"{s}\"\n", .{temp_buffer[0..bytes_read]});
        }

        if (exact_match) {
            if (std.mem.endsWith(u8, output_buffer.items, expected)) return true;
        } else {
            if (std.mem.indexOf(u8, output_buffer.items, expected) != null) return true;
        }
    }
}

/// True once the rendered `screen` satisfies `assertion` (contains/row checks).
/// Snapshot assertions are settled-then-compared by the caller, so they always
/// report "not yet matched" here and fall through to the settle path.
fn frameSatisfied(allocator: std.mem.Allocator, screen: *vterm.VTerm, assertion: FrameAssertion) bool {
    switch (assertion) {
        .contains => |text| return screen.containsText(text),
        .row => |r| {
            const line = screen.getLine(allocator, r.index) catch return false;
            defer allocator.free(line);
            return std.mem.eql(u8, line, r.expected);
        },
        .snapshot => return false,
    }
}

/// Whether a `snapshot` frame is settled and safe to capture, given the two
/// deterministic signals the settle loop tracks. `child_exited` wins outright —
/// a dead child cannot repaint, so the current frame is final no matter how
/// short the idle has been (this is what makes an end-of-render golden immune to
/// CI-load timing). Otherwise the stream must have been quiet for the full
/// `settle_ms` window, so a child that pauses mid-frame is not snapshotted
/// half-drawn (widen `settle_ms` per-step for a known-slow path).
fn snapshotSettled(child_exited: bool, idle_ms: i64, settle_ms: u32) bool {
    return child_exited or idle_ms >= @as(i64, settle_ms);
}

/// Poll — feeding new output into `screen` — until the rendered frame satisfies
/// `assertion` or `timeout_ms` elapses. This is the settle strategy for frame
/// steps: no fixed sleep, just "read → render → re-check" like `waitForOutput`,
/// so a slow paint is tolerated and a fast one returns immediately.
///
/// A `snapshot` assertion instead settles the frame before comparing — a
/// whole-screen golden needs a stable frame, not a single substring. Two
/// deterministic settle signals, in order of preference:
///   1. the child has exited (HUP) — nothing can repaint, so compare at once;
///   2. the stream has stayed idle for `settle_ms` — a time window, not a fixed
///      poll count, so it holds regardless of poll granularity and can be
///      widened per-step for a slow render (see `InteractionStep.settle_ms`).
/// Then it compares (or updates) via the shared snapshot machinery.
fn waitForFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: anytype,
    assertion: FrameAssertion,
    timeout_ms: u32,
    settle_ms: u32,
    config: InteractiveConfig,
    output_buffer: *std.ArrayList(u8),
    transcript_buffer: ?*std.ArrayList(u8),
    screen: *vterm.VTerm,
) InteractiveError!bool {
    const start_time = nowMs(io);
    var temp_buffer: [4096]u8 = undefined;

    // Fast path: already satisfied from output rendered by prior steps.
    if (frameSatisfied(allocator, screen, assertion)) {
        try reportFrame(allocator, transcript_buffer, assertion, true);
        return true;
    }

    // Timestamp of the last byte seen — the anchor for the idle window. A frame
    // is "settled" once `settle_ms` has passed with no new output.
    var last_activity = start_time;
    while (true) {
        const elapsed = nowMs(io) - start_time;
        if (elapsed > timeout_ms) break;

        const remaining: i32 = @intCast(@max(@as(i64, 0), @as(i64, timeout_ms) - elapsed));
        const bytes_read = session.pollRead(&temp_buffer, @min(remaining, 50));
        if (bytes_read == 0) {
            // A snapshot settles on either deterministic signal (contains/row
            // keep polling to the deadline — they may still be painting).
            if (assertion == .snapshot and
                snapshotSettled(session.hasExited(), nowMs(io) - last_activity, settle_ms))
            {
                break;
            }
            continue;
        }
        last_activity = nowMs(io);

        try output_buffer.appendSlice(allocator, temp_buffer[0..bytes_read]);
        screen.write(temp_buffer[0..bytes_read]);

        if (assertion != .snapshot and frameSatisfied(allocator, screen, assertion)) {
            try reportFrame(allocator, transcript_buffer, assertion, true);
            return true;
        }
    }

    // Deadline (or settle) reached. Snapshot compares the settled frame; the
    // others print a readable rendered-screen diagnostic and fail.
    switch (assertion) {
        .snapshot => |name| {
            try assertFrameSnapshot(allocator, io, screen, config, name);
            try reportFrame(allocator, transcript_buffer, assertion, true);
            return true;
        },
        .contains, .row => {
            printFrameMismatch(allocator, screen, assertion);
            try reportFrame(allocator, transcript_buffer, assertion, false);
            return false;
        },
    }
}

fn reportFrame(allocator: std.mem.Allocator, transcript_buffer: ?*std.ArrayList(u8), assertion: FrameAssertion, ok: bool) !void {
    const tb = transcript_buffer orelse return;
    const mark: []const u8 = if (ok) "\u{2713}" else "\u{2717}";
    switch (assertion) {
        .contains => |t| try transcriptPrint(tb, allocator, "{s} Frame contains: \"{s}\"\n", .{ mark, t }),
        .row => |r| try transcriptPrint(tb, allocator, "{s} Frame row {d} == \"{s}\"\n", .{ mark, r.index, r.expected }),
        .snapshot => |n| try transcriptPrint(tb, allocator, "{s} Frame snapshot: {s}\n", .{ mark, n }),
    }
}

/// Render the whole screen and compare/update it against a golden snapshot,
/// reusing snapshot.zig's masking + update flow. The path is
/// `<snapshot_root>/tests/snapshots/e2e/<name>.txt` — the same layout the
/// in-process tier uses, but resolved at runtime (the builder can't carry a
/// comptime `@src()`), so `name` is the file stem the caller chooses.
fn assertFrameSnapshot(
    allocator: std.mem.Allocator,
    io: std.Io,
    screen: *vterm.VTerm,
    config: InteractiveConfig,
    name: []const u8,
) InteractiveError!void {
    const root = config.snapshot_root orelse {
        std.log.err("expectFrame(\"{s}\") needs config.snapshot_root set", .{name});
        return InteractiveError.InvalidScript;
    };

    // Full rendered screen, rows joined by newlines, trailing blank rows kept so
    // the golden captures the exact frame geometry.
    const actual = try screen.getAllText(allocator);
    defer allocator.free(actual);
    const framed = try reflowToRows(allocator, actual, screen.width, screen.height);
    defer allocator.free(framed);

    const masked = try snapshot.maskDynamicContent(allocator, framed);
    defer allocator.free(masked);

    const dir = "tests/snapshots/e2e";
    const file = try std.fmt.allocPrint(allocator, "{s}/{s}.txt", .{ dir, name });
    defer allocator.free(file);

    if (config.update_snapshots) {
        root.createDirPath(io, dir) catch |err| {
            std.log.err("failed to create snapshot dir {s}: {any}", .{ dir, err });
            return InteractiveError.InvalidScript;
        };
        root.writeFile(io, .{ .sub_path = file, .data = masked }) catch |err| {
            std.log.err("failed to write snapshot {s}: {any}", .{ file, err });
            return InteractiveError.InvalidScript;
        };
        std.debug.print("\u{2705} Updated frame snapshot: {s}\n", .{file});
        return;
    }

    const expected = root.readFileAlloc(io, file, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("\n\u{250c}\u{2500} FRAME SNAPSHOT MISSING: {s}\n", .{file});
            std.debug.print("\u{2502} Re-run with .update_snapshots = true to create. Rendered screen:\n", .{});
            printBoxedScreen(masked);
            return InteractiveError.ExpectationNotMet;
        },
        else => return InteractiveError.InputSendFailed,
    };
    defer allocator.free(expected);

    if (!std.mem.eql(u8, expected, masked)) {
        std.debug.print("\n\u{250c}\u{2500} FRAME SNAPSHOT MISMATCH: {s}\n", .{file});
        std.debug.print("\u{2502} expected (golden) vs actual (rendered screen):\n", .{});
        printScreenDiff(expected, masked);
        std.debug.print("\u{2502} Re-run with .update_snapshots = true to update.\n", .{});
        return InteractiveError.ExpectationNotMet;
    }
}

/// getAllText emits width*height chars with no row breaks; split it back into
/// `height` rows of `width`, trimming each row's trailing spaces.
fn reflowToRows(allocator: std.mem.Allocator, flat: []const u8, width: u16, height: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    // getAllText UTF-8-encodes wide chars, so byte length can exceed width*height;
    // fall back to a plain copy if the geometry doesn't line up (ASCII TUIs, the
    // common case here, always line up).
    if (flat.len != @as(usize, width) * @as(usize, height)) {
        return allocator.dupe(u8, flat);
    }
    var row: u16 = 0;
    while (row < height) : (row += 1) {
        if (row > 0) try out.append(allocator, '\n');
        const start = @as(usize, row) * width;
        var end = start + width;
        while (end > start and flat[end - 1] == ' ') end -= 1;
        try out.appendSlice(allocator, flat[start..end]);
    }
    return out.toOwnedSlice(allocator);
}

/// Print a readable rendered-screen diagnostic for a failed contains/row frame
/// assertion — the whole screen boxed, so the reader sees exactly what WAS
/// drawn versus what was asserted.
fn printFrameMismatch(allocator: std.mem.Allocator, screen: *vterm.VTerm, assertion: FrameAssertion) void {
    std.debug.print("\n\u{250c}\u{2500} FRAME ASSERTION FAILED \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n", .{});
    switch (assertion) {
        .contains => |t| std.debug.print("\u{2502} expectFrameContains(\"{s}\") — text is not visible on screen\n", .{t}),
        .row => |r| {
            const line = screen.getLine(allocator, r.index) catch "";
            defer if (line.len > 0) allocator.free(line);
            std.debug.print("\u{2502} expectRow({d}, \"{s}\")\n", .{ r.index, r.expected });
            std.debug.print("\u{2502}   actual row {d}: \"{s}\"\n", .{ r.index, line });
        },
        .snapshot => {},
    }
    std.debug.print("\u{2502} rendered screen ({d}x{d}):\n", .{ screen.width, screen.height });
    const flat = screen.getAllText(allocator) catch return;
    defer allocator.free(flat);
    const framed = reflowToRows(allocator, flat, screen.width, screen.height) catch return;
    defer allocator.free(framed);
    printBoxedScreen(framed);
    std.debug.print("\u{2514}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n", .{});
}

/// Loud, one-shot diagnostic for a script that did not run to completion. Prints
/// which step broke, why, the vterm geometry + rendered screen (so a frame or
/// prompt mismatch is legible), and the tail of the raw byte stream. Without
/// this, a step failure only surfaces as a nonzero child exit code — the harness
/// kills the still-blocked child, and the test's `expect(exit_code == 0)` fails
/// with no clue what the child actually drew. This is the keeper: a failed frame
/// (or expect) step must fail loudly with the screen, not cryptically.
fn dumpScriptFailure(
    allocator: std.mem.Allocator,
    outcome: ScriptOutcome,
    screen: ?*vterm.VTerm,
    output: []const u8,
) void {
    if (outcome.failure == .none) return;
    std.debug.print("\n\u{250c}\u{2500} INTERACTIVE SCRIPT FAILED at step {d} \u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n", .{outcome.failed_step + 1});
    switch (outcome.failure) {
        .none => {},
        .expect => |e| std.debug.print("\u{2502} step kind: expect(\"{s}\") — text never appeared in the stream\n", .{e}),
        .send => |s| std.debug.print("\u{2502} step kind: send(\"{s}\") — write to child failed\n", .{s}),
        .total_timeout => std.debug.print("\u{2502} step kind: total interaction timeout exceeded\n", .{}),
        .frame => |a| switch (a) {
            .contains => |t| std.debug.print("\u{2502} step kind: expectFrameContains(\"{s}\") — not visible on the rendered screen\n", .{t}),
            .row => |r| std.debug.print("\u{2502} step kind: expectRow({d}, \"{s}\")\n", .{ r.index, r.expected }),
            .snapshot => |n| std.debug.print("\u{2502} step kind: expectFrame(\"{s}\")\n", .{n}),
        },
    }
    if (screen) |term| {
        std.debug.print("\u{2502} rendered screen ({d}x{d}):\n", .{ term.width, term.height });
        if (term.getAllText(allocator)) |flat| {
            defer allocator.free(flat);
            if (reflowToRows(allocator, flat, term.width, term.height)) |framed| {
                defer allocator.free(framed);
                printBoxedScreen(framed);
            } else |_| {}
        } else |_| {}
    } else {
        std.debug.print("\u{2502} (no VTerm allocated — cannot render screen)\n", .{});
    }
    // Tail of the raw stream, escaped, so control/cursor bytes are legible.
    const tail_len = @min(output.len, 512);
    const tail = output[output.len - tail_len ..];
    std.debug.print("\u{2502} raw byte-stream tail ({d} of {d} bytes), escaped:\n\u{2502}   ", .{ tail_len, output.len });
    for (tail) |b| {
        if (b == '\n') {
            std.debug.print("\\n", .{});
        } else if (b == '\r') {
            std.debug.print("\\r", .{});
        } else if (b == 0x1b) {
            std.debug.print("\\e", .{});
        } else if (b >= 0x20 and b < 0x7f) {
            std.debug.print("{c}", .{b});
        } else {
            std.debug.print("\\x{x:0>2}", .{b});
        }
    }
    std.debug.print("\n\u{2514}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n", .{});
}

fn printBoxedScreen(screen_text: []const u8) void {
    var lines = std.mem.splitScalar(u8, screen_text, '\n');
    while (lines.next()) |line| {
        std.debug.print("\u{2502} \u{2502}{s}\n", .{line});
    }
}

fn printScreenDiff(expected: []const u8, actual: []const u8) void {
    var exp_lines = std.mem.splitScalar(u8, expected, '\n');
    var act_lines = std.mem.splitScalar(u8, actual, '\n');
    var row: usize = 0;
    while (true) {
        const e = exp_lines.next();
        const a = act_lines.next();
        if (e == null and a == null) break;
        const el = e orelse "";
        const al = a orelse "";
        if (!std.mem.eql(u8, el, al)) {
            std.debug.print("\u{2502} row {d}:\n", .{row});
            std.debug.print("\u{2502}   -\"{s}\"\n", .{el});
            std.debug.print("\u{2502}   +\"{s}\"\n", .{al});
        }
        row += 1;
    }
}

/// Send input to the process.
fn sendInput(
    allocator: std.mem.Allocator,
    session: anytype,
    input: []const u8,
    input_type: InputType,
    input_buffer: *std.ArrayList(u8),
    transcript_buffer: ?*std.ArrayList(u8),
    echo_input: bool,
) InteractiveError!bool {
    session.writeAll(input) catch return false;
    try input_buffer.appendSlice(allocator, input);

    // Add newline for text input (unless it's a control sequence or already ends with one).
    if (input_type == .text and !std.mem.endsWith(u8, input, "\n")) {
        session.writeAll("\n") catch return false;
        try input_buffer.append(allocator, '\n');
    }

    if (transcript_buffer) |tb| {
        const display_input = if (input_type == .hidden) "[HIDDEN]" else input;
        try transcriptPrint(tb, allocator, "Sent: \"{s}\"\n", .{display_input});
    }

    if (echo_input and input_type != .hidden) {
        std.log.info("Sent input: {s}", .{input});
    }

    return true;
}

fn writeFd(fd: posix.fd_t, bytes: []const u8) error{WriteFailed}!void {
    var index: usize = 0;
    while (index < bytes.len) {
        const rc = posix.system.write(fd, bytes[index..].ptr, bytes.len - index);
        switch (posix.errno(rc)) {
            .SUCCESS => index += @intCast(rc),
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

/// Drain any remaining output until idle or timeout.
/// Drain a PTY master until the child's side hangs up — POLLHUP (or EIO/EOF
/// on read) once the last slave fd closes on child exit — or until
/// `deadline_ms` passes. Returns true if the hangup was seen (the child is
/// gone), false on deadline. Data is always read before honoring HUP, so a
/// final burst that arrives together with the hangup is not lost.
fn drainUntilHup(
    allocator: std.mem.Allocator,
    io: std.Io,
    fd: posix.fd_t,
    output_buffer: *std.ArrayList(u8),
    deadline_ms: u64,
) InteractiveError!bool {
    const start_time = nowMs(io);
    var temp_buffer: [4096]u8 = undefined;

    while (@as(u64, @intCast(nowMs(io) - start_time)) < deadline_ms) {
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, 50) catch return false;
        if (ready == 0) continue; // poll window elapsed; check deadline and re-poll

        if (fds[0].revents & posix.POLL.IN != 0) {
            const bytes_read = posix.read(fd, &temp_buffer) catch |err| switch (err) {
                // A closed PTY slave surfaces as EIO on the master.
                error.InputOutput => return true,
                else => return false,
            };
            if (bytes_read == 0) return true;
            try output_buffer.appendSlice(allocator, temp_buffer[0..bytes_read]);
            continue;
        }
        if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) return true;
    }
    return false;
}

fn drainOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    fd: posix.fd_t,
    output_buffer: *std.ArrayList(u8),
    timeout_ms: u32,
) InteractiveError!void {
    const start_time = nowMs(io);
    var temp_buffer: [4096]u8 = undefined;

    // Prefer the deterministic signal: read until the write end hangs up
    // (POLLHUP / read()==0 / EIO on a PTY master) — the child has closed its
    // output, so nothing more is coming. The idle window (~150ms of silence) is
    // only a fallback for a child that goes quiet without closing, so we still
    // return instead of spinning to the full timeout. Breaking on "buffer
    // already has data" would drop output arriving after the last matched
    // `expect`, so we never do that.
    const idle_settle_ms: i64 = 150;
    var last_activity = start_time;
    while (true) {
        const elapsed = nowMs(io) - start_time;
        if (elapsed > timeout_ms) break;

        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, 50) catch break;
        if (ready == 0) {
            if (nowMs(io) - last_activity >= idle_settle_ms) break; // gone quiet
            continue; // poll window elapsed; re-check deadline and poll again
        }

        if (fds[0].revents & posix.POLL.IN != 0) {
            const bytes_read = posix.read(fd, &temp_buffer) catch |err| switch (err) {
                error.InputOutput => break, // PTY slave closed ⇒ EOF
                error.WouldBlock => continue,
                else => break,
            };
            if (bytes_read == 0) break; // clean EOF: write end closed
            last_activity = nowMs(io);
            try output_buffer.appendSlice(allocator, temp_buffer[0..bytes_read]);
            continue;
        }
        // Hangup/error with no more readable data: the child is gone.
        if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) break;
    }
}

/// Helper function to test both TTY and non-TTY modes
pub fn runInteractiveDualMode(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: []const []const u8,
    script: InteractiveScript,
    config: InteractiveConfig,
) InteractiveError!struct {
    tty_result: InteractiveResult,
    pipe_result: InteractiveResult,
} {
    var tty_config = config;
    tty_config.allocate_pty = true;
    const tty_result = try runInteractive(allocator, io, command, script, tty_config);

    var pipe_config = config;
    pipe_config.allocate_pty = false;
    const pipe_result = try runInteractive(allocator, io, command, script, pipe_config);

    return .{
        .tty_result = tty_result,
        .pipe_result = pipe_result,
    };
}

// ============================================================================
// TESTS
// ============================================================================

test "PtyManager initialization and cleanup" {
    // PtyManager is POSIX-only (PTY + termios + ioctl). The comptime block keeps
    // its body from being analyzed on Windows, where those symbols don't exist.
    if (builtin.os.tag != .windows) {
        const allocator = std.testing.allocator;

        var pty = PtyManager.init(allocator) catch |err| {
            if (err == error.FileNotFound or err == error.AccessDenied) {
                return;
            }
            return err;
        };
        defer pty.deinit();

        try std.testing.expect(pty.master_fd != -1);
        try std.testing.expect(pty.slave_fd != -1);
        try std.testing.expect(pty.slave_name != null);
    }
}

test "PtyManager terminal settings" {
    if (builtin.os.tag != .windows) {
        const allocator = std.testing.allocator;

        // No controlling terminal → PTY operations may not work; skip.
        if (!isFdTty(std.Io.File.stdin().handle)) return;

        var pty = PtyManager.init(allocator) catch {
            return;
        };
        defer pty.deinit();

        try std.testing.expect(pty.master_fd != -1);
        try std.testing.expect(pty.slave_fd != -1);
    }
}

test "PtyManager window size control" {
    if (builtin.os.tag != .windows) {
        const allocator = std.testing.allocator;

        var pty = PtyManager.init(allocator) catch |err| {
            if (err == error.FileNotFound or err == error.AccessDenied) {
                return;
            }
            return err;
        };
        defer pty.deinit();

        pty.setWindowSize(24, 80) catch {
            return;
        };

        const size = pty.getWindowSize() catch {
            return;
        };

        try std.testing.expect(size.row == 24);
        try std.testing.expect(size.col == 80);
    }
}

test "runInteractive drives a command over pipes" {
    if (builtin.os.tag == .windows) return;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var script = InteractiveScript.init(allocator);
    defer script.deinit();

    // `cat` echoes stdin to stdout; send a line and expect it back.
    _ = script.send("zcli-e2e-ping").expect("zcli-e2e-ping");

    var result = runInteractive(allocator, io, &.{"cat"}, script, .{
        .allocate_pty = false,
        .total_timeout_ms = 5000,
    }) catch |err| {
        // Spawning may be restricted in some sandboxes; don't fail the suite.
        std.log.warn("runInteractive skipped: {any}", .{err});
        return;
    };
    defer result.deinit();

    try std.testing.expect(std.mem.indexOf(u8, result.output, "zcli-e2e-ping") != null);
}

test "expectFrame* builders record frame assertions" {
    const allocator = std.testing.allocator;

    var script = InteractiveScript.init(allocator);
    defer script.deinit();

    _ = script
        .expectFrameContains("hello")
        .expectRow(3, "world")
        .expectFrame("golden");

    try std.testing.expect(script.steps.items.len == 3);
    try std.testing.expectEqualStrings("hello", script.steps.items[0].frame.?.contains);
    try std.testing.expect(script.steps.items[1].frame.?.row.index == 3);
    try std.testing.expectEqualStrings("world", script.steps.items[1].frame.?.row.expected);
    try std.testing.expectEqualStrings("golden", script.steps.items[2].frame.?.snapshot);
}

test "frameSatisfied matches rendered cells, not the raw stream" {
    const allocator = std.testing.allocator;
    var term = try vterm.VTerm.init(allocator, 20, 5);
    defer term.deinit();

    // Draw "OK" at row 2 via absolute cursor positioning — the literal "OK"
    // arrives after a CUP sequence, exactly the case where a stream grep would
    // pass on unrelated bytes but the SCREEN must actually show it in place.
    term.write("\x1b[3;1HOK done");

    try std.testing.expect(frameSatisfied(allocator, &term, .{ .contains = "OK done" }));
    try std.testing.expect(frameSatisfied(allocator, &term, .{ .row = .{ .index = 2, .expected = "OK done" } }));
    // Wrong row must NOT satisfy — the strength a stream substring lacks.
    try std.testing.expect(!frameSatisfied(allocator, &term, .{ .row = .{ .index = 0, .expected = "OK done" } }));
    try std.testing.expect(!frameSatisfied(allocator, &term, .{ .contains = "absent" }));
}

test "reflowToRows splits a flat screen into trimmed rows" {
    const allocator = std.testing.allocator;
    // 4 wide, 2 tall: "ab  " + "c   " → "ab\nc" (trailing spaces trimmed).
    const flat = "ab  c   ";
    const out = try reflowToRows(allocator, flat, 4, 2);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ab\nc", out);
}

test "runInteractive frame assertions catch a mispositioned row over a PTY" {
    if (builtin.os.tag == .windows) return;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // A tiny script that homes the cursor and paints "READY" on row 3 (1-based)
    // using absolute positioning, then holds so the frame is stable. `sh` reads
    // one line of stdin before exiting so the harness can end the session.
    const program =
        "printf '\\033[2J\\033[3;1HREADY\\033[10;1H'; read _dummy";

    var script = InteractiveScript.init(allocator);
    defer script.deinit();
    _ = script
        // Rendered-frame assertions: "READY" is visible, and specifically on
        // row 2 (0-based) where it was positioned — not merely in the stream.
        .expectFrameContains("READY").withTimeout(4000)
        .expectRow(2, "READY").withTimeout(4000)
        // End the session (the `read` returns, `sh` exits).
        .send("go");

    var result = runInteractive(allocator, io, &.{ "/bin/sh", "-c", program }, script, .{
        .allocate_pty = true,
        .terminal_size = .{ .rows = 24, .cols = 40 },
        .total_timeout_ms = 8000,
    }) catch |err| switch (err) {
        // PTY allocation can be denied in sandboxes; skip loudly, unless
        // ZCLI_REQUIRE_INTERACTIVE=1 demands this tier actually run.
        error.PtyAllocationFailed => {
            if (interactiveRequired()) {
                std.debug.print("ZCLI_REQUIRE_INTERACTIVE=1 but a PTY could not be allocated: {any}\n", .{err});
                return err;
            }
            std.debug.print("runInteractive unavailable: {any}\n", .{err});
            return;
        },
        else => return err,
    };
    defer result.deinit();

    try std.testing.expect(result.steps_executed >= 2);
}

test "InteractiveScript builder API" {
    const allocator = std.testing.allocator;

    var script = InteractiveScript.init(allocator);
    defer script.deinit();

    _ = script
        .expect("Enter name:")
        .send("John Doe")
        .expectExact("Hello, John Doe!")
        .sendControl(.enter)
        .sendSignal(.SIGINT)
        .sendRaw("\x1b[A") // Up arrow
        .sendHidden("password")
        .delay(100)
        .withTimeout(5000)
        .optional();

    try std.testing.expect(script.steps.items.len == 8);

    const expect_step = script.steps.items[0];
    try std.testing.expectEqualStrings("Enter name:", expect_step.expect.?);

    const send_step = script.steps.items[1];
    try std.testing.expectEqualStrings("John Doe", send_step.send.?);
    try std.testing.expect(send_step.input_type == .text);

    const exact_step = script.steps.items[2];
    try std.testing.expect(exact_step.exact_match);

    const control_step = script.steps.items[3];
    try std.testing.expect(control_step.input_type == .control);
    try std.testing.expect(control_step.control.? == .enter);

    const signal_step = script.steps.items[4];
    try std.testing.expect(signal_step.signal.? == .SIGINT);

    const raw_step = script.steps.items[5];
    try std.testing.expect(raw_step.input_type == .raw);

    const hidden_step = script.steps.items[6];
    try std.testing.expect(hidden_step.input_type == .hidden);

    const delay_step = script.steps.items[7];
    try std.testing.expect(delay_step.expect == null);
    try std.testing.expect(delay_step.send == null);

    const last_step = script.steps.items[script.steps.items.len - 1];
    try std.testing.expect(last_step.timeout_ms == 5000);
    try std.testing.expect(last_step.optional);
}

test "ControlSequence byte conversion" {
    try std.testing.expectEqualStrings("\n", ControlSequence.enter.toBytes());
    try std.testing.expectEqualStrings("\x03", ControlSequence.ctrl_c.toBytes());
    try std.testing.expectEqualStrings("\x04", ControlSequence.ctrl_d.toBytes());
    try std.testing.expectEqualStrings("\x1b", ControlSequence.escape.toBytes());
    try std.testing.expectEqualStrings("\t", ControlSequence.tab.toBytes());
    try std.testing.expectEqualStrings("\x1b[A", ControlSequence.up_arrow.toBytes());
    try std.testing.expectEqualStrings("\x1b[B", ControlSequence.down_arrow.toBytes());
    try std.testing.expectEqualStrings("\x1b[D", ControlSequence.left_arrow.toBytes());
    try std.testing.expectEqualStrings("\x1b[C", ControlSequence.right_arrow.toBytes());
}

test "Signal enum values" {
    try std.testing.expect(Signal.SIGINT.toInt() == 2);
    try std.testing.expect(Signal.SIGTERM.toInt() == 15);
    try std.testing.expect(Signal.SIGTSTP.toInt() == 20);
    try std.testing.expect(Signal.SIGCONT.toInt() == 18);
    try std.testing.expect(Signal.SIGWINCH.toInt() == 28);
    try std.testing.expect(Signal.SIGHUP.toInt() == 1);
}

test "InteractiveConfig defaults" {
    const config = InteractiveConfig{};

    try std.testing.expect(config.allocate_pty == true);
    try std.testing.expect(config.total_timeout_ms == 30000);
    try std.testing.expect(config.buffer_size == 64 * 1024);
    try std.testing.expect(config.echo_input == false);
    try std.testing.expect(config.save_transcript == false);
    try std.testing.expect(config.terminal_mode == .cooked);
    try std.testing.expect(config.disable_echo == false);
    try std.testing.expect(config.forward_signals == false);
    try std.testing.expect(config.frame_settle_ms == 150);
}

test "snapshotSettled: child exit beats an unmet idle window" {
    // A dead child cannot repaint, so the frame is final regardless of how short
    // the idle has been — this is the deterministic settle that makes an
    // end-of-render golden immune to CI-load timing.
    try std.testing.expect(snapshotSettled(true, 0, 150));
    try std.testing.expect(snapshotSettled(true, 0, 1_000_000));
}

test "snapshotSettled: alive child settles only after the full idle window" {
    // Below the window: still painting, do not capture (the mid-frame flake).
    try std.testing.expect(!snapshotSettled(false, 0, 150));
    try std.testing.expect(!snapshotSettled(false, 149, 150));
    // At/above the window: stable, safe to capture.
    try std.testing.expect(snapshotSettled(false, 150, 150));
    try std.testing.expect(snapshotSettled(false, 300, 150));
    // A widened window keeps waiting where the old fixed ~150ms would have fired.
    try std.testing.expect(!snapshotSettled(false, 200, 500));
}

test "withSettle overrides the per-step snapshot idle window" {
    const allocator = std.testing.allocator;
    var script = InteractiveScript.init(allocator);
    defer script.deinit();

    _ = script.expectFrame("slow_screen").withSettle(750);

    const step = script.steps.items[script.steps.items.len - 1];
    try std.testing.expect(step.frame != null);
    try std.testing.expectEqual(@as(?u32, 750), step.settle_ms);

    // A snapshot step with no override falls back to the config default.
    _ = script.expectFrame("normal_screen");
    const defaulted = script.steps.items[script.steps.items.len - 1];
    try std.testing.expectEqual(@as(?u32, null), defaulted.settle_ms);
}

test "InteractiveResult structure" {
    const allocator = std.testing.allocator;

    var result = InteractiveResult{
        .exit_code = 0,
        .output = try allocator.dupe(u8, "test output"),
        .input = try allocator.dupe(u8, "test input"),
        .success = true,
        .steps_executed = 5,
        .duration_ms = 1500,
        .transcript = try allocator.dupe(u8, "test transcript"),
        .allocator = allocator,
    };
    defer result.deinit();

    try std.testing.expect(result.exit_code == 0);
    try std.testing.expect(result.success);
    try std.testing.expect(result.steps_executed == 5);
    try std.testing.expect(result.duration_ms == 1500);
    try std.testing.expectEqualStrings("test output", result.output);
    try std.testing.expectEqualStrings("test input", result.input);
    try std.testing.expectEqualStrings("test transcript", result.transcript.?);
}

test "createPtyFallback functionality" {
    if (builtin.os.tag != .windows) {
        const allocator = std.testing.allocator;

        const result = createPtyFallback(allocator) catch |err| {
            std.log.err("PTY fallback creation failed: {any}", .{err});
            return;
        };
        defer {
            closeFd(result.master);
            closeFd(result.slave);
            allocator.free(result.slave_name);
        }

        try std.testing.expect(result.master != -1);
        try std.testing.expect(result.slave != -1);
        try std.testing.expectEqualStrings("/dev/pts/fake", result.slave_name);
    }
}

test "error handling in InteractiveError" {
    const test_error: InteractiveError = InteractiveError.ProcessStartFailed;
    try std.testing.expect(test_error == InteractiveError.ProcessStartFailed);

    const terminal_error: InteractiveError = InteractiveError.TerminalSettingsError;
    try std.testing.expect(terminal_error == InteractiveError.TerminalSettingsError);

    const window_error: InteractiveError = InteractiveError.WindowSizeError;
    try std.testing.expect(window_error == InteractiveError.WindowSizeError);
}

test "signal forwarding functionality" {
    if (builtin.os.tag != .windows) {
        const allocator = std.testing.allocator;

        var pty_manager = PtyManager.init(allocator) catch {
            return;
        };
        defer pty_manager.deinit();

        // Invalid PID is rejected.
        const invalid_result = pty_manager.forwardSignal(-1, .SIGTERM);
        try std.testing.expectError(error.InvalidPid, invalid_result);

        try pty_manager.setupSignalForwarding(1); // init always exists

        try pty_manager.setWindowSize(25, 80);
        pty_manager.synchronizeWindowSize(1) catch |err| {
            std.log.info("Window size sync failed as expected in test: {any}", .{err});
        };
    }
}

test "terminal capability detection" {
    if (builtin.os.tag != .windows) {
        const allocator = std.testing.allocator;

        var pty_manager = PtyManager.init(allocator) catch {
            var null_pty = PtyManager{
                .allocator = allocator,
                .master_fd = -1,
            };
            const caps = null_pty.detectTerminalCapabilities();
            try std.testing.expect(!caps.has_pty);
            try std.testing.expect(!caps.supports_window_size);
            try std.testing.expect(!caps.supports_termios);
            return;
        };
        defer pty_manager.deinit();

        const caps = pty_manager.detectTerminalCapabilities();
        try std.testing.expect(caps.has_pty);

        _ = caps.supports_window_size;
        _ = caps.supports_termios;
        _ = caps.supports_raw_mode;
        _ = caps.supports_echo_control;
        _ = caps.supports_line_buffering;

        pty_manager.autoAdjustWindowSize() catch |err| {
            std.log.info("Auto window size adjustment failed as expected in test: {any}", .{err});
        };
    }
}
