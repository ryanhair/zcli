# options-features

A small `deployctl` CLI whose only job is to exercise option-parsing features
that had no example anywhere in the repo:

- **`deploy`** — a required option (`--region`, satisfiable by `--region`,
  `$DEPLOY_REGION`, or config), a multi-value/array option (`--tag`,
  repeatable), a per-field `validate` hook (`--replicas`, range-checked), and a
  custom `parse` type (`--timeout`, `"30s"`/`"5m"`/`"1h"`).
- **`export`** — `meta.exclusive` (`--json`/`--yaml` are mutually exclusive)
  and a directional `meta.options.<field>.requires` (`--format` only makes
  sense alongside `--output`).

```
deployctl deploy api --region us-east-1 --tag env=prod --replicas 5 --timeout 2m
deployctl export --json
deployctl export --output state.txt --format text
```

## Build

```
zig build
./zig-out/bin/deployctl --help
```
