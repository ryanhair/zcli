//! GitHub Actions workflow scaffolds, shared by the `gh add workflow ...`
//! commands and `zcli init`'s extras step (ADR-0028 increment 5). Command
//! modules can't import each other, so the content and the write logic live
//! here in the `scaffold` shared module.
//!
//! Actions are pinned to full commit SHAs (with the version as a comment) so
//! a moved or compromised tag can't change what runs — when upgrading an
//! action, update the SHA and the comment together, in every workflow here.

const std = @import("std");

pub const Outcome = enum { created, not_a_project, already_exists };

/// Write one workflow file into `dir`'s .github/workflows/, creating the
/// directories as needed. Refuses to overwrite an existing file and refuses
/// to run outside a zcli project (no src/commands). Takes `dir` explicitly
/// so tests exercise a scratch directory.
pub fn write(dir: std.Io.Dir, io: std.Io, file_name: []const u8, content: []const u8) !Outcome {
    dir.access(io, "src/commands", .{}) catch return .not_a_project;

    dir.createDir(io, ".github", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    dir.createDir(io, ".github/workflows", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var path_buf: [128]u8 = undefined;
    const sub_path = try std.fmt.bufPrint(&path_buf, ".github/workflows/{s}", .{file_name});

    if (dir.access(io, sub_path, .{})) {
        return .already_exists;
    } else |err| switch (err) {
        error.FileNotFound => {}, // Good, safe to create
        else => return err,
    }

    var file = try dir.createFile(io, sub_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);

    return .created;
}

/// CI: build + unit tests on every push/PR. Deliberately minimal — one job,
/// ubuntu only; a project that needs a matrix grows one itself.
pub const ci_yml =
    \\name: CI
    \\
    \\# Actions are pinned to full commit SHAs (with the version as a comment)
    \\# so a moved or compromised tag can't change what runs in this workflow.
    \\# When upgrading an action, update the SHA and the comment together.
    \\
    \\on:
    \\  push:
    \\    branches: [main]
    \\  pull_request:
    \\
    \\jobs:
    \\  test:
    \\    name: Build and test
    \\    runs-on: ubuntu-latest
    \\    steps:
    \\      - name: Checkout code
    \\        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1
    \\
    \\      - name: Setup Zig
    \\        uses: mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29 # v2.2.1
    \\        with:
    \\          version: 0.16.0
    \\
    \\      - name: Build
    \\        run: zig build
    \\
    \\      - name: Test
    \\        run: zig build test
    \\
;

/// Release: cross-compile on tag push, checksum, and publish a GitHub
/// release with the binaries attached.
pub const release_yml =
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

test "write fails outside a zcli project" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expectEqual(Outcome.not_a_project, try write(tmp.dir, io, "release.yml", release_yml));
}

test "write creates a pinned, version-matched release workflow" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "src", .default_dir);
    try tmp.dir.createDir(io, "src/commands", .default_dir);

    try testing.expectEqual(Outcome.created, try write(tmp.dir, io, "release.yml", release_yml));

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

test "write creates the CI workflow with pinned actions" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "src", .default_dir);
    try tmp.dir.createDir(io, "src/commands", .default_dir);

    try testing.expectEqual(Outcome.created, try write(tmp.dir, io, "ci.yml", ci_yml));

    const content = try tmp.dir.readFileAlloc(io, ".github/workflows/ci.yml", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "name: CI") != null);
    try testing.expect(std.mem.indexOf(u8, content, "actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1") != null);
    try testing.expect(std.mem.indexOf(u8, content, "zig build test") != null);
}

test "write refuses to overwrite an existing workflow" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "src", .default_dir);
    try tmp.dir.createDir(io, "src/commands", .default_dir);
    try tmp.dir.createDir(io, ".github", .default_dir);
    try tmp.dir.createDir(io, ".github/workflows", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = ".github/workflows/release.yml", .data = "custom content\n" });

    try testing.expectEqual(Outcome.already_exists, try write(tmp.dir, io, "release.yml", release_yml));

    const content = try tmp.dir.readFileAlloc(io, ".github/workflows/release.yml", testing.allocator, .limited(4096));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("custom content\n", content);
}
