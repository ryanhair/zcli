# markdown examples

Six focused, self-contained `main`s — one per slice of the API. Each wires a
buffered stdout writer and drives the `markdown` package directly, with comments
that explain *what* every API call demonstrates, so the files double as
documentation.

Run one (they print styled ANSI, so a real terminal shows color — piping still
works):

```sh
zig build run-elements      # or: semantic, interpolation, palette,
                            #     capabilities, build_report
```

Build all of them at once:

```sh
zig build examples          # binaries land in zig-out/bin/markdown-<name>
```

| Example         | Shows off                                                                 |
| --------------- | ------------------------------------------------------------------------- |
| `elements`      | every block + inline element: headers, lists, code, quotes, rules, links  |
| `semantic`      | all 13 semantic roles + composing them with inline markdown + values      |
| `interpolation` | runtime `{s}`/`{d}`/`{d:.2}`/`{x}` interpolation across every context      |
| `palette`       | custom palettes + the low-level `parse` / `writeWithPalette` / `print`     |
| `capabilities`  | the same markdown at `no_color` / `ansi_16` / `ansi_256` / `true_color`   |
| `build_report`  | a realistic CLI report combining everything end-to-end                    |

Tips:

- See the raw escape codes with `zig build run-capabilities | cat -v`.
- `no_color` output (and thus `NO_COLOR=1`) drops all ANSI — verify with
  `zig build run-semantic | cat -v`.

Every example is compiled by `zig build test`, so they can't bitrot against the
API.
