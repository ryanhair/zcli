const std = @import("std");
const ztheme = @import("ztheme");

pub fn main() !void {
    const theme_ctx = ztheme.Theme.initForced(true);
    
    std.debug.print("Capability: {s}\n", .{theme_ctx.capabilityString()});
    std.debug.print("Color enabled: {}\n", .{theme_ctx.color_enabled});
    std.debug.print("Is TTY: {}\n", .{theme_ctx.is_tty});
    std.debug.print("Background type: {s}\n", .{switch (theme_ctx.background_type) {
        .dark => "Dark",
        .light => "Light", 
        .unknown => "Unknown",
    }});
    
    // Test semantic color
    const success_color = ztheme.theme("Success").success();
    std.debug.print("Success has style: {}\n", .{success_color.hasStyle()});
    if (success_color.style.semantic_role) |role| {
        std.debug.print("Semantic role: {}\n", .{role});
    }
    if (success_color.style.fg) |fg| {
        std.debug.print("Foreground color set: {}\n", .{fg});
    }
}