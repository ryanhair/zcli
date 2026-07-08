//! Progress — spinners and progress bars for CLI applications.
//!
//! This file is the type: `@import("progress")` returns a struct bundling the
//! environment progress indicators need — writer, `io`, and theme — and the two
//! constructors (`spinner`, `progressBar`) are methods on it. Standalone
//! library: no zcli dependency required. Animations auto-disable when output is
//! not a TTY.
//!
//! ```zig
//! const Progress = @import("progress");
//!
//! const p: Progress = .{ .writer = writer, .io = io };
//!
//! // Spinner for indeterminate progress — animates itself until finished
//! var spinner = p.spinner(.{});
//! spinner.start("Loading...");
//! // ... do work ...
//! spinner.succeed("Done!");
//!
//! // Progress bar for known totals
//! var bar = p.progressBar(.{ .total = 100 });
//! for (0..100) |i| bar.update(i + 1, null);
//! bar.finish();
//! ```
//!
//! In a zcli command, `context.progress()` returns an instance pre-wired to the
//! command's stdout, `io`, and theme.

writer: *std.Io.Writer,
/// The framework's `std.Io` — powers the spinner's background animation task
/// and the progress bar's timing.
io: std.Io,
/// Theme + terminal capabilities for styling (spinner via the theme's
/// `progress.spinner` token, bar via `progress.bar_fill`/`bar_empty`, result
/// symbols via the palette's success/err/warning/info roles); zcli commands
/// carry this in `context.theme` (`context.progress()` wires it up).
theme: ThemeContext = .fallback,

const std = @import("std");
const theme_pkg = @import("theme");
const terminal = @import("terminal");

const Progress = @This();

/// Theming re-export, so standalone users can build a custom style context
/// without depending on the `theme` package directly (it's transitive here).
pub const ThemeContext = theme_pkg.ThemeContext;

/// Start a spinner for indeterminate progress, wired to this instance's
/// writer, `io`, and theme.
pub fn spinner(self: Progress, config: SpinnerConfig) Spinner {
    return Spinner.init(self.writer, self.io, self.theme, config);
}

/// Start a progress bar for a known total, wired to this instance's writer,
/// `io`, and theme.
pub fn progressBar(self: Progress, config: ProgressBarConfig) ProgressBar {
    return ProgressBar.init(self.writer, self.io, self.theme, config);
}

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

/// Result symbols for spinner completion. Adapts to terminal unicode support.
pub const ResultSymbol = struct {
    pub fn success(unicode: bool) []const u8 {
        return terminal.symbols.success(unicode);
    }
    pub fn failure(unicode: bool) []const u8 {
        return terminal.symbols.failure(unicode);
    }
    pub fn warning(unicode: bool) []const u8 {
        return terminal.symbols.warning(unicode);
    }
    pub fn info(unicode: bool) []const u8 {
        return terminal.symbols.info(unicode);
    }
};

/// Spinner configuration
pub const SpinnerConfig = struct {
    style: SpinnerStyle = .dots,
    /// Whether to hide cursor during animation
    hide_cursor: bool = true,
    /// Prefix before spinner
    prefix: []const u8 = "",
    /// Suffix after message
    suffix: []const u8 = "",
    /// Whether terminal supports unicode
    unicode: bool = true,
};

/// Spinner for indeterminate progress
pub const Spinner = struct {
    writer: *std.Io.Writer,
    io: std.Io,
    theme: ThemeContext,
    config: SpinnerConfig,
    message: []const u8,
    frame_index: usize,
    is_tty: bool,
    active: bool,
    /// Guards message/frame_index/active and all writes while animating.
    mutex: std.Io.Mutex,
    animation: ?std.Io.Future(void),

    /// Initialize a new spinner. Prefer `Progress.spinner`, which supplies the
    /// writer, `io`, and theme from the bundle.
    pub fn init(writer: *std.Io.Writer, io: std.Io, theme: ThemeContext, config: SpinnerConfig) Spinner {
        return .{
            .writer = writer,
            .io = io,
            .theme = theme,
            .config = config,
            .message = "",
            .frame_index = 0,
            .is_tty = detectTTY(),
            .active = false,
            .mutex = .init,
            .animation = null,
        };
    }

    /// Start the spinner with a message. On a TTY this spawns a background
    /// task that animates the spinner until a finish method is called, so
    /// the spinner must not be moved or copied after `start`. If the `Io`
    /// implementation cannot run the animation concurrently, the spinner
    /// degrades to a static frame.
    pub fn start(self: *Spinner, message: []const u8) void {
        self.message = message;
        self.active = true;
        self.frame_index = 0;

        if (self.is_tty and self.config.hide_cursor) {
            self.writeAll("\x1b[?25l"); // Hide cursor
        }

        self.render();

        if (self.is_tty) {
            self.animation = self.io.concurrent(animate, .{self}) catch null;
        }
    }

    /// Update the spinner message
    pub fn setText(self: *Spinner, message: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.message = message;
        if (self.active) self.render();
    }

    /// Background task: advance and redraw the spinner every frame
    /// interval until a finish method cancels it.
    fn animate(self: *Spinner) void {
        const interval_ns = self.config.style.interval() * std.time.ns_per_ms;
        while (true) {
            self.io.sleep(.{ .nanoseconds = interval_ns }, .awake) catch return;
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (!self.active) return;
            self.frame_index = (self.frame_index + 1) % self.config.style.frames().len;
            self.render();
        }
    }

    /// Deactivate and reap the animation task. After this returns the
    /// caller has exclusive use of the writer.
    fn stopAnimation(self: *Spinner) void {
        self.mutex.lockUncancelable(self.io);
        self.active = false;
        self.mutex.unlock(self.io);
        if (self.animation) |*future| {
            future.cancel(self.io);
            self.animation = null;
        }
    }

    /// Stop the spinner with a success message
    pub fn succeed(self: *Spinner, message: []const u8) void {
        self.finishWithRole(ResultSymbol.success(self.config.unicode), .success, message);
    }

    /// Stop the spinner with a failure message
    pub fn fail(self: *Spinner, message: []const u8) void {
        self.finishWithRole(ResultSymbol.failure(self.config.unicode), .err, message);
    }

    /// Stop the spinner with a warning message
    pub fn warn(self: *Spinner, message: []const u8) void {
        self.finishWithRole(ResultSymbol.warning(self.config.unicode), .warning, message);
    }

    /// Stop the spinner with an info message
    pub fn info(self: *Spinner, message: []const u8) void {
        self.finishWithRole(ResultSymbol.info(self.config.unicode), .info, message);
    }

    /// Stop the spinner without a result symbol
    pub fn stop(self: *Spinner) void {
        self.stopAndClear();
    }

    /// Stop and persist the current message
    pub fn stopAndPersist(self: *Spinner, symbol: []const u8, message: []const u8) void {
        self.finishPlain(symbol, message);
    }

    fn writeAll(self: *Spinner, data: []const u8) void {
        self.writer.writeAll(data) catch {};
    }

    /// Write the style's escape sequence; returns true if one was written
    fn writeStyle(self: *Spinner, style: theme_pkg.Style) bool {
        return style.writeSequence(self.writer, self.theme.capability()) catch false;
    }

    fn finishWithRole(self: *Spinner, symbol: []const u8, role: theme_pkg.SemanticRole, message: []const u8) void {
        self.stopAnimation();

        if (self.is_tty) {
            self.writeAll("\r\x1b[K"); // Clear line
            const wrote_color = self.writeStyle(self.theme.resolve(role));
            self.writeAll(symbol);
            if (wrote_color) {
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
        flushWriter(self.writer);
    }

    fn finishPlain(self: *Spinner, symbol: []const u8, message: []const u8) void {
        self.stopAnimation();

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
        flushWriter(self.writer);
    }

    fn stopAndClear(self: *Spinner) void {
        self.stopAnimation();

        if (self.is_tty) {
            self.writeAll("\r\x1b[K"); // Clear line
            if (self.config.hide_cursor) {
                self.writeAll("\x1b[?25h"); // Show cursor
            }
            flushWriter(self.writer);
        }
    }

    fn render(self: *Spinner) void {
        if (!self.is_tty) {
            // Non-TTY: no animation; print a plain status line per message
            self.writeAll(self.config.prefix);
            self.writeAll("- ");
            self.writeAll(self.message);
            self.writeAll(self.config.suffix);
            self.writeAll("\n");
            flushWriter(self.writer);
            return;
        }

        const style_frames = self.config.style.frames();
        const frame = style_frames[self.frame_index];

        // Move to beginning of line and clear
        self.writeAll("\r\x1b[K");

        // Write prefix
        self.writeAll(self.config.prefix);

        // Write themed spinner frame
        const spinner_style = self.theme.resolveRef(self.theme.progressTokens().spinner);
        const wrote_color = self.writeStyle(spinner_style);
        self.writeAll(frame);
        if (wrote_color) {
            self.writeAll("\x1b[0m");
        }

        // Write message
        self.writeAll(" ");
        self.writeAll(self.message);
        self.writeAll(self.config.suffix);
        flushWriter(self.writer);
    }
};

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
pub const ProgressBar = struct {
    writer: *std.Io.Writer,
    io: std.Io,
    theme: ThemeContext,
    config: ProgressBarConfig,
    current: usize,
    start_time: i64,
    is_tty: bool,
    message: []const u8,

    fn nowMs(self: *ProgressBar) i64 {
        return @intCast(@divTrunc(std.Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds, std.time.ns_per_ms));
    }

    /// Initialize a new progress bar. Prefer `Progress.progressBar`, which
    /// supplies the writer, `io`, and theme from the bundle.
    pub fn init(writer: *std.Io.Writer, io: std.Io, theme: ThemeContext, config: ProgressBarConfig) ProgressBar {
        return .{
            .writer = writer,
            .io = io,
            .theme = theme,
            .config = config,
            .current = 0,
            .start_time = @intCast(@divTrunc(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds, std.time.ns_per_ms)),
            .is_tty = detectTTY(),
            .message = "",
        };
    }

    /// Update progress with optional message
    pub fn update(self: *ProgressBar, current: usize, message: ?[]const u8) void {
        self.current = @min(current, self.config.total);
        if (message) |m| {
            self.message = m;
        }
        self.render();
    }

    /// Increment progress by amount
    pub fn increment(self: *ProgressBar, amount: usize) void {
        self.update(self.current + amount, null);
    }

    /// Set the message without updating progress
    pub fn setMessage(self: *ProgressBar, message: []const u8) void {
        self.message = message;
        self.render();
    }

    /// Mark progress as complete
    pub fn finish(self: *ProgressBar) void {
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
        flushWriter(self.writer);
    }

    /// Finish with a custom message
    pub fn finishWithMessage(self: *ProgressBar, message: []const u8) void {
        self.message = message;
        self.finish();
    }

    fn writeAll(self: *ProgressBar, data: []const u8) void {
        self.writer.writeAll(data) catch {};
    }

    fn render(self: *ProgressBar) void {
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

        // Bar (styled only on a TTY, like the spinner — piped output stays plain)
        const ctx = self.theme;
        const tokens = ctx.progressTokens();
        self.writeAll("[");
        if (filled > 0) {
            const wrote = self.is_tty and (ctx.resolveRef(tokens.bar_fill).writeSequence(self.writer, ctx.capability()) catch false);
            for (0..filled) |_| {
                self.writeAll(self.config.complete_char);
            }
            if (wrote) self.writeAll("\x1b[0m");
        }
        if (empty > 0) {
            const wrote = self.is_tty and (ctx.resolveRef(tokens.bar_empty).writeSequence(self.writer, ctx.capability()) catch false);
            for (0..empty) |_| {
                self.writeAll(self.config.incomplete_char);
            }
            if (wrote) self.writeAll("\x1b[0m");
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
            const elapsed = self.nowMs() - self.start_time;
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
            const elapsed_ms = self.nowMs() - self.start_time;
            const elapsed_secs: u64 = @intCast(@divTrunc(elapsed_ms, 1000));

            var elapsed_buf: [16]u8 = undefined;
            const elapsed_str = formatDuration(elapsed_secs, &elapsed_buf);
            self.writeAll(" [");
            self.writeAll(elapsed_str);
            self.writeAll("]");
        }

        // Rate
        if (self.config.show_rate and self.current > 0) {
            const elapsed_ms = self.nowMs() - self.start_time;
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
        flushWriter(self.writer);
    }
};

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
    // Use direct handle check without io
    return terminal.isStdoutTty();
}

/// Flush a writer if it supports flushing. Works with both pointer and value writer types.
fn flushWriter(writer: anytype) void {
    const W = @TypeOf(writer);
    const T = if (@typeInfo(W) == .pointer) @typeInfo(W).pointer.child else W;
    if (@hasDecl(T, "flush")) {
        writer.flush() catch {};
    }
}

// ============================================================================
// Tests
// ============================================================================

/// A `Progress` bundle over a fixed test writer.
fn testProgress(writer: *std.Io.Writer, theme: ThemeContext) Progress {
    return .{ .writer = writer, .io = std.testing.io, .theme = theme };
}

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

test "the bundle wires writer, io, and theme into a spinner" {
    var output: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    const p: Progress = .{ .writer = &writer, .io = std.testing.io };
    const s = p.spinner(.{});
    try std.testing.expect(!s.active);
    try std.testing.expectEqual(@as(usize, 0), s.frame_index);
    try std.testing.expectEqual(&writer, s.writer);
}

test "spinner initialization" {
    var output: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    const s = Spinner.init(&writer, std.testing.io, .fallback, .{});
    try std.testing.expect(!s.active);
    try std.testing.expectEqual(@as(usize, 0), s.frame_index);
}

test "spinner animates and finishes on a TTY" {
    var output: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var s = testProgress(&writer, .fallback).spinner(.{});
    s.is_tty = true; // force the TTY path; the fixed writer captures ANSI output

    s.start("working");
    s.setText("still working");
    s.succeed("done");

    try std.testing.expect(!s.active);
    try std.testing.expect(s.animation == null);
    const written = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "working") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "done") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[?25h") != null); // cursor restored
}

test "spinner prints status lines when not a TTY" {
    var output: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var s = testProgress(&writer, .fallback).spinner(.{});
    s.is_tty = false;

    s.start("connecting");
    s.setText("uploading");
    s.succeed("synced");

    const written = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "- connecting\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "- uploading\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, " synced\n") != null);
}

test "spinner result symbols style through the palette roles" {
    var output: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    const custom = theme_pkg.Theme{
        .palette = .{ .success = .{ .foreground = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } } },
    };
    var s = testProgress(&writer, .{
        .theme = &custom,
        .caps = .{ .capability = .true_color, .is_tty = true, .color_enabled = true },
    }).spinner(.{});
    s.is_tty = true;

    s.start("working");
    s.succeed("done");

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "38;2;1;2;3") != null);
}

test "spinner frame styles through the progress.spinner token" {
    var output: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    const custom = theme_pkg.Theme{
        .progress = .{ .spinner = .{ .style = .{ .foreground = .{ .rgb = .{ .r = 9, .g = 8, .b = 7 } } } } },
    };
    var s = testProgress(&writer, .{
        .theme = &custom,
        .caps = .{ .capability = .true_color, .is_tty = true, .color_enabled = true },
    }).spinner(.{});
    s.is_tty = true;

    s.start("working");
    s.stop();

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "38;2;9;8;7") != null);
}

test "spinner renders no color sequences under no_color" {
    var output: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var s = testProgress(&writer, .{
        .caps = .{ .capability = .no_color, .is_tty = true, .color_enabled = false },
    }).spinner(.{});
    s.is_tty = true;

    s.start("working");
    s.succeed("done");

    const written = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "done") != null);
    // Cursor-control escapes remain; SGR color/attribute sequences must not
    try std.testing.expect(std.mem.indexOf(u8, written, "38;2") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[0m") == null);
}

test "progress bar initialization" {
    var output: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    const bar = testProgress(&writer, .fallback).progressBar(.{
        .total = 100,
        .width = 20,
    });
    try std.testing.expectEqual(@as(usize, 0), bar.current);
    try std.testing.expectEqual(@as(usize, 100), bar.config.total);
}

test "progress bar update" {
    var output: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var bar = testProgress(&writer, .fallback).progressBar(.{
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
    var writer: std.Io.Writer = .fixed(&output);

    var bar = testProgress(&writer, .fallback).progressBar(.{
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

test "progress bar styles fill and empty through the theme tokens on a TTY" {
    var output: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    const custom = theme_pkg.Theme{
        .progress = .{
            .bar_fill = .{ .style = .{ .foreground = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } } },
            .bar_empty = .{ .style = .{ .foreground = .{ .rgb = .{ .r = 4, .g = 5, .b = 6 } } } },
        },
    };
    var bar = testProgress(&writer, .{
        .theme = &custom,
        .caps = .{ .capability = .true_color, .is_tty = true, .color_enabled = true },
    }).progressBar(.{
        .total = 10,
        .width = 10,
        .show_eta = false,
    });
    bar.is_tty = true;

    bar.update(5, null);

    const written = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "38;2;1;2;3") != null); // fill
    try std.testing.expect(std.mem.indexOf(u8, written, "38;2;4;5;6") != null); // empty
}

test "progress bar stays plain when piped (non-TTY)" {
    var output: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var bar = testProgress(&writer, .fallback).progressBar(.{
        .total = 10,
        .width = 10,
        .show_eta = false,
    });
    bar.is_tty = false;

    bar.update(5, null);

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[") == null);
}

test "progress bar does not exceed total" {
    var output: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var bar = testProgress(&writer, .fallback).progressBar(.{
        .total = 100,
        .show_eta = false,
    });
    bar.is_tty = false;

    bar.update(150, null);
    try std.testing.expect(bar.current == 100);
}

test {
    std.testing.refAllDecls(@This());
}
