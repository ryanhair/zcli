//! Test root for the progress package. Rooted here (not at progress.zig) so
//! the vterm golden-frame harness is a test-only import, never a dependency
//! of the shipped module.

test {
    _ = @import("progress.zig");
    _ = @import("vterm_test.zig");
}
