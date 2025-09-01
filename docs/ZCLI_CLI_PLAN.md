# zcli CLI: Developer Experience Plan

## 🚨 20-YEAR DX VETERAN REALITY CHECK

### **THE HARD TRUTH**: Most CLI tools fail because they solve imaginary problems.

**BRUTAL QUESTION**: Why would a developer use this instead of copying a working CLI project?

**HONEST ASSESSMENT**: 
- ✅ **Zig CLI ecosystem is tiny** → High impact potential if tool is excellent
- ⚠️ **Interactive CLIs are risky** → Developers often prefer copy-paste for speed
- ❌ **`zcli run` might be pointless** → `zig build run` already exists and works

### **REFINED SCOPE** (Cut another 50%)
**MVP FOCUS**: 2 commands that solve REAL pain: `new`, `add command`
**REMOVED FROM MVP**: `run` (zig build works), `info` (filesystem shows structure)

**THE 80/20 INSIGHT**: Developers spend 80% of time writing command logic, 20% on boilerplate. Focus on eliminating that 20%.

## ⚡ THE REAL VALUE PROPOSITION

### **What Actually Matters:**

1. **`zcli new my-cli`** → Perfect project structure in 30 seconds
   - **Includes working example commands** (hello, version)
   - **Proper build.zig configuration** 
   - **README with clear next steps**
   - **Zero configuration needed**

2. **`zcli add command deploy`** → Perfect command template in 60 seconds
   - **Type-safe argument/option structs**
   - **Example implementation with TODOs**
   - **Proper error handling patterns**
   - **Auto-generated help text**

### **Why This Wins:**
- **Faster than copying** → No hunting for good examples
- **Best practices included** → Error handling, help text, examples
- **Learning tool** → See how good zcli code looks
- **Consistency** → All commands follow same patterns

### **The Interactive Bet:**
**RISK**: Developers might find interactive slower than flags
**MITIGATION**: Make interactive SO good that it's faster than thinking
- Smart defaults (string args, bool options)
- Common patterns suggested
- One-key selections
- Preview generated code

## 🚀 AUTO-GROUP CREATION

**Decision: Remove `zcli add group` command entirely**

**PROS of Auto-Creation:**
- ✅ **One less command to learn** - Simpler API surface
- ✅ **More intuitive** - Just create `users/list`, group appears automatically
- ✅ **Follows filesystem convention** - Like `mkdir -p` creating parent dirs
- ✅ **Prevents orphaned groups** - Can't have empty groups with no commands
- ✅ **Faster workflow** - One step instead of two

**CONS (and mitigations):**
- ⚠️ **Accidental groups from typos** → Interactive mode confirms: "Group 'usres' doesn't exist. Create it?"
- ⚠️ **Can't pre-create empty groups** → Not needed; groups without commands are useless
- ⚠️ **Less explicit** → Clear output messages: "✅ Created group 'users' and command 'users/list'"

**Implementation:**
```bash
$ zcli add command users/list
Group 'users' doesn't exist. Create it? (Y/n): y
✅ Created group: users/
✅ Created command: users/list
```

## Overview

The `zcli` CLI is a meta-tool built with the zcli framework to help developers create, manage, and maintain CLI applications using zcli. It embodies the principle of "eating our own dog food" while providing an exceptional developer experience that makes building CLIs effortless.

## Core Philosophy

**Zero to CLI in minutes**: A developer should be able to go from an empty directory to a fully functional, multi-command CLI in under 5 minutes.

**Convention over Configuration**: Leverage zcli's build-time introspection to minimize boilerplate and configuration while maintaining full flexibility.

**Type-Safe Development**: Ensure developers get compile-time guarantees and excellent error messages throughout the development process.

**Frictionless Workflow**: Every command should feel natural and reduce cognitive load, letting developers focus on their CLI's logic rather than framework mechanics.

## Target Developer Journey

### 1. Getting Started (< 2 minutes)
```bash
# Start a new CLI project
zcli new my-awesome-cli
cd my-awesome-cli

# Add your first command
zcli add command hello

# Test it immediately
zcli run hello world
# Output: Hello, world!
```

### 2. Building Features (< 5 minutes)
```bash
# Add a command with group auto-creation - so easy!
$ zcli add command users/list
Group 'users' doesn't exist. Create it? (Y/n): y
[Interactive prompts guide you through adding args, options, examples...]
✅ Created group: users/
✅ Created command: users/list

$ zcli add command users/create
[Interactive prompts for name, email arguments...]
✅ Created command: users/create

# Test the new commands immediately
$ zcli run users list --format=json --limit=5
[Output from your command]

$ zcli run users create "John Doe" "john@example.com"
[Output from your command]
```

### 3. Development Workflow (ongoing)
```bash
# Watch mode for rapid development
zcli dev

# Run tests
zcli test

# Validate project structure and help text
zcli validate

# Build for production
zcli build --release
```

## Feature Breakdown

### Project Management Commands

#### `zcli new <name> [template]`
Create a new CLI project with proper structure and build configuration.

**Templates:** *(Start with just one, add others based on demand)*
- `default` - Multi-command CLI with examples *(most common use case)*
- ~~`simple` - Single command CLI~~ *(developers can just delete commands they don't need)*
- ~~`advanced` - Complex CLI~~ *(premature - let users build complexity gradually)*
- ~~`library` - CLI + library~~ *(niche use case, add later if needed)*

**Generated Structure:**
```
my-cli/
├── build.zig              # Configured for zcli
├── src/
│   ├── main.zig          # Entry point
│   ├── commands/         # Command implementations
│   │   └── hello.zig     # Example command
│   └── lib.zig          # Shared utilities
├── tests/
│   └── integration_test.zig
└── README.md            # Getting started guide
```

#### ~~`zcli init [template]`~~ *(REMOVE - Low value, high complexity)*
~~Convert an existing Zig project to use zcli framework.~~
*Most developers start fresh. This is complex to implement well and rarely used.*

#### `zcli info` *(SIMPLIFY - Developers want less noise)*
Display project information and command structure.

**Output:** *(Remove activity tracking - developers don't care about timestamps)*
```
my-awesome-cli v1.0.0
Commands: 8 (3 groups)

Command Structure:
├── hello
├── version
└── users/
    ├── list
    ├── create
    └── delete
```

### Command Generation

#### `zcli add command <path> [options]`
Generate a new command with proper structure and type safety.

**Interactive Mode (DEFAULT - Best DX!):**
```bash
$ zcli add command users/list

📝 Command: users/list
Description: List all users with optional filtering

What would you like to add?
  > Add argument
    Add option
    Add example
    Done

Adding argument:
Name: filter
Type: 
  > string (text)
    int (number)
    bool (true/false)
    enum (choice)
    [Show advanced types...]
    
Required? (Y/n): n

✓ Added optional argument 'filter' of type string

What would you like to add?
    Add argument
  > Add option
    Add example
    Done

Adding option:
Name: format
Type:
    string
    int
    bool
  > enum
    
Enum values (comma-separated): json,table,csv
Default value: table

✓ Added option 'format' of type enum{json,table,csv} with default 'table'

What would you like to add?
    Add argument
    Add option
    Add example
  > Done

✅ Created command users/list with:
  - 1 optional argument: filter
  - 1 option: --format
```

**Non-Interactive Mode (for automation/power users):**
```bash
# All in one command - great for scripts and CI
zcli add command deploy \
  --description "Deploy application to environment" \
  --arg "environment:string" \
  --arg "version:?string" \
  --option "force:bool=false" \
  --option "timeout:u32=300" \
  --no-interactive

# Partial specification - interactive fills in the rest
zcli add command greet --arg "name:string"
```

**Generated Command Template:**
```zig
const std = @import("std");
const zcli = @import("zcli");

pub const Args = struct {
    environment: []const u8,
    version: ?[]const u8 = null,
};

pub const Options = struct {
    force: bool = false,
    timeout: u32 = 300,
};

pub const meta = .{
    .description = "Deploy application to specified environment",
    .examples = &.{
        "deploy staging v1.2.3",
        "deploy production --force --timeout=600",
    },
};

pub fn execute(ctx: zcli.Context, args: Args, options: Options) !void {
    // TODO: Implement your command logic here
    
    try ctx.stdout().print("Deploying to {s}", .{args.environment});
    if (args.version) |v| {
        try ctx.stdout().print(" version {s}", .{v});
    }
    try ctx.stdout().print("\n");
}
```

#### ~~`zcli add group <name>`~~ *(REMOVED - Groups auto-created)*
~~Create a command group (directory with index.zig).~~
*Groups are automatically created when adding commands with paths like `users/list`.*

#### ~~`zcli remove command <path>`~~ *(REMOVE - Just delete the file)*
~~Remove a command and clean up references.~~
*Developers can just delete the .zig file. No magic cleanup needed.*

### Development Tools

#### ~~`zcli dev [command...]`~~ *(DEFER - Nice to have, not essential)*
~~Watch mode for rapid development with hot reload.~~
*Developers can use `zig build` in watch mode or IDE integration. Focus on core workflow first.*

#### `zcli run <command> [args...]` *(ESSENTIAL)*
Run a command in development mode without building first.

#### ~~`zcli test [pattern]`~~ *(REMOVE - Just use `zig build test`)*
~~Run project tests with zcli-specific test utilities.~~
*Don't reinvent the wheel. Zig's test system works fine.*

#### `zcli build [--release]` *(SIMPLIFY - Wrapper around `zig build`)*
Build the CLI with optimal settings.

**Options:** *(Start minimal, add based on demand)*
- `--release` - Optimized production build
- ~~`--target <target>` - Cross-compilation target~~ *(just use `zig build -Dtarget=...`)*
- ~~`--output <path>` - Custom output path~~ *(zig build handles this)*

### Quality Assurance

#### ~~`zcli validate`~~ *(DEFER - Complex, limited ROI initially)*
~~Comprehensive project validation.~~
*The zig compiler already validates most things. Start simple, add specific validations based on user pain points.*

#### ~~`zcli lint`~~ *(REMOVE - Use `zig fmt` and existing tools)*
~~Code style and best practice validation.~~
*Zig has `zig fmt`. Don't reinvent.*

#### ~~`zcli docs [--format=html|markdown|man]`~~ *(DEFER - Sophisticated but niche)*
~~Generate comprehensive documentation.~~
*Auto-generated help is good enough initially. Most CLIs use `--help`.*

### Distribution *(DEFER - Phase 3+ features)*

#### ~~`zcli package [--targets=<list>]`~~ *(DEFER)*
~~Package CLI for distribution across platforms.~~
*Users can use `zig build` with different targets. Focus on core workflow first.*

#### ~~`zcli release <version>`~~ *(DEFER)*
~~Prepare release with version bumping and changelog generation.~~
*Nice automation but not essential for initial adoption.*

## ~~Advanced Features~~ *(REMOVE ENTIRE SECTION - Premature optimization)*

### ~~Templates and Scaffolding~~ *(REMOVE)*
*Start with one good template. Add more based on user requests.*

### ~~Plugin System~~ *(REMOVE)*
*Complex architecture decision. Most developers don't need plugins initially.*

### ~~Development Environment~~ *(MOSTLY REMOVE)*

#### ~~`zcli completions <shell>`~~ *(DEFER - Nice but not essential)*
*Good UX but complex to implement well. Focus on core workflow.*

#### ~~`zcli debug <command> [args...]`~~ *(REMOVE - Just use normal debugging)*
*Developers know how to debug. Don't add complexity.*

## Implementation Priorities

### Phase 1: The Minimum Viable Tool (2-3 weeks)
- [x] zcli framework (completed)
- [ ] `zcli new` - Perfect project scaffolding with working examples
- [ ] `zcli add command` - Interactive command generation

### Phase 2: Polish *(Only if developers actually use Phase 1)*
- [ ] Rich type system support (enums, arrays, optionals)
- [ ] Better error messages and validation
- [ ] Non-interactive mode for automation

### ~~Phase 3+~~ *(Probably never needed)*
- ~~`zcli run` - Just use `zig build run`~~
- ~~`zcli info` - Just use `ls src/commands/`~~
- ~~`zcli build` - Just use `zig build`~~

### ~~Phase 3: Advanced Tooling~~ *(REMOVE - Premature)*
~~Complex features that most users won't need initially~~

### ~~Phase 4: Ecosystem~~ *(REMOVE - Way premature)*
~~Focus on core experience first~~

## Technical Considerations

### Project Structure Detection
- Automatically detect zcli projects via build.zig content
- Support for monorepos with multiple CLI projects
- Graceful handling of non-zcli projects

### Error Handling and User Experience
- Rich error messages with suggestions
- Progress indicators for long operations
- Undo capabilities where appropriate
- Comprehensive help system

### Performance
- Incremental builds and caching
- Parallel execution where possible
- Minimal startup time
- Memory-efficient operations

### Cross-Platform Support
- Windows, macOS, Linux support
- Proper path handling
- Shell-specific optimizations
- CI/CD integration helpers

## Success Metrics *(How we know if this matters)*

### **Leading Indicators** (Week 1-4):
1. **Time to Working CLI**: `zcli new` → working CLI in < 60 seconds
2. **Command Generation Speed**: `zcli add command` faster than copy-paste
3. **Generated Code Quality**: Developers don't need to modify generated templates

### **Adoption Signals** (Month 1-3):
1. **GitHub Projects**: >50 repos using zcli CLI tool in first 3 months
2. **Community Feedback**: "I wouldn't write a CLI in Zig without zcli"
3. **Repeat Usage**: Same developers creating multiple CLIs with the tool

### **Hard Questions** (Honest success criteria):
- **Do we use it ourselves?** → For all internal Zig CLIs
- **Do examples look professional?** → Generated code should be tutorial-quality
- **Is it faster than alternatives?** → Beats copying existing CLI projects

## Future Vision

The `zcli` CLI should become the de facto standard for CLI development in Zig, similar to how Create React App transformed React development or how Rails simplified web development. It should be so good that developers prefer building CLIs in Zig specifically because of the zcli experience, not just for performance reasons.

### ~~Long-term Goals~~ *(REMOVE - Distracting from real goals)*
~~Over-engineered features that sound impressive but don't solve real problems:~~
- ~~**Visual CLI Builder**: GUI for designing command structures~~
- ~~**AI-Powered Generation**: Natural language to CLI command conversion~~
- ~~**Cloud Integration**: Deploy CLIs as serverless functions~~
- ~~**Performance Analytics**: Built-in telemetry and optimization suggestions~~
- ~~**Ecosystem Marketplace**: Community-driven templates and plugins~~

*Focus: Make the basic workflow so good that developers love it.*

## 🎯 Next Steps (Ruthlessly Prioritized)

### **Week 1-2: Prove the Value**
1. **Build `zcli new`** - One perfect template that creates working CLI
2. **Test with real users** - Can they go from zero to working CLI in 60 seconds?
3. **Measure success** - Is it faster than copying an existing project?

### **Week 3-4: Add Command Generation**  
1. **Build `zcli add command`** - Interactive command scaffolding
2. **Focus on code quality** - Generated templates should be exemplary
3. **Test edge cases** - Complex args, options, nested commands

### **Week 5+: Only if Phase 1 Succeeds**
1. **Gather user feedback** - What's missing? What's annoying?
2. **Add requested features** - Driven by actual usage, not speculation
3. **Polish rough edges** - Better error messages, edge cases

## 🚨 FAILURE CONDITIONS (When to stop)

- **No one uses `zcli new` after 4 weeks** → Tool isn't valuable
- **Generated code needs lots of manual fixes** → Templates are poor quality  
- **Developers still prefer copying projects** → Tool isn't faster enough
- **Interactive mode is slow/annoying** → UX assumptions were wrong

---

*This is a hypothesis, not a plan. Kill it fast if it doesn't work.*