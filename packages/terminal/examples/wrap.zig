//! Display-width and word-wrapping — the measurement half of the package.
//!
//! Terminal layout can't use byte length or codepoint count as a proxy for how
//! many columns a string occupies: CJK ideographs are double-width, emoji (ZWJ
//! sequences, flags, skin-tone modifiers) are one grapheme but two columns,
//! combining marks add none, and ANSI color escapes paint nothing. This example
//! shows the width/wrap API getting all of those right.
//!
//! It's non-interactive — it takes over nothing — so it runs anywhere, including
//! piped. `run-wrap` prints a width table plus a wrap of a mixed-script paragraph
//! at a fixed column budget.
//!
//! Run with: zig build run-wrap   (from packages/terminal)

const std = @import("std");
const terminal = @import("terminal");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    // --- displayWidth vs byte length vs grapheme count -----------------------
    try w.writeAll("displayWidth — columns, not bytes or codepoints\n");
    try w.writeAll("-----------------------------------------------\n");
    const samples = [_][]const u8{
        "hello", // plain ASCII: 5 bytes, 5 cols
        "café", // combining/precomposed accent: still 4 cols
        "日本語", // CJK: 3 graphemes, 6 cols (double-width)
        "👍🏽", // emoji + skin-tone modifier: 1 grapheme, 2 cols
        "👨‍👩‍👧", // ZWJ family: 1 grapheme, 2 cols
        "\x1b[31mred\x1b[0m", // ANSI-colored "red": escapes are 0 cols
    };
    for (samples) |s| {
        try w.print("  bytes={d:>2}  graphemes={d:>2}  width={d:>2}  {s}\n", .{
            s.len,
            terminal.graphemeCount(s),
            terminal.displayWidth(s),
            s,
        });
    }

    // --- wrapToWidth: allocating, returns slices into the input --------------
    const width: usize = 30;
    const para =
        "The terminal package measures width by grapheme cluster, so 日本語 and " ++
        "emoji 👍🏽 wrap on the same column budget as plain ASCII text does.";

    try w.print("\nwrapToWidth at {d} columns (│ marks the budget):\n", .{width});
    try w.writeByte('+');
    for (0..width) |_| try w.writeByte('-');
    try w.writeAll("+\n");

    const lines = try terminal.wrapToWidth(gpa, para, width);
    defer gpa.free(lines);
    for (lines) |line| {
        // Right-pad to the budget so the closing │ lines up — using displayWidth,
        // not line.len, because these lines contain multi-column graphemes.
        try w.print("|{s}", .{line});
        const pad = width -| terminal.displayWidth(line);
        for (0..pad) |_| try w.writeByte(' ');
        try w.writeAll("|\n");
    }
    try w.writeByte('+');
    for (0..width) |_| try w.writeByte('-');
    try w.writeAll("+\n");

    // --- wrapCount: same wrap without allocating (layout pre-measure) --------
    try w.print("\nwrapCount says that is {d} lines (no allocation).\n", .{
        terminal.wrapCount(para, width),
    });
}
