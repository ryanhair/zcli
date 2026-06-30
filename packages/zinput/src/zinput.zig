//! zinput — Interactive terminal prompts for CLI applications.
//!
//! Standalone library: works with any writer/reader, no zcli dependency required.
//! Falls back to line-based input when stdin is not a TTY.
//!
//! ```zig
//! const zinput = @import("zinput");
//!
//! const name = try zinput.text(writer, reader, allocator, .{ .message = "Name:" });
//! const ok = try zinput.confirm(writer, reader, .{ .message = "Continue?" });
//! const idx = try zinput.select(writer, reader, .{ .message = "Pick:", .choices = &.{"a", "b"} });
//! ```

const std = @import("std");
pub const terminal = @import("terminal");

pub const text_prompt = @import("text.zig");
pub const confirm_prompt = @import("confirm.zig");
pub const select_prompt = @import("select.zig");
pub const multi_select_prompt = @import("multi_select.zig");
pub const password_prompt = @import("password.zig");
pub const search_prompt = @import("search.zig");
pub const number_prompt = @import("number.zig");
pub const editor_prompt = @import("editor.zig");

// Re-export main functions
pub const text = text_prompt.text;
pub const confirm = confirm_prompt.confirm;
pub const select = select_prompt.select;
pub const multiSelect = multi_select_prompt.multiSelect;
pub const password = password_prompt.password;
pub const search = search_prompt.search;
pub const number = number_prompt.number;
pub const editor = editor_prompt.editor;

/// Flush a writer if it supports flushing. Works with both pointer and value writer types.
pub fn flushWriter(writer: anytype) void {
    const W = @TypeOf(writer);
    const T = if (@typeInfo(W) == .pointer) @typeInfo(W).pointer.child else W;
    if (@hasDecl(T, "flush")) {
        writer.flush() catch {};
    }
}

// Re-export config types
pub const TextConfig = text_prompt.TextConfig;
pub const Preview = text_prompt.Preview;
pub const ConfirmConfig = confirm_prompt.ConfirmConfig;
pub const SelectConfig = select_prompt.SelectConfig;
pub const MultiSelectConfig = multi_select_prompt.MultiSelectConfig;
pub const PasswordConfig = password_prompt.PasswordConfig;
pub const SearchConfig = search_prompt.SearchConfig;
pub const NumberConfig = number_prompt.NumberConfig;
pub const EditorConfig = editor_prompt.EditorConfig;

test {
    std.testing.refAllDecls(@This());
}
