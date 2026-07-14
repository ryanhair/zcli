//! Focus-routing helpers (ADR-0018): `focusNext`, `focusPrev`, and `FocusRing`.

const std = @import("std");
const terminal = @import("terminal");

const Key = terminal.Key;

/// The next focus target with wrap-around (Tab). `E` is the app's focus enum
/// whose variants are its focusable fields, in order.
pub fn focusNext(comptime E: type, current: E) E {
    const n = @typeInfo(E).@"enum".fields.len;
    return @enumFromInt((@intFromEnum(current) + 1) % n);
}

/// The previous focus target with wrap-around (Shift-Tab / `.back_tab`).
pub fn focusPrev(comptime E: type, current: E) E {
    const n = @typeInfo(E).@"enum".fields.len;
    return @enumFromInt((@intFromEnum(current) + n - 1) % n);
}

/// A field type joins the focus ring iff it is a struct exposing a `pub`
/// `handle` method — the same duck-typed "convention, not interface" stance
/// ADR-0018 takes for `view`/`handle`. Plain data, rects, and the focus value
/// itself are skipped.
fn isWidget(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "handle");
}

/// The widget-field names of `State`, in declaration order — that array *is*
/// the ring. Frozen into a `const` so the returned type doesn't capture a
/// comptime var.
fn ringOf(comptime State: type) []const [:0]const u8 {
    comptime var names: []const [:0]const u8 = &.{};
    inline for (@typeInfo(State).@"struct".fields) |f| {
        if (isWidget(f.type)) names = names ++ &[_][:0]const u8{f.name};
    }
    return names;
}

/// A comptime focus-routing helper — **sugar over the ADR-0018 switch, not a
/// layer**. It derives the focus ring from `State`'s widget fields (in
/// declaration order) and generalizes `focusNext`/`focusPrev` plus the manual
/// `switch (focus) { .a => a.handle(key), ... }` dispatch. No framework loop,
/// no registry, no retained state — the caller can bypass it entirely.
///
/// `FocusRing(State)` gives you:
///   - `Focus`, a named enum reified from the widget-field names (index = tag),
///   - `next(Focus) Focus` / `prev(Focus) Focus`, wrapping over the ring,
///   - `dispatch(state, focus, key, extras) bool`, which routes `key` to the
///     focused widget's `handle` and returns *consumed*.
///
/// **Where focus lives.** A `State` field can't be typed `FocusRing(State).Focus`
/// — that makes `@typeInfo(State)` depend on itself ("type … depends on itself
/// for type information"). So the caller keeps focus *outside* `State` (a local
/// `Ring.Focus`, as `examples/form.zig` does) — the ring type is still derived
/// from the widget fields, focus just isn't one of them.
///
/// **Extras (`dispatch`).** Widgets have heterogeneous `handle` arities
/// (`TextInput.handle(key)` vs `Select.handle(key, count, visible)`). `extras`
/// is an anon struct mapping a widget field name to a tuple of its *extra* args;
/// `dispatch` appends `@field(extras, name)` after `.{ widget, key }` when the
/// field is present. Because `focus` is a runtime value, `dispatch`'s `inline for`
/// compiles *every* arm — so `extras` must describe **every** multi-arg widget
/// field, not only the focused one (single-arg widgets need no entry).
pub fn FocusRing(comptime State: type) type {
    const names = ringOf(State);
    const Tag = std.math.IntFittingRange(0, if (names.len <= 1) 0 else names.len - 1);
    return struct {
        /// The ring: widget-field names of `State`, in declaration order.
        pub const ring = names;
        /// A named enum over the ring (`@intFromEnum` is the ring index).
        pub const Focus = @Enum(Tag, .exhaustive, names, &std.simd.iota(Tag, names.len));

        /// Next focus target, wrapping (Tab). Widens through `usize` so a
        /// one-bit tag can't overflow on `+ 1`.
        pub fn next(f: Focus) Focus {
            return @enumFromInt((@as(usize, @intFromEnum(f)) + 1) % names.len);
        }

        /// Previous focus target, wrapping (Shift-Tab / `.back_tab`).
        pub fn prev(f: Focus) Focus {
            return @enumFromInt((@as(usize, @intFromEnum(f)) + names.len - 1) % names.len);
        }

        /// Route `key` to the focused widget's `handle` and return *consumed*.
        /// `extras` supplies each multi-arg widget's extra args (see the type
        /// doc). Identical codegen to a hand-written switch — no vtable.
        pub fn dispatch(state: *State, f: Focus, key: Key, extras: anytype) bool {
            inline for (names, 0..) |name, i| {
                if (i == @intFromEnum(f)) {
                    const w = &@field(state, name);
                    const Widget = @TypeOf(w.*);
                    if (@hasField(@TypeOf(extras), name)) {
                        return @call(.auto, Widget.handle, .{ w, key } ++ @field(extras, name));
                    } else {
                        return @call(.auto, Widget.handle, .{ w, key });
                    }
                }
            }
            unreachable;
        }
    };
}
