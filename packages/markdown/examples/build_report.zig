//! `build_report` — a realistic end-to-end use of the package: a CLI printing a
//! build/test report. It combines headers, lists, code blocks, blockquotes,
//! rules, links, semantic status tags, and runtime interpolation in one
//! document — the way you'd actually reach for `markdown` in a tool.
//!
//! Run:  zig build run-build_report

const std = @import("std");
const md = @import("markdown");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var fmt = md.formatter(out, .true_color);

    // Pretend these came from an actual build/test run.
    const passed: u32 = 247;
    const failed: u32 = 3;
    const skipped: u32 = 12;
    const coverage: f64 = 94.2;
    const duration_s: f64 = 12.4;

    // The report is one document. Block elements (headers/lists/code/quote/rule)
    // structure it; format specifiers pull in the runtime numbers. This whole
    // string is parsed to ANSI at comptime.
    try fmt.write(
        \\# Build Report
        \\
        \\Completed in **{d:.1}s** with coverage of **{d:.1}%**.
        \\
        \\## Summary
        \\
        \\- **{d}** passed
        \\- **{d}** failed
        \\- *{d}* skipped
        \\
        \\## Failing tests
        \\
        \\1. `auth/login_test.zig` — token refresh returned 401
        \\2. `net/pool_test.zig` — connection timeout after 5s
        \\3. `parse/lexer_test.zig` — unexpected EOF
        \\
        \\> **Action required:** fix the failures above before merging.
        \\
        \\Reproduce a single failure with:
        \\
        \\```bash
        \\$ zig test src/auth/login_test.zig
        \\```
        \\
        \\---
        \\
        \\Full logs: [CI run #4821](https://ci.example.com/runs/4821)
        \\
    , .{ duration_s, coverage, passed, failed, skipped });

    // Semantic tags shine for the one-line status footer: tag by meaning and let
    // the palette (and NO_COLOR) decide the styling. These are inline-only, so
    // we keep them out of the block document above.
    try out.writeAll("\n");
    if (failed == 0) {
        try fmt.write("<success>**PASS** — all {d} tests green</success>\n", .{passed});
    } else {
        try fmt.write(
            "<error>**FAIL** — {d} of {d} tests failing</error>\n",
            .{ failed, passed + failed },
        );
    }

    try stdout_writer.end();
}
