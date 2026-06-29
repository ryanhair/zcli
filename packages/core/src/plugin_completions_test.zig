//! Tests for the zcli_completions shell-script generators (bash, zsh, fish).
//! These exercise the pure `generate()` functions: feed sample command/option
//! metadata in, assert the emitted script has the right structure and mentions
//! every command and flag.

const std = @import("std");
const zcli = @import("zcli");

const bash = @import("plugins/zcli_completions/bash.zig");
const zsh = @import("plugins/zcli_completions/zsh.zig");
const fish = @import("plugins/zcli_completions/fish.zig");

const app_name = "myapp";

const global_options = [_]zcli.OptionInfo{
    .{ .name = "verbose", .short = 'v', .description = "Verbose output" },
    .{ .name = "help", .short = 'h', .description = "Show help" },
};

const add_options = [_]zcli.OptionInfo{
    .{ .name = "priority", .short = 'p', .description = "Task priority", .takes_value = true },
    .{ .name = "force", .short = 'f', .description = "Skip confirmation" },
};

const commands = [_]zcli.CommandInfo{
    .{ .path = &.{"add"}, .description = "Add a task", .options = &add_options, .aliases = &.{"a"} },
    .{ .path = &.{"list"}, .description = "List tasks" },
    .{ .path = &.{ "sprint", "create" }, .description = "Create a sprint" },
};

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "bash.generate - produces a registered completion function mentioning all commands" {
    const script = try bash.generate(std.testing.allocator, app_name, &commands, &global_options);
    defer std.testing.allocator.free(script);

    try std.testing.expect(script.len > 0);
    // Completion function definition + registration.
    try std.testing.expect(contains(script, "_myapp_completions()"));
    try std.testing.expect(contains(script, "complete -F _myapp_completions myapp"));
    // Every command surfaces.
    try std.testing.expect(contains(script, "add"));
    try std.testing.expect(contains(script, "list"));
    try std.testing.expect(contains(script, "sprint"));
    // Global and per-command options surface.
    try std.testing.expect(contains(script, "--verbose"));
    try std.testing.expect(contains(script, "--priority"));
}

test "zsh.generate - produces a #compdef header and command function" {
    const script = try zsh.generate(std.testing.allocator, app_name, &commands, &global_options);
    defer std.testing.allocator.free(script);

    try std.testing.expect(script.len > 0);
    // zsh requires the #compdef directive on the first line.
    try std.testing.expect(std.mem.startsWith(u8, script, "#compdef myapp"));
    try std.testing.expect(contains(script, "_myapp()"));
    try std.testing.expect(contains(script, "add"));
    try std.testing.expect(contains(script, "list"));
}

test "fish.generate - emits complete directives with flags" {
    const script = try fish.generate(std.testing.allocator, app_name, &commands, &global_options);
    defer std.testing.allocator.free(script);

    try std.testing.expect(script.len > 0);
    try std.testing.expect(contains(script, "complete -c myapp"));
    // Long and short forms of an option.
    try std.testing.expect(contains(script, "-l priority"));
    try std.testing.expect(contains(script, "-s p"));
    // A value-taking option is marked requires-argument (-r).
    try std.testing.expect(contains(script, "-r"));
}

test "generators - hidden commands are excluded" {
    const hidden_commands = [_]zcli.CommandInfo{
        .{ .path = &.{"visible"}, .description = "Shown" },
        .{ .path = &.{"secret"}, .description = "Hidden", .hidden = true },
    };

    const script = try bash.generate(std.testing.allocator, app_name, &hidden_commands, &global_options);
    defer std.testing.allocator.free(script);

    try std.testing.expect(contains(script, "visible"));
    try std.testing.expect(!contains(script, "secret"));
}

test "generators - empty command set still yields a valid script skeleton" {
    const empty = [_]zcli.CommandInfo{};
    const script = try bash.generate(std.testing.allocator, app_name, &empty, &global_options);
    defer std.testing.allocator.free(script);

    try std.testing.expect(contains(script, "_myapp_completions()"));
    try std.testing.expect(contains(script, "--verbose"));
}
