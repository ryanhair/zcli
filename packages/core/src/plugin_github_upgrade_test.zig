//! Surfaces the zcli_github_upgrade plugin's inline tests under the default test
//! runner. The literal socket round-trip belongs to std.http.Client, but every
//! piece of logic in the upgrade path is exercised by tests inside plugin.zig:
//! URL construction, gzip body decoding, release-JSON version selection,
//! checksum parsing + SHA-256 hashing, version comparison, and the atomic
//! backup/replace swap (against temp files, via replaceBinaryAt).
test {
    _ = @import("plugins/zcli_github_upgrade/plugin.zig");
}
