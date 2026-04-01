const std = @import("std");
const zcli = @import("zcli");
const zprogress = zcli.zprogress;

pub const meta = .{
    .description = "Simulate file downloads with progress indicators",
    .examples = &.{
        "zpdemo download                    # Simulate downloading files",
        "zpdemo download --files 5          # Download 5 files",
        "zpdemo download --size 1000        # Each file is 1000 KB",
    },
    .options = .{
        .files = .{ .description = "Number of files to download" },
        .size = .{ .description = "Size of each file in KB" },
    },
};

pub const Args = struct {};

pub const Options = struct {
    files: u32 = 3,
    size: u32 = 500,
};

pub fn execute(_: Args, options: Options, context: anytype) !void {
    const stdout = context.stdout();

    try stdout.print("Download Simulation\n", .{});
    try stdout.print("===================\n\n", .{});

    // Simulate downloading multiple files
    const file_names = [_][]const u8{
        "package-core.tar.gz",
        "runtime-libs.zip",
        "documentation.pdf",
        "assets-bundle.tar",
        "source-code.tar.gz",
        "dependencies.lock",
        "config-files.zip",
        "test-data.json",
    };

    var total_downloaded: u64 = 0;
    const files_to_download = @min(options.files, file_names.len);

    for (0..files_to_download) |i| {
        const file_name = file_names[i];
        const size = options.size;

        downloadFile(file_name, size);
        total_downloaded += size;
    }

    try stdout.print("\nDownload complete!\n", .{});
    try stdout.print("Total: {d} files, {d} KB\n", .{ files_to_download, total_downloaded });
}

fn downloadFile(file_name: []const u8, size_kb: u32) void {
    // Phase 1: Connecting spinner
    var spinner = zprogress.spinner(.{
        .style = .dots,
    });

    var connect_msg: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&connect_msg, "Connecting to download {s}...", .{file_name}) catch "Connecting...";
    spinner.start(msg);

    // Simulate connection delay (300-700ms)
    const connect_time: i64 = 300 + @mod(std.time.timestamp(), 400);
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < connect_time) {
        spinner.tick();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    spinner.succeed("Connected");

    // Phase 2: Downloading with progress bar
    const chunks = size_kb / 10; // 10 KB chunks
    var bar = zprogress.progressBar(.{
        .total = chunks,
        .width = 35,
        .show_eta = true,
        .show_rate = true,
    });

    var download_msg: [128]u8 = undefined;
    const dl_msg = std.fmt.bufPrint(&download_msg, "Downloading {s}", .{file_name}) catch "Downloading";
    bar.setMessage(dl_msg);

    var chunk: usize = 0;
    while (chunk < chunks) : (chunk += 1) {
        bar.update(chunk + 1, null);
        // Variable download speed
        const delay: u64 = 20 + (chunk % 40);
        std.Thread.sleep(delay * std.time.ns_per_ms);
    }

    var finish_msg: [128]u8 = undefined;
    const f_msg = std.fmt.bufPrint(&finish_msg, "{s} ({d} KB)", .{ file_name, size_kb }) catch "Complete";
    bar.finishWithMessage(f_msg);
}
