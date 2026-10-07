# options-features

A small `deployctl` CLI whose only job is to exercise option-parsing features
that had no example anywhere in the repo:

- **`deploy`** — a required option (`--region`, satisfiable by `--region`,
  `$DEPLOY_REGION`, or config), a multi-value/array option (`--tag`,
  repeatable), enum arrays (`--zone primary,canary`, also `$DEPLOY_ZONES`), a per-field `validate` hook (`--replicas`, range-checked), and a
  custom `parse` type (`--timeout`, `"30s"`/`"5m"`/`"1h"`).
- **`export`** — `meta.exclusive` (`--json`/`--yaml` are mutually exclusive)
  and a directional `meta.options.<field>.requires` (`--format` only makes
  sense alongside `--output`).

```
deployctl deploy api --region us-east-1 --tag env=prod --replicas 5 --timeout 2m
deployctl export --json
deployctl export --output state.txt --format text
```

Each `--tag` occurrence is one literal value: `--tag "owner=a,b" --tag env=prod`
produces two entries. Array options only split values when their metadata declares
an explicit `.delimiter` (for example, `.delimiter = ','`); it is not the default.
See [Commands](../../docs/COMMANDS.md#repeatable-options-and-stdin-text) for delimiter and explicit stdin
text options.

## Build

```
zig build
./zig-out/bin/deployctl --help
```

## Shared command helpers

`deploy` and `export` both use the `Duration` parser from
`src/commands/_deployment.zig`. The underscore excludes it from discovery.
`build.zig` creates one module named `deployment`, passes it to both `generate`
and `addCommandTests` through `shared_modules`, and commands import
`@import("deployment")`. Its own tests run alongside the command tests.

```sh
zig build test
./zig-out/bin/deployctl deploy api --region us-east-1 --zone primary,canary
./zig-out/bin/deployctl export --timeout 2m
```
