const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Add GitHub Actions workflow for building and releasing binaries",
    .examples = &.{
        "add gh workflow release",
    },
};

pub const Args = struct {};

pub const Options = struct {};

pub fn execute(_: Args, _: Options, context: *zcli.Context) !void {
    const stdout = context.stdout();
    const stderr = context.stderr();

    // Verify we're in a zcli project
    const cwd = std.fs.cwd();
    cwd.access("src/commands", .{}) catch {
        try stderr.print("Error: Not in a zcli project directory\n", .{});
        try stderr.print("Run this command from the root of your zcli project (where build.zig is)\n", .{});
        return error.NotInZcliProject;
    };

    // Create .github/workflows directory
    cwd.makeDir(".github") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    cwd.makeDir(".github/workflows") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Check if workflow already exists
    cwd.access(".github/workflows/release.yml", .{}) catch |err| switch (err) {
        error.FileNotFound => {}, // Good
        else => {
            try stderr.print("Error: .github/workflows/release.yml already exists\n", .{});
            return err;
        },
    };

    try stdout.print("Creating GitHub Actions release workflow...\n", .{});

    // Generate workflow content
    const workflow_content =
        \\name: Release
        \\
        \\on:
        \\  push:
        \\    tags:
        \\      - 'v*'
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
        \\        uses: actions/checkout@v4
        \\
        \\      - name: Setup Zig
        \\        uses: goto-bus-stop/setup-zig@v2
        \\        with:
        \\          version: 0.14.1
        \\
        \\      - name: Build binary
        \\        run: zig build -Doptimize=ReleaseFast -Dtarget=${{ matrix.zig_target }}
        \\
        \\      - name: Get app name from build.zig
        \\        id: appname
        \\        run: |
        \\          APP_NAME=$(grep '\.name = ' build.zig | head -1 | sed 's/.*"\(.*\)".*/\1/')
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
        \\        uses: actions/upload-artifact@v4
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
        \\        uses: actions/checkout@v4
        \\
        \\      - name: Download all artifacts
        \\        uses: actions/download-artifact@v4
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
        \\        uses: softprops/action-gh-release@v1
        \\        with:
        \\          files: release/*
        \\          generate_release_notes: true
        \\          draft: false
        \\          prerelease: false
        \\        env:
        \\          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        \\
    ;

    var workflow_file = try cwd.createFile(".github/workflows/release.yml", .{});
    defer workflow_file.close();
    try workflow_file.writeAll(workflow_content);

    try stdout.print("✓ Created .github/workflows/release.yml\n\n", .{});
    try stdout.print("Next steps:\n", .{});
    try stdout.print("  1. Commit and push the workflow file:\n", .{});
    try stdout.print("     git add .github/workflows/release.yml\n", .{});
    try stdout.print("     git commit -m \"Add GitHub release workflow\"\n", .{});
    try stdout.print("     git push\n\n", .{});
    try stdout.print("  2. Create your first release tag:\n", .{});
    try stdout.print("     git tag -a v0.1.0 -m \"Initial release\"\n", .{});
    try stdout.print("     git push origin v0.1.0\n\n", .{});
    try stdout.print("  3. For subsequent releases, use the zcli release command:\n", .{});
    try stdout.print("     zcli release patch   # 0.1.0 → 0.1.1\n", .{});
    try stdout.print("     zcli release minor   # 0.1.0 → 0.2.0\n", .{});
    try stdout.print("     zcli release major   # 0.1.0 → 1.0.0\n\n", .{});
    try stdout.print("  4. Monitor builds at:\n", .{});
    try stdout.print("     https://github.com/YOUR_USERNAME/YOUR_REPO/actions\n\n", .{});
}
