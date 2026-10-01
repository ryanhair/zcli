//! Editor prompt — launches the user's editor for multiline text input.
//!
//! The editor command is resolved from the threaded `environ` (`$VISUAL`, then
//! `$EDITOR`, falling back to `vi`) unless `editor_cmd` overrides it. We read
//! the environment through the passed-in map rather than a global getenv.
//!
//! The hint line renders on the ui engine; before spawning the editor the
//! App is closed (cursor restored, region persisted) so the editor gets a
//! clean terminal.

const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("terminal");
const Prompts = @import("Prompts.zig");
const lr = @import("list_render.zig");
const ui = lr.ui;

pub const EditorConfig = struct {
    message: []const u8,
    default: ?[]const u8 = null,
    extension: []const u8 = ".txt",
    prefix: []const u8 = "? ",
    /// Explicit editor command. When null the editor is resolved from `environ`
    /// (`$VISUAL`, then `$EDITOR`, else `vi`/`notepad`); set this to force a specific
    /// program regardless of the environment.
    editor_cmd: ?[]const u8 = null,
    /// At an interactive prompt, bypass the Enter invitation. Noninteractive
    /// prompts still read stdin. Use `edit` to require an editor independently
    /// of stdout redirection and receive structured recovery information.
    immediate: bool = false,
    /// Explicit program and arguments, without command-string parsing.
    argv: ?[]const []const u8 = null,
    io: std.Io,
    /// Threaded environ. Used to resolve the editor command (`$VISUAL`/`$EDITOR`)
    /// and to choose the scratch directory. POSIX defaults to `vi` and `/tmp`;
    /// Windows defaults to `notepad` and TEMP/TMP (or the working directory).
    environ: ?*const std.process.Environ.Map = null,
};

/// Launch the user's editor for multiline input. Returns owned string,
/// `error.UserAborted` if the user presses Ctrl-C, or `error.EndOfStream` if
/// stdin closes with no input to submit.
pub fn editor(p: Prompts, config: EditorConfig) ![]u8 {
    const writer = p.writer;
    const reader = p.reader;
    const allocator = p.allocator;
    const is_tty = p.isInteractive();

    if (!is_tty) {
        try writer.print("{s}{s}", .{ config.prefix, config.message });
        // Non-TTY: read all remaining input until EOF.
        try writer.writeAll("\n");
        // Flush so the prompt is visible before we block reading input —
        // buffered writers otherwise strand it until after input arrives.
        Prompts.flushWriter(writer);
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        while (true) {
            const byte = terminal.key.readByteFn(reader) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            try buf.append(allocator, byte);
        }
        // Nothing typed on a closed stdin surfaces rather than masquerading as
        // an empty document (the `default` is pre-fill content, not a fallback).
        if (buf.items.len == 0) return error.EndOfStream;
        return try buf.toOwnedSlice(allocator);
    }

    if (config.immediate) return finishPromptEdit(p, config);

    // Wait for Enter in raw mode, hint line rendered as a frame.
    Prompts.flushWriter(writer);
    const raw = terminal.enableRawMode(std.Io.File.stdin().handle) catch {
        try writer.print("{s}{s}\n", .{ config.prefix, config.message });
        return error.EditorFailed;
    };
    var raw_active = true;
    errdefer if (raw_active) raw.disable();
    // Watches for SIGWINCH so a resize while the user is at the hint line
    // repaints instead of leaving the wrapped prompt stale. Torn down (along
    // with raw mode) before the child editor is spawned so it inherits a clean
    // terminal and default signal disposition.
    var watcher = terminal.ResizeWatcher.init();
    var watcher_active = true;
    errdefer if (watcher_active) watcher.deinit();
    const stdin = std.Io.File.stdin().handle;
    var app = try ui.App.init(p.allocator, writer, .{
        .capability = p.theme.capability(),
        .hybrid_raw = raw,
    });
    defer app.deinit();
    try renderFrame(&app, p.theme, config);

    while (true) {
        const k = switch (try terminal.readEvent(reader, stdin, &watcher)) {
            .resize => {
                try renderFrame(&app, p.theme, config);
                continue;
            },
            .key => |key| key,
            else => continue,
        };
        switch (k) {
            .enter => break,
            .ctrl => |c| {
                if (c == 'c') {
                    try app.clear();
                    try app.emit("{s}{s}", .{ config.prefix, config.message });
                    app.deinit();
                    watcher.deinit();
                    watcher_active = false;
                    raw.disable();
                    raw_active = false;
                    Prompts.flushWriter(writer);
                    return error.UserAborted;
                }
            },
            else => {},
        }
    }
    // Persist the prompt line and hand the editor a clean terminal: region
    // closed, cursor restored, resize watcher and raw mode off.
    try app.clear();
    try app.emit("{s}{s}", .{ config.prefix, config.message });
    app.deinit();
    watcher.deinit();
    watcher_active = false;
    raw.disable();
    raw_active = false;
    Prompts.flushWriter(writer);

    return finishPromptEdit(p, config);
}

fn finishPromptEdit(p: Prompts, config: EditorConfig) ![]u8 {
    var result = try edit(p.allocator, .{
        .io = config.io,
        .environ = config.environ,
        .default = config.default,
        .extension = config.extension,
        .editor_cmd = config.editor_cmd,
        .argv = config.argv,
    });
    switch (result) {
        .edited => |content| return content,
        .failed => |failure| {
            defer result.deinit(p.allocator);
            if (failure.recovery_path) |path| {
                p.writer.print("Edited content preserved at {s}\n", .{path}) catch {};
                Prompts.flushWriter(p.writer);
            }
            return switch (failure.phase) {
                .launch => error.EditorLaunchFailed,
                .read => error.EditorReadFailed,
                else => error.EditorFailed,
            };
        },
    }
}

pub const EditConfig = struct {
    io: std.Io,
    environ: ?*const std.process.Environ.Map = null,
    default: ?[]const u8 = null,
    extension: []const u8 = ".txt",
    /// Preferred for programmatic configuration. Filename is appended as one
    /// argument. An empty argv is invalid; it never falls back to the env.
    argv: ?[]const []const u8 = null,
    /// Command string override. Uses shell-word quoting without expansion.
    editor_cmd: ?[]const u8 = null,
    /// Override scratch location; otherwise TMPDIR, Windows TEMP/TMP, or /tmp.
    temp_dir: ?[]const u8 = null,
    max_bytes: usize = max_editor_bytes,
    /// Interactive editing attaches /dev/tty or CONIN$/CONOUT$ independently
    /// of process stdout. Inherit is explicit for noninteractive tools/tests.
    attachment: enum { controlling_terminal, inherit } = .controlling_terminal,
    recovery: enum { preserve_changed, discard } = .preserve_changed,
};

pub const EditorFailure = struct {
    phase: enum { command, terminal, create, write, launch, wait, termination, read },
    cause: ?anyerror = null,
    termination: ?std.process.Child.Term = null,
    /// Owned path. Deinitializing the result frees this path, not the file.
    recovery_path: ?[]u8 = null,
};

pub const EditResult = union(enum) {
    edited: []u8,
    failed: EditorFailure,

    pub fn deinit(self: *EditResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .edited => |content| allocator.free(content),
            .failed => |f| if (f.recovery_path) |path| allocator.free(path),
        }
        self.* = undefined;
    }
};

/// Opens the editor immediately, preserving saved bytes exactly. This operation
/// does not render an invitation or silently substitute the initial document.
/// Expected editor failures are data; allocation failures remain Zig errors.
pub fn edit(allocator: std.mem.Allocator, config: EditConfig) !EditResult {
    // A private arena owns the parsed argv; results use the caller allocator.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    const command = if (config.argv) |argv| argv else parseEditorWords(temporary, resolveEditCmd(config)) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failed = .{ .phase = .command, .cause = err } };
    };
    if (command.len == 0 or command[0].len == 0) return .{ .failed = .{ .phase = .command, .cause = error.InvalidEditorCommand } };
    for (command) |arg| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return .{ .failed = .{ .phase = .command, .cause = error.InvalidEditorCommand } };
    }
    if (std.mem.indexOfAny(u8, config.extension, "/\\") != null or std.mem.indexOfScalar(u8, config.extension, 0) != null) {
        return .{ .failed = .{ .phase = .create, .cause = error.InvalidExtension } };
    }

    const program = resolveEditorProgram(temporary, config.io, config.environ, command[0]) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failed = .{ .phase = .launch, .cause = err } };
    };

    var input_terminal: ?std.Io.File = null;
    var output_terminal: ?std.Io.File = null;
    defer if (input_terminal) |f| f.close(config.io);
    defer if (output_terminal) |f| f.close(config.io);
    if (config.attachment == .controlling_terminal) {
        if (builtin.os.tag == .windows) {
            input_terminal = openWindowsConsole(false) catch |err|
                return .{ .failed = .{ .phase = .terminal, .cause = err } };
            output_terminal = openWindowsConsole(true) catch |err|
                return .{ .failed = .{ .phase = .terminal, .cause = err } };
        } else {
            input_terminal = std.Io.Dir.cwd().openFile(config.io, "/dev/tty", .{ .mode = .read_write }) catch |err|
                return .{ .failed = .{ .phase = .terminal, .cause = err } };
        }
    }

    var name_buf: [scratch_name_len]u8 = undefined;
    const scratch_name = randomScratchName(config.io, &name_buf);
    const tmp_name = try std.fs.path.join(allocator, &.{ resolveTempDir(config), try std.fmt.allocPrint(temporary, "{s}{s}", .{ scratch_name, config.extension }) });
    var preserve = false;
    var created = false;
    const cwd = std.Io.Dir.cwd();
    // Register cleanup before writing, including on allocation/read failures.
    defer if (!preserve) {
        if (created) cwd.deleteFile(config.io, tmp_name) catch {};
        allocator.free(tmp_name);
    };
    var tmp_file = cwd.createFile(config.io, tmp_name, .{
        .exclusive = true,
        .permissions = @enumFromInt(0o600),
    }) catch |err| return .{ .failed = .{ .phase = .create, .cause = err } };
    created = true;
    const write_error: ?anyerror = blk: {
        defer tmp_file.close(config.io);
        tmp_file.writeStreamingAll(config.io, config.default orelse "") catch |err| break :blk err;
        break :blk null;
    };
    if (write_error) |err| return .{ .failed = .{ .phase = .write, .cause = err } };

    const argv = try temporary.alloc([]const u8, command.len + 1);
    @memcpy(argv[0..command.len], command);
    argv[0] = program;
    argv[command.len] = tmp_name;
    const output = output_terminal orelse input_terminal;
    var child = std.process.spawn(config.io, .{
        .argv = argv,
        .environ_map = config.environ,
        .stdin = if (input_terminal) |f| .{ .file = f } else .inherit,
        .stdout = if (output) |f| .{ .file = f } else .inherit,
        .stderr = if (output) |f| .{ .file = f } else .inherit,
    }) catch |err| {
        var failure: EditorFailure = .{ .phase = .launch, .cause = err };
        preserve = preserveScratch(temporary, config, tmp_name);
        if (preserve) failure.recovery_path = tmp_name;
        return .{ .failed = failure };
    };
    const term = child.wait(config.io) catch |err| {
        // Ensure a failed wait cannot leave the editor writing an unlinked file.
        child.kill(config.io);
        var failure: EditorFailure = .{ .phase = .wait, .cause = err };
        preserve = preserveScratch(temporary, config, tmp_name);
        if (preserve) failure.recovery_path = tmp_name;
        return .{ .failed = failure };
    };
    if (term != .exited or term.exited != 0) {
        var failure: EditorFailure = .{ .phase = .termination, .termination = term };
        preserve = preserveScratch(temporary, config, tmp_name);
        if (preserve) failure.recovery_path = tmp_name;
        return .{ .failed = failure };
    }
    const content = readEditedFile(config.io, tmp_name, allocator, config.max_bytes) catch |err| {
        // A successful editor may have saved work that we could not read back.
        // Preserve the file before returning, including an allocation failure.
        preserve = config.recovery == .preserve_changed;
        return .{ .failed = .{ .phase = .read, .cause = err, .recovery_path = if (preserve) tmp_name else null } };
    };
    return .{ .edited = content };
}

fn preserveScratch(allocator: std.mem.Allocator, config: EditConfig, path: []const u8) bool {
    if (config.recovery == .discard) return false;
    const content = readEditedFile(config.io, path, allocator, config.max_bytes) catch return true;
    defer allocator.free(content);
    return !std.mem.eql(u8, content, config.default orelse "");
}

fn resolveEditCmd(config: EditConfig) []const u8 {
    if (config.editor_cmd) |cmd| return cmd;
    if (config.environ) |env| {
        if (env.get("VISUAL")) |cmd| if (cmd.len != 0) return cmd;
        if (env.get("EDITOR")) |cmd| if (cmd.len != 0) return cmd;
    }
    return if (builtin.os.tag == .windows) "notepad" else "vi";
}

fn resolveTempDir(config: EditConfig) []const u8 {
    if (config.temp_dir) |dir| return dir;
    if (config.environ) |env| {
        if (env.get("TMPDIR")) |dir| return dir;
        if (builtin.os.tag == .windows) {
            if (env.get("TEMP")) |dir| return dir;
            if (env.get("TMP")) |dir| return dir;
        }
    }
    return if (builtin.os.tag == .windows) "." else "/tmp";
}

/// Shell-word grammar: whitespace separates arguments, quotes group them,
/// backslashes escape characters. No variable, tilde, glob or command expansion.
/// Single quotes are literal; double-quoted backslash escapes only shell quote
/// characters (and a newline). This also preserves quoted Windows path slashes.
/// The result and each word are owned by allocator.
pub fn parseEditorWords(allocator: std.mem.Allocator, command: []const u8) ![][]u8 {
    var words: std.ArrayList([]u8) = .empty;
    errdefer {
        for (words.items) |word| allocator.free(word);
        words.deinit(allocator);
    }
    var word: std.ArrayList(u8) = .empty;
    defer word.deinit(allocator);
    var quote: ?u8 = null;
    var started = false;
    var index: usize = 0;
    while (index < command.len) : (index += 1) {
        const ch = command[index];
        if (ch == 0) return error.InvalidEditorCommand;
        if (quote == '\'') {
            if (ch == '\'') quote = null else try word.append(allocator, ch);
        } else if (ch == '\\') {
            if (index + 1 == command.len) return error.InvalidEditorCommand;
            const next = command[index + 1];
            if (next == 0) return error.InvalidEditorCommand;
            if (quote == '"' and std.mem.indexOfScalar(u8, "$`\\\"\n", next) == null) {
                try word.append(allocator, ch);
                started = true;
                continue;
            }
            index += 1;
            if (next != '\n') {
                try word.append(allocator, next);
                started = true;
            }
        } else if (quote != null) {
            if (ch == quote.?) quote = null else try word.append(allocator, ch);
        } else if (ch == '\'' or ch == '"') {
            quote = ch;
            started = true;
        } else if (std.ascii.isWhitespace(ch)) {
            if (started) {
                try appendWord(allocator, &words, &word);
                started = false;
            }
        } else {
            try word.append(allocator, ch);
            started = true;
        }
    }
    if (quote != null) return error.InvalidEditorCommand;
    if (started) try appendWord(allocator, &words, &word);
    if (words.items.len == 0 or words.items[0].len == 0) return error.InvalidEditorCommand;
    return words.toOwnedSlice(allocator);
}

test "EditorConfig defaults" {
    const cfg = EditorConfig{ .message = "Edit:", .io = std.testing.io };
    try std.testing.expect(cfg.default == null);
    try std.testing.expectEqualStrings(".txt", cfg.extension);
}

test "non-TTY: EOF with no input errors" {
    const allocator = std.testing.allocator;
    var input = "".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    try std.testing.expectError(error.EndOfStream, editor(.{ .writer = &output_writer, .reader = &input_reader, .allocator = allocator }, .{
        .message = "Edit:",
        .default = "prefill",
        .io = std.testing.io,
    }));
}

test "non-TTY: reads piped multiline input" {
    const allocator = std.testing.allocator;
    var input = "line one\nline two".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try editor(.{ .writer = &output_writer, .reader = &input_reader, .allocator = allocator, .interactive = false }, .{
        .message = "Edit:",
        .io = std.testing.io,
        .immediate = true,
    });
    defer allocator.free(result);

    try std.testing.expectEqualStrings("line one\nline two", result);
}

/// Upper bound on the edited document we read back. High enough that real
/// hand-edited text never hits it, low enough to stay a sane guard against a
/// pathological file. The old 1 MiB cap threw away the user's work.
const max_editor_bytes = 128 * 1024 * 1024;

/// Length of a scratch file name: the ".prompts_edit-" prefix plus 16 hex chars.
const scratch_name_len = ".prompts_edit-".len + 16;

/// A random, unpredictable name for the scratch file, so a local attacker
/// cannot pre-plant anything (e.g. a symlink) at the edit path.
fn randomScratchName(io: std.Io, buf: *[scratch_name_len]u8) []const u8 {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const hex = std.fmt.bytesToHex(&random_bytes, .lower);
    return std.fmt.bufPrint(buf, ".prompts_edit-{s}", .{hex}) catch unreachable;
}

test "resolveEditCmd - explicit override wins, then VISUAL and EDITOR" {
    const io = std.testing.io;

    // No environ, no override → vi.
    try std.testing.expectEqualStrings(if (builtin.os.tag == .windows) "notepad" else "vi", resolveEditCmd(.{ .io = io }));

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    // Only EDITOR set.
    try env.put("EDITOR", "nano");
    try std.testing.expectEqualStrings("nano", resolveEditCmd(.{ .io = io, .environ = &env }));

    // VISUAL takes precedence over EDITOR.
    try env.put("VISUAL", "code -w");
    try std.testing.expectEqualStrings("code -w", resolveEditCmd(.{ .io = io, .environ = &env }));

    // An explicit override beats the environment entirely.
    try std.testing.expectEqualStrings("emacs", resolveEditCmd(.{ .io = io, .environ = &env, .editor_cmd = "emacs" }));
}

test "randomScratchName - hidden, fixed-length, unpredictable" {
    var buf_a: [scratch_name_len]u8 = undefined;
    var buf_b: [scratch_name_len]u8 = undefined;
    const a = randomScratchName(std.testing.io, &buf_a);
    const b = randomScratchName(std.testing.io, &buf_b);

    try std.testing.expect(std.mem.startsWith(u8, a, ".prompts_edit-"));
    try std.testing.expectEqual(scratch_name_len, a.len);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

fn renderFrame(app: *ui.App, ctx: Prompts.ThemeContext, config: EditorConfig) !void {
    const a = app.arena();
    const ws = terminal.getWindowSize(std.Io.File.stdout().handle) catch terminal.Winsize{ .row = 24, .col = 80 };
    const usable: u16 = @intCast(@min(@max(@as(usize, ws.col) -| 1, 1), std.math.maxInt(u16)));
    const head = try std.fmt.allocPrint(a, "{s}{s} ", .{ config.prefix, config.message });
    const hint = "(press Enter to open editor) ";
    const hint_style = ctx.resolveRef(ctx.promptTokens().hint);
    try app.frame(try ui.column(a, .{ .width = .{ .len = usable } }, &.{
        try ui.row(a, .{}, &.{
            ui.textOpts(.{ .wrap = .clip }, head),
            ui.textOpts(.{ .style = hint_style, .wrap = .clip }, hint),
        }),
    }));
    const line = try std.fmt.allocPrint(app.arena(), "{s}{s}", .{ head, hint });
    const pos = Prompts.endPosition(line, usable);
    try app.showCursorAt(pos.x, pos.y);
}

fn appendWord(allocator: std.mem.Allocator, words: *std.ArrayList([]u8), word: *std.ArrayList(u8)) !void {
    const text = try word.toOwnedSlice(allocator);
    errdefer allocator.free(text);
    try words.append(allocator, text);
}

test "editor words support args, quotes, escaped spaces and explicit shells" {
    const allocator = std.testing.allocator;
    const words = try parseEditorWords(allocator, "sh -c 'echo edited > \"$1\"' --");
    defer {
        for (words) |word| allocator.free(word);
        allocator.free(words);
    }
    try std.testing.expectEqual(@as(usize, 4), words.len);
    try std.testing.expectEqualStrings("sh", words[0]);
    try std.testing.expectEqualStrings("-c", words[1]);
    try std.testing.expectEqualStrings("echo edited > \"$1\"", words[2]);
    try std.testing.expectEqualStrings("--", words[3]);
    const quoted = try parseEditorWords(allocator, "\"C:\\Program Files\\editor.exe\" --wait 'a b' c\\ d \"\" $HOME");
    defer {
        for (quoted) |word| allocator.free(word);
        allocator.free(quoted);
    }
    try std.testing.expectEqualStrings("C:\\Program Files\\editor.exe", quoted[0]);
    try std.testing.expectEqualStrings("c d", quoted[3]);
    try std.testing.expectEqualStrings("", quoted[4]);
    try std.testing.expectEqualStrings("$HOME", quoted[5]);
    for ([_][]const u8{ "", "'unterminated", "unclosed\\", "\"\"", "bad\x00value" }) |bad|
        try std.testing.expectError(error.InvalidEditorCommand, parseEditorWords(allocator, bad));
}

fn wordsUnderAllocationFailure(allocator: std.mem.Allocator) !void {
    const words = try parseEditorWords(allocator, "code --wait 'hello world' \"\"");
    defer {
        for (words) |word| allocator.free(word);
        allocator.free(words);
    }
}

test "editor word parsing cleans up every failed allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, wordsUnderAllocationFailure, .{});
}

fn testEdit(allocator: std.mem.Allocator, config: EditConfig) !EditResult {
    var c = config;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(config.io, ".", allocator);
    defer allocator.free(path);
    c.temp_dir = path;
    c.attachment = .inherit;
    return edit(allocator, c);
}

test "immediate operation preserves edited newlines and valid empty documents" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var result = try testEdit(allocator, .{
        .io = std.testing.io,
        .default = "old text",
        .editor_cmd = "sh -c 'printf \"edited\\n\" > \"$1\"' --",
    });
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("edited\n", result.edited);
    var empty = try testEdit(allocator, .{ .io = std.testing.io, .default = "old", .argv = &.{ "/bin/sh", "-c", ": > \"$1\"", "--" } });
    defer empty.deinit(allocator);
    try std.testing.expectEqualStrings("", empty.edited);
}

test "editor termination is a structured failure with recovery when changed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);
    var result = try edit(allocator, .{
        .io = std.testing.io,
        .temp_dir = path,
        .attachment = .inherit,
        .default = "old",
        .argv = &.{ "/bin/sh", "-c", "printf saved > \"$1\"; exit 1", "--" },
    });
    defer result.deinit(allocator);
    try std.testing.expectEqual(.termination, result.failed.phase);
    try std.testing.expectEqual(@as(u8, 1), result.failed.termination.?.exited);
    const recovery = result.failed.recovery_path.?;
    const saved = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, recovery, allocator, .limited(100));
    defer allocator.free(saved);
    try std.testing.expectEqualStrings("saved", saved);
    var unchanged = try testEdit(allocator, .{ .io = std.testing.io, .default = "old", .argv = &.{ "/bin/sh", "-c", "exit 1", "--" } });
    defer unchanged.deinit(allocator);
    try std.testing.expectEqual(.termination, unchanged.failed.phase);
    try std.testing.expect(unchanged.failed.recovery_path == null);
    var launch = try testEdit(allocator, .{ .io = std.testing.io, .argv = &.{"/nonexistent-zcli-editor"} });
    defer launch.deinit(allocator);
    try std.testing.expectEqual(.launch, launch.failed.phase);
}

test "successful save with failed readback preserves recovery file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);
    var result = try edit(allocator, .{
        .io = std.testing.io,
        .temp_dir = path,
        .attachment = .inherit,
        .argv = &.{ "/bin/sh", "-c", "printf saved > \"$1\"", "--" },
        .max_bytes = 2,
    });
    defer result.deinit(allocator);
    try std.testing.expectEqual(.read, result.failed.phase);
    try std.testing.expectEqual(error.StreamTooLong, result.failed.cause.?);
    const saved = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, result.failed.recovery_path.?, allocator, .limited(100));
    defer allocator.free(saved);
    try std.testing.expectEqualStrings("saved", saved);
}

// std.Io's NT path resolver does not support CONIN$/CONOUT$ device names.
// Open the attached console with Win32 directly, then use ordinary File
// ownership and SpawnOptions.file so redirects never become editor UI.
extern "kernel32" fn CreateFileW(
    name: [*:0]const u16,
    access: u32,
    share_mode: u32,
    security: ?*anyopaque,
    disposition: u32,
    flags: u32,
    template: ?std.os.windows.HANDLE,
) callconv(.winapi) std.os.windows.HANDLE;

fn openWindowsConsole(output: bool) !std.Io.File {
    const name = if (output) std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$") else std.unicode.utf8ToUtf16LeStringLiteral("CONIN$");
    // GENERIC_READ|GENERIC_WRITE, FILE_SHARE_READ|FILE_SHARE_WRITE,
    // OPEN_EXISTING. Console handles are synchronous and closed by File.
    const handle = CreateFileW(name, 0xc0000000, 3, null, 3, 0, null);
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.NoControllingTerminal;
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

/// Resolve supplied PATH ourselves: std.process.spawn uses the parent's PATH
/// even when environ_map is supplied. Always pass an absolute filename when
/// using a threaded environment. Relative PATH entries retain normal meaning.
fn resolveEditorProgram(allocator: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, name: []const u8) ![]const u8 {
    try refuseWindowsBatch(name);
    if (std.mem.indexOfScalar(u8, name, '/') != null or (builtin.os.tag == .windows and std.mem.indexOfAny(u8, name, "\\:") != null)) {
        return std.Io.Dir.cwd().realPathFileAlloc(io, name, allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ProgramNotFound,
        };
    }
    const map = env orelse return name;
    const search_path = map.get("PATH") orelse return error.ProgramNotFound;
    const extensions: []const []const u8 = if (builtin.os.tag == .windows and std.fs.path.extension(name).len == 0) &.{ ".exe", ".com" } else &.{""};
    var directories = std.mem.splitScalar(u8, search_path, if (builtin.os.tag == .windows) ';' else ':');
    while (directories.next()) |entry| {
        const dir = if (entry.len == 0) "." else entry;
        for (extensions) |extension| {
            const basename = try std.fmt.allocPrint(allocator, "{s}{s}", .{ name, extension });
            defer allocator.free(basename);
            const candidate = try std.fs.path.join(allocator, &.{ dir, basename });
            defer allocator.free(candidate);
            std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch continue;
            try refuseWindowsBatch(candidate);
            return std.Io.Dir.cwd().realPathFileAlloc(io, candidate, allocator) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
        }
    }
    return error.ProgramNotFound;
}

fn refuseWindowsBatch(path: []const u8) !void {
    if (builtin.os.tag != .windows) return;
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".bat") or std.ascii.eqlIgnoreCase(extension, ".cmd")) return error.BatchScriptRefused;
}

test "editor lookup uses threaded PATH and explicit argv accepts spaces" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    var file = try tmp.dir.createFile(io, "an editor", .{ .permissions = @enumFromInt(0o700) });
    try file.writeStreamingAll(io, "#!/bin/sh\nprintf '%s\\n' \"$MARK\" > \"$1\"\n");
    file.close(io);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("PATH", path);
    try env.put("VISUAL", "'an editor'");
    try env.put("MARK", "threaded");
    var result = try edit(allocator, .{ .io = io, .environ = &env, .temp_dir = path, .attachment = .inherit });
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("threaded\n", result.edited);
    const explicit_path = try std.fs.path.join(allocator, &.{ path, "an editor" });
    defer allocator.free(explicit_path);
    var explicit = try edit(allocator, .{ .io = io, .environ = &env, .temp_dir = path, .attachment = .inherit, .argv = &.{explicit_path} });
    defer explicit.deinit(allocator);
    try std.testing.expectEqualStrings("threaded\n", explicit.edited);
    try env.put("PATH", "/nonexistent-zcli-path");
    var missing = try edit(allocator, .{ .io = io, .environ = &env, .temp_dir = path, .attachment = .inherit });
    defer missing.deinit(allocator);
    try std.testing.expectEqual(.launch, missing.failed.phase);
    try std.testing.expectEqual(error.ProgramNotFound, missing.failed.cause.?);
}

fn readEditedFile(io: std.Io, path: []const u8, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    // std.Io allocRemaining treats the limit as exclusive. Probe one additional
    // byte so documents exactly at the public limit are accepted.
    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes +| 1));
    if (content.len > max_bytes) {
        allocator.free(content);
        return error.StreamTooLong;
    }
    return content;
}

test "editor cap accepts exact boundary and zero accepts empty" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var exact = try testEdit(allocator, .{ .io = std.testing.io, .max_bytes = 6, .argv = &.{ "/bin/sh", "-c", "printf 'saved\\n' > \"$1\"", "--" } });
    defer exact.deinit(allocator);
    try std.testing.expectEqualStrings("saved\n", exact.edited);
    var empty = try testEdit(allocator, .{ .io = std.testing.io, .max_bytes = 0, .argv = &.{ "/bin/sh", "-c", ": > \"$1\"", "--" } });
    defer empty.deinit(allocator);
    try std.testing.expectEqualStrings("", empty.edited);
}

test "noninteractive immediate prompt propagates read failure" {
    const Failing = struct {
        fn stream(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
            return error.ReadFailed;
        }
    };
    var partial = "partial".*;
    var reader: std.Io.Reader = .{ .vtable = &.{ .stream = Failing.stream }, .buffer = &partial, .seek = 0, .end = partial.len };
    var out_buffer: [100]u8 = undefined;
    var output: std.Io.Writer = .fixed(&out_buffer);
    try std.testing.expectError(error.ReadFailed, editor(.{ .allocator = std.testing.allocator, .reader = &reader, .writer = &output, .interactive = false }, .{ .io = std.testing.io, .message = "Edit:", .immediate = true }));
}

test "nested EDITOR value and empty VISUAL resolve through threaded environment" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/bin:/usr/bin");
    try env.put("VISUAL", "");
    try env.put("EDITOR", "sh -c 'echo edited > \"$1\"' --");
    var result = try testEdit(std.testing.allocator, .{ .io = std.testing.io, .environ = &env });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("edited\n", result.edited);
}
