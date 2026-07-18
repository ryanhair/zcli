const std = @import("std");
const zcli = @import("zcli");
const scaffold = @import("scaffold");

pub const meta = .{
    .description = "Add GitHub Actions workflow for building and releasing binaries",
    .examples = &.{
        "gh add workflow release",
    },
};

pub const Args = struct {};

pub const Options = struct {};

// Convention: this command takes `context: anytype` (not `*Context`) so tests
// can pass a lightweight stub instead of a full app registry; commands that
// don't need that testability use `*Context` for the compile-time contract.
// The workflow content and write logic live in scaffold/workflows.zig, shared
// with `zcli init`'s extras step (ADR-0028) and `gh add workflow ci`.
pub fn execute(_: Args, _: Options, context: anytype) !void {
    var stdout = context.stdout();
    const io = context.io;

    const outcome = try scaffold.workflows.write(std.Io.Dir.cwd(), io, "release.yml", scaffold.workflows.release_yml);
    switch (outcome) {
        .not_a_project => return context.fail("Error: Not in a zcli project directory\nRun this command from the root of your zcli project (where build.zig is)", .{}),
        .already_exists => return context.fail("Error: .github/workflows/release.yml already exists\nRemove it first if you want to regenerate it", .{}),
        .created => {},
    }

    try stdout.print("Creating GitHub Actions release workflow...\n", .{});
    try stdout.print("✓ Created .github/workflows/release.yml\n\n", .{});
    try stdout.print("Next steps:\n", .{});
    try stdout.print("  1. Commit and push the workflow file:\n", .{});
    try stdout.print("     git add .github/workflows/release.yml\n", .{});
    try stdout.print("     git commit -m \"Add GitHub release workflow\"\n", .{});
    try stdout.print("     git push\n\n", .{});
    try stdout.print("  2. Create and push your first release using the zcli release command:\n", .{});
    try stdout.print("     zcli release 0.1.0   # Create initial release\n", .{});
    try stdout.print("     # Or specify a bump type:\n", .{});
    try stdout.print("     zcli release patch   # 0.1.0 → 0.1.1\n", .{});
    try stdout.print("     zcli release minor   # 0.1.0 → 0.2.0\n", .{});
    try stdout.print("     zcli release major   # 0.1.0 → 1.0.0\n\n", .{});
    try stdout.print("  3. Monitor builds at:\n", .{});
    try stdout.print("     https://github.com/YOUR_USERNAME/YOUR_REPO/actions\n\n", .{});
}
