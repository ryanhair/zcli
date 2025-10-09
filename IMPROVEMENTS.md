Framework improvements:

- Better error messages and suggestions
- More assertion helpers
- Performance optimizations
- Command groups can have options (get put on context maybe?)

Core improvements:

- Validate `.meta` against `options` and `args`
- Validate `.meta.examples` against `options` and `args`
- Change `root.zig` to `index.zig`, same as subcommands
- Add `optional` info to fields that are optional
- Stdout system that doesn't deadlock

Documentation & examples:

- Usage guide for the testing framework
- More comprehensive examples
- Integration with other zcli packages

Simulator:

- Put your CLI through the paces, automatically. You can run tests at 1000x against generated seeds, and when one fails, it gets reported to you, so you can reproduce and fix.

Markdown DSL:

- Add VSCode plugin for an [injection grammar](https://code.visualstudio.com/api/language-extensions/syntax-highlight-guide#injection-grammars) that injects our DSL into Zig files under the right context

Layout Engine:

- Take a look at [yoga](https://github.com/facebook/yoga/tree/main)

Completions:

-

Replay:

- Allow the user to replay a recorded CLI session. This can be used for:
  - User testing - find out how the users are actually using your CLI
  - Replay testing seeds - Run the CLI against a seed, and save ones that fail

Interactive Testing:

-

Versioning:

-

Auto-updater:

-

General TODOs:

- Check out our context extensions. Are we still using a StringHashMap as context for extension data? I want a more strongly-typed system that is as intuitive and easy to use as possible, let's work on a plan for that.
- Verify short option handlingn works, and has tests, like `-abc` or option bundling without space (`-ovalue`)
- Make `commands_dir` optional. It should default to `src/commands`
- Align command options and args and everything else (right now only aligned by section)
