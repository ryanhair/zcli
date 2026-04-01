//! zprogress - Progress indicators for CLI applications
//!
//! Provides spinners for indeterminate progress and progress bars for
//! known totals. Auto-disables animations when output is not a TTY.
//!
//! Basic usage:
//! ```zig
//! const zprogress = @import("zprogress");
//!
//! // Spinner for indeterminate progress
//! var spinner = zprogress.spinner(.{});
//! spinner.start("Loading...");
//! // ... do work ...
//! spinner.succeed("Done!");
//!
//! // Progress bar for known totals
//! var bar = zprogress.progressBar(.{ .total = 100 });
//! for (0..100) |i| {
//!     bar.update(i + 1, null);
//! }
//! bar.finish();
//! ```

const std = @import("std");
const ztheme = @import("ztheme");

/// Spinner animation styles
pub const SpinnerStyle = enum {
    dots,
    dots2,
    dots3,
    line,
    arrow,
    bounce,
    clock,
    moon,
    simple,

    pub fn frames(self: SpinnerStyle) []const []const u8 {
        return switch (self) {
            .dots => &.{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
            .dots2 => &.{ "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" },
            .dots3 => &.{ "⠁", "⠂", "⠄", "⡀", "⢀", "⠠", "⠐", "⠈" },
            .line => &.{ "-", "\\", "|", "/" },
            .arrow => &.{ "←", "↖", "↑", "↗", "→", "↘", "↓", "↙" },
            .bounce => &.{ "⠁", "⠂", "⠄", "⠂" },
            .clock => &.{ "🕐", "🕑", "🕒", "🕓", "🕔", "🕕", "🕖", "🕗", "🕘", "🕙", "🕚", "🕛" },
            .moon => &.{ "🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘" },
            .simple => &.{ "|", "/", "-", "\\" },
        };
    }

    pub fn interval(self: SpinnerStyle) u64 {
        return switch (self) {
            .dots, .dots2, .dots3 => 80,
            .line, .simple => 100,
            .arrow => 100,
            .bounce => 120,
            .clock, .moon => 150,
        };
    }
};

/// Result symbols for spinner completion
pub const ResultSymbol = struct {
    pub const success = "✔";
    pub const failure = "✖";
    pub const warning = "⚠";
    pub const info = "ℹ";
};

/// Spinner configuration
pub const SpinnerConfig = struct {
    style: SpinnerStyle = .dots,
    /// Color for the spinner frame
    color: ztheme.Color = .cyan,
    /// Whether to hide cursor during animation
    hide_cursor: bool = true,
    /// Prefix before spinner
    prefix: []const u8 = "",
    /// Suffix after message
    suffix: []const u8 = "",
};

/// Spinner for indeterminate progress
pub fn Spinner(comptime WriterType: type) type {
    return struct {
        const Self = @This();

        writer: WriterType,
        config: SpinnerConfig,
        message: []const u8,
        frame_index: usize,
        is_tty: bool,
        active: bool,
        last_update: i64,

        /// Initialize a new spinner
        pub fn init(writer: WriterType, config: SpinnerConfig) Self {
            return .{
                .writer = writer,
                .config = config,
                .message = "",
                .frame_index = 0,
                .is_tty = detectTTY(),
                .active = false,
                .last_update = 0,
            };
        }

        /// Start the spinner with an optional message
        pub fn start(self: *Self, message: []const u8) void {
            self.message = message;
            self.active = true;
            self.frame_index = 0;
            self.last_update = std.time.milliTimestamp();

            if (self.is_tty and self.config.hide_cursor) {
                self.writeAll("\x1b[?25l"); // Hide cursor
            }

            self.render();
        }

        /// Update the spinner message
        pub fn setText(self: *Self, message: []const u8) void {
            self.message = message;
        }

        /// Advance the spinner animation (call this in a loop or timer)
        pub fn tick(self: *Self) void {
            if (!self.active) return;

            const now = std.time.milliTimestamp();
            const interval_val: i64 = @intCast(self.config.style.interval());

            if (now - self.last_update >= interval_val) {
                const style_frames = self.config.style.frames();
                self.frame_index = (self.frame_index + 1) % style_frames.len;
                self.last_update = now;
                self.render();
            }
        }

        /// Stop the spinner with a success message
        pub fn succeed(self: *Self, message: []const u8) void {
            self.finishWithColor(ResultSymbol.success, .green, message);
        }

        /// Stop the spinner with a failure message
        pub fn fail(self: *Self, message: []const u8) void {
            self.finishWithColor(ResultSymbol.failure, .red, message);
        }

        /// Stop the spinner with a warning message
        pub fn warn(self: *Self, message: []const u8) void {
            self.finishWithColor(ResultSymbol.warning, .yellow, message);
        }

        /// Stop the spinner with an info message
        pub fn info(self: *Self, message: []const u8) void {
            self.finishWithColor(ResultSymbol.info, .blue, message);
        }

        /// Stop the spinner without a result symbol
        pub fn stop(self: *Self) void {
            self.stopAndClear();
        }

        /// Stop and persist the current message
        pub fn stopAndPersist(self: *Self, symbol: []const u8, message: []const u8) void {
            self.finishPlain(symbol, message);
        }

        fn writeAll(self: *Self, data: []const u8) void {
            self.writer.writeAll(data) catch {};
        }

        fn colorSequence(color: ztheme.Color) []const u8 {
            const style = ztheme.Style{ .foreground = color };
            return style.sequenceForCapability(.ansi_16);
        }

        fn finishWithColor(self: *Self, symbol: []const u8, color: ztheme.Color, message: []const u8) void {
            self.active = false;

            if (self.is_tty) {
                self.writeAll("\r\x1b[K"); // Clear line
                const seq = colorSequence(color);
                if (seq.len > 0) {
                    self.writeAll(seq);
                }
                self.writeAll(symbol);
                if (seq.len > 0) {
                    self.writeAll("\x1b[0m");
                }
                self.writeAll(" ");
                self.writeAll(message);
                self.writeAll("\n");

                if (self.config.hide_cursor) {
                    self.writeAll("\x1b[?25h"); // Show cursor
                }
            } else {
                self.writeAll(symbol);
                self.writeAll(" ");
                self.writeAll(message);
                self.writeAll("\n");
            }
        }

        fn finishPlain(self: *Self, symbol: []const u8, message: []const u8) void {
            self.active = false;

            if (self.is_tty) {
                self.writeAll("\r\x1b[K");
                self.writeAll(symbol);
                self.writeAll(" ");
                self.writeAll(message);
                self.writeAll("\n");

                if (self.config.hide_cursor) {
                    self.writeAll("\x1b[?25h");
                }
            } else {
                self.writeAll(symbol);
                self.writeAll(" ");
                self.writeAll(message);
                self.writeAll("\n");
            }
        }

        fn stopAndClear(self: *Self) void {
            self.active = false;

            if (self.is_tty) {
                self.writeAll("\r\x1b[K"); // Clear line
                if (self.config.hide_cursor) {
                    self.writeAll("\x1b[?25h"); // Show cursor
                }
            }
        }

        fn render(self: *Self) void {
            if (!self.is_tty) {
                // Non-TTY: don't animate, just show static message on first render
                if (self.frame_index == 0) {
                    self.writeAll(self.config.prefix);
                    self.writeAll("- ");
                    self.writeAll(self.message);
                    self.writeAll(self.config.suffix);
                    self.writeAll("\n");
                }
                return;
            }

            const style_frames = self.config.style.frames();
            const frame = style_frames[self.frame_index];

            // Move to beginning of line and clear
            self.writeAll("\r\x1b[K");

            // Write prefix
            self.writeAll(self.config.prefix);

            // Write colored spinner frame
            const color_seq = colorSequence(self.config.color);
            if (color_seq.len > 0) {
                self.writeAll(color_seq);
            }
            self.writeAll(frame);
            if (color_seq.len > 0) {
                self.writeAll("\x1b[0m");
            }

            // Write message
            self.writeAll(" ");
            self.writeAll(self.message);
            self.writeAll(self.config.suffix);
        }
    };
}

/// Progress bar configuration
pub const ProgressBarConfig = struct {
    /// Total value for 100% completion
    total: usize = 100,
    /// Width of the progress bar in characters
    width: usize = 40,
    /// Character for completed portion
    complete_char: []const u8 = "█",
    /// Character for incomplete portion
    incomplete_char: []const u8 = "░",
    /// Whether to show percentage
    show_percentage: bool = true,
    /// Whether to show ETA
    show_eta: bool = true,
    /// Whether to show elapsed time
    show_elapsed: bool = false,
    /// Whether to show rate (items/sec)
    show_rate: bool = false,
    /// Whether to clear the bar on finish
    clear_on_finish: bool = false,
    /// Format string for the bar: {bar} {percent} {current}/{total} {eta}
    prefix: []const u8 = "",
    suffix: []const u8 = "",
};

/// Progress bar for determinate progress
pub fn ProgressBar(comptime WriterType: type) type {
    return struct {
        const Self = @This();

        writer: WriterType,
        config: ProgressBarConfig,
        current: usize,
        start_time: i64,
        is_tty: bool,
        message: []const u8,

        /// Initialize a new progress bar
        pub fn init(writer: WriterType, config: ProgressBarConfig) Self {
            return .{
                .writer = writer,
                .config = config,
                .current = 0,
                .start_time = std.time.milliTimestamp(),
                .is_tty = detectTTY(),
                .message = "",
            };
        }

        /// Update progress with optional message
        pub fn update(self: *Self, current: usize, message: ?[]const u8) void {
            self.current = @min(current, self.config.total);
            if (message) |m| {
                self.message = m;
            }
            self.render();
        }

        /// Increment progress by amount
        pub fn increment(self: *Self, amount: usize) void {
            self.update(self.current + amount, null);
        }

        /// Set the message without updating progress
        pub fn setMessage(self: *Self, message: []const u8) void {
            self.message = message;
            self.render();
        }

        /// Mark progress as complete
        pub fn finish(self: *Self) void {
            self.current = self.config.total;
            self.render();

            if (self.is_tty) {
                if (self.config.clear_on_finish) {
                    self.writeAll("\r\x1b[K");
                } else {
                    self.writeAll("\n");
                }
            } else {
                self.writeAll("\n");
            }
        }

        /// Finish with a custom message
        pub fn finishWithMessage(self: *Self, message: []const u8) void {
            self.message = message;
            self.finish();
        }

        fn writeAll(self: *Self, data: []const u8) void {
            self.writer.writeAll(data) catch {};
        }

        fn render(self: *Self) void {
            const percent = if (self.config.total > 0)
                (self.current * 100) / self.config.total
            else
                0;

            const filled = if (self.config.total > 0)
                (self.current * self.config.width) / self.config.total
            else
                0;
            const empty = self.config.width - filled;

            if (self.is_tty) {
                self.writeAll("\r\x1b[K");
            }

            // Prefix
            if (self.config.prefix.len > 0) {
                self.writeAll(self.config.prefix);
            }

            // Message
            if (self.message.len > 0) {
                self.writeAll(self.message);
                self.writeAll(" ");
            }

            // Bar
            self.writeAll("[");
            for (0..filled) |_| {
                self.writeAll(self.config.complete_char);
            }
            for (0..empty) |_| {
                self.writeAll(self.config.incomplete_char);
            }
            self.writeAll("]");

            // Percentage
            if (self.config.show_percentage) {
                var buf: [8]u8 = undefined;
                const percent_str = std.fmt.bufPrint(&buf, " {d:>3}%", .{percent}) catch "???%";
                self.writeAll(percent_str);
            }

            // Current/Total
            var count_buf: [32]u8 = undefined;
            const count_str = std.fmt.bufPrint(&count_buf, " {d}/{d}", .{ self.current, self.config.total }) catch "";
            self.writeAll(count_str);

            // ETA
            if (self.config.show_eta and self.current > 0) {
                const elapsed = std.time.milliTimestamp() - self.start_time;
                if (elapsed > 0 and self.current < self.config.total) {
                    const remaining = self.config.total - self.current;
                    const ms_per_item: i64 = @divTrunc(elapsed, @as(i64, @intCast(self.current)));
                    const eta_ms: i64 = ms_per_item * @as(i64, @intCast(remaining));
                    const eta_secs: u64 = @intCast(@divTrunc(eta_ms, 1000));

                    var eta_buf: [16]u8 = undefined;
                    const eta_str = formatDuration(eta_secs, &eta_buf);
                    self.writeAll(" ETA: ");
                    self.writeAll(eta_str);
                }
            }

            // Elapsed
            if (self.config.show_elapsed) {
                const elapsed_ms = std.time.milliTimestamp() - self.start_time;
                const elapsed_secs: u64 = @intCast(@divTrunc(elapsed_ms, 1000));

                var elapsed_buf: [16]u8 = undefined;
                const elapsed_str = formatDuration(elapsed_secs, &elapsed_buf);
                self.writeAll(" [");
                self.writeAll(elapsed_str);
                self.writeAll("]");
            }

            // Rate
            if (self.config.show_rate and self.current > 0) {
                const elapsed_ms = std.time.milliTimestamp() - self.start_time;
                if (elapsed_ms > 0) {
                    const rate: f64 = @as(f64, @floatFromInt(self.current)) / (@as(f64, @floatFromInt(elapsed_ms)) / 1000.0);

                    var rate_buf: [16]u8 = undefined;
                    const rate_str = std.fmt.bufPrint(&rate_buf, " {d:.1}/s", .{rate}) catch "";
                    self.writeAll(rate_str);
                }
            }

            // Suffix
            if (self.config.suffix.len > 0) {
                self.writeAll(self.config.suffix);
            }

            // For non-TTY, add newline since we can't overwrite
            if (!self.is_tty) {
                self.writeAll("\n");
            }
        }
    };
}

/// Format duration in seconds to human readable string
fn formatDuration(secs: u64, buf: []u8) []const u8 {
    if (secs < 60) {
        return std.fmt.bufPrint(buf, "{d}s", .{secs}) catch "?s";
    } else if (secs < 3600) {
        const mins = secs / 60;
        const remaining_secs = secs % 60;
        return std.fmt.bufPrint(buf, "{d}m{d}s", .{ mins, remaining_secs }) catch "?m?s";
    } else {
        const hours = secs / 3600;
        const mins = (secs % 3600) / 60;
        return std.fmt.bufPrint(buf, "{d}h{d}m", .{ hours, mins }) catch "?h?m";
    }
}

/// Detect if stdout is a TTY
fn detectTTY() bool {
    return std.fs.File.stdout().isTty();
}

// Thread-local buffer for stdout writer
threadlocal var stdout_buffer: [0]u8 = .{};
threadlocal var stdout_writer_storage: std.fs.File.Writer = undefined;
threadlocal var stdout_initialized: bool = false;

fn getStdoutWriter() *std.Io.Writer {
    if (!stdout_initialized) {
        stdout_writer_storage = std.fs.File.stdout().writer(&stdout_buffer);
        stdout_initialized = true;
    }
    return &stdout_writer_storage.interface;
}

/// Create a spinner with the default writer (stdout)
pub fn spinner(config: SpinnerConfig) Spinner(*std.Io.Writer) {
    return Spinner(*std.Io.Writer).init(getStdoutWriter(), config);
}

/// Create a progress bar with the default writer (stdout)
pub fn progressBar(config: ProgressBarConfig) ProgressBar(*std.Io.Writer) {
    return ProgressBar(*std.Io.Writer).init(getStdoutWriter(), config);
}

// ============================================================================
// Tests
// ============================================================================

test "spinner style frames" {
    const dots_frames = SpinnerStyle.dots.frames();
    try std.testing.expect(dots_frames.len > 0);
    try std.testing.expectEqualStrings("⠋", dots_frames[0]);

    const simple_frames = SpinnerStyle.simple.frames();
    try std.testing.expect(simple_frames.len == 4);
}

test "spinner style intervals" {
    try std.testing.expect(SpinnerStyle.dots.interval() > 0);
    try std.testing.expect(SpinnerStyle.clock.interval() > SpinnerStyle.dots.interval());
}

test "format duration" {
    var buf: [16]u8 = undefined;

    try std.testing.expectEqualStrings("5s", formatDuration(5, &buf));
    try std.testing.expectEqualStrings("1m30s", formatDuration(90, &buf));
    try std.testing.expectEqualStrings("1h30m", formatDuration(5400, &buf));
}

test "spinner initialization" {
    var output: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&output);

    const s = Spinner(@TypeOf(fbs.writer())).init(fbs.writer(), .{});
    try std.testing.expect(!s.active);
    try std.testing.expectEqual(@as(usize, 0), s.frame_index);
}

test "progress bar initialization" {
    var output: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&output);

    const bar = ProgressBar(@TypeOf(fbs.writer())).init(fbs.writer(), .{
        .total = 100,
        .width = 20,
    });
    try std.testing.expectEqual(@as(usize, 0), bar.current);
    try std.testing.expectEqual(@as(usize, 100), bar.config.total);
}

test "progress bar update" {
    var output: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&output);

    var bar = ProgressBar(@TypeOf(fbs.writer())).init(fbs.writer(), .{
        .total = 100,
        .width = 10,
        .show_eta = false,
    });

    // Mock non-TTY behavior for testing
    bar.is_tty = false;

    bar.update(50, null);
    try std.testing.expect(bar.current == 50);
}

test "progress bar increment" {
    var output: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&output);

    var bar = ProgressBar(@TypeOf(fbs.writer())).init(fbs.writer(), .{
        .total = 100,
        .width = 10,
        .show_eta = false,
    });
    bar.is_tty = false;

    bar.increment(10);
    try std.testing.expect(bar.current == 10);

    bar.increment(5);
    try std.testing.expect(bar.current == 15);
}

test "progress bar does not exceed total" {
    var output: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&output);

    var bar = ProgressBar(@TypeOf(fbs.writer())).init(fbs.writer(), .{
        .total = 100,
        .show_eta = false,
    });
    bar.is_tty = false;

    bar.update(150, null);
    try std.testing.expect(bar.current == 100);
}
