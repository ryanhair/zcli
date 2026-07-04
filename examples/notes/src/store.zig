//! store.zig — load and save notes as a JSON file, shared across commands.
//!
//! This is a shared module (see `zcli guide sharing`): every command imports
//! `store` and calls load()/save(), so persistence lives in exactly one place.
//! The on-disk format is whatever `std.json` makes of `Notes` — a typed struct
//! goes out, the same typed struct comes back, with no hand-written parsing.

const std = @import("std");

/// One saved note. Field names become the JSON object keys.
pub const Note = struct {
    title: []const u8,
    body: []const u8,
};

/// The whole file: a top-level object with a `notes` array. Defaulting every
/// field means an absent or empty file still decodes to a valid, empty value.
pub const Notes = struct {
    notes: []Note = &.{},
};

/// Where the data lives, relative to the current working directory.
pub const filename = "notes.json";

/// Load the notes file into `arena`-owned memory, or an empty set if it does
/// not exist yet. `io` is `context.io` (a `std.Io`) and `arena` is
/// `context.allocator`, so the result is reclaimed when the command ends —
/// never free it yourself (see `zcli guide arena`).
pub fn load(io: std.Io, arena: std.mem.Allocator) !Notes {
    const cwd = std.Io.Dir.cwd();
    const bytes = cwd.readFileAlloc(io, filename, arena, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{}, // first run — nothing saved yet
        else => return err,
    };
    // parseFromSlice fills a typed value directly — no walking a generic
    // `std.json.Value`. `.alloc_always` copies strings into the arena so they
    // outlive `bytes`; the parser's own arena is taken from `arena` too, so the
    // command arena reclaims all of it at once.
    const parsed = try std.json.parseFromSlice(Notes, arena, bytes, .{ .allocate = .alloc_always });
    return parsed.value;
}

/// Write `notes` back to disk as pretty-printed JSON. `std.json.fmt` renders
/// any value as JSON through the `{f}` format specifier — no manual string
/// building, no stringify call to look up.
pub fn save(io: std.Io, notes: Notes) !void {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, filename, .{}); // truncates and rewrites
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    try fw.interface.print("{f}", .{std.json.fmt(notes, .{ .whitespace = .indent_2 })});
    try fw.interface.flush(); // the file writer is buffered — flush before close
}

/// Find a note by title, or null if there isn't one.
pub fn find(notes: Notes, title: []const u8) ?Note {
    for (notes.notes) |note| {
        if (std.mem.eql(u8, note.title, title)) return note;
    }
    return null;
}
