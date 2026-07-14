# upgrade-demo

A minimal CLI wiring the `github_upgrade` plugin (previously only used by
zcli's own meta-CLI — no `examples/` app demonstrated it). `build.zig` shows
the whole shape:

```zig
zcli.builtin(.github_upgrade, .{
    .repo = "your-org/your-cli",       // placeholder — point at your own repo
    .command_name = "upgrade",
    .verification = .checksum_only,    // demo-only; see the comment in build.zig
}),
```

adding an `upgrade` command that checks GitHub Releases for `{repo}`'s latest
`upgrade-demo-v*` tag, downloads the matching release asset, verifies it, and
replaces the running binary.

`repo` is a placeholder pointing nowhere real — running `upgrade-demo upgrade`
against it will simply fail to find a release. `.verification` has no
default; this example opts explicitly into `.checksum_only` (with a comment
explaining the real option) rather than fabricate a minisign key, since a real
release pipeline should sign `checksums.txt` and pin the public key instead
(see `docs/RELEASE-SIGNING.md`, and `projects/zcli/build.zig` for the real
thing zcli upgrades itself with).

```
zig build
./zig-out/bin/upgrade-demo status
./zig-out/bin/upgrade-demo upgrade --help
```
