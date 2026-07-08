//! Test root for the ui package. Rooted here (not at ui.zig) so the golden
//! tests can import vterm, which is a test-only dependency of this package.

test {
    _ = @import("surface.zig");
    _ = @import("diff.zig");
    _ = @import("layout_test.zig");
    _ = @import("golden_test.zig");
    _ = @import("app_test.zig");
}
