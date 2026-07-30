//! Fuzz targets for zcli's public parsing seams.
//!
//! `zig build fuzz-smoke` runs both fixed corpora below deterministically.
//! `zig build fuzz --fuzz=50K` coverage-guides the in-memory argv properties.
//! Response-file expansion stays in the deterministic Smith corpus because
//! repeating real filesystem I/O inside Zig 0.16's multi-instance fuzzer does
//! not terminate reliably on hosted Linux/x86_64 runners.

const std = @import("std");
const zcli = @import("zcli");
const testing = std.testing;

const Args = struct {
    first: ?[]const u8 = null,
    rest: []const []const u8 = &.{},
};

const Mode = enum { safe, fast, thorough };

const Options = struct {
    verbose: bool = false,
    quiet: bool = false,
    count: u16 = 0,
    mode: Mode = .safe,
    output: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
};

const options_meta = .{ .options = .{
    .verbose = .{ .short = 'v' },
    .quiet = .{ .short = 'q' },
    .count = .{ .short = 'c' },
    .mode = .{ .short = 'm' },
    .output = .{ .short = 'o' },
    .tags = .{ .short = 't' },
} };

// Smith's corpus encoding for `slice` is a little-endian u32 length followed
// by that many bytes. These are semantic seeds, not a list of expected crash
// strings: the assertions below are metamorphic/lifetime properties and Zig's
// fuzzer mutates the decisions represented by these bytes.
const argv_corpus = &.{
    "\x09\x00\x00\x00--count=7" ++
        "\x09\x00\x00\x00--tags=a,b" ++
        "\x05\x00\x00\x00input" ++
        "\x00\x00\x00\x00",
    "\x03\x00\x00\x00-vq" ++
        "\x07\x00\x00\x00--mode=" ++
        "\x02\x00\x00\x00\xC3\x28" ++
        "\x02\x00\x00\x00--" ++
        "\x08\x00\x00\x00--literal" ++
        "\x00\x00\x00\x00",
};

test "fuzz public argv parser seams" {
    // One std.testing.fuzz call deliberately owns both in-memory properties.
    // Zig 0.16's
    // fuzzer schedules fuzz *tests*, not every call across a test artifact, so
    // separate test blocks can starve behind the first selected target during
    // a short CI run. One callback guarantees every generated input drives
    // both the arbitrary-argv and equivalent-spelling properties.
    try testing.fuzz({}, fuzzParsers, .{
        .corpus = &.{
            argv_corpus[0],
            argv_corpus[1],
            // Metamorphic seed: count=7, output="out", tag="alpha", positional="input".
            "\x07\x00\x00\x00\x00\x00\x00\x00" ++
                "\x03\x00\x00\x00out" ++
                "\x05\x00\x00\x00alpha" ++
                "\x05\x00\x00\x00input",
            // Response-line shapes including spaces and arbitrary bytes.
            "\x05\x00\x00\x00alpha" ++
                "\x08\x00\x00\x00two words" ++
                "\x04\x00\x00\x00\x00\x1B\xFFx" ++
                "\x00\x00\x00\x00",
        },
    });
}

test "response-file parser Smith corpus" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var context: ResponseContext = .{ .dir = tmp.dir };

    // Keep real filesystem I/O out of the coverage-guided callback. Zig 0.16's
    // Linux/x86_64 fuzz runner may launch multiple instances; repeatedly
    // writing fixed paths from that callback exhausted CI timeouts even at a
    // 1K bound. The checked-in Smith inputs still exercise arbitrary bytes,
    // CRLF/LF trimming, comments, nested @ literals, expansion, and parsing in
    // every ordinary test/fuzz-smoke run.
    inline for (argv_corpus) |input| {
        var smith: testing.Smith = .{ .in = input };
        try fuzzResponseFile(&context, &smith);
    }
    var empty: testing.Smith = .{ .in = "" };
    try fuzzResponseFile(&context, &empty);
}

fn fuzzParsers(_: void, smith: *testing.Smith) !void {
    try fuzzArgv({}, smith);
    try fuzzEquivalentSpellings({}, smith);
}

fn fuzzArgv(_: void, smith: *testing.Smith) !void {
    var storage: [12][64]u8 = undefined;
    var argv_storage: [storage.len][]const u8 = undefined;
    var argc: usize = 0;
    while (argc < storage.len) : (argc += 1) {
        const len = smith.slice(&storage[argc]);
        if (len == 0) break;
        argv_storage[argc] = storage[argc][0..len];
    }
    const argv = argv_storage[0..argc];

    var first_diag: ?zcli.ZcliDiagnostic = null;
    const first_parse = zcli.parseCommandLine(
        Args,
        Options,
        options_meta,
        testing.allocator,
        null,
        argv,
        &first_diag,
    );

    if (first_parse) |first| {
        defer first.deinit();

        // Successful string results must remain views into caller-owned argv.
        // This catches copying, truncation at NUL, and dangling temporary data.
        if (first.args.first) |value| try expectExactArg(argv, value);
        for (first.args.rest) |value| try expectExactArg(argv, value);
        if (first.options.output) |value| try expectContainedInArg(argv, value);
        for (first.options.tags) |value| try expectContainedInArg(argv, value);

        // Parsing is stateless: the same byte slices must produce the same
        // success/error branch and values on an immediate second invocation.
        var second_diag: ?zcli.ZcliDiagnostic = null;
        const second = try zcli.parseCommandLine(
            Args,
            Options,
            options_meta,
            testing.allocator,
            null,
            argv,
            &second_diag,
        );
        defer second.deinit();
        try expectEquivalent(first, second);
    } else |first_err| {
        var second_diag: ?zcli.ZcliDiagnostic = null;
        const second_parse = zcli.parseCommandLine(
            Args,
            Options,
            options_meta,
            testing.allocator,
            null,
            argv,
            &second_diag,
        );
        if (second_parse) |second| {
            second.deinit();
            return error.NonRepeatableParserResult;
        } else |second_err| {
            try testing.expectEqual(first_err, second_err);
        }
    }
}

fn fuzzEquivalentSpellings(_: void, smith: *testing.Smith) !void {
    const count = smith.value(u16);

    var output_buf: [48]u8 = undefined;
    const output_len = smith.slice(&output_buf);
    normalizeSeparatedValue(output_buf[0..output_len]);
    const output = output_buf[0..output_len];

    var tag_buf: [48]u8 = undefined;
    var tag_len = smith.slice(&tag_buf);
    // Empty CSV segments are deliberately invalid. Keep this metamorphic
    // target in the success domain so all three spellings can be compared.
    if (tag_len == 0) {
        tag_buf[0] = 'x';
        tag_len = 1;
    }
    normalizeSeparatedValue(tag_buf[0..tag_len]);
    for (tag_buf[0..tag_len]) |*byte| {
        if (byte.* == ',') byte.* = '_';
    }
    const tag = tag_buf[0..tag_len];

    var positional_buf: [48]u8 = undefined;
    const positional_len = smith.slice(&positional_buf);
    const positional = positional_buf[0..positional_len];

    var count_buf: [5]u8 = undefined;
    const count_text = try std.fmt.bufPrint(&count_buf, "{d}", .{count});

    var long_count_buf: [16]u8 = undefined;
    const long_count = try concat(&long_count_buf, "--count=", count_text);
    var short_count_buf: [8]u8 = undefined;
    const short_count = try concat(&short_count_buf, "-c", count_text);

    var long_output_buf: [64]u8 = undefined;
    const long_output = try concat(&long_output_buf, "--output=", output);
    var short_output_buf: [64]u8 = undefined;
    const short_output = try concat(&short_output_buf, "-o=", output);

    var long_tag_buf: [64]u8 = undefined;
    const long_tag = try concat(&long_tag_buf, "--tags=", tag);
    var short_tag_buf: [64]u8 = undefined;
    const short_tag = try concat(&short_tag_buf, "-t=", tag);

    // Same command represented with separated long values, attached long
    // values, and attached/bundled short values, in different orders.
    const separated = [_][]const u8{
        "--verbose", "--quiet", "--count", count_text, "--output",
        output,      "--tags",  tag,       "--",       positional,
    };
    const long_attached = [_][]const u8{
        long_tag, long_output, long_count, "--quiet", "--verbose", "--", positional,
    };
    const short_attached = [_][]const u8{
        "-vq", short_count, short_output, short_tag, "--", positional,
    };

    const a = try parseMustSucceed(&separated);
    defer a.deinit();
    const b = try parseMustSucceed(&long_attached);
    defer b.deinit();
    const c = try parseMustSucceed(&short_attached);
    defer c.deinit();

    try expectEquivalent(a, b);
    try expectEquivalent(a, c);
    try testing.expectEqual(count, a.options.count);
    try testing.expectEqualStrings(output, a.options.output.?);
    try testing.expectEqualStrings(tag, a.options.tags[0]);
    try testing.expectEqualStrings(positional, a.args.first.?);
}

const ResponseContext = struct {
    dir: std.Io.Dir,
};

fn fuzzResponseFile(context: *ResponseContext, smith: *testing.Smith) !void {
    var line_storage: [6][48]u8 = undefined;
    var values_storage: [line_storage.len][50]u8 = undefined;
    var values: [line_storage.len][]const u8 = undefined;
    var value_count: usize = 0;

    while (value_count < line_storage.len) : (value_count += 1) {
        const len = smith.slice(&line_storage[value_count]);
        if (len == 0) break;
        for (line_storage[value_count][0..len]) |*byte| {
            if (byte.* == '\n' or byte.* == '\r') byte.* = '_';
        }
        values_storage[value_count][0] = 'x';
        @memcpy(values_storage[value_count][1..][0..len], line_storage[value_count][0..len]);
        values_storage[value_count][len + 1] = 'x';
        values[value_count] = values_storage[value_count][0 .. len + 2];
    }

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(testing.allocator);
    try content.appendSlice(testing.allocator, "# ignored comment\r\n \t\r\n");
    for (values[0..value_count], 0..) |value, i| {
        // Exercise trimming and both line-ending forms without changing the
        // expected argument bytes (the x sentinels protect arbitrary edges).
        try content.append(testing.allocator, '\t');
        try content.appendSlice(testing.allocator, value);
        try content.append(testing.allocator, ' ');
        try content.appendSlice(testing.allocator, if (i % 2 == 0) "\r\n" else "\n");
    }
    // If expansion accidentally becomes recursive this resolves to "wrong";
    // the documented single-level result is the literal @nested.rsp token.
    try content.appendSlice(testing.allocator, "@nested.rsp\n");

    try context.dir.writeFile(testing.io, .{ .sub_path = "nested.rsp", .data = "wrong\n" });
    try context.dir.writeFile(testing.io, .{ .sub_path = "input.rsp", .data = content.items });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: ?zcli.response_file.Diagnostic = null;
    const source_argv = [_][]const u8{ "prefix", "@input.rsp", "--", "@literal" };
    const expanded = try zcli.response_file.expandArgs(
        arena.allocator(),
        testing.io,
        context.dir,
        &source_argv,
        &diag,
    );

    try testing.expect(diag == null);
    try testing.expectEqual(4 + value_count, expanded.len);
    try testing.expectEqualStrings("prefix", expanded[0]);
    try testing.expectEqual(source_argv[0].ptr, expanded[0].ptr);
    for (values[0..value_count], expanded[1 .. 1 + value_count]) |expected, actual| {
        try testing.expectEqualStrings(expected, actual);
    }
    try testing.expectEqualStrings("@nested.rsp", expanded[1 + value_count]);
    try testing.expectEqualStrings("--", expanded[2 + value_count]);
    try testing.expectEqualStrings("@literal", expanded[3 + value_count]);
    try testing.expectEqual(source_argv[3].ptr, expanded[3 + value_count].ptr);

    // Drive the next public seam too: direct argv and response-file argv must
    // bind to the same positionals after the parser consumes `--`.
    const parsed = try zcli.parseCommandLine(
        struct { values: []const []const u8 },
        struct {},
        null,
        arena.allocator(),
        null,
        expanded,
        null,
    );
    defer parsed.deinit();
    try testing.expectEqual(3 + value_count, parsed.args.values.len);
    try testing.expectEqualStrings("prefix", parsed.args.values[0]);
    for (values[0..value_count], parsed.args.values[1 .. 1 + value_count]) |expected, actual| {
        try testing.expectEqualStrings(expected, actual);
    }
    try testing.expectEqualStrings("@nested.rsp", parsed.args.values[1 + value_count]);
    try testing.expectEqualStrings("@literal", parsed.args.values[2 + value_count]);
}

fn parseMustSucceed(argv: []const []const u8) !zcli.CommandParseResult(Args, Options) {
    return zcli.parseCommandLine(
        Args,
        Options,
        options_meta,
        testing.allocator,
        null,
        argv,
        null,
    );
}

fn expectEquivalent(
    a: zcli.CommandParseResult(Args, Options),
    b: zcli.CommandParseResult(Args, Options),
) !void {
    try testing.expectEqual(a.args.first == null, b.args.first == null);
    if (a.args.first) |value| try testing.expectEqualStrings(value, b.args.first.?);
    try testing.expectEqual(a.args.rest.len, b.args.rest.len);
    for (a.args.rest, b.args.rest) |left, right| try testing.expectEqualStrings(left, right);

    try testing.expectEqual(a.options.verbose, b.options.verbose);
    try testing.expectEqual(a.options.quiet, b.options.quiet);
    try testing.expectEqual(a.options.count, b.options.count);
    try testing.expectEqual(a.options.mode, b.options.mode);
    try testing.expectEqual(a.options.output == null, b.options.output == null);
    if (a.options.output) |value| try testing.expectEqualStrings(value, b.options.output.?);
    try testing.expectEqual(a.options.tags.len, b.options.tags.len);
    for (a.options.tags, b.options.tags) |left, right| try testing.expectEqualStrings(left, right);
}

fn expectExactArg(argv: []const []const u8, value: []const u8) !void {
    for (argv) |arg| {
        if (arg.ptr == value.ptr and arg.len == value.len) return;
    }
    return error.ResultDoesNotBorrowArg;
}

fn expectContainedInArg(argv: []const []const u8, value: []const u8) !void {
    const value_start = @intFromPtr(value.ptr);
    const value_end = value_start + value.len;
    for (argv) |arg| {
        const arg_start = @intFromPtr(arg.ptr);
        const arg_end = arg_start + arg.len;
        if (value_start >= arg_start and value_end <= arg_end) return;
    }
    return error.ResultDoesNotBorrowArg;
}

fn normalizeSeparatedValue(value: []u8) void {
    if (value.len > 0 and value[0] == '-') value[0] = 'x';
}

fn concat(buffer: []u8, prefix: []const u8, value: []const u8) ![]const u8 {
    if (prefix.len + value.len > buffer.len) return error.NoSpaceLeft;
    @memcpy(buffer[0..prefix.len], prefix);
    @memcpy(buffer[prefix.len..][0..value.len], value);
    return buffer[0 .. prefix.len + value.len];
}
