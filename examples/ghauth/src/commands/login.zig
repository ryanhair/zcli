const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Store your GitHub token (read from $GITHUB_TOKEN)",
    .examples = &.{"login"},
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(_: Args, _: Options, context: *Context) !void {
    const stderr = context.stderr();

    // The auth flow that *produces* a credential is freeform command code, not a
    // framework feature (ADR-0003). Here it's just reading an env var — kept out
    // of argv so the token never lands in the user's shell history. A real CLI
    // might instead run an OAuth device-code flow and end up with a token here.
    const token = context.environ.get("GITHUB_TOKEN") orelse {
        try stderr.print("Error: set GITHUB_TOKEN to a personal access token, then run `ghauth login`.\n", .{});
        return error.MissingToken;
    };
    if (token.len == 0) {
        try stderr.print("Error: GITHUB_TOKEN is set but empty.\n", .{});
        return error.MissingToken;
    }

    // zcli_secrets only stores/reads the opaque credential — it puts it in the
    // OS keychain, never a plaintext file.
    try context.plugins.zcli_secrets.set("token", token);

    try context.stdout().print("Saved your GitHub token to the OS keychain. Try `ghauth whoami`.\n", .{});
}
