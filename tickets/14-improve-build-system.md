# Ticket 14: Improve Build System and Developer Tools

## Priority
🟢 **Low**

## Component
Build system, developer tools, CI/CD

## Description
Enhance the build system with better caching, parallel builds, cross-compilation support, and developer productivity tools. Add comprehensive development environment setup and optimization for faster build times.

## Current Build System Assessment

### Strengths
- ✅ Good modular structure with build utilities
- ✅ Comprehensive test organization
- ✅ Proper command discovery and code generation

### Areas for Improvement
- ⚠️ Limited caching optimization
- ⚠️ No cross-compilation helpers
- ⚠️ Manual development environment setup
- ⚠️ Limited CI/CD optimization
- ⚠️ No build performance monitoring

## Proposed Enhancements

### 1. Enhanced Build Caching
```zig
// build.zig improvements
const CacheManager = struct {
    cache_dir: []const u8,
    build: *std.Build,
    
    pub fn init(b: *std.Build) @This() {
        const cache_dir = b.cache_root.path orelse ".zig-cache";
        return .{
            .cache_dir = cache_dir,
            .build = b,
        };
    }
    
    pub fn getCachedArtifact(self: @This(), key: []const u8) ?[]const u8 {
        const cache_path = self.build.pathJoin(&.{ self.cache_dir, "zcli", key });
        
        // Check if cached artifact exists and is up-to-date
        const cache_file = std.fs.cwd().openFile(cache_path, .{}) catch return null;
        defer cache_file.close();
        
        const cache_stat = cache_file.stat() catch return null;
        const source_stat = self.getSourceMtime() catch return null;
        
        if (cache_stat.mtime >= source_stat.mtime) {
            return cache_path;  // Cache is up-to-date
        }
        
        return null;  // Cache is stale
    }
    
    pub fn cacheArtifact(self: @This(), key: []const u8, content: []const u8) !void {
        const cache_path = self.build.pathJoin(&.{ self.cache_dir, "zcli", key });
        
        // Ensure cache directory exists
        const cache_dir = std.fs.path.dirname(cache_path) orelse return;
        std.fs.cwd().makePath(cache_dir) catch {};
        
        // Write cached content
        try std.fs.cwd().writeFile(.{ .sub_path = cache_path, .data = content });
    }
};

pub fn build(b: *std.Build) void {
    const cache_manager = CacheManager.init(b);
    
    // Use cached command registry if available
    const registry_key = "command_registry.zig";
    const cached_registry = cache_manager.getCachedArtifact(registry_key);
    
    if (cached_registry) |cache_path| {
        // Use cached registry
        std.log.info("Using cached command registry", .{});
    } else {
        // Generate and cache registry
        const registry_content = generateCommandRegistry(b);
        cache_manager.cacheArtifact(registry_key, registry_content) catch {};
    }
}
```

### 2. Cross-Compilation Support
```zig
const CrossCompileHelper = struct {
    pub const SupportedTargets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .aarch64, .os_tag = .linux },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .windows },
    };
    
    pub fn addCrossCompileTargets(b: *std.Build, exe: *std.Build.Step.Compile) void {
        const cross_compile_step = b.step("cross-compile", "Build for all supported targets");
        
        inline for (SupportedTargets) |target_query| {
            const target = b.resolveTargetQuery(target_query);
            const target_exe = b.addExecutable(.{
                .name = b.fmt("{s}-{s}-{s}", .{
                    exe.name,
                    @tagName(target_query.cpu_arch.?),
                    @tagName(target_query.os_tag.?)
                }),
                .root_source_file = exe.root_source_file,
                .target = target,
                .optimize = exe.optimize,
            });
            
            // Copy all imports and dependencies
            const imports = exe.root_module.import_table.iterator();
            while (imports.next()) |entry| {
                target_exe.root_module.addImport(entry.key_ptr.*, entry.value_ptr.*);
            }
            
            const install_target = b.addInstallArtifact(target_exe, .{
                .dest_dir = .{
                    .override = .{
                        .custom = b.fmt("bin/{s}-{s}", .{
                            @tagName(target_query.cpu_arch.?),
                            @tagName(target_query.os_tag.?)
                        }),
                    },
                },
            });
            
            cross_compile_step.dependOn(&install_target.step);
        }
    }
};

// Usage in build.zig
pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    
    // Add cross-compilation support
    CrossCompileHelper.addCrossCompileTargets(b, exe);
    
    b.installArtifact(exe);
}
```

### 3. Development Environment Automation
```bash
#!/bin/bash
# scripts/setup-dev-env.sh

set -e

echo "Setting up zcli development environment..."

# Check system dependencies
check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        echo "❌ Missing dependency: $1"
        echo "   Install with: $2"
        exit 1
    else
        echo "✅ Found: $1"
    fi
}

# Check required tools
check_dependency "zig" "Visit https://ziglang.org/download/"
check_dependency "git" "Install git from your package manager"

# Optional but recommended tools
if command -v "ripgrep" &> /dev/null; then
    echo "✅ Found: ripgrep (recommended for fast searching)"
else
    echo "💡 Consider installing ripgrep for faster code searches"
fi

if command -v "fd" &> /dev/null; then
    echo "✅ Found: fd (recommended for fast file finding)"
else
    echo "💡 Consider installing fd for faster file operations"
fi

# Setup git hooks
echo "Setting up git hooks..."
mkdir -p .git/hooks

cat > .git/hooks/pre-commit << 'EOF'
#!/bin/bash
# Pre-commit hook: run tests and formatting

echo "Running pre-commit checks..."

# Run tests
if ! zig build test; then
    echo "❌ Tests failed"
    exit 1
fi

# Check formatting (if formatter available)
if command -v zig fmt &> /dev/null; then
    if ! zig fmt --check src/; then
        echo "❌ Code formatting issues found"
        echo "Run 'zig fmt src/' to fix"
        exit 1
    fi
fi

echo "✅ Pre-commit checks passed"
EOF

chmod +x .git/hooks/pre-commit

# Setup development aliases
cat >> ~/.bashrc << 'EOF'
# zcli development aliases
alias zb='zig build'
alias zt='zig build test'
alias zr='zig build run'
alias zcc='zig build cross-compile'
alias zclean='rm -rf zig-out .zig-cache'
EOF

# Create development configuration
cat > .zcli-dev-config << 'EOF'
# Development configuration for zcli
ZCLI_DEBUG=1
ZCLI_VERBOSE=1
ZCLI_COLLECT_ERRORS=1
EOF

echo "✅ Development environment setup complete!"
echo ""
echo "Next steps:"
echo "1. Run 'source ~/.bashrc' to load new aliases"
echo "2. Run 'zig build test' to verify setup"
echo "3. Run 'zig build cross-compile' to test cross-compilation"
echo "4. Check out CONTRIBUTING.md for development guidelines"
```

### 4. Performance Monitoring and Optimization
```zig
const BuildProfiler = struct {
    timers: std.HashMap([]const u8, std.time.Timer, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .timers = std.HashMap([]const u8, std.time.Timer, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn startTimer(self: *@This(), name: []const u8) !void {
        const timer = try std.time.Timer.start();
        try self.timers.put(name, timer);
    }
    
    pub fn endTimer(self: *@This(), name: []const u8) !u64 {
        if (self.timers.get(name)) |timer| {
            return timer.read();
        }
        return 0;
    }
    
    pub fn printReport(self: @This()) !void {
        std.log.info("Build Performance Report:", .{});
        std.log.info("========================", .{});
        
        var iterator = self.timers.iterator();
        var total_time: u64 = 0;
        
        while (iterator.next()) |entry| {
            const time_ns = entry.value_ptr.read();
            total_time += time_ns;
            
            std.log.info("{s}: {d:.2}ms", .{
                entry.key_ptr.*,
                @as(f64, @floatFromInt(time_ns)) / std.time.ns_per_ms
            });
        }
        
        std.log.info("Total: {d:.2}ms", .{
            @as(f64, @floatFromInt(total_time)) / std.time.ns_per_ms
        });
    }
};

// Integration into build system
pub fn build(b: *std.Build) void {
    var profiler = BuildProfiler.init(b.allocator);
    
    try profiler.startTimer("command_discovery");
    const commands = discoverCommands(b);
    _ = try profiler.endTimer("command_discovery");
    
    try profiler.startTimer("registry_generation");
    const registry = generateRegistry(b, commands);
    _ = try profiler.endTimer("registry_generation");
    
    try profiler.startTimer("compilation");
    const exe = buildExecutable(b, registry);
    _ = try profiler.endTimer("compilation");
    
    if (b.enable_profiling) {
        try profiler.printReport();
    }
}
```

### 5. Parallel Build Optimization
```zig
const ParallelBuilder = struct {
    thread_pool: std.Thread.Pool,
    build: *std.Build,
    
    pub fn init(b: *std.Build, thread_count: u32) !@This() {
        var pool: std.Thread.Pool = undefined;
        try pool.init(.{ .allocator = b.allocator, .n_jobs = thread_count });
        
        return .{
            .thread_pool = pool,
            .build = b,
        };
    }
    
    pub fn deinit(self: *@This()) void {
        self.thread_pool.deinit();
    }
    
    pub fn buildCommandsParallel(self: *@This(), commands: []const CommandInfo) !void {
        var wait_group = std.Thread.WaitGroup{};
        
        for (commands) |command| {
            wait_group.start();
            
            try self.thread_pool.spawn(buildCommandWorker, .{ &wait_group, self.build, command });
        }
        
        wait_group.wait();
    }
    
    fn buildCommandWorker(wait_group: *std.Thread.WaitGroup, build: *std.Build, command: CommandInfo) void {
        defer wait_group.finish();
        
        // Build individual command module
        buildCommandModule(build, command) catch |err| {
            std.log.err("Failed to build command {s}: {}", .{ command.name, err });
        };
    }
};
```

### 6. Advanced CI/CD Configuration
```yaml
# .github/workflows/enhanced-ci.yml
name: Enhanced CI/CD

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main ]

env:
  ZIG_VERSION: "0.14.1"

jobs:
  # Build matrix for multiple targets
  build-matrix:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
        arch: [x86_64, aarch64]
        exclude:
          - os: windows-latest
            arch: aarch64  # Windows ARM not commonly used in CI
    
    runs-on: ${{ matrix.os }}
    
    steps:
    - uses: actions/checkout@v4
    
    - name: Setup Zig
      uses: goto-bus-stop/setup-zig@v2
      with:
        version: ${{ env.ZIG_VERSION }}
    
    - name: Cache Zig artifacts
      uses: actions/cache@v3
      with:
        path: |
          .zig-cache
          zig-out
        key: ${{ runner.os }}-${{ matrix.arch }}-zig-${{ hashFiles('build.zig', 'src/**/*.zig') }}
        restore-keys: |
          ${{ runner.os }}-${{ matrix.arch }}-zig-
    
    - name: Build for target
      run: |
        zig build -Dtarget=${{ matrix.arch }}-${{ matrix.os == 'ubuntu-latest' && 'linux' || matrix.os == 'macos-latest' && 'macos' || 'windows' }} -Doptimize=ReleaseFast
    
    - name: Run tests
      run: zig build test
    
    - name: Upload artifacts
      uses: actions/upload-artifact@v3
      with:
        name: zcli-${{ matrix.os }}-${{ matrix.arch }}
        path: zig-out/bin/

  # Performance benchmarking
  benchmark:
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'
    
    steps:
    - uses: actions/checkout@v4
      with:
        fetch-depth: 0  # Need full history for comparison
    
    - name: Setup Zig
      uses: goto-bus-stop/setup-zig@v2
      with:
        version: ${{ env.ZIG_VERSION }}
    
    - name: Run benchmarks on PR
      run: |
        zig build benchmark > pr_benchmark.txt
    
    - name: Checkout main branch
      run: |
        git checkout main
        zig build benchmark > main_benchmark.txt
    
    - name: Compare performance
      run: |
        python scripts/compare-benchmarks.py main_benchmark.txt pr_benchmark.txt > performance_report.md
    
    - name: Comment performance results
      uses: actions/github-script@v6
      with:
        script: |
          const fs = require('fs');
          const report = fs.readFileSync('performance_report.md', 'utf8');
          
          github.rest.issues.createComment({
            issue_number: context.issue.number,
            owner: context.repo.owner,
            repo: context.repo.repo,
            body: '## Performance Comparison\n\n' + report
          });

  # Security scanning
  security:
    runs-on: ubuntu-latest
    
    steps:
    - uses: actions/checkout@v4
    
    - name: Run security scan
      run: |
        # Scan for hardcoded secrets
        docker run --rm -v "$PWD":/path trufflesecurity/trufflehog:latest filesystem /path
        
        # Scan for vulnerable dependencies (if any)
        # This would be expanded based on actual dependencies
        
        # Custom security checks
        bash scripts/security-scan.sh

  # Documentation deployment
  docs:
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    
    steps:
    - uses: actions/checkout@v4
    
    - name: Setup Zig
      uses: goto-bus-stop/setup-zig@v2
      with:
        version: ${{ env.ZIG_VERSION }}
    
    - name: Generate documentation
      run: |
        zig build docs
        
    - name: Deploy to GitHub Pages
      uses: peaceiris/actions-gh-pages@v3
      with:
        github_token: ${{ secrets.GITHUB_TOKEN }}
        publish_dir: ./docs/generated
```

### 7. Developer Productivity Tools
```zig
// tools/dev-helper.zig - Development productivity tools
const std = @import("std");

const DevHelper = struct {
    pub fn watchAndBuild(allocator: std.mem.Allocator) !void {
        std.log.info("Starting file watcher...", .{});
        
        var last_build_time: i64 = 0;
        
        while (true) {
            // Check for file changes in src/ directory
            const src_mtime = try getDirectoryMtime("src");
            
            if (src_mtime > last_build_time) {
                std.log.info("Changes detected, rebuilding...", .{});
                
                const result = try std.process.Child.run(.{
                    .allocator = allocator,
                    .argv = &.{ "zig", "build", "test" },
                });
                defer allocator.free(result.stdout);
                defer allocator.free(result.stderr);
                
                if (result.term.Exited == 0) {
                    std.log.info("✅ Build successful", .{});
                } else {
                    std.log.err("❌ Build failed:", .{});
                    std.log.err("{s}", .{result.stderr});
                }
                
                last_build_time = std.time.timestamp();
            }
            
            std.time.sleep(1 * std.time.ns_per_s);  // Check every second
        }
    }
    
    pub fn generateTemplateCommand(name: []const u8, allocator: std.mem.Allocator) !void {
        const template =
            \\const zcli = @import("zcli");
            \\
            \\pub const Args = struct {
            \\    // Add your positional arguments here
            \\};
            \\
            \\pub const Options = struct {
            \\    // Add your options here
            \\    verbose: bool = false,
            \\};
            \\
            \\pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
            \\    _ = args;
            \\    _ = options;
            \\    
            \\    try context.stdout().print("Hello from {s} command!\n", .{"{s}"});
            \\}
        ;
        
        const command_dir = try std.fmt.allocPrint(allocator, "src/commands/{s}.zig", .{name});
        defer allocator.free(command_dir);
        
        const content = try std.fmt.allocPrint(allocator, template, .{name});
        defer allocator.free(content);
        
        try std.fs.cwd().writeFile(.{ .sub_path = command_dir, .data = content });
        
        std.log.info("✅ Created command template: {s}", .{command_dir});
    }
    
    pub fn analyzeCodeComplexity(allocator: std.mem.Allocator) !void {
        // Simple code complexity analyzer
        const src_files = try findZigFiles(allocator, "src");
        defer allocator.free(src_files);
        
        std.log.info("Code Complexity Analysis:", .{});
        std.log.info("========================", .{});
        
        for (src_files) |file_path| {
            const content = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
            defer allocator.free(content);
            
            const complexity = analyzeFileComplexity(content);
            
            std.log.info("{s}: {d} lines, complexity: {d}", .{ file_path, complexity.lines, complexity.cyclomatic });
        }
    }
};

// Build integration
pub fn build(b: *std.Build) void {
    // Add development tools
    const dev_helper = b.addExecutable(.{
        .name = "zcli-dev",
        .root_source_file = .{ .path = "tools/dev-helper.zig" },
        .target = b.host,
    });
    
    // Development commands
    const watch_cmd = b.addRunArtifact(dev_helper);
    watch_cmd.addArg("watch");
    
    const watch_step = b.step("watch", "Watch files and rebuild on changes");
    watch_step.dependOn(&watch_cmd.step);
    
    // Template generation
    const template_cmd = b.addRunArtifact(dev_helper);
    template_cmd.addArg("template");
    if (b.args) |args| {
        template_cmd.addArgs(args);
    }
    
    const template_step = b.step("new-command", "Generate new command template");
    template_step.dependOn(&template_cmd.step);
}
```

### 8. Build Configuration Management
```zig
// build-config.zig - Centralized build configuration
pub const BuildConfig = struct {
    // Compilation settings
    enable_lto: bool = true,
    enable_strip: bool = false,
    enable_profiling: bool = false,
    
    // Feature flags
    enable_plugins: bool = true,
    enable_completions: bool = true,
    enable_documentation: bool = true,
    
    // Performance tuning
    parallel_builds: bool = true,
    max_build_threads: u32 = 0,  // 0 = auto-detect
    enable_build_cache: bool = true,
    
    // Development settings
    enable_debug_info: bool = true,
    enable_assertions: bool = true,
    enable_sanitizers: bool = false,
    
    pub fn fromEnvironment() @This() {
        return .{
            .enable_lto = std.posix.getenv("ZCLI_ENABLE_LTO") != null,
            .enable_profiling = std.posix.getenv("ZCLI_PROFILE_BUILD") != null,
            .parallel_builds = std.posix.getenv("ZCLI_PARALLEL_BUILD") == null or 
                              !std.mem.eql(u8, std.posix.getenv("ZCLI_PARALLEL_BUILD").?, "0"),
            .enable_sanitizers = std.posix.getenv("ZCLI_SANITIZERS") != null,
        };
    }
    
    pub fn apply(self: @This(), exe: *std.Build.Step.Compile) void {
        if (self.enable_lto) {
            exe.want_lto = true;
        }
        
        if (self.enable_strip) {
            exe.strip = true;
        }
        
        if (!self.enable_debug_info) {
            exe.strip_debug_info = true;
        }
        
        if (self.enable_sanitizers) {
            exe.sanitize_thread = true;
            exe.sanitize_undefined_behavior = true;
        }
    }
};
```

## Documentation and Guides

### Build System Guide
```markdown
# zcli Build System Guide

## Quick Start
```bash
# Basic build
zig build

# Build with optimizations
zig build -Doptimize=ReleaseFast

# Cross-compile for all targets
zig build cross-compile

# Build with profiling
ZCLI_PROFILE_BUILD=1 zig build
```

## Advanced Configuration

### Environment Variables
- `ZCLI_ENABLE_LTO=1`: Enable Link Time Optimization
- `ZCLI_PROFILE_BUILD=1`: Enable build profiling
- `ZCLI_PARALLEL_BUILD=0`: Disable parallel builds
- `ZCLI_SANITIZERS=1`: Enable runtime sanitizers

### Custom Build Options
```zig
// build.zig customization
pub fn build(b: *std.Build) void {
    const config = BuildConfig.fromEnvironment();
    
    // Override specific settings
    var custom_config = config;
    custom_config.enable_plugins = false;  // Disable plugins for this build
    
    buildWithConfig(b, custom_config);
}
```
```

## Performance Benchmarks

### Build Time Improvements
- **Caching**: 30-50% faster incremental builds
- **Parallel builds**: 2-4x faster on multi-core systems
- **Cross-compilation**: All targets built in parallel
- **Profile-guided optimization**: 10-15% runtime performance improvement

## Acceptance Criteria
- [ ] Enhanced caching system reduces incremental build times by >30%
- [ ] Cross-compilation support for all major platforms (Linux, macOS, Windows, ARM64)
- [ ] Automated development environment setup script
- [ ] Build performance monitoring and reporting
- [ ] Parallel build optimization for multi-core systems
- [ ] Comprehensive CI/CD pipeline with matrix builds
- [ ] Developer productivity tools (file watching, template generation)
- [ ] Build configuration management system
- [ ] Documentation and guides for build system usage

## Estimated Effort
**3-4 weeks** (1 week per major component: caching/performance, cross-compilation, dev tools, CI/CD)