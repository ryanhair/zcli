# showcase — the kitchen-sink example

A fully functional task tracker CLI (`tasks`) that exercises every zcli
feature in one app. Where [notes](../notes/), [repostat](../repostat/), and
[ghauth](../ghauth/) each teach one idiom, this is the tour.

```
$ tasks init          # interactive project wizard
$ tasks add "My task" # add via flags, or `tasks add` for the prompt flow
$ tasks list          # colored, themed task list (alias: ls)
$ tasks search        # type-to-filter search prompt
$ tasks sync          # spinner + progress bar demo
$ tasks sprint create # nested command group
```

What it demonstrates:

- **14 commands** in `src/commands/` — args, options, aliases (`ls`, `rm`),
  and a nested `sprint` group with its own `index.zig`.
- **Six zinput prompt types** — text, confirm, select, number, search, and
  editor (`init`, `add`, `edit`, `search`), each falling back to line input
  when piped.
- **zprogress** — spinners and progress bars in `sync` and `import`.
- **ztheme** — semantic colors and status badges via `context.theme`.
- **A shared module** — `src/store.zig` (JSON persistence to `tasks.json`)
  registered once as a `shared_modules` entry in `build.zig`.
- **Six built-in plugins** — `zcli.builtin(.help/.version/.not_found/
  .completions/.output/.config, .{})`, including per-command defaults from
  `.tasks.config.json`.
- **Doc generation** — `zcli.generateDocs` writes markdown + HTML docs on
  every build.
- **Per-command unit tests** — `zcli.addCommandTests` wires each command
  file's `test` blocks into `zig build test`.

Run it:

```
zig build
./zig-out/bin/tasks --help
```
