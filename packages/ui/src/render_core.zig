//! RenderCore: the pure render pipeline state — the double-buffered surfaces
//! a frame renders into and diffs against (ADR-0013). No terminal state, no
//! cursor, no scrollback: given a laid-out node and a writer, it paints the
//! minimal byte stream and swaps the buffers. Everything here is exercised
//! headlessly; the terminal-owning pieces live in `TerminalSession` and the
//! orchestration in `App`.
//!
//! Byte-stream contract: `frame` and `repaint` hand the writer to
//! `diff.Renderer`, whose addressing assumes the cursor is parked at column 0
//! of the region's top row — `RegionCursor` owns that invariant; `App`
//! asserts it before calling in.

const std = @import("std");
const surface_mod = @import("surface.zig");
const node_mod = @import("node.zig");
const diff_mod = @import("diff.zig");

const Surface = surface_mod.Surface;
const Node = node_mod.Node;
const RenderCtx = node_mod.RenderCtx;

pub const RenderCore = struct {
    /// What the terminal currently shows (diff source).
    front: Surface,
    /// The paint target.
    back: Surface,
    /// Whether `front` matches what's on screen (false forces a full paint).
    front_valid: bool = false,

    pub fn init(gpa: std.mem.Allocator) !RenderCore {
        var front = try Surface.init(gpa, 0, 0);
        errdefer front.deinit();
        return .{
            .front = front,
            .back = try Surface.init(gpa, 0, 0),
        };
    }

    pub fn deinit(self: *RenderCore) void {
        self.front.deinit();
        self.back.deinit();
    }

    /// The screen no longer matches `front` (the region was erased or
    /// scrolled): the next `frame` must paint from scratch.
    pub fn invalidate(self: *RenderCore) void {
        self.front_valid = false;
    }

    /// Resize both buffers to the frame's size. A size change invalidates —
    /// the diff renderer treats mismatched surfaces as a full repaint anyway,
    /// and the region rows on screen are re-reserved by the caller.
    pub fn setSize(self: *RenderCore, w: u16, h: u16) !void {
        if (w == self.back.width and h == self.back.height) return;
        try self.back.resize(w, h);
        try self.front.resize(w, h);
        self.front_valid = false;
    }

    /// Render `node` into the back buffer, paint the diff against the front,
    /// and swap. Emits zero bytes for an unchanged frame.
    pub fn frame(
        self: *RenderCore,
        writer: *std.Io.Writer,
        rctx: *const RenderCtx,
        node: *const Node,
        renderer: diff_mod.Renderer,
    ) !void {
        self.back.clear();
        try node_mod.render(rctx, node, self.back.root());
        const prev: ?*const Surface = if (self.front_valid) &self.front else null;
        try renderer.paint(writer, prev, &self.back);
        std.mem.swap(Surface, &self.front, &self.back);
        self.front_valid = true;
    }

    /// Fully repaint the last frame (`front`) assuming nothing about the
    /// screen — after `emit` erased the region out from under it.
    pub fn repaint(self: *RenderCore, writer: *std.Io.Writer, renderer: diff_mod.Renderer) !void {
        try renderer.paint(writer, null, &self.front);
        self.front_valid = true;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const theme = @import("theme");

fn textNode(content: []const u8) Node {
    return .{ .kind = .{ .text = .{ .content = content, .style = .{} } } };
}

test "second frame diffs against the first; unchanged frame emits zero bytes" {
    var core = try RenderCore.init(testing.allocator);
    defer core.deinit();
    try core.setSize(10, 1);

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rctx = RenderCtx{ .allocator = arena.allocator(), .unicode = true };
    const renderer = diff_mod.Renderer{ .capability = .ansi_16, .sync = false };

    const n = textNode("hello");
    try core.frame(&aw.writer, &rctx, &n, renderer);
    const first_len = aw.written().len;
    try testing.expect(first_len > 0);

    // Identical frame: the diff finds nothing to paint.
    try core.frame(&aw.writer, &rctx, &n, renderer);
    try testing.expectEqual(first_len, aw.written().len);
}

test "invalidate forces the next frame to repaint in full" {
    var core = try RenderCore.init(testing.allocator);
    defer core.deinit();
    try core.setSize(10, 1);

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rctx = RenderCtx{ .allocator = arena.allocator(), .unicode = true };
    const renderer = diff_mod.Renderer{ .capability = .ansi_16, .sync = false };

    const n = textNode("hello");
    try core.frame(&aw.writer, &rctx, &n, renderer);
    aw.clearRetainingCapacity();

    core.invalidate();
    try core.frame(&aw.writer, &rctx, &n, renderer);
    // Not the zero-byte unchanged-diff path: the full row was repainted.
    try testing.expect(std.mem.indexOf(u8, aw.written(), "hello") != null);
}

test "setSize to the same size preserves the diff source" {
    var core = try RenderCore.init(testing.allocator);
    defer core.deinit();
    try core.setSize(10, 1);
    core.front_valid = true;
    try core.setSize(10, 1);
    try testing.expect(core.front_valid);
    try core.setSize(12, 1);
    try testing.expect(!core.front_valid);
}
