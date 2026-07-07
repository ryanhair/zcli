# zcli README demo — records the `tasks` showcase app.
# Run from examples/tasks: vhs demo.tape

Output demo.gif

Set Shell "bash"
Set FontSize 18
Set Width 900
Set Height 560
Set Padding 16
Set Theme "Catppuccin Mocha"
Set TypingSpeed 50ms

Hide
Type "export PATH=$PWD/zig-out/bin:$PATH && cp demo-seed.json tasks.json && clear"
Enter
Show

# --- Interactive prompts: text, select (arrow keys), number ---
Type "tasks add"
Sleep 500ms
Enter
Sleep 800ms
Type@70ms "Ship v1.0"
Sleep 400ms
Enter
Sleep 600ms
Down
Sleep 350ms
Down
Sleep 350ms
Enter
Sleep 600ms
Type "3"
Sleep 300ms
Enter
Sleep 1.5s

# --- Colored task table ---
Type "tasks list"
Sleep 400ms
Enter
Sleep 2.5s

# --- Type-to-filter search ---
Type "tasks search"
Sleep 400ms
Enter
Sleep 800ms
Type@90ms "oauth"
Sleep 800ms
Enter
Sleep 2s

# --- Spinner ---
Type "tasks sync"
Sleep 400ms
Enter
Sleep 2.5s

Sleep 2.5s
