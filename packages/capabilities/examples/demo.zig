//! Terminal Capabilities Detection Demo
//!
//! This demo showcases the capabilities detection package by querying
//! the current terminal and displaying its capabilities.

const std = @import("std");
const capabilities = @import("capabilities");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Terminal Capabilities Detection Demo ===\n\n", .{});

    // Check if we're running in a TTY
    const is_tty = capabilities.isTty();
    std.debug.print("Running in TTY: {}\n\n", .{is_tty});

    if (!is_tty) {
        std.debug.print("⚠️  Not running in a terminal - capabilities will be limited\n", .{});
        std.debug.print("   Try running this demo directly in a terminal for best results.\n\n", .{});
    }

    // Quick size detection
    std.debug.print("--- Quick Size Detection ---\n", .{});
    if (capabilities.detectSize()) |size| {
        std.debug.print("Terminal size: {}x{} ({} cells)\n", .{ size.width, size.height, size.cells() });
    } else |err| {
        std.debug.print("Size detection failed: {}\n", .{err});
    }

    // Quick color detection
    std.debug.print("\n--- Quick Color Detection ---\n", .{});
    if (capabilities.detectColor(allocator, null)) |color| {
        std.debug.print("Color support: {s}\n", .{@tagName(color)});
        std.debug.print("  Supports ANSI colors: {}\n", .{color.supportsAnsi()});
        std.debug.print("  Supports 256 colors: {}\n", .{color.supports256()});
        std.debug.print("  Supports RGB colors: {}\n", .{color.supportsRgb()});
    } else |err| {
        std.debug.print("Color detection failed: {}\n", .{err});
    }

    // Full capability detection
    std.debug.print("\n--- Full Capability Detection ---\n", .{});
    std.debug.print("Detecting capabilities (timeout: 100ms)...\n", .{});

    if (capabilities.detect(allocator)) |caps| {
        const description = try caps.describe(allocator);
        defer allocator.free(description);

        std.debug.print("\n{s}", .{description});

        // Additional detailed info
        std.debug.print("\n--- Additional Features ---\n", .{});
        std.debug.print("Cursor control: {}\n", .{caps.cursor_control});
        std.debug.print("Scrolling regions: {}\n", .{caps.scrolling_regions});
        std.debug.print("Bracketed paste: {}\n", .{caps.bracketed_paste});
        std.debug.print("Focus events: {}\n", .{caps.focus_events});

        if (caps.alternate_screen.available) {
            std.debug.print("Alternate screen: ✓ Available", .{});
            if (caps.alternate_screen.preserves_scrollback) {
                std.debug.print(" (preserves scrollback)", .{});
            }
            std.debug.print("\n", .{});
        } else {
            std.debug.print("Alternate screen: ✗ Not available\n", .{});
        }
    } else |err| {
        std.debug.print("Full detection failed: {}\n", .{err});
        std.debug.print("This is expected when not running in a proper terminal.\n", .{});
    }

    // Demo color support levels
    std.debug.print("\n--- Color Support Demonstration ---\n", .{});
    demoColorSupport();

    std.debug.print("\n=== Demo Complete ===\n", .{});
}

fn demoColorSupport() void {
    const color_levels = [_]capabilities.ColorSupport{ .none, .ansi_16, .palette_256, .truecolor };

    for (color_levels) |level| {
        std.debug.print("{s:>12}: ", .{@tagName(level)});
        std.debug.print("ANSI={} 256={} RGB={}\n", .{
            level.supportsAnsi(),
            level.supports256(),
            level.supportsRgb(),
        });
    }
}
