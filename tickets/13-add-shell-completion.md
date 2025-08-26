# Ticket 13: Add Shell Completion Support

## Priority
🟢 **Low**

## Component
Build system, completion generation

## Description
Add support for generating shell completion scripts for bash, zsh, fish, and PowerShell. This would significantly improve user experience by providing tab completion for commands, options, and values.

## Current State
- ❌ No shell completion support
- ❌ Users must type commands and options fully
- ❌ No discovery of available commands/options
- ❌ Poor user experience for complex CLIs

## Proposed Implementation

### 1. Completion Data Generation
```zig
pub const CompletionGenerator = struct {
    pub fn generateCompletionData(comptime commands: []const CommandInfo) CompletionData {
        return .{
            .commands = extractCommandPaths(commands),
            .global_options = extractGlobalOptions(),
            .command_options = extractCommandOptions(commands),
        };
    }
    
    const CompletionData = struct {
        commands: []const []const []const u8,      // Hierarchical command paths
        global_options: []const OptionInfo,        // Global options
        command_options: []const CommandOptionMap, // Per-command options
        
        pub fn toBashScript(self: @This(), app_name: []const u8) []const u8 {
            // Generate bash completion script
        }
        
        pub fn toZshScript(self: @This(), app_name: []const u8) []const u8 {
            // Generate zsh completion script
        }
        
        pub fn toFishScript(self: @This(), app_name: []const u8) []const u8 {
            // Generate fish completion script
        }
        
        pub fn toPowerShellScript(self: @This(), app_name: []const u8) []const u8 {
            // Generate PowerShell completion script
        }
    };
};
```

### 2. Build Integration
```zig
// build.zig integration
pub fn addCompletionGeneration(
    b: *std.Build, 
    exe: *std.Build.Step.Compile, 
    app_name: []const u8,
    commands: []const CommandInfo
) void {
    const completion_data = CompletionGenerator.generateCompletionData(commands);
    
    // Generate completion scripts for all supported shells
    const shells = [_]Shell{ .bash, .zsh, .fish, .powershell };
    
    inline for (shells) |shell| {
        const script_content = switch (shell) {
            .bash => completion_data.toBashScript(app_name),
            .zsh => completion_data.toZshScript(app_name),
            .fish => completion_data.toFishScript(app_name),
            .powershell => completion_data.toPowerShellScript(app_name),
        };
        
        const output_file = b.fmt("completions/{s}.{s}", .{ app_name, @tagName(shell) });
        const write_file = b.addWriteFile(output_file, script_content);
        write_file.step.dependOn(&exe.step);
        
        b.getInstallStep().dependOn(&write_file.step);
    }
}
```

### 3. Bash Completion Implementation
```bash
# Generated completion script for bash
_myapp_complete() {
    local cur prev opts commands
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    
    # Global options available everywhere
    local global_opts="--help --version --verbose --config"
    
    # Extract current command path
    local command_path=()
    local i=1
    while [[ $i -lt $COMP_CWORD ]]; do
        local word="${COMP_WORDS[$i]}"
        if [[ ! "$word" =~ ^- ]]; then
            command_path+=("$word")
        fi
        ((i++))
    done
    
    # Determine completion based on current context
    case "${#command_path[@]}" in
        0)
            # Top-level: complete main commands
            local commands="help users files deploy"
            COMPREPLY=($(compgen -W "$commands $global_opts" -- "$cur"))
            ;;
        1)
            case "${command_path[0]}" in
                users)
                    local subcommands="list create delete update"
                    local user_opts="--format --limit --sort"
                    COMPREPLY=($(compgen -W "$subcommands $user_opts $global_opts" -- "$cur"))
                    ;;
                files)
                    local file_opts="--input --output --recursive"
                    COMPREPLY=($(compgen -W "$file_opts $global_opts" -- "$cur"))
                    # Complete filenames for file arguments
                    COMPREPLY+=($(compgen -f -- "$cur"))
                    ;;
                *)
                    COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
                    ;;
            esac
            ;;
    esac
    
    return 0
}

complete -F _myapp_complete myapp
```

### 4. Zsh Completion Implementation
```zsh
#compdef myapp

_myapp() {
    local context state line
    typeset -A opt_args
    
    _arguments -C \
        '(--help -h)'{--help,-h}'[Show help message]' \
        '(--version -V)'{--version,-V}'[Show version]' \
        '(--verbose -v)'{--verbose,-v}'[Enable verbose output]' \
        '--config[Configuration file]:file:_files' \
        '1: :_myapp_commands' \
        '*::arg:->args'
    
    case $state in
        args)
            case $words[1] in
                users)
                    _arguments \
                        '1: :_myapp_users_commands' \
                        '--format[Output format]:format:(json yaml table)' \
                        '--limit[Limit results]:number:' \
                        '--sort[Sort field]:field:(name email created)'
                    ;;
                files)
                    _arguments \
                        '1: :_files' \
                        '--input[Input file]:file:_files' \
                        '--output[Output file]:file:_files' \
                        '(--recursive -r)'{--recursive,-r}'[Process recursively]'
                    ;;
            esac
            ;;
    esac
}

_myapp_commands() {
    local commands; commands=(
        'users:Manage users'
        'files:Process files'
        'deploy:Deploy application'
        'help:Show help'
    )
    _describe -t commands 'commands' commands
}

_myapp_users_commands() {
    local commands; commands=(
        'list:List users'
        'create:Create new user'
        'delete:Delete user'
        'update:Update user'
    )
    _describe -t commands 'user commands' commands
}

_myapp "$@"
```

### 5. Fish Completion Implementation
```fish
# Fish completion for myapp

# Global options (available for all commands)
complete -c myapp -s h -l help -d "Show help message"
complete -c myapp -s V -l version -d "Show version"
complete -c myapp -s v -l verbose -d "Enable verbose output"
complete -c myapp -l config -d "Configuration file" -F

# Top-level commands
complete -c myapp -f -n "__fish_use_subcommand" -a "users" -d "Manage users"
complete -c myapp -f -n "__fish_use_subcommand" -a "files" -d "Process files"
complete -c myapp -f -n "__fish_use_subcommand" -a "deploy" -d "Deploy application"
complete -c myapp -f -n "__fish_use_subcommand" -a "help" -d "Show help"

# Users subcommands
complete -c myapp -f -n "__fish_seen_subcommand_from users; and not __fish_seen_subcommand_from list create delete update" -a "list" -d "List users"
complete -c myapp -f -n "__fish_seen_subcommand_from users; and not __fish_seen_subcommand_from list create delete update" -a "create" -d "Create new user"
complete -c myapp -f -n "__fish_seen_subcommand_from users; and not __fish_seen_subcommand_from list create delete update" -a "delete" -d "Delete user"
complete -c myapp -f -n "__fish_seen_subcommand_from users; and not __fish_seen_subcommand_from list create delete update" -a "update" -d "Update user"

# Users options
complete -c myapp -n "__fish_seen_subcommand_from users" -l format -d "Output format" -x -a "json yaml table"
complete -c myapp -n "__fish_seen_subcommand_from users" -l limit -d "Limit results" -x
complete -c myapp -n "__fish_seen_subcommand_from users" -l sort -d "Sort field" -x -a "name email created"

# Files options
complete -c myapp -n "__fish_seen_subcommand_from files" -l input -d "Input file" -F
complete -c myapp -n "__fish_seen_subcommand_from files" -l output -d "Output file" -F
complete -c myapp -n "__fish_seen_subcommand_from files" -s r -l recursive -d "Process recursively"
```

### 6. PowerShell Completion Implementation
```powershell
# PowerShell completion for myapp

Register-ArgumentCompleter -Native -CommandName myapp -ScriptBlock {
    param($commandName, $wordToComplete, $cursorPosition)
    
    $tokens = $wordToComplete -split '\s+'
    $lastToken = $tokens[-1]
    
    # Global options
    $globalOptions = @('--help', '--version', '--verbose', '--config')
    
    # Determine current context
    $commandPath = @()
    for ($i = 1; $i -lt $tokens.Length; $i++) {
        if (-not $tokens[$i].StartsWith('-')) {
            $commandPath += $tokens[$i]
        }
    }
    
    $completions = @()
    
    switch ($commandPath.Length) {
        0 {
            # Top-level commands
            $commands = @('users', 'files', 'deploy', 'help')
            $completions = $commands + $globalOptions
        }
        1 {
            switch ($commandPath[0]) {
                'users' {
                    $subcommands = @('list', 'create', 'delete', 'update')
                    $userOptions = @('--format', '--limit', '--sort')
                    $completions = $subcommands + $userOptions + $globalOptions
                }
                'files' {
                    $fileOptions = @('--input', '--output', '--recursive')
                    $completions = $fileOptions + $globalOptions
                    
                    # Add file completions
                    if ($lastToken -eq '--input' -or $lastToken -eq '--output') {
                        $completions += Get-ChildItem -Name
                    }
                }
                default {
                    $completions = $globalOptions
                }
            }
        }
    }
    
    $completions | Where-Object { $_ -like "$lastToken*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    }
}
```

### 7. Dynamic Completion Support
```zig
// Support for dynamic completions (e.g., from API calls)
pub const DynamicCompletion = struct {
    pub fn completeUsernames(partial: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
        // Query database/API for usernames matching partial
        const users = try fetchUsers(partial, allocator);
        defer allocator.free(users);
        
        var completions = std.ArrayList([]const u8).init(allocator);
        
        for (users) |user| {
            if (std.mem.startsWith(u8, user.name, partial)) {
                try completions.append(try allocator.dupe(u8, user.name));
            }
        }
        
        return completions.toOwnedSlice();
    }
    
    pub fn completeFilePaths(partial: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
        var completions = std.ArrayList([]const u8).init(allocator);
        
        const dir_path = std.fs.path.dirname(partial) orelse ".";
        const basename = std.fs.path.basename(partial);
        
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return completions.toOwnedSlice();
        defer dir.close();
        
        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (std.mem.startsWith(u8, entry.name, basename)) {
                const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
                try completions.append(full_path);
            }
        }
        
        return completions.toOwnedSlice();
    }
};

// Integration with completion generation
pub fn generateDynamicCompletion(app_name: []const u8, args: []const []const u8) ![]const []const u8 {
    const allocator = std.heap.page_allocator;
    
    // Parse current command context
    const context = try parseCompletionContext(args, allocator);
    defer context.deinit();
    
    // Generate appropriate completions based on context
    return switch (context.completion_type) {
        .username => DynamicCompletion.completeUsernames(context.partial, allocator),
        .filepath => DynamicCompletion.completeFilePaths(context.partial, allocator),
        .static => context.static_completions,
    };
}
```

### 8. Installation Helper
```bash
#!/bin/bash
# install-completions.sh - Helper script to install completions

COMPLETION_DIR=""
APP_NAME="$1"

if [[ -z "$APP_NAME" ]]; then
    echo "Usage: $0 <app-name>"
    exit 1
fi

# Detect shell and completion directory
case "$SHELL" in
    */bash)
        if [[ -d "/usr/share/bash-completion/completions" ]]; then
            COMPLETION_DIR="/usr/share/bash-completion/completions"
        elif [[ -d "/usr/local/share/bash-completion/completions" ]]; then
            COMPLETION_DIR="/usr/local/share/bash-completion/completions"
        elif [[ -d ~/.bash_completion.d ]]; then
            COMPLETION_DIR=~/.bash_completion.d
        fi
        COMPLETION_FILE="completions/$APP_NAME.bash"
        ;;
    */zsh)
        # Check various zsh completion directories
        for dir in /usr/share/zsh/site-functions /usr/local/share/zsh/site-functions ~/.zsh/completions; do
            if [[ -d "$dir" ]]; then
                COMPLETION_DIR="$dir"
                break
            fi
        done
        COMPLETION_FILE="completions/$APP_NAME.zsh"
        ;;
    */fish)
        if [[ -d ~/.config/fish/completions ]]; then
            COMPLETION_DIR=~/.config/fish/completions
        elif [[ -d /usr/share/fish/completions ]]; then
            COMPLETION_DIR=/usr/share/fish/completions
        fi
        COMPLETION_FILE="completions/$APP_NAME.fish"
        ;;
esac

if [[ -n "$COMPLETION_DIR" && -f "$COMPLETION_FILE" ]]; then
    echo "Installing $APP_NAME completion for $(basename $SHELL)..."
    cp "$COMPLETION_FILE" "$COMPLETION_DIR/"
    echo "Completion installed to $COMPLETION_DIR/"
    echo "You may need to restart your shell or run 'source ~/.bashrc' (or equivalent)"
else
    echo "Could not determine completion directory for your shell or completion file not found"
    echo "Available completion files:"
    ls -la completions/
fi
```

## Testing Strategy

### Completion Testing Framework
```zig
test "completion generation" {
    const test_commands = [_]CommandInfo{
        .{ .path = "users list", .description = "List users" },
        .{ .path = "users create", .description = "Create user" },
        .{ .path = "files process", .description = "Process files" },
    };
    
    const completion_data = CompletionGenerator.generateCompletionData(&test_commands);
    
    // Test bash completion generation
    const bash_script = completion_data.toBashScript("testapp");
    try testing.expect(std.mem.indexOf(u8, bash_script, "users") != null);
    try testing.expect(std.mem.indexOf(u8, bash_script, "_testapp_complete") != null);
    
    // Test other shells
    const zsh_script = completion_data.toZshScript("testapp");
    try testing.expect(std.mem.indexOf(u8, zsh_script, "#compdef testapp") != null);
}

test "completion script syntax" {
    // Test that generated scripts have valid syntax
    const completion_data = CompletionGenerator.generateCompletionData(&[_]CommandInfo{});
    
    // Write scripts to temporary files and validate syntax
    const bash_script = completion_data.toBashScript("test");
    const temp_file = try std.fs.cwd().createFile("test_completion.bash", .{});
    defer temp_file.close();
    defer std.fs.cwd().deleteFile("test_completion.bash") catch {};
    
    try temp_file.writeAll(bash_script);
    
    // Run bash syntax check
    const result = try std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "bash", "-n", "test_completion.bash" },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    
    try testing.expectEqual(@as(u8, 0), result.term.Exited);
}
```

### Manual Testing Guide
```markdown
# Manual Completion Testing

## Bash Testing
1. Source the completion script: `source completions/myapp.bash`
2. Test basic completion: `myapp <TAB><TAB>`
3. Test subcommand completion: `myapp users <TAB><TAB>`
4. Test option completion: `myapp --<TAB><TAB>`
5. Test file completion: `myapp --config <TAB><TAB>`

## Zsh Testing  
1. Copy completion to zsh functions: `cp completions/myapp.zsh ~/.zsh/completions/_myapp`
2. Reload zsh: `exec zsh`
3. Test completion as above

## Fish Testing
1. Copy completion: `cp completions/myapp.fish ~/.config/fish/completions/`
2. Test completion: `myapp <TAB>`
```

## Integration Examples

### Simple CLI
```zig
// build.zig
const std = @import("std");
const zcli = @import("zcli");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "mycli",
        .root_source_file = .{ .path = "src/main.zig" },
    });
    
    const zcli_module = b.addModule("zcli", .{ .root_source_file = .{ .path = "zcli/src/zcli.zig" } });
    exe.root_module.addImport("zcli", zcli_module);
    
    // Generate shell completions
    const commands = [_]zcli.CommandInfo{
        .{ .path = "hello", .description = "Say hello" },
        .{ .path = "goodbye", .description = "Say goodbye" },
    };
    
    zcli.addCompletionGeneration(b, exe, "mycli", &commands);
    
    b.installArtifact(exe);
}
```

### Complex CLI with Dynamic Completions
```zig
// For CLIs that need dynamic completions (API calls, database queries, etc.)
const exe = b.addExecutable(.{
    .name = "cloudctl",
    .root_source_file = .{ .path = "src/main.zig" },
});

// Add completion command for dynamic completions
const completion_exe = b.addExecutable(.{
    .name = "cloudctl-complete",
    .root_source_file = .{ .path = "src/completion.zig" },
});

zcli.addDynamicCompletionSupport(b, exe, completion_exe, "cloudctl", &commands);
```

## Performance Considerations

### Completion Speed
```zig
// Optimize completion performance for large command sets
pub const FastCompletion = struct {
    // Pre-built trie for fast prefix matching
    completion_trie: CompletionTrie,
    
    pub fn init(commands: []const CommandInfo) @This() {
        return .{
            .completion_trie = CompletionTrie.build(commands),
        };
    }
    
    pub fn findCompletions(self: @This(), prefix: []const u8) []const []const u8 {
        return self.completion_trie.findMatches(prefix);
    }
};
```

### Lazy Loading
```bash
# Only load completions when needed (bash example)
_myapp_complete() {
    # Load completions lazily
    if [[ -z "$_MYAPP_COMPLETIONS_LOADED" ]]; then
        source /usr/share/myapp/completions-data.bash
        _MYAPP_COMPLETIONS_LOADED=1
    fi
    
    # Use loaded completions
    _myapp_complete_impl "$@"
}
```

## Documentation and User Guide

### Installation Instructions
```markdown
# Shell Completion Installation

## Automatic Installation (Recommended)
```bash
# Install with completion support
make install-with-completions

# Or use the helper script
./scripts/install-completions.sh myapp
```

## Manual Installation

### Bash
```bash
# System-wide
sudo cp completions/myapp.bash /usr/share/bash-completion/completions/myapp

# User-only  
mkdir -p ~/.bash_completion.d
cp completions/myapp.bash ~/.bash_completion.d/
```

### Zsh
```bash
# Add to your fpath in ~/.zshrc
fpath=(~/.zsh/completions $fpath)
mkdir -p ~/.zsh/completions
cp completions/myapp.zsh ~/.zsh/completions/_myapp
```
```

## Acceptance Criteria
- [ ] Generate completion scripts for bash, zsh, fish, and PowerShell
- [ ] Support hierarchical command completion
- [ ] Complete global and command-specific options
- [ ] Support file path completion for file arguments
- [ ] Dynamic completion support for custom completers
- [ ] Installation helper scripts for all supported shells
- [ ] Comprehensive testing of generated completion scripts
- [ ] Documentation and examples for completion setup
- [ ] Performance optimized for large command sets

## Estimated Effort
**2-3 weeks** (1 week for core completion generation, 1-2 weeks for shell-specific implementations and testing)