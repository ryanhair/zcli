# ZTheme Markdown DSL Implementation Plan

## Overview

Implement a comptime markdown-style DSL for ZTheme that allows developers to write styled CLI output using familiar markdown syntax combined with semantic HTML-like tags. All parsing and optimization happens at compile time for zero runtime overhead.

## Goals

1. **Familiar Syntax**: Use markdown that developers already know
2. **Clear Content Separation**: Easy to see actual content vs styling
3. **Compile-time Processing**: Zero runtime parsing cost
4. **Semantic Integration**: Support for ZTheme's semantic roles
5. **Optimal ANSI Output**: Generate minimal, efficient escape sequences
6. **Type Safety**: Compile-time validation of style combinations

## Target API

```zig
// Basic markdown styling
const text1 = ztheme.md("*Hi there, this is **important!***");

// Semantic roles
const text2 = ztheme.md("<success>✓ Build completed</success> with <warning>3 warnings</warning>");

// Mixed syntax
const text3 = ztheme.md("**Error:** <error>Connection failed</error>");

// Complex nesting
const text4 = ztheme.md(
    \\## Build Report
    \\
    \\Status: <success>**Completed**</success>
    \\Command: <command>`cargo build --release`</command>
    \\Output: <path>*target/release/app*</path>
);

// All render the same way
try text1.render(writer, &theme_ctx);
```

## Supported Syntax

### Phase 1: Basic Markdown
- `*italic*` → italic text
- `**bold**` → bold text  
- `***bold italic***` → bold + italic
- `` `code` `` → monospace/code style
- `~~strikethrough~~` → strikethrough text

### Phase 2: Semantic Tags
- `<success>text</success>` → semantic success color
- `<error>text</error>` → semantic error color
- `<warning>text</warning>` → semantic warning color
- `<info>text</info>` → semantic info color
- `<muted>text</muted>` → semantic muted color

### Phase 3: Extended Semantic Tags
- `<command>text</command>` → command styling
- `<flag>text</flag>` → flag styling
- `<path>text</path>` → path styling
- `<link>text</link>` → link styling
- `<value>text</value>` → value styling
- `<header>text</header>` → header styling
- `<code>text</code>` → code styling (alternative to backticks)

### Phase 4: Advanced Features
- `# Header` → header styling with semantic role
- `## Subheader` → subheader styling
- Line breaks and paragraph handling
- Escaped characters: `\*not italic\*`
- Mixed nesting validation

## Implementation Phases

### Phase 1: Foundation (Week 1)
1. **Create DSL module structure**
   - `src/ztheme/dsl/` directory
   - `markdown.zig` - main parser
   - `ast.zig` - AST node definitions
   - `renderer.zig` - AST to ANSI conversion

2. **Basic tokenizer**
   - Tokenize markdown syntax at comptime
   - Handle `*`, `**`, `` ` `` tokens
   - Basic error reporting

3. **Simple parser**
   - Parse italic and bold markdown
   - Build AST from tokens
   - Handle simple nesting

4. **Basic renderer**
   - Convert AST to styled text
   - Generate ANSI escape sequences
   - Integrate with existing ZTheme style system

### Phase 2: Semantic Integration (Week 2)
1. **XML-like tag parser**
   - Parse `<tag>content</tag>` syntax
   - Validate known semantic tags
   - Error handling for malformed tags

2. **Semantic role mapping**
   - Map tag names to `SemanticRole` enum
   - Integrate with palette system
   - Handle unknown tags gracefully

3. **Mixed syntax support**
   - Combine markdown and semantic tags
   - Proper precedence handling
   - Nesting validation

### Phase 3: Advanced Parsing (Week 3)
1. **Complex nesting support**
   - Handle deeply nested styles
   - Optimize ANSI sequence generation
   - Style inheritance and combination

2. **Extended semantic tags**
   - Add all CLI-specific semantic roles
   - Custom tag validation
   - Documentation generation

3. **Performance optimization**
   - Minimize comptime compilation overhead
   - Optimize generated ANSI sequences
   - Memory-efficient AST representation

### Phase 4: Polish & Features (Week 4)
1. **Advanced markdown features**
   - Headers (`#`, `##`)
   - Escape sequences (`\*`)
   - Line break handling

2. **Developer experience**
   - Comprehensive error messages
   - Debugging utilities
   - Documentation and examples

3. **Testing and validation**
   - Complete test coverage
   - Performance benchmarks
   - Real-world usage examples

## Technical Architecture

### AST Node Types
```zig
const NodeType = enum {
    text,           // Plain text
    italic,         // *text*
    bold,           // **text**
    bold_italic,    // ***text***
    code,           // `text`
    strikethrough,  // ~~text~~
    semantic,       // <tag>text</tag>
    header,         // # text
    root,           // Container node
};

const AstNode = struct {
    node_type: NodeType,
    content: []const u8,
    semantic_role: ?SemanticRole = null,
    children: []const AstNode = &.{},
};
```

### Parser Architecture
```zig
const Parser = struct {
    source: []const u8,
    pos: usize,
    
    fn parse(comptime source: []const u8) []const AstNode { ... }
    fn parseNode() AstNode { ... }
    fn parseMarkdown() AstNode { ... }
    fn parseSemanticTag() AstNode { ... }
};
```

### Renderer Architecture
```zig
const Renderer = struct {
    fn render(nodes: []const AstNode, capability: TerminalCapability) ComptimeString { ... }
    fn renderNode(node: AstNode, capability: TerminalCapability) ComptimeString { ... }
    fn optimizeAnsiSequences(sequences: []const []const u8) []const u8 { ... }
};
```

## Testing Strategy

### Unit Tests
- Tokenizer tests for each syntax element
- Parser tests for various combinations
- AST validation tests
- Renderer output verification
- Error case handling

### Integration Tests
- Full pipeline tests (source → AST → ANSI)
- Capability-specific rendering tests
- Performance benchmarks
- Memory usage validation

### Real-world Tests
- CLI output examples
- Complex nested scenarios
- Edge case handling
- Cross-platform compatibility

## Success Metrics

1. **Performance**: Comptime parsing adds <1s to compilation
2. **Correctness**: 100% test coverage, all edge cases handled
3. **Usability**: Intuitive API that reduces styling code by 70%
4. **Compatibility**: Works across all terminal capabilities
5. **Maintainability**: Clear, well-documented codebase

## Risks and Mitigations

### Risk: Comptime Performance
- **Mitigation**: Incremental parsing, efficient AST representation
- **Monitoring**: Compilation time benchmarks

### Risk: Complex Nesting Edge Cases
- **Mitigation**: Comprehensive test suite, formal grammar
- **Monitoring**: Fuzzing tests, user feedback

### Risk: API Complexity
- **Mitigation**: Extensive documentation, examples
- **Monitoring**: Developer feedback, usage analytics

## Deliverables

1. **Implementation**
   - Complete DSL parser and renderer
   - Integration with existing ZTheme API
   - Comprehensive test suite

2. **Documentation**
   - API reference documentation
   - Usage examples and tutorials
   - Migration guide from current API

3. **Validation**
   - Performance benchmarks
   - Cross-platform testing results
   - User acceptance testing

## Timeline

- **Week 1**: Basic markdown parsing (`*`, `**`, `` ` ``)
- **Week 2**: Semantic tag integration (`<success>`, etc.)
- **Week 3**: Advanced features and optimization
- **Week 4**: Polish, documentation, and validation

## Next Steps

1. Create comprehensive test suite (this document)
2. Set up DSL module structure
3. Implement basic tokenizer
4. Begin Phase 1 implementation

---

*This plan serves as the single source of truth for the ZTheme Markdown DSL implementation. All development should reference and update this document as needed.*