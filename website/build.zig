const std = @import("std");
const zine = @import("zine");

pub fn build(b: *std.Build) !void {
    // Build the website
    const website = zine.website(b, .{});
    b.getInstallStep().dependOn(&website.step);

    // Development server
    const serve = b.step("serve", "Start the Zine development server");
    const run_zine = zine.serve(b, .{});
    serve.dependOn(&run_zine.step);
}
