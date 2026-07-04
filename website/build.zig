const std = @import("std");

// The site is built by the prebuilt `zine` binary (./zine), NOT by Zig: Zine
// 0.11.x's Zig integration doesn't compile on Zig 0.16, so `build.zig` can't
// import `zine`. Instead these steps front that binary and regenerate the
// build-derived data (assets/site-data.json) first — so the version shown on the
// site is always in sync with the root build.zig.zon and you never have to
// remember to run the sync by hand.
//
// Requires ./zine (download once from the zine v0.11.3 GitHub release; gitignored).
pub fn build(b: *std.Build) void {
    const root = b.path(".");

    // Regenerate assets/site-data.json from the source-of-truth files (build.zig.zon, ...).
    const sync = b.addSystemCommand(&.{"./sync-site-data.sh"});
    sync.setCwd(root);

    // `zig build serve` — dev server with live reload.
    const serve = b.addSystemCommand(&.{"./zine"});
    serve.setCwd(root);
    serve.step.dependOn(&sync.step);
    b.step("serve", "Start the Zine development server").dependOn(&serve.step);

    // `zig build` / `zig build release` — production build into ./public.
    // Zine refuses a non-empty output dir, so clear it first.
    const clean = b.addSystemCommand(&.{ "rm", "-rf", "public" });
    clean.setCwd(root);

    const release = b.addSystemCommand(&.{ "./zine", "release" });
    release.setCwd(root);
    release.step.dependOn(&sync.step);
    release.step.dependOn(&clean.step);

    b.step("release", "Build the site into ./public").dependOn(&release.step);
    b.getInstallStep().dependOn(&release.step);
}
