const std = @import("std");
const zcli = @import("zcli");
const scaffold = @import("scaffold");

pub const meta = .{
    .description = "Add GitHub Actions workflow that builds and tests on every push and PR",
    .examples = &.{
        "gh add workflow ci",
    },
};

pub const Args = struct {};

pub const Options = struct {};

// Convention: this command takes `context: anytype` (not `*Context`) so tests
// can pass a lightweight stub instead of a full app registry; commands that
// don't need that testability use `*Context` for the compile-time contract.
pub fn execute(_: Args, _: Options, context: anytype) !void {
    var stdout = context.stdout();
    const io = context.io;

    const outcome = try scaffold.workflows.write(std.Io.Dir.cwd(), io, "ci.yml", scaffold.workflows.ci_yml);
    switch (outcome) {
        .not_a_project => return context.fail("Error: Not in a zcli project directory\nRun this command from the root of your zcli project (where build.zig is)", .{}),
        .already_exists => return context.fail("Error: .github/workflows/ci.yml already exists\nRemove it first if you want to regenerate it", .{}),
        .created => {},
    }

    try stdout.print("Creating GitHub Actions CI workflow...\n", .{});
    try stdout.print("✓ Created .github/workflows/ci.yml\n\n", .{});
    try stdout.print("Next steps:\n", .{});
    try stdout.print("  Commit and push the workflow file:\n", .{});
    try stdout.print("     git add .github/workflows/ci.yml\n", .{});
    try stdout.print("     git commit -m \"Add CI workflow\"\n", .{});
    try stdout.print("     git push\n", .{});
}
