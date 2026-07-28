#!/usr/bin/env bash
set -euo pipefail

# Generate a synthetic zcli app with N top-level commands, for the comptime
# scaling gate (#730).
#
# A zcli app's whole command registry is one comptime fold in the generated
# zcli_generated.zig, sharing one `@setEvalBranchQuota` budget. Before #730 that
# budget ran out at 28 top-level commands — below git, docker, kubectl, and gh —
# and the app author had no escape hatch, because the file that needed the
# quota is framework-generated. The ceiling was invisible until someone hit it,
# so CI now compiles a project past it on every change to the framework
# (.github/workflows/ci.yml → registry-scale).
#
# Usage: scripts/gen-scale-project.sh <command-count> <output-dir>
#
# The generated project path-depends on THIS checkout, so it exercises the
# working tree rather than a published release. Run it by hand to reproduce a
# scaling failure locally:
#
#   scripts/gen-scale-project.sh 120 /tmp/zcli-scale && \
#     (cd /tmp/zcli-scale && zig build)

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <command-count> <output-dir>" >&2
  exit 2
fi

count="$1"
out="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

rm -rf "$out"
mkdir -p "$out/src/commands"

# Relative, because Zig rejects an absolute `.path` dependency.
rel_root="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' \
  "$repo_root" "$(cd "$out" && pwd)")"

cat > "$out/build.zig" <<'EOF'
const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zcli_dep = b.dependency("zcli", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "scale",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zcli", zcli_dep.module("zcli"));

    const zcli = @import("zcli");

    const cmd_registry = try zcli.generate(b, exe, zcli_dep, .{
        .commands_dir = "src/commands",
        // The default builtin set an app scaffolded by `zcli init` gets, so the
        // gate measures the composition a real app compiles.
        .plugins = &.{
            zcli.builtin(.help, .{}),
            zcli.builtin(.version, .{}),
            zcli.builtin(.not_found, .{}),
            zcli.builtin(.completions, .{}),
        },
        .app_name = "scale",
        .app_description = "Synthetic registry scaling probe (#730)",
    });
    exe.root_module.addImport("command_registry", cmd_registry);

    b.installArtifact(exe);
}
EOF

# The fingerprint's high half is a checksum of the package name and its low half
# is an arbitrary id, so this literal stays valid on every machine as long as
# the name is `.scale`.
cat > "$out/build.zig.zon" <<EOF
.{
    .name = .scale,
    .version = "0.1.0",
    .fingerprint = 0xec462584ba3dd91e,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .zcli = .{ .path = "$rel_root" },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
EOF

cat > "$out/src/main.zig" <<'EOF'
const std = @import("std");
const zcli = @import("zcli");
const registry = @import("command_registry");

pub const std_options: std.Options = .{ .log_level = .warn };
pub const panic = zcli.ui.panic;
pub const debug = zcli.ui.debug;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var app = registry.init();
    app.run(init.gpa, init.io, init.environ_map, args) catch |err| switch (err) {
        error.CommandNotFound => std.process.exit(1),
        else => return err,
    };
}
EOF

# Each command carries the shapes the comptime passes actually walk: positional
# args, several options (one enum, so completions have choices to enumerate),
# `meta` with a description and examples, and an alias — a bare `execute` would
# understate the per-command comptime cost the quota has to cover.
for i in $(seq 1 "$count"); do
  cat > "$out/src/commands/cmd$i.zig" <<EOF
const std = @import("std");
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Synthetic command number $i",
    .examples = &.{ "cmd$i", "cmd$i target --count 3" },
    .aliases = &.{"c$i"},
};

pub const Args = struct {
    target: ?[]const u8 = null,
};

pub const Options = struct {
    verbose: bool = false,
    count: u32 = 1,
    label: []const u8 = "default",
    mode: enum { fast, slow } = .fast,
};

pub fn execute(args: Args, options: Options, context: *Context) !void {
    try context.stdout().print("cmd$i {s} {d} {s} {s} {}\n", .{
        args.target orelse "-",
        options.count,
        options.label,
        @tagName(options.mode),
        options.verbose,
    });
}
EOF
done

echo "generated $count-command project at $out (zcli path dep: $rel_root)"
