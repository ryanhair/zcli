//! Focus-routing helpers (ADR-0018): `focusNext` and `focusPrev`.
//!
//! Focus is caller-owned — a plain enum you hold in your own state. These two
//! helpers cycle it with wrap-around; routing a key to the focused widget is a
//! hand-written `switch (focus) { .a => a.handle(key), ... }` (ADR-0018's
//! "convention, not framework" stance). See `examples/form.zig`.

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
