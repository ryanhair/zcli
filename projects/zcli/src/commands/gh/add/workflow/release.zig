const std = @import("std");
const zcli = @import("zcli");

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
pub fn execute(_: Args, _: Options, context: anytype) !void {
    var stdout = context.stdout();
    const io = context.io;

    const outcome = try writeReleaseWorkflow(std.Io.Dir.cwd(), io);
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

const WorkflowOutcome = enum { created, not_a_project, already_exists };

/// Writes the release workflow into `dir`. Takes `dir` explicitly (rather
/// than hardcoding `std.Io.Dir.cwd()`) so it can be exercised against a
/// scratch directory in tests without touching the real repo.
fn writeReleaseWorkflow(dir: std.Io.Dir, io: std.Io) !WorkflowOutcome {
    dir.access(io, "src/commands", .{}) catch return .not_a_project;

    dir.createDir(io, ".github", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    dir.createDir(io, ".github/workflows", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    if (dir.access(io, ".github/workflows/release.yml", .{})) {
        return .already_exists;
    } else |err| switch (err) {
        error.FileNotFound => {}, // Good, safe to create
        else => return err,
    }

    var workflow_file = try dir.createFile(io, ".github/workflows/release.yml", .{});
    defer workflow_file.close(io);
    try workflow_file.writeStreamingAll(io, workflow_content);

    return .created;
}

// Generate workflow content
const workflow_content =
    \\name: Release
    \\
    \\# Actions are pinned to full commit SHAs (with the version as a comment)
    \\# so a moved or compromised tag can't change what runs in this workflow.
    \\# When upgrading an action, update the SHA and the comment together.
    \\
    \\on:
    \\  push:
    \\    tags:
    \\      - '*-v*'
    \\
    \\jobs:
    \\  build:
    \\    name: Build ${{ matrix.target }}
    \\    runs-on: ${{ matrix.os }}
    \\    strategy:
    \\      matrix:
    \\        include:
    \\          - os: ubuntu-latest
    \\            target: x86_64-linux
    \\            zig_target: x86_64-linux-musl
    \\          - os: ubuntu-latest
    \\            target: aarch64-linux
    \\            zig_target: aarch64-linux-musl
    \\          - os: macos-latest
    \\            target: x86_64-macos
    \\            zig_target: x86_64-macos
    \\          - os: macos-latest
    \\            target: aarch64-macos
    \\            zig_target: aarch64-macos
    \\
    \\    steps:
    \\      - name: Checkout code
    \\        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1
    \\
    \\      - name: Setup Zig
    \\        uses: mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29 # v2.2.1
    \\        with:
    \\          version: 0.16.0
    \\
    \\      - name: Build binary
    \\        # ReleaseSafe keeps runtime safety checks (bounds/overflow) in a
    \\        # binary that parses untrusted input; -Dstrip=true drops debug info,
    \\        # which dominates size. If your build.zig predates the `strip`
    \\        # option, add: b.option(bool, "strip", "...") and `.strip = strip`
    \\        # on the exe module.
    \\        run: zig build -Doptimize=ReleaseSafe -Dstrip=true -Dtarget=${{ matrix.zig_target }}
    \\
    \\      - name: Get app name from build.zig.zon
    \\        id: appname
    \\        run: |
    \\          # Extract .name from build.zig.zon (handles both quoted strings and identifiers)
    \\          NAME_LINE=$(grep -m1 '\.name = ' build.zig.zon)
    \\          if [[ "$NAME_LINE" =~ \.name\ =\ \"([^\"]+)\" ]]; then
    \\            APP_NAME="${BASH_REMATCH[1]}"
    \\          elif [[ "$NAME_LINE" =~ \.name\ =\ \.([^,}\ ]+) ]]; then
    \\            APP_NAME="${BASH_REMATCH[1]}"
    \\          else
    \\            echo "Error: Could not parse .name from build.zig.zon"
    \\            exit 1
    \\          fi
    \\          echo "name=$APP_NAME" >> $GITHUB_OUTPUT
    \\
    \\      - name: Package binary
    \\        run: |
    \\          mkdir -p dist
    \\          cp zig-out/bin/${{ steps.appname.outputs.name }} dist/${{ steps.appname.outputs.name }}-${{ matrix.target }}
    \\          chmod +x dist/${{ steps.appname.outputs.name }}-${{ matrix.target }}
    \\
    \\      - name: Generate checksum
    \\        run: |
    \\          cd dist
    \\          shasum -a 256 ${{ steps.appname.outputs.name }}-${{ matrix.target }} > ${{ steps.appname.outputs.name }}-${{ matrix.target }}.sha256
    \\
    \\      - name: Upload artifact
    \\        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
    \\        with:
    \\          name: ${{ steps.appname.outputs.name }}-${{ matrix.target }}
    \\          path: |
    \\            dist/${{ steps.appname.outputs.name }}-${{ matrix.target }}
    \\            dist/${{ steps.appname.outputs.name }}-${{ matrix.target }}.sha256
    \\
    \\  release:
    \\    name: Create Release
    \\    needs: build
    \\    runs-on: ubuntu-latest
    \\    permissions:
    \\      contents: write
    \\
    \\    steps:
    \\      - name: Checkout code
    \\        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1
    \\
    \\      - name: Download all artifacts
    \\        uses: actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093 # v4.3.0
    \\        with:
    \\          path: dist
    \\
    \\      - name: Flatten artifact structure
    \\        run: |
    \\          mkdir -p release
    \\          find dist -type f \( -name '*-x86_64-*' -o -name '*-aarch64-*' \) -exec cp {} release/ \;
    \\          ls -la release/
    \\
    \\      - name: Create checksums file
    \\        run: |
    \\          cd release
    \\          cat *.sha256 > checksums.txt
    \\          rm *.sha256
    \\
    \\      - name: Create Release
    \\        uses: softprops/action-gh-release@3bb12739c298aeb8a4eeaf626c5b8d85266b0e65 # v2.6.2
    \\        with:
    \\          files: release/*
    \\          generate_release_notes: true
    \\          draft: false
    \\          prerelease: false
    \\        env:
    \\          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    \\
;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "writeReleaseWorkflow fails outside a zcli project" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const outcome = try writeReleaseWorkflow(tmp.dir, io);
    try testing.expectEqual(WorkflowOutcome.not_a_project, outcome);
}

test "writeReleaseWorkflow creates a pinned, version-matched workflow" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "src", .default_dir);
    try tmp.dir.createDir(io, "src/commands", .default_dir);

    const outcome = try writeReleaseWorkflow(tmp.dir, io);
    try testing.expectEqual(WorkflowOutcome.created, outcome);

    const content = try tmp.dir.readFileAlloc(io, ".github/workflows/release.yml", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "name: Release") != null);
    // Every `uses:` action must be pinned to a full commit SHA (with the
    // version as a trailing comment), never a mutable tag.
    try testing.expect(std.mem.indexOf(u8, content, "actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1") != null);
    try testing.expect(std.mem.indexOf(u8, content, "mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29 # v2.2.1") != null);
    try testing.expect(std.mem.indexOf(u8, content, "version: 0.16.0") != null);
    try testing.expect(std.mem.indexOf(u8, content, "-Dstrip=true") != null);
}

test "writeReleaseWorkflow refuses to overwrite an existing workflow" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "src", .default_dir);
    try tmp.dir.createDir(io, "src/commands", .default_dir);
    try tmp.dir.createDir(io, ".github", .default_dir);
    try tmp.dir.createDir(io, ".github/workflows", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = ".github/workflows/release.yml", .data = "custom content\n" });

    const outcome = try writeReleaseWorkflow(tmp.dir, io);
    try testing.expectEqual(WorkflowOutcome.already_exists, outcome);

    const content = try tmp.dir.readFileAlloc(io, ".github/workflows/release.yml", testing.allocator, .limited(4096));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("custom content\n", content);
}
