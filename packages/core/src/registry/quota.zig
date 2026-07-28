//! One place that answers "how many comptime backwards branches does a
//! registry of N commands need?" (#730).
//!
//! Zig gives every analysis unit a 1000-branch budget and no way for an
//! application author to raise it from the outside: `zcli_generated.zig` is
//! framework-generated, so a user whose app outgrows the ceiling has no
//! escape hatch — the build simply fails, pointing at a framework or std
//! source location. That made 28 top-level commands a hard wall (#730).
//!
//! Before this module the framework scattered hardcoded quotas (1_000_000,
//! 100_000, 10_000) across the registry, none of them a function of the
//! command count. Each was a wall a slightly larger app would hit, in a
//! different file, with a different confusing message — fixing one only moved
//! the failure to the next. Now every registry comptime pass sizes its budget
//! from the population it is about to walk.
//!
//! Deliberately NOT covered here: the flat quotas on the per-module passes
//! (`zcli.validateCommand`/`validateMeta`, `plugin_types.validatePlugin`,
//! `diagnostic_errors`, `levenshtein`). Their cost is bounded by one command's
//! or one plugin's own declarations, not by how many commands the app has, so
//! a command count is not the right input for them — and being per-item, they
//! were never the thing an app outgrew.
//!
//! `@setEvalBranchQuota` raises a *ceiling*, it does not consume anything —
//! an over-estimate costs nothing at compile time. The only real risk of a
//! large quota is that a genuine framework infinite loop takes longer to
//! surface, which is why the estimate is still tied to the input size rather
//! than being `maxInt(u32)`.

const std = @import("std");

/// Comptime branch budget for a pass over `command_count` commands.
///
/// The registry's comptime passes are at worst quadratic in the command
/// count: `validation.zig` compares every command path against every other
/// (uniqueness) and every plugin global option against every command option
/// (shadowing, #663). On top of that sits per-command linear work — path
/// splitting, `meta` walks, and the `comptimePrint` that renders usage lines
/// in `compiled.zig`.
///
/// The multipliers are deliberately orders of magnitude above measured cost,
/// so ordinary growth (more options per command, deeper paths, a richer
/// `meta`) can never re-raise the ceiling this module exists to remove.
/// Measured at the time of writing: ~36 branches per command in the builder
/// fold (27 commands exhausted the 1000 default) and ~170 per command in
/// `buildCommandInfo` (60 commands exhausted a flat 10_000). Every value this
/// returns is also at or above the flat constant it replaced, so no existing
/// app loses headroom.
pub fn forCommands(comptime command_count: usize) u32 {
    // The `+ 8` floor covers the framework's own fixed population — the
    // builtin plugins' commands and global options — so a zero-command
    // registry still gets a workable budget rather than a near-empty one.
    //
    // Clamped before squaring so the quadratic term can't overflow: past
    // `saturate_at` the formula already exceeds `maxInt(u32)`, which is the
    // most `@setEvalBranchQuota` can be given anyway.
    const saturate_at = 4000;
    const n: u64 = if (command_count > saturate_at) saturate_at + 8 else command_count + 8;
    const budget: u64 = 10_000 + n * 5_000 + n * n * 1_000;
    return if (budget > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(budget);
}

// Asserted at comptime, not in a `test` body: `forCommands` only ever runs at
// compile time, so checking it there means the check runs on every build of
// this file and cannot be skipped by a test filter.
comptime {
    // The floor alone must already clear every flat constant this replaced —
    // 5000 (diagnostic_errors), 10_000 (compiled/plugin_types), 100_000
    // (discoverPluginCommands) — and the registry-wide 1_000_000 must be
    // cleared well before the 100-command target this exists for.
    std.debug.assert(forCommands(0) > 100_000);
    std.debug.assert(forCommands(30) > 1_000_000);
    std.debug.assert(forCommands(100) > 10_000_000);
    // Monotonic: a bigger app never gets a smaller budget.
    std.debug.assert(forCommands(50) > forCommands(49));
    // Saturates instead of overflowing on an absurd command count.
    std.debug.assert(forCommands(std.math.maxInt(usize)) > forCommands(1000));
}
