const std = @import("std");
const zcli = @import("zcli");
const serde = @import("serde");

test "zcli config parsing calls the exact application-owned serde module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    serde.toml.calls = 0;
    serde.yaml.calls = 0;
    const table = try zcli.plugin_abi.config_parse.parseToml(allocator, "[deploy]\nzone = [\"primary\", \"canary\"]\n");
    const root = try zcli.plugin_abi.config_parse.parseYaml(allocator, "deploy:\n  zone: [primary, canary]\n");
    try std.testing.expect(table.contains("deploy"));
    try std.testing.expect(root == .mapping);
    try std.testing.expectEqual(@as(usize, 1), serde.toml.calls);
    try std.testing.expectEqual(@as(usize, 1), serde.yaml.calls);
}
