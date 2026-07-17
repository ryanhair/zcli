//! Progress — spinners, bars, and stacked multi-bars for CLI applications.
//!
//! This file is the type: `@import("progress")` returns a struct bundling the
//! environment progress indicators need — writer, `io`, allocator, and theme —
//! and the three constructors (`spinner`, `progressBar`, `multiBar`) are
//! methods on it. Standalone library: no zcli dependency required.
//!
//! Rendering runs on the ui engine (ADR-0013): each indicator owns a small
//! `ui.App` live region, so diffing, resize re-layout, cursor bookkeeping, and
//! flush discipline are the engine's problem — this package only describes what
//! a frame looks like. Finishing an indicator emits its result as a static line
//! that flows into scrollback (or, for bars, persists the final frame). When
//! output is not a TTY, indicators degrade to plain lines: spinners print one
//! status line per message, bars are silent until a single finish line, and
//! animations never spawn.
//!
//! ```zig
//! const Progress = @import("progress");
//!
//! const p: Progress = .{ .writer = writer, .io = io, .allocator = allocator };
//!
//! // Spinner for indeterminate progress — animates itself until finished.
//! // While it animates it owns the stream from a background task: do not write
//! // to that stream yourself (use `setMessage`, or finish first).
//! var spinner = try p.spinner(.{});
//! spinner.start("Loading...");
//! spinner.succeed("Done!");
//!
//! // Progress bar for known totals
//! var bar = try p.progressBar(.{ .total = 100 });
//! for (0..100) |i| bar.update(i + 1, null);
//! bar.finish();
//!
//! // Stacked bars for parallel work
//! var mb = try p.multiBar(.{});
//! defer mb.deinit();
//! const dl = try mb.add("api.tar.gz", 1024);
//! mb.set(dl, 512);
//! mb.finish();
//! ```
//!
//! In a zcli command, `context.progress()` returns an instance pre-wired to the
//! command's stderr, `io`, arena allocator, and theme. Progress goes to stderr
//! by convention so it survives stdout redirection (`myapp | tee`) while keeping
//! piped stdout clean. Interactivity keys on the `writer`'s own target when its
//! handle is recoverable (a standalone user writing to stdout gets it right),
//! falling back to stderr otherwise.

writer: *std.Io.Writer,
/// The framework's `std.Io` — powers each indicator's `ui.App` (animation
/// task, timing, terminal polling).
io: std.Io,
/// Backs each indicator's `ui.App` (surfaces, retained static tail).
allocator: std.mem.Allocator,
/// Theme + terminal capabilities for styling (spinner via the theme's
/// `progress.spinner` token, bars via `progress.bar_fill`/`bar_empty`, result
/// symbols via the palette's success/err/warning/info roles); zcli commands
/// carry this in `context.theme` (`context.progress()` wires it up).
theme: ThemeContext = .fallback,

const std = @import("std");
const theme_pkg = @import("theme");
const terminal = @import("terminal");
const ui = @import("ui");

const Progress = @This();

/// The terminal-restore panic handler. Every indicator hides the cursor via a
/// hybrid `ui.App`, so a panic mid-animation must restore the terminal — the App
/// enforces this at compile time. Install it in your root source file:
/// `pub const panic = Progress.panic;` (zcli apps use `zcli.ui.panic`).
pub const panic = ui.panic;

/// Theming re-export, so standalone users can build a custom style context
/// without depending on the `theme` package directly (it's transitive here).
pub const ThemeContext = theme_pkg.ThemeContext;

/// Start a spinner for indeterminate progress, wired to this instance's
/// writer, `io`, allocator, and theme.
pub fn spinner(self: Progress, config: SpinnerConfig) !Spinner {
    return Spinner.init(self.allocator, self.writer, self.io, self.theme, config);
}

/// Start a progress bar for a known total, wired to this instance's writer,
/// `io`, allocator, and theme.
pub fn progressBar(self: Progress, config: ProgressBarConfig) !ProgressBar {
    return ProgressBar.init(self.allocator, self.writer, self.io, self.theme, config);
}

/// Start a stacked multi-bar for parallel work, wired to this instance's
/// writer, `io`, allocator, and theme.
pub fn multiBar(self: Progress, config: MultiBarConfig) !MultiBar {
    return MultiBar.init(self.allocator, self.writer, self.io, self.theme, config);
}

/// Recover the OS handle behind `writer` when it is a `std.Io.File.Writer`
/// interface (the common case: stdout/stderr streams). Discriminates by vtable
/// so it never `@fieldParentPtr`s a foreign writer (e.g. `Allocating`, `fixed`).
fn writerHandle(writer: *std.Io.Writer) ?std.Io.File.Handle {
    if (writer.vtable.drain != std.Io.File.Writer.drain) return null;
    const file_writer: *const std.Io.File.Writer = @fieldParentPtr("interface", writer);
    return file_writer.file.handle;
}

/// Whether animation should run: key interactivity to the writer's own target
/// when we can recover its handle, falling back to stderr when we can't.
fn writerInteractive(writer: *std.Io.Writer) bool {
    if (writerHandle(writer)) |handle| return terminal.isTty(handle);
    return terminal.isStderrTty();
}

/// The handle the App polls for terminal state (size, TTY probes): the writer's
/// own handle when determinable, else stderr — matching `writerInteractive`.
fn writerOutHandle(writer: *std.Io.Writer) std.Io.File.Handle {
    return writerHandle(writer) orelse std.Io.File.stderr().handle;
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

/// Spinner configuration
pub const SpinnerConfig = struct {
    style: SpinnerStyle = .dots,
    /// Prefix before spinner
    prefix: []const u8 = "",
    /// Suffix after message
    suffix: []const u8 = "",
    /// Whether terminal supports unicode
    unicode: bool = true,
};

/// Spinner for indeterminate progress.
///
/// Writer-exclusivity requirement: while a spinner is animating it drives the
/// underlying stream (the command's stderr) from a background task. That stream
/// is buffered and not thread-safe, so the main thread must not write to it
/// concurrently — a `context.stderr().print(...)` racing the animation
/// interleaves bytes mid-escape-sequence and garbles the terminal. To surface a
/// message while a spinner runs, use `setMessage`, or finish the spinner
/// (`succeed`/`fail`/`stop`/…) before writing to the stream yourself.
pub const Spinner = struct {
    io: std.Io,
    theme: ThemeContext,
    config: SpinnerConfig,
    app: ui.App,
    /// Spinner-owned copy of the caller's message. The background `animate`
    /// task reads this at tick time, so we never retain the caller's slice —
    /// a caller passing a stack/`bufPrint` buffer and reusing it after
    /// `start`/`setMessage` returns would otherwise race the bg thread on
    /// freed/mutated memory. Long messages truncate to the buffer.
    message_buf: [256]u8 = undefined,
    message_len: usize = 0,
    tick: usize = 0,
    active: bool = false,
    closed: bool = false,
    /// Guards message/tick/active and the App while animating.
    mutex: std.Io.Mutex = .init,
    animation: ?std.Io.Future(void) = null,

    /// Initialize a new spinner writing to `writer`. Prefer `Progress.spinner`,
    /// which supplies the allocator, writer, `io`, and theme from the bundle.
    pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer, io: std.Io, theme: ThemeContext, config: SpinnerConfig) !Spinner {
        return .{
            .io = io,
            .theme = theme,
            .config = config,
            .app = try ui.App.init(allocator, writer, .{
                .capability = theme.capability(),
                .unicode = config.unicode,
                .interactive = writerInteractive(writer),
                .out_handle = writerOutHandle(writer),
            }),
        };
    }

    /// Release the spinner without a result (safe after any finish method).
    /// Stops the animation task first so an error-unwind `defer s.deinit()`
    /// that runs while the spinner is still animating cannot tear down the App
    /// out from under the background `animate` task (use-after-free). Mirrors
    /// `stop()` minus the clear; both calls are safe after a prior finish.
    pub fn deinit(self: *Spinner) void {
        self.stopAnimation();
        self.close();
    }

    /// Copy `msg` into spinner-owned storage (truncating past the buffer) so
    /// the animation task never reads the caller's slice. Callers holding the
    /// mutex (or before the animate task spawns) may invoke this safely.
    fn storeMessage(self: *Spinner, msg: []const u8) void {
        var n = @min(msg.len, self.message_buf.len);
        if (n < msg.len) {
            // A hard byte-count truncation can land mid-codepoint. Back off
            // over UTF-8 continuation bytes (0b10xxxxxx) until `n` sits on a
            // codepoint boundary, so ui.text never receives a truncated
            // multibyte sequence.
            while (n > 0 and (msg[n] & 0xC0) == 0x80) : (n -= 1) {}
        }
        @memcpy(self.message_buf[0..n], msg[0..n]);
        self.message_len = n;
    }

    /// The current spinner message, backed by spinner-owned storage.
    fn messageSlice(self: *const Spinner) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    /// Start the spinner with a message. On a TTY this spawns a background
    /// task that animates the spinner until a finish method is called, so
    /// the spinner must not be moved or copied after `start`. If the `Io`
    /// implementation cannot run the animation concurrently, the spinner
    /// degrades to a static frame.
    pub fn start(self: *Spinner, message: []const u8) void {
        // Guard double-start: a second start would overwrite `animation`,
        // leaking the first future and spawning a second animate task racing
        // the first. Also refuse to start after a finish (App is torn down).
        if (self.closed or self.active) return;
        self.storeMessage(message);
        self.active = true;
        self.tick = 0;
        self.render();
        if (self.app.options.interactive) {
            self.animation = self.io.concurrent(animate, .{self}) catch null;
        }
    }

    /// Update the spinner message
    pub fn setMessage(self: *Spinner, message: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.storeMessage(message);
        if (self.active) self.render();
    }

    /// The completion glyph for `role`, resolved through the theme's glyph
    /// tokens at the terminal's detected unicode capability.
    fn resultGlyph(self: *Spinner, glyph: theme_pkg.Glyph) []const u8 {
        return glyph.pick(self.config.unicode);
    }

    /// Stop the spinner with a success message
    pub fn succeed(self: *Spinner, message: []const u8) void {
        self.finishRole(.success, self.resultGlyph(self.theme.glyphTokens().success), message);
    }

    /// Stop the spinner with a failure message
    pub fn fail(self: *Spinner, message: []const u8) void {
        self.finishRole(.err, self.resultGlyph(self.theme.glyphTokens().failure), message);
    }

    /// Stop the spinner with a warning message
    pub fn warn(self: *Spinner, message: []const u8) void {
        self.finishRole(.warning, self.resultGlyph(self.theme.glyphTokens().warning), message);
    }

    /// Stop the spinner with an info message
    pub fn info(self: *Spinner, message: []const u8) void {
        self.finishRole(.info, self.resultGlyph(self.theme.glyphTokens().info), message);
    }

    /// Stop and persist `symbol` + the message as a plain static line.
    pub fn persist(self: *Spinner, symbol: []const u8, message: []const u8) void {
        if (self.closed) return;
        self.stopAnimation();
        self.app.clear() catch {};
        self.app.emit("{s} {s}", .{ symbol, message }) catch {};
        self.close();
    }

    /// Stop the spinner leaving no output behind.
    pub fn stop(self: *Spinner) void {
        if (self.closed) return;
        self.stopAnimation();
        self.app.clear() catch {};
        self.close();
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
            self.tick +%= 1;
            self.render();
        }
    }

    /// Deactivate and reap the animation task. After this returns the
    /// caller has exclusive use of the App.
    fn stopAnimation(self: *Spinner) void {
        self.mutex.lockUncancelable(self.io);
        self.active = false;
        self.mutex.unlock(self.io);
        if (self.animation) |*future| {
            future.cancel(self.io);
            self.animation = null;
        }
    }

    fn finishRole(self: *Spinner, role: theme_pkg.SemanticRole, symbol: []const u8, message: []const u8) void {
        if (self.closed) return;
        self.stopAnimation();
        self.app.clear() catch {};
        if (self.app.options.interactive) {
            // The result line is static output; the role style is baked into
            // the emitted text (retained escapes are zero-width for reflow).
            var buf: [64]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            const wrote = self.theme.resolve(role).writeSequence(&w, self.theme.capability()) catch false;
            self.app.emit("{s}{s}{s} {s}", .{
                w.buffered(),
                symbol,
                if (wrote) "\x1b[0m" else "",
                message,
            }) catch {};
        } else {
            self.app.emit("{s} {s}", .{ symbol, message }) catch {};
        }
        self.close();
    }

    fn render(self: *Spinner) void {
        if (!self.app.options.interactive) {
            // Piped: one plain status line per message.
            self.app.emit("{s}- {s}{s}", .{ self.config.prefix, self.messageSlice(), self.config.suffix }) catch {};
            return;
        }
        self.renderFrame() catch {};
    }

    fn renderFrame(self: *Spinner) !void {
        const a = self.app.arena();
        const tail = try std.fmt.allocPrint(a, " {s}{s}", .{ self.messageSlice(), self.config.suffix });
        try self.app.frame(try ui.row(a, .{}, &.{
            ui.textOpts(.{ .wrap = .clip }, self.config.prefix),
            ui.widgets.spinner(.{
                .theme = self.theme.theme,
                .frames = self.config.style.frames(),
            }, self.tick),
            ui.textOpts(.{ .wrap = .clip }, tail),
        }));
    }

    fn close(self: *Spinner) void {
        if (self.closed) return;
        self.closed = true;
        self.app.deinit();
    }
};

/// Progress bar configuration
pub const ProgressBarConfig = struct {
    /// Total value for 100% completion
    total: usize = 100,
    /// Width of the bar itself in characters (excluding brackets and stats)
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
    /// Whether to clear the bar on finish (otherwise the final frame persists)
    clear_on_finish: bool = false,
    prefix: []const u8 = "",
    suffix: []const u8 = "",
    /// Whether terminal supports unicode
    unicode: bool = true,
};

/// Progress bar for determinate progress. Caller-driven: each `update`
/// paints one frame. Piped output stays silent until one finish line.
pub const ProgressBar = struct {
    io: std.Io,
    theme: ThemeContext,
    config: ProgressBarConfig,
    app: ui.App,
    current: usize = 0,
    start_time: i64,
    message: []const u8 = "",
    closed: bool = false,

    /// Initialize a new progress bar writing to `writer`. Prefer
    /// `Progress.progressBar`, which supplies the allocator, writer, `io`, and
    /// theme from the bundle.
    pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer, io: std.Io, theme: ThemeContext, config: ProgressBarConfig) !ProgressBar {
        return .{
            .io = io,
            .theme = theme,
            .config = config,
            .app = try ui.App.init(allocator, writer, .{
                .capability = theme.capability(),
                .unicode = config.unicode,
                .interactive = writerInteractive(writer),
                .out_handle = writerOutHandle(writer),
            }),
            .start_time = nowMsIo(io),
        };
    }

    /// Release the bar without finishing (safe after `finish`).
    pub fn deinit(self: *ProgressBar) void {
        self.close();
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

    /// Mark progress as complete. The final frame persists on screen
    /// (unless `clear_on_finish`); piped output gets one summary line.
    pub fn finish(self: *ProgressBar) void {
        self.current = self.config.total;
        if (!self.app.options.interactive) {
            self.app.emit("{s}{s}{s}{d}/{d} (100%){s}", .{
                self.config.prefix,
                self.message,
                if (self.message.len > 0) " " else "",
                self.config.total,
                self.config.total,
                self.config.suffix,
            }) catch {};
        } else if (self.config.clear_on_finish) {
            self.app.clear() catch {};
        } else {
            self.render();
        }
        self.close();
    }

    /// Finish with a custom message
    pub fn finishWithMessage(self: *ProgressBar, message: []const u8) void {
        self.message = message;
        self.finish();
    }

    fn nowMs(self: *ProgressBar) i64 {
        return nowMsIo(self.io);
    }

    fn render(self: *ProgressBar) void {
        if (!self.app.options.interactive) return;
        self.renderFrame() catch {};
    }

    fn renderFrame(self: *ProgressBar) !void {
        const a = self.app.arena();
        const fraction: f32 = if (self.config.total > 0)
            @as(f32, @floatFromInt(self.current)) / @as(f32, @floatFromInt(self.config.total))
        else
            0;

        const left = try std.fmt.allocPrint(a, "{s}{s}{s}", .{
            self.config.prefix,
            self.message,
            if (self.message.len > 0) " " else "",
        });

        // Stats after the bar: " 50% 5/10 ETA: 3s [1m2s] 1.5/s"
        var stats_buf: [160]u8 = undefined;
        var sw: std.Io.Writer = .fixed(&stats_buf);
        if (self.config.show_percentage) {
            const percent = if (self.config.total > 0) (self.current * 100) / self.config.total else 0;
            sw.print(" {d:>3}%", .{percent}) catch {};
        }
        sw.print(" {d}/{d}", .{ self.current, self.config.total }) catch {};
        if (self.config.show_eta and self.current > 0 and self.current < self.config.total) {
            const elapsed = self.nowMs() - self.start_time;
            if (elapsed > 0) {
                const remaining = self.config.total - self.current;
                const ms_per_item: i64 = @divTrunc(elapsed, @as(i64, @intCast(self.current)));
                const eta_secs: u64 = @intCast(@divTrunc(ms_per_item * @as(i64, @intCast(remaining)), 1000));
                var eta_buf: [16]u8 = undefined;
                sw.print(" ETA: {s}", .{formatDuration(eta_secs, &eta_buf)}) catch {};
            }
        }
        if (self.config.show_elapsed) {
            const elapsed_secs: u64 = @intCast(@divTrunc(self.nowMs() - self.start_time, 1000));
            var elapsed_buf: [16]u8 = undefined;
            sw.print(" [{s}]", .{formatDuration(elapsed_secs, &elapsed_buf)}) catch {};
        }
        if (self.config.show_rate and self.current > 0) {
            const elapsed_ms = self.nowMs() - self.start_time;
            if (elapsed_ms > 0) {
                const rate: f64 = @as(f64, @floatFromInt(self.current)) /
                    (@as(f64, @floatFromInt(elapsed_ms)) / 1000.0);
                sw.print(" {d:.1}/s", .{rate}) catch {};
            }
        }
        const stats = try a.dupe(u8, sw.buffered());

        try self.app.frame(try ui.row(a, .{}, &.{
            ui.textOpts(.{ .wrap = .clip }, left),
            ui.textOpts(.{ .wrap = .clip }, "["),
            try ui.widgets.bar(a, .{
                .theme = self.theme.theme,
                .width = .{ .len = @intCast(self.config.width) },
                .filled_char = self.config.complete_char,
                .empty_char = self.config.incomplete_char,
            }, fraction),
            ui.textOpts(.{ .wrap = .clip }, "]"),
            ui.textOpts(.{ .wrap = .clip }, stats),
            ui.textOpts(.{ .wrap = .clip }, self.config.suffix),
        }));
    }

    fn close(self: *ProgressBar) void {
        if (self.closed) return;
        self.closed = true;
        self.app.deinit();
    }
};

/// Multi-bar configuration
pub const MultiBarConfig = struct {
    /// Frame width in columns (label column + bars + percents)
    width: usize = 60,
    /// Whether to show per-bar percentages
    show_percent: bool = true,
    /// Whether terminal supports unicode
    unicode: bool = true,
};

/// Stacked progress bars for parallel work. Thread-safe: `set`/`increment`
/// may be called from worker threads. Caller-driven (no animation task).
/// Piped output is silent — log your own lines when not a TTY.
///
/// Quiescence requirement: every worker thread must stop calling `add`/`set`/
/// `increment` before `finish` or `deinit` runs. Those finishers take the
/// mutex and tear down the render App (and `deinit` frees the item labels), so
/// a worker that keeps going past the finisher would touch freed state. Join
/// your workers first, then finish once from a single thread.
pub const MultiBar = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    theme: ThemeContext,
    config: MultiBarConfig,
    app: ui.App,
    items: std.ArrayList(Item) = .empty,
    closed: bool = false,
    /// Guards items and the App across worker threads.
    mutex: std.Io.Mutex = .init,

    const Item = struct {
        label: []u8,
        current: usize,
        total: usize,
    };

    /// Initialize a multi-bar writing to `writer`. Prefer `Progress.multiBar`,
    /// which supplies the allocator, writer, `io`, and theme from the bundle.
    pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer, io: std.Io, theme: ThemeContext, config: MultiBarConfig) !MultiBar {
        return .{
            .allocator = allocator,
            .io = io,
            .theme = theme,
            .config = config,
            .app = try ui.App.init(allocator, writer, .{
                .capability = theme.capability(),
                .unicode = config.unicode,
                .interactive = writerInteractive(writer),
                .out_handle = writerOutHandle(writer),
            }),
        };
    }

    pub fn deinit(self: *MultiBar) void {
        self.close();
        for (self.items.items) |item| self.allocator.free(item.label);
        self.items.deinit(self.allocator);
    }

    /// Add a bar; the returned handle indexes `set`/`increment`.
    pub fn add(self: *MultiBar, label: []const u8, total: usize) !usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const owned = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned);
        try self.items.append(self.allocator, .{ .label = owned, .current = 0, .total = total });
        self.render();
        return self.items.items.len - 1;
    }

    /// Set a bar's progress.
    pub fn set(self: *MultiBar, bar_handle: usize, current: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const item = &self.items.items[bar_handle];
        item.current = @min(current, item.total);
        self.render();
    }

    /// Increment a bar's progress by amount.
    pub fn increment(self: *MultiBar, bar_handle: usize, amount: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const item = &self.items.items[bar_handle];
        item.current = @min(item.current + amount, item.total);
        self.render();
    }

    /// Finish: the final frame persists on screen, flowing into scrollback.
    pub fn finish(self: *MultiBar) void {
        self.close();
    }

    fn render(self: *MultiBar) void {
        if (self.closed) return;
        if (!self.app.options.interactive) return;
        self.renderFrame() catch {};
    }

    fn renderFrame(self: *MultiBar) !void {
        const a = self.app.arena();
        const bars = try a.alloc(ui.widgets.MultiBarItem, self.items.items.len);
        for (self.items.items, bars) |item, *b| {
            b.* = .{
                .label = item.label,
                .fraction = if (item.total > 0)
                    @as(f32, @floatFromInt(item.current)) / @as(f32, @floatFromInt(item.total))
                else
                    0,
            };
        }
        var node = try ui.widgets.multiBar(a, .{
            .theme = self.theme.theme,
            .show_percent = self.config.show_percent,
        }, bars);
        node.width = .{ .len = @intCast(self.config.width) };
        try self.app.frame(node);
    }

    /// Tear down the render App. Takes the mutex so it cannot race a worker
    /// mid-`set`/`increment` (which holds the mutex while calling `app.frame`),
    /// and the guard is checked under the lock so a double-finish is a no-op
    /// rather than a second `app.deinit` (use-after-free).
    fn close(self: *MultiBar) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return;
        self.closed = true;
        self.app.deinit();
    }
};

fn nowMsIo(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds, std.time.ns_per_ms));
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

// ============================================================================
// Tests (vterm golden-frame tests live in vterm_test.zig)
// ============================================================================

const testing = std.testing;

/// Force a test indicator into interactive mode with a fixed terminal —
/// tests never have a real TTY, and App must not poll for one.
fn forceInteractive(app: *ui.App) void {
    app.options.interactive = true;
    app.options.term_size = .{ .w = 80, .h = 24 };
}

test "writerHandle discriminates file writers from foreign writers" {
    // A `fixed` writer (foreign vtable) has no OS handle to recover.
    var buf: [64]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buf);
    try testing.expect(writerHandle(&fixed) == null);
    // Interactivity/out-handle fall back to stderr when the handle is unknown.
    try testing.expectEqual(writerInteractive(&fixed), terminal.isStderrTty());
    try testing.expectEqual(writerOutHandle(&fixed), std.Io.File.stderr().handle);

    // A real file writer exposes its target handle, so interactivity keys on
    // that stream rather than always stderr.
    var stream_buf: [64]u8 = undefined;
    var file_writer = std.Io.File.stderr().writerStreaming(testing.io, &stream_buf);
    const handle = writerHandle(&file_writer.interface);
    try testing.expect(handle != null);
    try testing.expectEqual(std.Io.File.stderr().handle, handle.?);
    try testing.expectEqual(std.Io.File.stderr().handle, writerOutHandle(&file_writer.interface));
    try testing.expectEqual(terminal.isTty(std.Io.File.stderr().handle), writerInteractive(&file_writer.interface));
}

test "spinner style frames" {
    const dots_frames = SpinnerStyle.dots.frames();
    try testing.expect(dots_frames.len > 0);
    try testing.expectEqualStrings("⠋", dots_frames[0]);

    const simple_frames = SpinnerStyle.simple.frames();
    try testing.expect(simple_frames.len == 4);
}

test "spinner style intervals" {
    try testing.expect(SpinnerStyle.dots.interval() > 0);
    try testing.expect(SpinnerStyle.clock.interval() > SpinnerStyle.dots.interval());
}

test "format duration" {
    var buf: [16]u8 = undefined;

    try testing.expectEqualStrings("5s", formatDuration(5, &buf));
    try testing.expectEqualStrings("1m30s", formatDuration(90, &buf));
    try testing.expectEqualStrings("1h30m", formatDuration(5400, &buf));
}

test "spinner initialization" {
    var output: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var s = try Spinner.init(testing.allocator, &writer, testing.io, .fallback, .{});
    defer s.deinit();
    try testing.expect(!s.active);
    try testing.expectEqual(@as(usize, 0), s.tick);
}

test "spinner animates and finishes when interactive" {
    var output: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var s = try Spinner.init(testing.allocator, &writer, testing.io, .fallback, .{});
    forceInteractive(&s.app);

    s.start("working");
    s.setMessage("still working");
    s.succeed("done");

    try testing.expect(!s.active);
    try testing.expect(s.animation == null);
    const written = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, written, "working") != null);
    try testing.expect(std.mem.indexOf(u8, written, "done") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\x1b[?25h") != null); // cursor restored
}

test "spinner prints status lines when not interactive" {
    var output: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var s = try Spinner.init(testing.allocator, &writer, testing.io, .fallback, .{});
    s.app.options.interactive = false;

    s.start("connecting");
    s.setMessage("uploading");
    s.succeed("synced");

    const written = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, written, "- connecting\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "- uploading\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, " synced\n") != null);
    // Plain output: no escapes at all.
    try testing.expect(std.mem.indexOfScalar(u8, written, 0x1b) == null);
}

test "spinner result symbols style through the palette roles" {
    var output: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    const custom = theme_pkg.Theme{
        .palette = .{ .success = .{ .foreground = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } } },
    };
    var s = try Spinner.init(testing.allocator, &writer, testing.io, .{
        .theme = &custom,
        .caps = .{ .capability = .true_color, .is_tty = true, .color_enabled = true },
    }, .{});
    forceInteractive(&s.app);

    s.start("working");
    s.succeed("done");

    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "38;2;1;2;3") != null);
}

test "spinner frame styles through the progress.spinner token" {
    var output: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    const custom = theme_pkg.Theme{
        .progress = .{ .spinner = .{ .style = .{ .foreground = .{ .rgb = .{ .r = 9, .g = 8, .b = 7 } } } } },
    };
    var s = try Spinner.init(testing.allocator, &writer, testing.io, .{
        .theme = &custom,
        .caps = .{ .capability = .true_color, .is_tty = true, .color_enabled = true },
    }, .{});
    forceInteractive(&s.app);

    s.start("working");
    s.stop();

    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "38;2;9;8;7") != null);
}

test "spinner renders no color sequences under no_color" {
    var output: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var s = try Spinner.init(testing.allocator, &writer, testing.io, .{
        .caps = .{ .capability = .no_color, .is_tty = true, .color_enabled = false },
    }, .{});
    forceInteractive(&s.app);

    s.start("working");
    s.succeed("done");

    const written = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, written, "done") != null);
    // Cursor-control escapes remain; SGR color/attribute sequences must not
    try testing.expect(std.mem.indexOf(u8, written, "38;2") == null);
    try testing.expect(std.mem.indexOf(u8, written, "\x1b[0m") == null);
}

test "progress bar initialization" {
    var output: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var bar = try ProgressBar.init(testing.allocator, &writer, testing.io, .fallback, .{
        .total = 100,
        .width = 20,
    });
    defer bar.deinit();
    try testing.expectEqual(@as(usize, 0), bar.current);
    try testing.expectEqual(@as(usize, 100), bar.config.total);
}

test "progress bar update and increment clamp to total" {
    var output: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var bar = try ProgressBar.init(testing.allocator, &writer, testing.io, .fallback, .{
        .total = 100,
        .width = 10,
        .show_eta = false,
    });
    defer bar.deinit();
    bar.app.options.interactive = false;

    bar.update(50, null);
    try testing.expect(bar.current == 50);
    bar.increment(10);
    try testing.expect(bar.current == 60);
    bar.update(150, null);
    try testing.expect(bar.current == 100);
}

test "progress bar styles fill and empty through the theme tokens" {
    var output: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    const custom = theme_pkg.Theme{
        .progress = .{
            .bar_fill = .{ .style = .{ .foreground = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } } },
            .bar_empty = .{ .style = .{ .foreground = .{ .rgb = .{ .r = 4, .g = 5, .b = 6 } } } },
        },
    };
    var bar = try ProgressBar.init(testing.allocator, &writer, testing.io, .{
        .theme = &custom,
        .caps = .{ .capability = .true_color, .is_tty = true, .color_enabled = true },
    }, .{
        .total = 10,
        .width = 10,
        .show_eta = false,
    });
    defer bar.deinit();
    forceInteractive(&bar.app);

    bar.update(5, null);

    const written = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, written, "38;2;1;2;3") != null); // fill
    try testing.expect(std.mem.indexOf(u8, written, "38;2;4;5;6") != null); // empty
}

test "progress bar is silent when piped, except one finish line" {
    var output: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var bar = try ProgressBar.init(testing.allocator, &writer, testing.io, .fallback, .{
        .total = 10,
        .show_eta = false,
    });
    bar.app.options.interactive = false;

    bar.update(5, null);
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);

    bar.finishWithMessage("imported");
    const written = writer.buffered();
    try testing.expectEqualStrings("imported 10/10 (100%)\n", written);
    try testing.expect(std.mem.indexOfScalar(u8, written, 0x1b) == null);
}

test "multi bar tracks items and clamps" {
    var output: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var mb = try MultiBar.init(testing.allocator, &writer, testing.io, .fallback, .{});
    defer mb.deinit();
    mb.app.options.interactive = false;

    const a_bar = try mb.add("api", 100);
    const b_bar = try mb.add("assets", 50);
    mb.set(a_bar, 42);
    mb.increment(b_bar, 60); // clamps at 50
    try testing.expectEqual(@as(usize, 42), mb.items.items[a_bar].current);
    try testing.expectEqual(@as(usize, 50), mb.items.items[b_bar].current);
    // Piped: silent.
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
    mb.finish();
}

test "spinner double finish does not touch a torn-down app" {
    // Regression: a second finish (succeed then stop) used to call
    // app.clear()/emit() on an already-deinited App — a use-after-free that
    // testing.allocator would trip. The `closed` guard makes it a no-op.
    var output: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var s = try Spinner.init(testing.allocator, &writer, testing.io, .fallback, .{});
    forceInteractive(&s.app);

    s.start("working");
    s.succeed("done");
    try testing.expect(s.closed);
    // Second (and third) finish variants must be safe no-ops.
    s.stop();
    s.fail("nope");
    s.persist("!", "nope");
    try testing.expect(s.closed);
}

test "spinner deinit stops the animation before tearing down the App" {
    // Regression (#500): the error-unwind path `defer s.deinit()` used to call
    // close() -> app.deinit() WITHOUT stopping the animate task first, so the
    // background task could render onto an already-deinited App (use-after-free
    // + Future leak). deinit now mirrors stop(): stopAnimation() then close().
    var output: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var s = try Spinner.init(testing.allocator, &writer, testing.io, .fallback, .{});
    forceInteractive(&s.app);

    s.start("working");
    // No finish method — simulate an error unwind running the defer.
    s.deinit();
    try testing.expect(!s.active);
    try testing.expect(s.animation == null);
    try testing.expect(s.closed);
}

test "spinner copies its message so a reused caller buffer is safe" {
    // Regression (#522): the message was stored by reference and read on the
    // animation task, so a caller reusing its buffer after start() returned
    // could feed freed/mutated bytes to the bg thread. The spinner now copies.
    var output: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var s = try Spinner.init(testing.allocator, &writer, testing.io, .fallback, .{});
    forceInteractive(&s.app);

    var msg_buf: [32]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "loading data", .{});
    s.start(msg);
    // Clobber the caller's buffer after start — a by-reference spinner would
    // now read 'X's on its next render; the copy keeps the original.
    @memset(&msg_buf, 'X');
    s.render();
    s.succeed("done");

    const written = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, written, "loading data") != null);
    try testing.expect(std.mem.indexOf(u8, written, "XXXX") == null);
}

test "spinner message truncation never splits a UTF-8 codepoint" {
    // Regression (#643): storeMessage hard-cuts at 256 bytes. Build a
    // message whose 256-byte cut point lands inside a 4-byte codepoint
    // (a padding prefix of 253 ASCII bytes followed by 😀, which starts
    // at byte 253 and spans bytes 253-256) and confirm the stored
    // message backs off to a codepoint boundary instead of emitting
    // invalid UTF-8.
    var output: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var s = try Spinner.init(testing.allocator, &writer, testing.io, .fallback, .{});

    var msg_buf: [512]u8 = undefined;
    @memset(msg_buf[0..253], 'a');
    const emoji = "\u{1F600}"; // 😀, 4 UTF-8 bytes
    @memcpy(msg_buf[253..257], emoji);
    const msg = msg_buf[0..257];

    s.storeMessage(msg);
    const stored = s.messageSlice();

    try testing.expect(stored.len <= 256);
    try testing.expect(std.unicode.utf8ValidateSlice(stored));
    // The emoji doesn't fully fit within 256 bytes, so it must be dropped
    // entirely rather than truncated mid-sequence.
    try testing.expectEqual(@as(usize, 253), stored.len);
    try testing.expect(std.mem.indexOf(u8, stored, "\u{1F600}") == null);
}

test "spinner double start does not spawn a second animation" {
    // Regression: a second start() overwrote `animation`, leaking the first
    // future and racing a second animate task. The guard makes it a no-op, so
    // the message set by the first start is preserved.
    var output: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var s = try Spinner.init(testing.allocator, &writer, testing.io, .fallback, .{});
    forceInteractive(&s.app);

    s.start("first");
    s.start("second"); // ignored while already active
    try testing.expectEqualStrings("first", s.messageSlice());
    s.stop();
    // start after finish is also refused.
    s.start("after-close");
    try testing.expect(!s.active);
}

test "multi bar double finish and finish-then-deinit are safe" {
    // Regression: finish()/deinit() now take the mutex and check `closed`
    // under the lock, so repeated finish and a following deinit never call
    // app.deinit() twice (a use-after-free).
    var output: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var mb = try MultiBar.init(testing.allocator, &writer, testing.io, .fallback, .{});
    defer mb.deinit(); // deinit after finish must be safe
    forceInteractive(&mb.app);

    const h = try mb.add("api", 100);
    mb.set(h, 50);
    mb.finish();
    try testing.expect(mb.closed);
    mb.finish(); // second finish is a no-op
    // A set() racing past finish is dropped rather than painting a dead app.
    mb.set(h, 75);
    try testing.expect(mb.closed);
}

test "multi bar renders labels, bars, and percents when interactive" {
    var output: [32768]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);

    var mb = try MultiBar.init(testing.allocator, &writer, testing.io, .fallback, .{});
    defer mb.deinit();
    forceInteractive(&mb.app);

    const h = try mb.add("api.tar.gz", 100);
    mb.set(h, 50);
    mb.finish();

    // Byte-level assertions only see the first full paint — an update diffs
    // down to the changed cells (vterm_test.zig asserts the updated screen).
    const written = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, written, "api.tar.gz") != null);
    try testing.expect(std.mem.indexOf(u8, written, "  0%") != null);
    try testing.expect(std.mem.indexOf(u8, written, "░") != null);
    try testing.expect(std.mem.indexOf(u8, written, "█") != null); // from the 50% diff
}
