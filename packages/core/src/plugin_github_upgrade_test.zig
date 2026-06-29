//! Surfaces the zcli_github_upgrade plugin's inline tests under the default test
//! runner. The plugin's network functions (fetch/download) can't be unit-tested
//! without a live HTTP server, but the checksum-parsing, SHA-256 hashing, and
//! version-comparison logic is pure and is covered by tests inside plugin.zig.
test {
    _ = @import("plugins/zcli_github_upgrade/plugin.zig");
}
