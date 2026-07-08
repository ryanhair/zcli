//! Test root for the progress package. Rooted here (not at Progress.zig) so
//! the vterm golden-frame harness is a test-only import, never a dependency
//! of the shipped module.

test {
    _ = @import("Progress.zig");
    _ = @import("vterm_test.zig");
}
