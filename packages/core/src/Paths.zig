//! Resolve platform-standard per-user application directories from an
//! explicitly supplied environment.
//!
//! Two orthogonal axes, deliberately NOT one "platform" knob:
//!
//!   convention — WHICH environment variables and fallback tails describe the
//!                location. A *policy*. A tool's own contract may pin this
//!                (bash-completion is XDG-rooted wherever it runs).
//!   syntax     — separators, absoluteness rules, dirname. A property of the
//!                FILESYSTEM being addressed, so anything doing I/O must use
//!                the host's.
//!
//! Resolution is a PURE STRING FUNCTION: `base`/`resolve`/`dir`/`file`/`home`
//! touch no filesystem and need no `io`. Only the `ensure*` family does I/O.
//!
//! The import IS the type, matching `Prompts` / `Progress`. In a command,
//! prefer `context.paths()`, which returns an instance pre-wired to the
//! per-command arena, the threaded environ, and the app name.

const std = @import("std");
const builtin = @import("builtin");

allocator: std.mem.Allocator,
environ: *const std.process.Environ.Map,
/// The directory segment used for this app's private subtree. Validated by
/// every method (see `InvalidAppName`) — `Paths` never trusts its caller.
app_name: []const u8,
/// Which environment variables and fallback tails to use.
convention: Convention = Convention.host,
/// Which path syntax to emit. Must be `.host` for any method that does I/O.
syntax: Syntax = Syntax.host,

const Paths = @This();

/// The three kinds of per-user location a CLI needs.
pub const Kind = enum { config, cache, data };

/// Location policy: which variables, which fallback tails.
pub const Convention = enum {
    windows,
    macos,
    /// XDG Base Directory spec — Linux, the BSDs, and any tool that pins its
    /// own locations to XDG regardless of host (see `zcli_completions`).
    xdg,

    pub const host: Convention = switch (builtin.os.tag) {
        .windows => .windows,
        .macos => .macos,
        else => .xdg,
    };
};

/// Path syntax: separators, absoluteness, dirname.
pub const Syntax = enum {
    posix,
    windows,

    pub const host: Syntax = switch (builtin.os.tag) {
        .windows => .windows,
        else => .posix,
    };

    pub fn sep(self: Syntax) u8 {
        return switch (self) {
            .windows => '\\',
            .posix => '/',
        };
    }

    pub fn isSep(self: Syntax, c: u8) bool {
        return switch (self) {
            .windows => c == '\\' or c == '/',
            .posix => c == '/',
        };
    }

    /// Strictly narrower than `std.fs.path.isAbsoluteWindows`, which is not a
    /// safe "can I append to this" test:
    ///
    ///   * `\foo` is rooted on the *current drive* — process state, not a
    ///     location.
    ///   * bare `\\server` parses as a network share whose disk designator
    ///     swallows the whole string, so appending `{app}` yields
    ///     `\\server\myapp` — the app name becomes the SHARE name.
    ///   * `\\?\…` and `\\.\…` device namespaces bypass normalization.
    ///
    /// So `.windows` accepts exactly two forms: a drive path `X:\…` / `X:/…`
    /// (drive-relative `C:foo` rejected), and a complete UNC root
    /// `\\server\share…` with two non-empty components. `.posix` accepts a
    /// path beginning with `/`.
    pub fn isFullyQualified(self: Syntax, p: []const u8) bool {
        return switch (self) {
            .posix => p.len > 0 and p[0] == '/',
            .windows => windowsRootLen(p) != null,
        };
    }

    /// Length of the root prefix of a fully-qualified `.windows` path — 3 for
    /// `X:\`, or the index just past the share component for `\\server\share`
    /// (never including a trailing separator) — or null when `p` is not
    /// fully qualified.
    ///
    /// ONE parser, answering both "may I append to this?" (`isFullyQualified`)
    /// and "how much of this is root that trailing-separator trimming must not
    /// eat?" (`rootLen`). Those two questions are the same parse, and keeping
    /// them as one implementation is what stops them drifting apart — a drift
    /// whose failure mode is trimming through a share root.
    fn windowsRootLen(p: []const u8) ?usize {
        const w: Syntax = .windows;

        // Drive path `X:\…` / `X:/…`. Drive-*relative* `C:foo` is rejected: it
        // is resolved against the process's per-drive working directory.
        if (p.len >= 3 and isDriveLetter(p[0]) and p[1] == ':' and w.isSep(p[2])) return 3;

        if (p.len >= 2 and w.isSep(p[0]) and w.isSep(p[1])) {
            // Server component: non-empty, and not the `?` / `.` that introduce
            // the device namespaces (`\\?\…`, `\\.\…`), which bypass
            // normalization entirely.
            var i: usize = 2;
            while (i < p.len and !w.isSep(p[i])) i += 1;
            const server = p[2..i];
            if (server.len == 0) return null;
            if (std.mem.eql(u8, server, "?") or std.mem.eql(u8, server, ".")) return null;
            if (i >= p.len) return null; // no separator after the server → no share
            i += 1;
            const share_start = i;
            while (i < p.len and !w.isSep(p[i])) i += 1;
            if (i == share_start) return null;
            return i;
        }
        return null;
    }

    pub fn dirname(self: Syntax, p: []const u8) ?[]const u8 {
        return switch (self) {
            .windows => std.fs.path.dirnameWindows(p),
            .posix => std.fs.path.dirnamePosix(p),
        };
    }
};

pub const ResolveError = error{
    /// No environment variable identifies the user's home / app-data root.
    HomeNotFound,
    /// The variable is set but is empty, relative, or a root form we refuse to
    /// append to (`\foo`, `C:foo`, `\\server`, `\\?\…`).
    HomeNotAbsolute,
    /// A terminal source (`HOME`, `%APPDATA%`, `%LOCALAPPDATA%`) is set but
    /// contains a control byte, or is invalid WTF-8 under `.windows` syntax.
    /// Note an *XDG* variable with the same defect is ignored rather than
    /// fatal — invalid → ignore for the optional override, invalid → error for
    /// the terminal source.
    HomeMalformed,
    /// `app_name` is not usable as a single path segment.
    InvalidAppName,
    /// A `sub_path` / `resolve` component is not usable as a segment.
    InvalidSubPath,
} || std.mem.Allocator.Error;

pub const EnsureError = ResolveError || std.Io.Dir.CreateDirPathError || error{
    /// An `ensure*` call on a `Paths` whose `syntax` is not `Syntax.host`. The
    /// resolver can emit any syntax; the filesystem underneath is always the
    /// host's, so mixing the two is a programming error.
    ForeignSyntax,
    /// `ensureParent` was handed a path that is not fully qualified.
    PathNotFullyQualified,
};

/// `0o700` on POSIX: these directories may hold tokens, and `createDirPath`'s
/// default of `0o777` masked by umask is typically `0755` — world-readable.
/// On Windows `Permissions` is a file-attribute enum where the default is
/// correct (access is governed by inherited ACLs).
const private_dir: std.Io.Dir.Permissions = if (builtin.os.tag == .windows or std.posix.mode_t == u0)
    .default_dir
else
    @enumFromInt(0o700);

fn isDriveLetter(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

// ---- validation ----

/// True when `name` is usable as a single path segment. Pure,
/// allocation-free and comptime-evaluable, so `registry/builder.zig` enforces
/// the identical rule at compile time that `Paths` enforces at runtime — the
/// containment property (every `app_name` the registry accepts is accepted
/// here) then holds by construction rather than by inspection.
///
/// A segment is valid iff all hold:
///
///   1. non-empty;
///   2. it is not composed solely of `.` characters (rejects `.`, `..`, `...`);
///   3. it contains none of `< > : " / \ | ? *` — the full Win32-forbidden set,
///      which subsumes both separators and the drive/ADS colon;
///   4. it contains no control byte (`0x00`–`0x1F`, `0x7F`);
///   5. it has no leading and no trailing ASCII space;
///   6. it has no trailing `.`;
///   7. it is valid WTF-8.
///
/// Rules 2, 5 and 6 close the Win32-normalization traversal: Win32 strips
/// trailing periods and spaces from a component before the path reaches the
/// filesystem, so `".. "`, `"..."` or `".. . "` would pass a naive `!eql("..")`
/// check and then *become* `".."` during I/O. Checked uniformly on every
/// syntax so a `.posix` resolution can never emit a string that becomes a
/// traversal when later handed to a Win32 API.
///
/// Rule 7 exists because Zig's Windows filesystem APIs specify `sub_path` as
/// WTF-8 and transcode to UTF-16 internally; invalid WTF-8 is a malformed
/// argument, not a merely unusual filename.
pub fn isValidSegment(name: []const u8) bool {
    if (name.len == 0) return false;

    var all_dots = true;
    for (name) |c| {
        if (c != '.') {
            all_dots = false;
            break;
        }
    }
    if (all_dots) return false;

    if (name[0] == ' ' or name[name.len - 1] == ' ') return false;
    if (name[name.len - 1] == '.') return false;

    for (name) |c| {
        if (c < 0x20 or c == 0x7F) return false;
        switch (c) {
            '<', '>', ':', '"', '/', '\\', '|', '?', '*' => return false,
            else => {},
        }
    }

    return std.unicode.wtf8ValidateSlice(name);
}

fn hasControlByte(v: []const u8) bool {
    for (v) |c| {
        if (c < 0x20 or c == 0x7F) return true;
    }
    return false;
}

/// A terminal source has no second-choice location, so a defect is fatal.
fn validateTerminal(self: Paths, v: []const u8) ResolveError!void {
    if (hasControlByte(v)) return error.HomeMalformed;
    if (self.syntax == .windows and !std.unicode.wtf8ValidateSlice(v)) return error.HomeMalformed;
    if (!self.syntax.isFullyQualified(v)) return error.HomeNotAbsolute;
}

/// An optional override (`XDG_*`, `BASH_COMPLETION_USER_DIR`) with any defect
/// is *ignored*, per the XDG spec's own disposition for an invalid value.
/// Returns the value when it is usable, null when it should be skipped.
pub fn validOverride(self: Paths, v: []const u8) ?[]const u8 {
    if (v.len == 0) return null;
    if (hasControlByte(v)) return null;
    if (self.syntax == .windows and !std.unicode.wtf8ValidateSlice(v)) return null;
    if (!self.syntax.isFullyQualified(v)) return null;
    return v;
}

// ---- pure resolution (no io, no syscalls) ----

const BaseSpec = struct {
    /// The environment-derived root.
    root: []const u8,
    /// Literal segments appended to it (empty when the root came from an
    /// override that already names the base).
    tail: []const []const u8,
};

fn baseSpec(self: Paths, kind: Kind) ResolveError!BaseSpec {
    switch (self.convention) {
        .windows => {
            // No fallback and no ignore-and-continue: unlike XDG there is no
            // second-choice location. Deriving `%USERPROFILE%\AppData\Roaming`
            // would be a guess — those folders can be redirected by group
            // policy, and writing to the un-redirected literal is exactly the
            // failure that scatters data outside a managed profile.
            const var_name: []const u8 = switch (kind) {
                .config => "APPDATA",
                .data, .cache => "LOCALAPPDATA",
            };
            const v = self.environ.get(var_name) orelse return error.HomeNotFound;
            try self.validateTerminal(v);
            return .{ .root = v, .tail = &.{} };
        },
        .macos, .xdg => {
            const var_name: []const u8 = switch (kind) {
                .config => "XDG_CONFIG_HOME",
                .data => "XDG_DATA_HOME",
                .cache => "XDG_CACHE_HOME",
            };
            const fallback: []const []const u8 = switch (kind) {
                .config => &.{".config"},
                .data => &.{ ".local", "share" },
                // macOS excludes ~/Library/Caches from Time Machine and points
                // its storage-management tooling at it, so a purgeable cache
                // belongs there. config/data stay XDG — the convention macOS
                // CLI users actually live in.
                .cache => if (self.convention == .macos)
                    &.{ "Library", "Caches" }
                else
                    &.{".cache"},
            };

            if (self.environ.get(var_name)) |v| {
                if (self.validOverride(v)) |ok| return .{ .root = ok, .tail = &.{} };
            }

            const home_value = self.environ.get("HOME") orelse return error.HomeNotFound;
            try self.validateTerminal(home_value);
            return .{ .root = home_value, .tail = fallback };
        },
    }
}

/// The app's own segments under `base(kind)`. `data` and `cache` share
/// `%LOCALAPPDATA%` on Windows and would otherwise collide, hence the leaf.
fn appSegments(self: Paths, kind: Kind, buf: *[2][]const u8) []const []const u8 {
    buf[0] = self.app_name;
    if (self.convention == .windows) {
        switch (kind) {
            .config => return buf[0..1],
            .data => {
                buf[1] = "data";
                return buf[0..2];
            },
            .cache => {
                buf[1] = "cache";
                return buf[0..2];
            },
        }
    }
    return buf[0..1];
}

/// Length of the root prefix of an already-normalized path — trailing
/// separators are never trimmed below this, so `"/"`, `"C:\"` and
/// `"\\server\share"` survive intact.
fn rootLen(self: Paths, p: []const u8) usize {
    return switch (self.syntax) {
        .posix => if (p.len > 0 and p[0] == '/') 1 else 0,
        // Shares `Syntax.windowsRootLen` with `isFullyQualified`, so the root
        // this refuses to trim is by construction the same root that made the
        // path acceptable. A base that reaches here has already been validated,
        // so the null branch is unreachable in practice; 0 is the safe answer.
        .windows => Syntax.windowsRootLen(p) orelse 0,
    };
}

/// Append the base: normalize separators to the syntax, then trim trailing
/// separators without eating the root.
fn appendBase(self: Paths, list: *std.ArrayList(u8), raw: []const u8) std.mem.Allocator.Error!void {
    const start = list.items.len;
    try list.appendSlice(self.allocator, raw);
    if (self.syntax == .windows) {
        for (list.items[start..]) |*c| {
            if (c.* == '/') c.* = '\\';
        }
    }
    const root_len = self.rootLen(list.items[start..]);
    var end = list.items.len;
    while (end > start + root_len and self.syntax.isSep(list.items[end - 1])) end -= 1;
    list.shrinkRetainingCapacity(end);
}

/// Insert exactly one separator between segments — and none when the left side
/// already ends in one because it is a root (`HOME="/"` → `/.config`, never
/// `//.config`). Segments are appended verbatim: they are already validated to
/// contain no separator.
fn appendSegment(self: Paths, list: *std.ArrayList(u8), seg: []const u8) std.mem.Allocator.Error!void {
    if (list.items.len > 0 and !self.syntax.isSep(list.items[list.items.len - 1])) {
        try list.append(self.allocator, self.syntax.sep());
    }
    try list.appendSlice(self.allocator, seg);
}

fn buildPath(self: Paths, kind: Kind, app_scoped: bool, tail: []const []const u8) ResolveError![]u8 {
    // Validation runs before anything else, so a rejected name or component
    // can never cause a partial `createDirPath` further up the call chain.
    if (!isValidSegment(self.app_name)) return error.InvalidAppName;
    for (tail) |seg| {
        if (!isValidSegment(seg)) return error.InvalidSubPath;
    }

    const spec = try self.baseSpec(kind);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(self.allocator);

    try self.appendBase(&list, spec.root);
    for (spec.tail) |seg| try self.appendSegment(&list, seg);
    if (app_scoped) {
        var buf: [2][]const u8 = undefined;
        for (self.appSegments(kind, &buf)) |seg| try self.appendSegment(&list, seg);
    }
    for (tail) |seg| try self.appendSegment(&list, seg);

    return list.toOwnedSlice(self.allocator);
}

/// The platform's base directory for `kind` — NOT app-scoped.
/// e.g. `/home/u/.config`, `C:\Users\u\AppData\Roaming`.
pub fn base(self: Paths, kind: Kind) ResolveError![]u8 {
    return self.buildPath(kind, false, &.{});
}

/// `base(kind)` joined with caller-supplied segments, NOT app-scoped. The
/// primitive for locations another tool owns, where the tail is not `{app}/…`.
/// An empty `segments` is legal and yields exactly `base(kind)`.
///
///   p.resolve(.data, &.{ "bash-completion", "completions", app })
pub fn resolve(self: Paths, kind: Kind, segments: []const []const u8) ResolveError![]u8 {
    return self.buildPath(kind, false, segments);
}

/// `root` joined with `segments` under this `Paths`' **syntax** rules — the
/// same normalization `base` and `resolve` apply: the root's separators are
/// normalized to the syntax, its trailing separators trimmed (never past the
/// root itself), and exactly one separator inserted before each segment.
///
/// For a location rooted somewhere this type did not resolve — a directory
/// another tool names through its own variable, such as
/// `BASH_COMPLETION_USER_DIR`. `root` must already be fully qualified for this
/// syntax (`validOverride` is the usual way to establish that), else
/// `error.HomeNotAbsolute`.
///
/// Exists so such callers do not hand-roll the join. A hand-rolled one
/// reintroduces exactly the defects these rules exist to prevent — a mixed
/// `C:/one\completions\…` from an un-normalized base, a doubled separator from
/// a root, and spellings of the same file that compare unequal.
pub fn joinUnder(self: Paths, root: []const u8, segments: []const []const u8) ResolveError![]u8 {
    if (!isValidSegment(self.app_name)) return error.InvalidAppName;
    for (segments) |seg| {
        if (!isValidSegment(seg)) return error.InvalidSubPath;
    }
    if (!self.syntax.isFullyQualified(root)) return error.HomeNotAbsolute;

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(self.allocator);
    try self.appendBase(&list, root);
    for (segments) |seg| try self.appendSegment(&list, seg);
    return list.toOwnedSlice(self.allocator);
}

/// This app's directory for `kind`.
/// e.g. `/home/u/.config/myapp`, `C:\Users\u\AppData\Local\myapp\cache`.
pub fn dir(self: Paths, kind: Kind) ResolveError![]u8 {
    return self.buildPath(kind, true, &.{});
}

/// A file inside `dir(kind)`. `sub_path` must be non-empty — `file` must name
/// a file, and an empty list would silently return the directory.
///
///   p.file(.config, &.{"credentials.json"})
///   p.file(.cache,  &.{ "downloads", "1.2.3", "toolchain.tar.gz" })
pub fn file(self: Paths, kind: Kind, sub_path: []const []const u8) ResolveError![]u8 {
    if (sub_path.len == 0) return error.InvalidSubPath;
    return self.buildPath(kind, true, sub_path);
}

/// The user's home directory, validated. For locations owned by some *other*
/// tool's convention (`~/.zsh/completions`). Returns an allocated copy.
pub fn home(self: Paths) ResolveError![]u8 {
    if (!isValidSegment(self.app_name)) return error.InvalidAppName;
    const home_value = self.environ.get("HOME") orelse return error.HomeNotFound;
    try self.validateTerminal(home_value);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(self.allocator);
    try self.appendBase(&list, home_value);
    return list.toOwnedSlice(self.allocator);
}

// ---- filesystem (io explicit; host syntax only) ----

fn createPrivateDirPath(io: std.Io, path: []const u8) std.Io.Dir.CreateDirPathError!void {
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, path, private_dir);
}

/// Create the parent directory chain of `path`, with the same guards and
/// permissions as `ensureFile`. THE primitive: `ensureFile` is defined as
/// `file()` followed by this.
///
/// Exists because `resolve` and `home` produce paths that are not app-scoped
/// and therefore cannot be expressed through `ensureFile` — without it a
/// caller such as `zcli_completions` has no way to reach the `ForeignSyntax`
/// guard and must hand-roll `dirname` + `createDirPath`.
///
/// Requires `syntax == Syntax.host` and a fully-qualified `path`.
pub fn ensureParent(self: Paths, io: std.Io, path: []const u8) EnsureError!void {
    if (self.syntax != Syntax.host) return error.ForeignSyntax;
    if (!self.syntax.isFullyQualified(path)) return error.PathNotFullyQualified;
    // Selected explicitly rather than via `std.fs.path.dirname`: with the
    // host-syntax guard above the two always agree, but the code should not
    // silently depend on that invariant holding forever.
    const parent = self.syntax.dirname(path) orelse return;
    try createPrivateDirPath(io, parent);
}

/// `dir(kind)`, created with parents if absent. Returns the path.
pub fn ensureDir(self: Paths, io: std.Io, kind: Kind) EnsureError![]u8 {
    if (self.syntax != Syntax.host) return error.ForeignSyntax;
    const path = try self.dir(kind);
    try createPrivateDirPath(io, path);
    return path;
}

/// `file(kind, sub_path)` with its **parent** directory created (with
/// parents). The file itself is not created. Returns the path.
pub fn ensureFile(self: Paths, io: std.Io, kind: Kind, sub_path: []const []const u8) EnsureError![]u8 {
    if (self.syntax != Syntax.host) return error.ForeignSyntax;
    const path = try self.file(kind, sub_path);
    try self.ensureParent(io, path);
    return path;
}

// ============================ tests ============================

const testing = std.testing;

/// Build a `Paths` over an inline environment. The resolution matrix is a pure
/// string function of two runtime fields, so every row runs on every host —
/// no cross-compilation, no CI matrix.
const Fixture = struct {
    map: std.process.Environ.Map,

    fn init(pairs: []const [2][]const u8) !Fixture {
        var map = std.process.Environ.Map.init(testing.allocator);
        errdefer map.deinit();
        for (pairs) |kv| try map.put(kv[0], kv[1]);
        return .{ .map = map };
    }

    fn deinit(self: *Fixture) void {
        self.map.deinit();
    }

    fn paths(self: *const Fixture, convention: Convention, syntax: Syntax) Paths {
        return .{
            .allocator = testing.allocator,
            .environ = &self.map,
            .app_name = "myapp",
            .convention = convention,
            .syntax = syntax,
        };
    }
};

// --- A. Resolution matrix ---

test "matrix: the full {3 kinds} x {3 conventions} x {2 syntaxes} grid" {
    // Every cell, with its exact expected string, run IN FULL on every host —
    // which is the point of `convention` and `syntax` being runtime fields
    // rather than comptime ones. No cross-compilation and no CI matrix is
    // needed to know what a Windows box would produce.
    //
    // Only the HOME-relative defaults are exercised here (no XDG_* set); the
    // override, ignore, and error behaviours have their own tests below.
    const Row = struct { Convention, Kind, []const u8 };

    // Each syntax needs a home that is fully qualified *in that syntax*, so the
    // two halves carry their own fixtures. Note `.windows` convention under
    // `.posix` syntax is a legal cell: the policy says "read %APPDATA%", the
    // syntax says "this is a POSIX filesystem".
    {
        var f = try Fixture.init(&.{
            .{ "HOME", "/home/u" },
            .{ "APPDATA", "/roaming" },
            .{ "LOCALAPPDATA", "/local" },
        });
        defer f.deinit();

        const rows = [_]Row{
            .{ .xdg, .config, "/home/u/.config/myapp" },
            .{ .xdg, .data, "/home/u/.local/share/myapp" },
            .{ .xdg, .cache, "/home/u/.cache/myapp" },
            .{ .macos, .config, "/home/u/.config/myapp" },
            .{ .macos, .data, "/home/u/.local/share/myapp" },
            .{ .macos, .cache, "/home/u/Library/Caches/myapp" },
            .{ .windows, .config, "/roaming/myapp" },
            .{ .windows, .data, "/local/myapp/data" },
            .{ .windows, .cache, "/local/myapp/cache" },
        };
        for (rows) |r| {
            const got = try f.paths(r[0], .posix).dir(r[1]);
            defer testing.allocator.free(got);
            try testing.expectEqualStrings(r[2], got);
        }
    }
    {
        var f = try Fixture.init(&.{
            .{ "HOME", "C:\\Users\\u" },
            .{ "APPDATA", "C:\\Users\\u\\AppData\\Roaming" },
            .{ "LOCALAPPDATA", "C:\\Users\\u\\AppData\\Local" },
        });
        defer f.deinit();

        const rows = [_]Row{
            .{ .xdg, .config, "C:\\Users\\u\\.config\\myapp" },
            .{ .xdg, .data, "C:\\Users\\u\\.local\\share\\myapp" },
            .{ .xdg, .cache, "C:\\Users\\u\\.cache\\myapp" },
            .{ .macos, .config, "C:\\Users\\u\\.config\\myapp" },
            .{ .macos, .data, "C:\\Users\\u\\.local\\share\\myapp" },
            .{ .macos, .cache, "C:\\Users\\u\\Library\\Caches\\myapp" },
            .{ .windows, .config, "C:\\Users\\u\\AppData\\Roaming\\myapp" },
            .{ .windows, .data, "C:\\Users\\u\\AppData\\Local\\myapp\\data" },
            .{ .windows, .cache, "C:\\Users\\u\\AppData\\Local\\myapp\\cache" },
        };
        for (rows) |r| {
            const got = try f.paths(r[0], .windows).dir(r[1]);
            defer testing.allocator.free(got);
            try testing.expectEqualStrings(r[2], got);
        }
    }
}

test "matrix: every cell's base is the dir minus the app segments" {
    // Pins `base` against `dir` across the whole grid, so the app-segment rule
    // (bare `{app}`, except `{app}\data` / `{app}\cache` under `.windows`)
    // cannot drift from the base resolution it is appended to.
    var f = try Fixture.init(&.{
        .{ "HOME", "/home/u" },
        .{ "APPDATA", "/roaming" },
        .{ "LOCALAPPDATA", "/local" },
    });
    defer f.deinit();

    for ([_]Convention{ .xdg, .macos, .windows }) |conv| {
        for ([_]Kind{ .config, .data, .cache }) |kind| {
            const p = f.paths(conv, .posix);
            const b = try p.base(kind);
            defer testing.allocator.free(b);
            const d = try p.dir(kind);
            defer testing.allocator.free(d);

            try testing.expect(std.mem.startsWith(u8, d, b));
            const tail = d[b.len..];
            const expected_tail = if (conv == .windows) switch (kind) {
                .config => "/myapp",
                .data => "/myapp/data",
                .cache => "/myapp/cache",
            } else "/myapp";
            try testing.expectEqualStrings(expected_tail, tail);
        }
    }
}

test "matrix: a fully-qualified XDG override wins over the HOME default" {
    var f = try Fixture.init(&.{
        .{ "HOME", "/home/u" },
        .{ "XDG_CONFIG_HOME", "/custom/xdg" },
        .{ "XDG_DATA_HOME", "/custom/data" },
        .{ "XDG_CACHE_HOME", "/custom/cache" },
    });
    defer f.deinit();
    const p = f.paths(.xdg, .posix);

    const cases = [_]struct { Kind, []const u8 }{
        .{ .config, "/custom/xdg/myapp" },
        .{ .data, "/custom/data/myapp" },
        .{ .cache, "/custom/cache/myapp" },
    };
    for (cases) |c| {
        const got = try p.dir(c[0]);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}

test "matrix: macOS cache honours XDG_CACHE_HOME (the row-5 migration)" {
    // The upgrade plugin used to hard-code ~/Library/Caches on macOS with no
    // XDG check at all. This assertion is what makes that migration real.
    var f = try Fixture.init(&.{
        .{ "HOME", "/Users/u" },
        .{ "XDG_CACHE_HOME", "/Users/u/.cache" },
    });
    defer f.deinit();
    const p = f.paths(.macos, .posix);

    const got = try p.dir(.cache);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/Users/u/.cache/myapp", got);
}

test "matrix: an invalid XDG override is IGNORED, not fatal" {
    // Empty, relative, control-bearing — all "invalid" in the XDG spec's
    // sense, whose prescribed disposition is to use the default.
    const bad = [_][]const u8{ "", "relative/path", ".", "/ok\n/bad" };
    for (bad) |v| {
        var f = try Fixture.init(&.{
            .{ "HOME", "/home/u" },
            .{ "XDG_CONFIG_HOME", v },
        });
        defer f.deinit();
        const p = f.paths(.xdg, .posix);

        const got = try p.dir(.config);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("/home/u/.config/myapp", got);
    }
}

test "matrix: an invalid-WTF-8 XDG override under windows syntax is ignored" {
    var f = try Fixture.init(&.{
        .{ "HOME", "C:\\Users\\u" },
        .{ "XDG_CONFIG_HOME", "C:\\bad\xc0" },
    });
    defer f.deinit();
    const p = f.paths(.xdg, .windows);

    const got = try p.dir(.config);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("C:\\Users\\u\\.config\\myapp", got);
}

test "matrix: terminal source defects are FATAL (the rule 2 / rule 3 asymmetry)" {
    // Adjacent to the ignore-the-override test on purpose: same defect,
    // opposite disposition, because there is no second-choice location.
    {
        var f = try Fixture.init(&.{});
        defer f.deinit();
        const p = f.paths(.xdg, .posix);
        try testing.expectError(error.HomeNotFound, p.dir(.config));
    }
    const not_absolute = [_][]const u8{ "", "relative/path", "./x" };
    for (not_absolute) |v| {
        var f = try Fixture.init(&.{.{ "HOME", v }});
        defer f.deinit();
        const p = f.paths(.xdg, .posix);
        try testing.expectError(error.HomeNotAbsolute, p.dir(.config));
    }
    {
        var f = try Fixture.init(&.{.{ "HOME", "/home/\nu" }});
        defer f.deinit();
        const p = f.paths(.xdg, .posix);
        try testing.expectError(error.HomeMalformed, p.dir(.config));
    }
    {
        var f = try Fixture.init(&.{.{ "HOME", "C:\\Users\\\xc0" }});
        defer f.deinit();
        const p = f.paths(.xdg, .windows);
        try testing.expectError(error.HomeMalformed, p.dir(.config));
    }
}

test "matrix: windows convention never derives from USERPROFILE" {
    var f = try Fixture.init(&.{.{ "USERPROFILE", "C:\\Users\\u" }});
    defer f.deinit();
    const p = f.paths(.windows, .windows);
    try testing.expectError(error.HomeNotFound, p.dir(.config));
    try testing.expectError(error.HomeNotFound, p.dir(.data));
    try testing.expectError(error.HomeNotFound, p.dir(.cache));
}

test "matrix: windows convention rejects rather than falls back" {
    {
        var f = try Fixture.init(&.{.{ "APPDATA", "" }});
        defer f.deinit();
        try testing.expectError(error.HomeNotAbsolute, f.paths(.windows, .windows).dir(.config));
    }
    {
        var f = try Fixture.init(&.{.{ "APPDATA", "relative\\path" }});
        defer f.deinit();
        try testing.expectError(error.HomeNotAbsolute, f.paths(.windows, .windows).dir(.config));
    }
    {
        var f = try Fixture.init(&.{.{ "APPDATA", "C:\\bad\n" }});
        defer f.deinit();
        try testing.expectError(error.HomeMalformed, f.paths(.windows, .windows).dir(.config));
    }
    {
        var f = try Fixture.init(&.{.{ "APPDATA", "C:\\bad\xc0" }});
        defer f.deinit();
        try testing.expectError(error.HomeMalformed, f.paths(.windows, .windows).dir(.config));
    }
}

test "matrix: cross-axis — xdg policy with windows syntax" {
    {
        var f = try Fixture.init(&.{.{ "HOME", "C:\\Users\\u" }});
        defer f.deinit();
        const got = try f.paths(.xdg, .windows).base(.data);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("C:\\Users\\u\\.local\\share", got);
    }
    {
        // The MSYS/Cygwin form is rejected rather than translated: translating
        // means guessing at a mount table we cannot read.
        var f = try Fixture.init(&.{.{ "HOME", "/c/Users/u" }});
        defer f.deinit();
        try testing.expectError(error.HomeNotAbsolute, f.paths(.xdg, .windows).base(.data));
    }
}

// --- B. Base validation ---

test "isFullyQualified: windows accepts only drive paths and complete UNC roots" {
    const s: Syntax = .windows;
    const good = [_][]const u8{ "C:\\x", "C:/x", "c:\\", "\\\\server\\share", "\\\\server\\share\\x" };
    for (good) |v| try testing.expect(s.isFullyQualified(v));

    const bad = [_][]const u8{
        "\\foo", "/foo",         "C:foo",                 "C:",
        "",      "\\\\server",   "\\\\server\\",          "\\\\",
        "foo",   "\\\\?\\C:\\x", "\\\\.\\PhysicalDrive0",
    };
    for (bad) |v| try testing.expect(!s.isFullyQualified(v));
}

test "isFullyQualified: posix" {
    const s: Syntax = .posix;
    try testing.expect(s.isFullyQualified("/x"));
    try testing.expect(s.isFullyQualified("/"));
    for ([_][]const u8{ "x", "./x", "", "C:\\x" }) |v| {
        try testing.expect(!s.isFullyQualified(v));
    }
}

test "a bare UNC server can never become a share name" {
    // \\server parses as an absolute path under std, with the disk designator
    // swallowing the whole string — appending {app} would yield \\server\myapp,
    // i.e. the app name silently becomes the SHARE name.
    var f = try Fixture.init(&.{.{ "APPDATA", "\\\\server" }});
    defer f.deinit();
    try testing.expectError(error.HomeNotAbsolute, f.paths(.windows, .windows).dir(.config));
}

// --- C. Join and normalization ---

test "join: windows syntax emits backslashes regardless of host" {
    var f = try Fixture.init(&.{.{ "APPDATA", "C:\\Users\\u" }});
    defer f.deinit();
    const got = try f.paths(.windows, .windows).file(.config, &.{ "a", "b.json" });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("C:\\Users\\u\\myapp\\a\\b.json", got);
}

test "join: posix syntax emits slashes regardless of host" {
    var f = try Fixture.init(&.{.{ "HOME", "/home/u" }});
    defer f.deinit();
    const got = try f.paths(.xdg, .posix).file(.config, &.{ "a", "b.json" });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/home/u/.config/myapp/a/b.json", got);
}

test "join: trailing separators trimmed, roots preserved" {
    const cases = [_]struct { Convention, Syntax, []const u8, []const u8, []const u8 }{
        .{ .xdg, .posix, "HOME", "/x/y/", "/x/y/.config/myapp" },
        .{ .xdg, .posix, "HOME", "/", "/.config/myapp" },
        .{ .windows, .windows, "APPDATA", "C:\\", "C:\\myapp" },
        .{ .windows, .windows, "APPDATA", "C:\\Users\\u\\", "C:\\Users\\u\\myapp" },
        .{ .windows, .windows, "APPDATA", "C:/Users/u", "C:\\Users\\u\\myapp" },
        .{ .windows, .windows, "APPDATA", "\\\\server\\share", "\\\\server\\share\\myapp" },
        .{ .windows, .windows, "APPDATA", "\\\\server\\share\\", "\\\\server\\share\\myapp" },
    };
    for (cases) |c| {
        var f = try Fixture.init(&.{.{ c[2], c[3] }});
        defer f.deinit();
        const got = try f.paths(c[0], c[1]).dir(.config);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c[4], got);
    }
}

test "join: Syntax.dirname agrees with the join for each syntax" {
    {
        var f = try Fixture.init(&.{.{ "HOME", "/home/u" }});
        defer f.deinit();
        const p = f.paths(.xdg, .posix);
        const full = try p.file(.config, &.{"c.json"});
        defer testing.allocator.free(full);
        const parent = try p.dir(.config);
        defer testing.allocator.free(parent);
        try testing.expectEqualStrings(parent, p.syntax.dirname(full).?);
    }
    {
        var f = try Fixture.init(&.{.{ "APPDATA", "C:\\Users\\u" }});
        defer f.deinit();
        const p = f.paths(.windows, .windows);
        const full = try p.file(.config, &.{"c.json"});
        defer testing.allocator.free(full);
        const parent = try p.dir(.config);
        defer testing.allocator.free(parent);
        try testing.expectEqualStrings(parent, p.syntax.dirname(full).?);
    }
}

// --- D. Segment predicate and empty lists ---

test "isValidSegment: rejects every unsafe spelling" {
    const bad = [_][]const u8{
        "",       ".",      "..",        "...",        "....",
        ".. ",    " ..",    ".. . ",     "foo.",       "foo ",
        " foo",   "a/b",    "a\\b",      "C:",         "file.txt:stream",
        "a<b",    "a>b",    "a\"b",      "a|b",        "a?b",
        "a*b",    "/x",     "../escape", "..\\escape",
        // control bytes
        "a\x00b",
        "a\x0Ab", "a\x1Fb", "a\x7Fb",
        // invalid WTF-8: lone continuation byte, truncated sequence
           "a\x80b",     "a\xE2",
    };
    for (bad) |v| try testing.expect(!isValidSegment(v));

    const good = [_][]const u8{
        "myapp",          "my-app", ".myapp", "my.app", "a b",
        "1.2.3",          "_x",
        "ЖЖ",
        "☺",
        // WTF-8 permits an unpaired surrogate where UTF-8 does not.
        "a\xed\xa0\x80b",
    };
    for (good) |v| try testing.expect(isValidSegment(v));
}

test "isValidSegment: agrees at comptime and at runtime" {
    // Pins the comptime-evaluability that registry/builder.zig depends on: a
    // future rule reaching for an allocator or @panic breaks the build here
    // rather than silently at a consumer's @compileError site.
    const inputs = [_][]const u8{ "myapp", "my-app", ".myapp", "my.app", ".", "..", "...", "foo.", "foo ", "a/b", "" };
    inline for (inputs) |v| {
        const at_comptime = comptime isValidSegment(v);
        try testing.expectEqual(at_comptime, isValidSegment(v));
    }
}

test "segments: invalid app_name and sub_path are rejected on every syntax" {
    const bad = [_][]const u8{ ".", "..", "...", "foo.", "foo ", " foo", "a/b", "a\\b" };
    for ([_]Syntax{ .posix, .windows }) |syn| {
        const conv: Convention = if (syn == .windows) .windows else .xdg;
        for (bad) |name| {
            var f = try Fixture.init(&.{
                .{ "HOME", "/home/u" },
                .{ "APPDATA", "C:\\Users\\u" },
            });
            defer f.deinit();

            var p = f.paths(conv, syn);
            p.app_name = name;
            try testing.expectError(error.InvalidAppName, p.dir(.config));

            const ok = f.paths(conv, syn);
            try testing.expectError(error.InvalidSubPath, ok.file(.config, &.{name}));
        }
    }
}

test "segments: app_name '..' never resolves to the base's parent" {
    var f = try Fixture.init(&.{.{ "HOME", "/home/u" }});
    defer f.deinit();
    var p = f.paths(.xdg, .posix);
    p.app_name = "..";
    try testing.expectError(error.InvalidAppName, p.dir(.config));
    try testing.expectError(error.InvalidAppName, p.base(.config));
    try testing.expectError(error.InvalidAppName, p.home());
}

test "empty lists: file() rejects, resolve() returns the base" {
    var f = try Fixture.init(&.{.{ "HOME", "/home/u" }});
    defer f.deinit();
    const p = f.paths(.xdg, .posix);

    try testing.expectError(error.InvalidSubPath, p.file(.config, &.{}));

    const resolved = try p.resolve(.config, &.{});
    defer testing.allocator.free(resolved);
    const b = try p.base(.config);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(b, resolved);
    try testing.expectEqualStrings("/home/u/.config", resolved);
}

test "resolve: builds a non-app-scoped tail" {
    var f = try Fixture.init(&.{.{ "HOME", "/home/u" }});
    defer f.deinit();
    const p = f.paths(.xdg, .posix);
    const got = try p.resolve(.data, &.{ "bash-completion", "completions", "myapp" });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/home/u/.local/share/bash-completion/completions/myapp", got);
}

test "home: returns a validated copy" {
    var f = try Fixture.init(&.{.{ "HOME", "/home/u/" }});
    defer f.deinit();
    const got = try f.paths(.xdg, .posix).home();
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/home/u", got);

    var missing = try Fixture.init(&.{});
    defer missing.deinit();
    try testing.expectError(error.HomeNotFound, missing.paths(.xdg, .posix).home());
}

// --- F. Filesystem behaviour ---

/// A `Paths` rooted at a real temp directory, so the `ensure*` family is
/// exercised on whichever platform the test runs on.
const TmpFixture = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    map: std.process.Environ.Map,

    fn init() !TmpFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(root);

        var map = std.process.Environ.Map.init(testing.allocator);
        errdefer map.deinit();
        // Every terminal source names the same real directory, spelled in the
        // HOST syntax (`root` is a realpath), because these tests do I/O and
        // therefore run at `Syntax.host`. `HOME` is set on Windows too: it is
        // not the Windows *convention*, but a test that overrides `convention`
        // to `.xdg` while leaving `syntax` at the host's — the §8.3 contract
        // `zcli_completions` is built on — reads `HOME` on every platform, and
        // a fixture that omits it would fail for want of a fixture rather than
        // for want of the behaviour under test.
        try map.put("HOME", root);
        if (builtin.os.tag == .windows) {
            try map.put("APPDATA", root);
            try map.put("LOCALAPPDATA", root);
        }
        return .{ .tmp = tmp, .root = root, .map = map };
    }

    fn deinit(self: *TmpFixture) void {
        self.map.deinit();
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn paths(self: *const TmpFixture) Paths {
        return .{
            .allocator = testing.allocator,
            .environ = &self.map,
            .app_name = "myapp",
        };
    }
};

test "ensureFile creates the parent chain but not the file, idempotently" {
    var f = try TmpFixture.init();
    defer f.deinit();
    const io = std.testing.io;
    const p = f.paths();

    const path = try p.ensureFile(io, .config, &.{ "nested", "creds.json" });
    defer testing.allocator.free(path);

    const parent = p.syntax.dirname(path).?;
    var d = try std.Io.Dir.cwd().openDir(io, parent, .{});
    d.close(io);

    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, path, .{}));

    // Idempotent.
    const again = try p.ensureFile(io, .config, &.{ "nested", "creds.json" });
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(path, again);
}

test "ensureDir creates and returns the app directory" {
    var f = try TmpFixture.init();
    defer f.deinit();
    const io = std.testing.io;
    const p = f.paths();

    const path = try p.ensureDir(io, .cache);
    defer testing.allocator.free(path);

    var d = try std.Io.Dir.cwd().openDir(io, path, .{});
    d.close(io);

    const expected = try p.dir(.cache);
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, path);
}

test "ensure*: a rejected sub_path creates nothing" {
    var f = try TmpFixture.init();
    defer f.deinit();
    const io = std.testing.io;
    const p = f.paths();

    try testing.expectError(error.InvalidSubPath, p.ensureFile(io, .config, &.{ "..", "escape" }));

    const app_dir = try p.dir(.config);
    defer testing.allocator.free(app_dir);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, app_dir, .{}));
}

test "ensureParent: works for a resolve-built, non-app-scoped path" {
    var f = try TmpFixture.init();
    defer f.deinit();
    const io = std.testing.io;

    var p = f.paths();
    p.convention = .xdg; // policy override, host syntax — the §8.3 contract
    const dest = try p.resolve(.data, &.{ "bash-completion", "completions", "myapp" });
    defer testing.allocator.free(dest);

    try p.ensureParent(io, dest);

    var d = try std.Io.Dir.cwd().openDir(io, p.syntax.dirname(dest).?, .{});
    d.close(io);
}

test "ensureParent: works for a home()-derived path" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // HOME is not the Windows contract
    var f = try TmpFixture.init();
    defer f.deinit();
    const io = std.testing.io;
    const p = f.paths();

    const h = try p.home();
    defer testing.allocator.free(h);
    const dest = try std.fs.path.join(testing.allocator, &.{ h, ".zsh", "completions", "_myapp" });
    defer testing.allocator.free(dest);

    try p.ensureParent(io, dest);
    var d = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(dest).?, .{});
    d.close(io);
}

test "ensureParent: rejects a relative path" {
    var f = try TmpFixture.init();
    defer f.deinit();
    try testing.expectError(
        error.PathNotFullyQualified,
        f.paths().ensureParent(std.testing.io, "relative/path/file"),
    );
}

test "ensure*: foreign syntax is refused" {
    var f = try TmpFixture.init();
    defer f.deinit();
    const io = std.testing.io;

    var p = f.paths();
    p.syntax = if (Syntax.host == .posix) .windows else .posix;

    try testing.expectError(error.ForeignSyntax, p.ensureDir(io, .config));
    try testing.expectError(error.ForeignSyntax, p.ensureFile(io, .config, &.{"x"}));
    try testing.expectError(error.ForeignSyntax, p.ensureParent(io, "/tmp/x/y"));
}

test "ensure*: newly created directories are 0700, existing ones are left alone" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f = try TmpFixture.init();
    defer f.deinit();
    const io = std.testing.io;
    const p = f.paths();

    const created = try p.ensureDir(io, .data);
    defer testing.allocator.free(created);

    const st = try std.Io.Dir.cwd().statFile(io, created, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), st.permissions.toMode() & 0o777);

    // A component we did NOT create keeps its own mode: no retroactive chmod.
    const existing = try p.resolve(.data, &.{"preexisting"});
    defer testing.allocator.free(existing);
    try std.Io.Dir.cwd().createDir(io, existing, @enumFromInt(0o755));
    const child = try p.resolve(.data, &.{ "preexisting", "child" });
    defer testing.allocator.free(child);
    try p.ensureParent(io, child);

    const st2 = try std.Io.Dir.cwd().statFile(io, existing, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o755), st2.permissions.toMode() & 0o777);
}
