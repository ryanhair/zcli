//! Startup-time and binary-size budgets for the shipped `zcli` binary.
//!
//! Run with `zig build budget -Doptimize=ReleaseSafe -Dstrip=true` (the exact
//! shape release.yml publishes), or from the repo root as part of
//! `zig build regression`.
//!
//! Why this lives here and not next to packages/core's parse benchmarks: those
//! measure the framework in-process, and neither startup nor binary size is
//! observable that way — both are properties of a linked, optimized artifact.
//! `projects/zcli` is the one place in the tree that produces one, and it
//! produces THE one: the binary users install.
//!
//! Both budgets are fail-closed. There is no "binary not found, skipping" path
//! and no environment flag that softens them, on the same reasoning as the
//! `ZCLI_REQUIRE_*` variables in ci.yml — a perf check that quietly no-ops is
//! strictly worse than no perf check, because it also removes the pressure to
//! notice it stopped working. That is precisely how the parse benchmarks
//! managed to not compile for an entire release era (#738).
//!
//! Build-time injected paths (see build.zig):
//!   - build_options.zcli_exe  absolute path to the built `zcli` binary

const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");

const io = testing.io;
const zcli_exe = build_options.zcli_exe;

// ============================================================================
// Budgets
// ============================================================================

/// Ceiling on the stripped ReleaseSafe binary, in bytes.
///
/// Measured: 2,030,216 bytes (macOS arm64, ReleaseSafe + strip); the static
/// musl Linux artifact the release ships is the same order (~2 MB, see
/// build.zig's strip comment). 4 MiB is a deliberate ~2x ceiling.
///
/// This is the load-bearing budget of the two, and the one to trust on a noisy
/// machine: binary size is *deterministic*. For a given Zig version, target and
/// optimize mode it does not vary run to run at all — no warm-up, no scheduler,
/// no co-tenant. It can be gated far more tightly than any timing, and 2x is
/// that tighter multiple: the only headroom it needs is for legitimate growth
/// between the day the budget is set and the day someone revisits it.
///
/// The regression it exists to catch is per-command binary growth (issue #730
/// measured 8-11 KB per command) and accidental linkage of something large.
/// Both blow past 2x long before they blow past 10x, and a 10x ceiling would
/// let the binary quadruple in silence.
///
/// Raising this is a legitimate outcome of a feature that needs the space —
/// but it should be a deliberate edit with a reason, which is the whole point
/// of it being a constant in a tracked file.
const max_binary_bytes: u64 = 4 * 1024 * 1024;

/// Ceiling on process startup: spawn `zcli --version`, wait for exit.
///
/// This is real end-to-end process time — fork/exec, dynamic loading, the
/// plugin pipeline, command lookup, exit — not in-process instrumentation of
/// the framework. Nothing about it is measured from inside the binary being
/// measured.
///
/// Measured: ~4 ms warm on an M-series dev box. PROVISIONAL: that box was
/// heavily loaded and had a wedged code-signing daemon stalling newly linked
/// binaries, so re-measure on an idle machine before tightening. The first
/// spawn after a build was ~300 ms (first-touch page-in plus code-signature
/// validation) against ~4 ms for every subsequent one, which is exactly why the
/// budget is applied to the MINIMUM of several runs rather than to the mean.
///
/// 100 ms is ~25x the observed warm figure, and deliberately loose. Timing on a
/// shared CI runner is the noisy case rather than the slow case: co-tenant CPU
/// steal can stretch any single spawn arbitrarily, and no percentile of a
/// 20-sample set is immune to that. The minimum is the right statistic here
/// because the fastest of N observations is the one least polluted by
/// interference, while a genuine regression — a network call at startup, eager
/// config I/O, a comptime table demoted to runtime initialization — raises the
/// floor along with everything else, so the minimum still moves. Treat the
/// size budget above as the primary gate and this as the coarse backstop.
const max_startup_ns: u64 = 100 * std.time.ns_per_ms;

/// How many spawns to take the minimum over. Enough that at least one lands in
/// a quiet slice on a busy runner; small enough to stay well under a second.
const startup_samples = 20;

// ============================================================================
// Tests
// ============================================================================

test "binary size stays within budget" {
    const stat = std.Io.Dir.cwd().statFile(io, zcli_exe, .{}) catch |err| {
        std.debug.print(
            "budget: cannot stat the zcli binary at '{s}': {t}\n" ++
                "The budget step depends on the install step, so a missing binary means the\n" ++
                "build wiring broke, not that the check should be skipped.\n",
            .{ zcli_exe, err },
        );
        return err;
    };

    std.debug.print("binary size: {d} bytes (budget {d})\n", .{ stat.size, max_binary_bytes });
    if (stat.size > max_binary_bytes) {
        std.debug.print(
            "budget: '{s}' is {d} bytes, over the {d}-byte ceiling.\n" ++
                "Either the growth is unintended (find it), or it is justified and\n" ++
                "max_binary_bytes in this file needs a deliberate bump with a reason.\n",
            .{ zcli_exe, stat.size, max_binary_bytes },
        );
        return error.BinarySizeBudgetExceeded;
    }
}

test "startup time stays within budget" {
    var min_ns: u64 = std.math.maxInt(u64);

    for (0..startup_samples) |_| {
        const start = std.Io.Clock.awake.now(io);

        // `--version` is the cheapest real dispatch: full process start, plugin
        // pipeline, and command lookup, with no filesystem or network work of
        // its own. Anything that creeps into startup shows up here.
        var child = try std.process.spawn(io, .{
            .argv = &.{ zcli_exe, "--version" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        const term = try child.wait(io);

        const elapsed: u64 = @intCast(@max(0, start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds));
        min_ns = @min(min_ns, elapsed);

        switch (term) {
            .exited => |code| if (code != 0) {
                std.debug.print("budget: `zcli --version` exited {d}\n", .{code});
                return error.VersionCommandFailed;
            },
            else => {
                std.debug.print("budget: `zcli --version` did not exit normally\n", .{});
                return error.VersionCommandFailed;
            },
        }
    }

    std.debug.print("startup (min of {d}): {d:.2} ms (budget {d} ms)\n", .{
        startup_samples,
        @as(f64, @floatFromInt(min_ns)) / @as(f64, std.time.ns_per_ms),
        max_startup_ns / std.time.ns_per_ms,
    });

    if (min_ns > max_startup_ns) {
        std.debug.print(
            "budget: fastest of {d} `zcli --version` runs took {d} ns, over the {d} ns ceiling.\n" ++
                "The minimum is the noise-resistant statistic, so this is a real slowdown in\n" ++
                "process startup or command dispatch, not runner jitter.\n",
            .{ startup_samples, min_ns, max_startup_ns },
        );
        return error.StartupTimeBudgetExceeded;
    }
}
