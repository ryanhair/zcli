const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Build an image from a Dockerfile",
    .usage = "image build [OPTIONS] PATH | URL | -",
    .examples = &.{
        "image build .",
        "image build --tag my-app:latest .",
        "image build --file Dockerfile.prod --tag my-app:prod .",
        "image build --build-arg NODE_VERSION=16 --tag my-app .",
        "image build --no-cache --tag my-app .",
    },
    .args = .{
        .context = "Build context (directory, URL, or '-' for stdin)",
    },
    .options = .{
        .tag = .{ .desc = "Name and optionally tag in 'name:tag' format", .short = 't' },
        .file = .{ .desc = "Name of the Dockerfile (default: 'PATH/Dockerfile')", .short = 'f' },
        .build_arg = .{ .desc = "Set build-time variables (can be used multiple times)" },
        .target = .{ .desc = "Set the target build stage to build" },
        .no_cache = .{ .desc = "Do not use cache when building the image" },
        .pull = .{ .desc = "Always attempt to pull a newer version of the image" },
        .quiet = .{ .desc = "Suppress the build output and print image ID on success", .short = 'q' },
        .rm = .{ .desc = "Remove intermediate containers after a successful build (default true)" },
        .force_rm = .{ .desc = "Always remove intermediate containers" },
        .squash = .{ .desc = "Squash newly built layers into a single new layer" },
        .platform = .{ .desc = "Set platform if server is multi-platform capable" },
        .progress = .{ .desc = "Set type of progress output (auto, plain, tty)" },
    },
};

pub const Args = struct {
    context: []const u8 = ".",
};

pub const Options = struct {
    tag: []const []const u8 = &.{},
    file: ?[]const u8 = null,
    build_arg: []const []const u8 = &.{},
    target: ?[]const u8 = null,
    no_cache: bool = false,
    pull: bool = false,
    quiet: bool = false,
    rm: bool = true,
    force_rm: bool = false,
    squash: bool = false,
    platform: ?[]const u8 = null,
    progress: enum { auto, plain, tty } = .auto,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    if (!options.quiet) {
        try context.stdout().print("Building image from context: {s}\n", .{args.context});

        const dockerfile = options.file orelse "Dockerfile";
        try context.stdout().print("Using Dockerfile: {s}\n", .{dockerfile});

        if (options.no_cache) {
            try context.stdout().print("Building without cache\n", .{});
        }

        if (options.pull) {
            try context.stdout().print("Pulling base images\n", .{});
        }

        if (options.build_arg.len > 0) {
            try context.stdout().print("Build arguments:\n", .{});
            for (options.build_arg) |arg| {
                try context.stdout().print("  {s}\n", .{arg});
            }
        }

        if (options.target) |target| {
            try context.stdout().print("Target stage: {s}\n", .{target});
        }

        if (options.platform) |platform| {
            try context.stdout().print("Platform: {s}\n", .{platform});
        }

        // Simulate build steps
        try context.stdout().print("\nStep 1/5 : FROM node:16-alpine\n", .{});
        try context.stdout().print(" ---> a1b2c3d4e5f6\n", .{});
        try context.stdout().print("Step 2/5 : WORKDIR /app\n", .{});
        try context.stdout().print(" ---> Running in b2c3d4e5f6a1\n", .{});
        try context.stdout().print(" ---> c3d4e5f6a1b2\n", .{});
        try context.stdout().print("Step 3/5 : COPY package*.json ./\n", .{});
        try context.stdout().print(" ---> d4e5f6a1b2c3\n", .{});
        try context.stdout().print("Step 4/5 : RUN npm install\n", .{});
        try context.stdout().print(" ---> Running in e5f6a1b2c3d4\n", .{});
        try context.stdout().print(" ---> f6a1b2c3d4e5\n", .{});
        try context.stdout().print("Step 5/5 : COPY . .\n", .{});
        try context.stdout().print(" ---> a1b2c3d4e5f6\n", .{});
        try context.stdout().print("Successfully built a1b2c3d4e5f6\n", .{});
    }

    // Generate image ID
    const image_id = "sha256:a1b2c3d4e5f6789abcdef0123456789abcdef0123456789abcdef0123456789a";

    if (options.tag.len > 0) {
        for (options.tag) |tag| {
            if (options.quiet) {
                try context.stdout().print("{s}\n", .{image_id});
            } else {
                try context.stdout().print("Successfully tagged {s}\n", .{tag});
            }
        }
    } else if (options.quiet) {
        try context.stdout().print("{s}\n", .{image_id});
    }

    if (options.squash and !options.quiet) {
        try context.stdout().print("Squashed image layers into single layer\n", .{});
    }
}
