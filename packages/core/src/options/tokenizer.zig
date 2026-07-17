//! The one argv tokenizer (#678).
//!
//! Three walkers used to re-implement long/short/bundle/value-lookahead argv
//! walking: the global-option layer (registry/compiled.zig), the pre-split
//! classifier (command_parser.zig), and the options parser (options/parser.zig).
//! The shared predicates in options/utils.zig (`isValueToken`, `isOption`,
//! `longOptionTakesValue`, `shortOptionTakesValue`) kept their *answers* in
//! agreement, but the short-bundle state machine and the next-token value
//! lookahead were still written three times. This module owns both: it turns
//! argv into a classified token stream, and all three walkers consume it.
//!
//! A `Spec` describes the option namespace being tokenized:
//!
//! - `longTakesValue(name) ?bool` — does long option `name` exist, and does it
//!   take a value? `null` means unknown.
//! - `shortTakesValue(char) ?bool` — same for a short option char.
//! - `unknown_short_aborts: bool` — bundle policy for an unknown char seen
//!   before the first value-taking char. The command layers keep walking (the
//!   parser will report the unknown char with a diagnostic); the global layer
//!   cannot partially consume a token, so an unknown char makes the whole
//!   bundle non-consumable (`Shorts.consumable == false`) and suppresses the
//!   value lookahead.
//!
//! The tokenizer only *classifies* — it never resolves names to fields, parses
//! values, or reports errors. Consumers keep their own matching, mutation, and
//! diagnostics; what they can no longer disagree on is where a token's value
//! comes from.

const std = @import("std");
const utils = @import("utils.zig");

/// The `Spec` for a command's `Options` struct + `meta`: delegates to the
/// shared resolution rules in options/utils.zig, so the pre-split classifier
/// and the options parser tokenize with exactly the semantics the parser
/// matches with (custom `meta` names, explicit-only shorts, boolean flags).
pub fn OptionsSpec(comptime OptionsType: type, comptime meta: anytype) type {
    return struct {
        pub const unknown_short_aborts = false;
        pub fn longTakesValue(name: []const u8) ?bool {
            return utils.longOptionTakesValue(OptionsType, meta, name);
        }
        pub fn shortTakesValue(char: u8) ?bool {
            return utils.shortOptionTakesValue(OptionsType, meta, char);
        }
    };
}

/// One step of the short-bundle state machine. Indices point into the bundle's
/// `chars` (the token without its leading `-`), so consumers can slice the
/// exact one-char spelling for diagnostics (`chars[i .. i + 1]`).
pub const ShortStep = union(enum) {
    /// A boolean flag char — consumes nothing, the walk continues.
    flag: usize,
    /// A char the spec doesn't know. Emitted mid-walk; whether the walk was
    /// worth continuing is the consumer's policy (the options parser errors
    /// here, the pre-split keeps classifying, the global layer never sees one
    /// because `unknown_short_aborts` already marked the bundle unconsumable).
    unknown: usize,
    /// The first value-taking char — always the last step. `attached` is the
    /// rest of the token when the char isn't last (`-ovalue`), else null and
    /// the value must come from the next argv token (`Shorts.next_value`).
    value: struct {
        index: usize,
        attached: ?[]const u8,
    },
};

/// The short-bundle walk over `chars`, shared by the tokenizer's own
/// lookahead decision and by consumers that mutate per-char state. GNU getopt
/// semantics: leading boolean flags one at a time; the first value-taking
/// char ends the walk, claiming the rest of the token as its attached value
/// when it isn't the last char.
pub fn ShortWalk(comptime Spec: type) type {
    return struct {
        chars: []const u8,
        i: usize = 0,
        done: bool = false,

        pub fn next(self: *@This()) ?ShortStep {
            if (self.done or self.i >= self.chars.len) return null;
            const idx = self.i;
            const takes_value = Spec.shortTakesValue(self.chars[idx]);
            if (takes_value == true) {
                self.done = true;
                return .{ .value = .{
                    .index = idx,
                    .attached = if (idx + 1 < self.chars.len) self.chars[idx + 1 ..] else null,
                } };
            }
            self.i += 1;
            return if (takes_value == null) .{ .unknown = idx } else .{ .flag = idx };
        }
    };
}

/// A classified argv tokenizer specialized on a `Spec`. Feed it argv; it
/// yields one `Token` per primary argv token, consuming a following token
/// itself when the shared lookahead rule says that token is an option's value
/// (`isValueToken`: a bare word, a negative number, or the bare `-` sentinel —
/// never another flag).
pub fn Tokenizer(comptime Spec: type) type {
    return struct {
        args: []const []const u8,
        /// The argv index of the next unread token. After `next()` returns, it
        /// is past the returned token *and* past any value token it consumed.
        index: usize = 0,
        terminated: bool = false,

        const Self = @This();

        /// A token that classifies no further: its raw argv text and index.
        pub const Item = struct {
            raw: []const u8,
            index: usize,
        };

        /// A `--name` / `--name=value` token.
        pub const Long = struct {
            raw: []const u8,
            index: usize,
            /// The option name (after `--`, before any `=`).
            name: []const u8,
            /// The `=value` part, if the token carried one.
            attached: ?[]const u8,
            /// `Spec.longTakesValue(name)`: null = unknown option.
            takes_value: ?bool,
            /// The following argv token, consumed as this option's value —
            /// non-null only when the option takes a value, no value was
            /// attached, and the next token is a value token.
            next_value: ?[]const u8,

            /// The option's value from either source, or null (missing).
            pub fn value(self: @This()) ?[]const u8 {
                return self.attached orelse self.next_value;
            }
        };

        /// A `-x` / `-xyz` token.
        pub const Shorts = struct {
            raw: []const u8,
            index: usize,
            /// The bundle chars (token without its leading `-`).
            chars: []const u8,
            /// False only under `Spec.unknown_short_aborts` when an unknown
            /// char precedes the first value-taking char: the whole token is
            /// not this namespace's to consume (and no lookahead happened).
            consumable: bool,
            /// The following argv token, consumed as the trailing value-taking
            /// char's value — non-null only when the bundle is consumable, its
            /// value-taker is the last char, and the next token is a value.
            next_value: ?[]const u8,

            /// Iterate the bundle's steps (the same walk the tokenizer used
            /// for its lookahead decision).
            pub fn walk(self: @This()) ShortWalk(Spec) {
                return .{ .chars = self.chars };
            }
        };

        pub const Token = union(enum) {
            /// The first bare `--`: end of options. Every later token —
            /// including further `--` — is yielded as `.positional`.
            terminator: Item,
            /// A value token (bare word, negative number, bare `-`), or
            /// anything at all after the terminator.
            positional: Item,
            long: Long,
            shorts: Shorts,
        };

        pub fn next(self: *Self) ?Token {
            if (self.index >= self.args.len) return null;
            const raw = self.args[self.index];
            const idx = self.index;
            self.index += 1;

            if (self.terminated) return .{ .positional = .{ .raw = raw, .index = idx } };
            if (std.mem.eql(u8, raw, "--")) {
                self.terminated = true;
                return .{ .terminator = .{ .raw = raw, .index = idx } };
            }
            // `isOption` (options/utils.zig — the single source of truth)
            // excludes negative numbers (`-.5`, `-inf`) and the bare `-`
            // stdin/stdout sentinel, which are positionals, not flags.
            if (!utils.isOption(raw)) return .{ .positional = .{ .raw = raw, .index = idx } };

            if (std.mem.startsWith(u8, raw, "--")) {
                const body = raw[2..];
                const eq = std.mem.indexOfScalar(u8, body, '=');
                const name = if (eq) |e| body[0..e] else body;
                const attached: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;
                const takes_value = Spec.longTakesValue(name);
                var next_value: ?[]const u8 = null;
                if (attached == null and takes_value == true) {
                    // The one next-token-is-a-value rule (#299): the following
                    // token is this option's value unless it is itself a flag.
                    if (self.index < self.args.len and utils.isValueToken(self.args[self.index])) {
                        next_value = self.args[self.index];
                        self.index += 1;
                    }
                }
                return .{ .long = .{
                    .raw = raw,
                    .index = idx,
                    .name = name,
                    .attached = attached,
                    .takes_value = takes_value,
                    .next_value = next_value,
                } };
            }

            // Short token `-x` or bundle `-xyz`: walk it once to decide the
            // lookahead (and, under `unknown_short_aborts`, consumability).
            const chars = raw[1..];
            var consumable = true;
            var wants_next = false;
            var probe = ShortWalk(Spec){ .chars = chars };
            while (probe.next()) |step| switch (step) {
                .flag => {},
                .unknown => if (Spec.unknown_short_aborts) {
                    consumable = false;
                    break;
                },
                .value => |v| {
                    wants_next = v.attached == null;
                },
            };
            var next_value: ?[]const u8 = null;
            if (consumable and wants_next and
                self.index < self.args.len and utils.isValueToken(self.args[self.index]))
            {
                next_value = self.args[self.index];
                self.index += 1;
            }
            return .{ .shorts = .{
                .raw = raw,
                .index = idx,
                .chars = chars,
                .consumable = consumable,
                .next_value = next_value,
            } };
        }
    };
}

// ============================================================================
// Tests — the state machine directly, under both bundle policies.
// ============================================================================

const TestOptions = struct {
    verbose: bool = false,
    debug: bool = false,
    file: ?[]const u8 = null,
    count: u32 = 1,
};
const test_meta = .{ .options = .{
    .verbose = .{ .short = 'v' },
    .debug = .{ .short = 'd' },
    .file = .{ .short = 'f' },
} };
const TestSpec = OptionsSpec(TestOptions, test_meta);

/// A spec with the global layer's all-or-nothing bundle policy, over the same
/// namespace, so the two policies can be contrasted on identical input.
const AbortSpec = struct {
    pub const unknown_short_aborts = true;
    pub fn longTakesValue(name: []const u8) ?bool {
        return TestSpec.longTakesValue(name);
    }
    pub fn shortTakesValue(char: u8) ?bool {
        return TestSpec.shortTakesValue(char);
    }
};

test "long: boolean flag does not look ahead" {
    var tok = Tokenizer(TestSpec){ .args = &.{ "--verbose", "input.txt" } };
    const t = tok.next().?.long;
    try std.testing.expectEqualStrings("verbose", t.name);
    try std.testing.expectEqual(@as(?bool, false), t.takes_value);
    try std.testing.expect(t.attached == null);
    try std.testing.expect(t.next_value == null);
    // The word stays a positional.
    try std.testing.expectEqualStrings("input.txt", tok.next().?.positional.raw);
    try std.testing.expect(tok.next() == null);
}

test "long: value option consumes the next value token" {
    var tok = Tokenizer(TestSpec){ .args = &.{ "--count", "5", "rest" } };
    const t = tok.next().?.long;
    try std.testing.expectEqual(@as(?bool, true), t.takes_value);
    try std.testing.expectEqualStrings("5", t.next_value.?);
    try std.testing.expectEqualStrings("5", t.value().?);
    try std.testing.expectEqual(@as(usize, 2), tok.index);
    try std.testing.expectEqualStrings("rest", tok.next().?.positional.raw);
}

test "long: --name=value carries its value attached, no lookahead" {
    var tok = Tokenizer(TestSpec){ .args = &.{ "--count=5", "word" } };
    const t = tok.next().?.long;
    try std.testing.expectEqualStrings("count", t.name);
    try std.testing.expectEqualStrings("5", t.attached.?);
    try std.testing.expect(t.next_value == null);
    try std.testing.expectEqualStrings("word", tok.next().?.positional.raw);
}

test "long: a flag is never consumed as another flag's value (#299)" {
    var tok = Tokenizer(TestSpec){ .args = &.{ "--count", "--verbose" } };
    const t = tok.next().?.long;
    try std.testing.expectEqual(@as(?bool, true), t.takes_value);
    try std.testing.expect(t.next_value == null); // missing value, not "--verbose"
    try std.testing.expectEqualStrings("verbose", tok.next().?.long.name);
}

test "long: negative numbers and bare '-' are value tokens (#287, #315)" {
    inline for ([_][]const u8{ "-5", "-.5", "-inf", "-1e5", "-" }) |val| {
        var tok = Tokenizer(TestSpec){ .args = &.{ "--count", val } };
        try std.testing.expectEqualStrings(val, tok.next().?.long.next_value.?);
        try std.testing.expect(tok.next() == null);
    }
}

test "long: unknown option gets no lookahead" {
    var tok = Tokenizer(TestSpec){ .args = &.{ "--bogus", "word" } };
    const t = tok.next().?.long;
    try std.testing.expectEqual(@as(?bool, null), t.takes_value);
    try std.testing.expect(t.next_value == null);
    try std.testing.expectEqualStrings("word", tok.next().?.positional.raw);
}

test "shorts: all-boolean bundle walks every char, no lookahead" {
    var tok = Tokenizer(TestSpec){ .args = &.{ "-vd", "word" } };
    const t = tok.next().?.shorts;
    try std.testing.expect(t.consumable);
    try std.testing.expect(t.next_value == null);
    var walk = t.walk();
    try std.testing.expectEqual(@as(usize, 0), walk.next().?.flag);
    try std.testing.expectEqual(@as(usize, 1), walk.next().?.flag);
    try std.testing.expect(walk.next() == null);
    try std.testing.expectEqualStrings("word", tok.next().?.positional.raw);
}

test "shorts: trailing value-taker consumes the next value token (#427)" {
    var tok = Tokenizer(TestSpec){ .args = &.{ "-vf", "out.txt" } };
    const t = tok.next().?.shorts;
    try std.testing.expectEqualStrings("out.txt", t.next_value.?);
    var walk = t.walk();
    try std.testing.expectEqual(@as(usize, 0), walk.next().?.flag);
    const v = walk.next().?.value;
    try std.testing.expectEqual(@as(usize, 1), v.index);
    try std.testing.expect(v.attached == null);
    try std.testing.expect(walk.next() == null);
    try std.testing.expect(tok.next() == null);
}

test "shorts: mid-bundle value-taker takes the rest attached, walk stops" {
    var tok = Tokenizer(TestSpec){ .args = &.{ "-vfd", "word" } };
    const t = tok.next().?.shorts;
    try std.testing.expect(t.next_value == null); // rest of token is the value
    var walk = t.walk();
    try std.testing.expectEqual(@as(usize, 0), walk.next().?.flag);
    const v = walk.next().?.value;
    try std.testing.expectEqualStrings("d", v.attached.?); // NOT the -d flag
    try std.testing.expect(walk.next() == null);
    try std.testing.expectEqualStrings("word", tok.next().?.positional.raw);
}

test "shorts: value-taker followed by a flag is a missing value, not a swallow (#299)" {
    var tok = Tokenizer(TestSpec){ .args = &.{ "-f", "--verbose" } };
    try std.testing.expect(tok.next().?.shorts.next_value == null);
    try std.testing.expectEqualStrings("verbose", tok.next().?.long.name);
}

test "shorts: unknown char — command policy keeps walking and looking ahead" {
    var tok = Tokenizer(TestSpec){ .args = &.{ "-xf", "out.txt" } };
    const t = tok.next().?.shorts;
    try std.testing.expect(t.consumable);
    try std.testing.expectEqualStrings("out.txt", t.next_value.?);
    var walk = t.walk();
    try std.testing.expectEqual(@as(usize, 0), walk.next().?.unknown);
    try std.testing.expectEqual(@as(usize, 1), walk.next().?.value.index);
}

test "shorts: unknown char — abort policy marks unconsumable, no lookahead" {
    var tok = Tokenizer(AbortSpec){ .args = &.{ "-xf", "out.txt" } };
    const t = tok.next().?.shorts;
    try std.testing.expect(!t.consumable);
    try std.testing.expect(t.next_value == null);
    // The would-be value stays an ordinary token for the next layer.
    try std.testing.expectEqualStrings("out.txt", tok.next().?.positional.raw);
}

test "shorts: abort policy never checks chars after the value-taker" {
    // `-fx`: f takes a value, so `x` is its attached value, not an option char.
    var tok = Tokenizer(AbortSpec){ .args = &.{"-fx"} };
    const t = tok.next().?.shorts;
    try std.testing.expect(t.consumable);
    var walk = t.walk();
    try std.testing.expectEqualStrings("x", walk.next().?.value.attached.?);
}

test "terminator: everything after the first -- is positional, verbatim" {
    var tok = Tokenizer(TestSpec){ .args = &.{ "--verbose", "--", "--count", "-vf", "--" } };
    try std.testing.expectEqualStrings("verbose", tok.next().?.long.name);
    const term = tok.next().?.terminator;
    try std.testing.expectEqualStrings("--", term.raw);
    try std.testing.expectEqual(@as(usize, 1), term.index);
    try std.testing.expectEqualStrings("--count", tok.next().?.positional.raw);
    try std.testing.expectEqualStrings("-vf", tok.next().?.positional.raw);
    try std.testing.expectEqualStrings("--", tok.next().?.positional.raw);
    try std.testing.expect(tok.next() == null);
}

test "positionals: bare words, negative numbers, bare '-', empty string" {
    var tok = Tokenizer(TestSpec){ .args = &.{ "word", "-5", "-.5", "-inf", "-", "" } };
    var count: usize = 0;
    while (tok.next()) |t| : (count += 1) {
        try std.testing.expect(t == .positional);
        try std.testing.expectEqual(count, t.positional.index);
    }
    try std.testing.expectEqual(@as(usize, 6), count);
}

test "index bookkeeping spans consumed value tokens" {
    var tok = Tokenizer(TestSpec){ .args = &.{ "-f", "a", "--count", "1", "w" } };
    const s = tok.next().?.shorts;
    try std.testing.expectEqual(@as(usize, 0), s.index);
    try std.testing.expectEqual(@as(usize, 2), tok.index);
    const l = tok.next().?.long;
    try std.testing.expectEqual(@as(usize, 2), l.index);
    try std.testing.expectEqual(@as(usize, 4), tok.index);
    try std.testing.expectEqual(@as(usize, 4), tok.next().?.positional.index);
}

test "OptionsSpec resolves custom meta names and explicit-only shorts" {
    const Opts = struct {
        output_file: ?[]const u8 = null,
        verbose: bool = false,
    };
    const meta = .{ .options = .{ .output_file = .{ .name = "out", .short = 'o' } } };
    const Spec = OptionsSpec(Opts, meta);
    try std.testing.expectEqual(@as(?bool, true), Spec.longTakesValue("out"));
    try std.testing.expectEqual(@as(?bool, null), Spec.longTakesValue("output-file")); // custom name shadows
    try std.testing.expectEqual(@as(?bool, false), Spec.longTakesValue("verbose"));
    try std.testing.expectEqual(@as(?bool, true), Spec.shortTakesValue('o'));
    try std.testing.expectEqual(@as(?bool, null), Spec.shortTakesValue('v')); // undeclared
}
