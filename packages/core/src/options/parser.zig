const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils.zig");
const array_utils = @import("array_utils.zig");
const logging = @import("../logging.zig");
const args_parser = @import("../args.zig");
const diagnostic_errors = @import("../diagnostic_errors.zig");
const custom_type = @import("../custom_type.zig");
const type_utils = @import("../type_utils.zig");
const levenshtein = @import("../levenshtein.zig");
const ZcliError = diagnostic_errors.ZcliError;
const ZcliDiagnostic = diagnostic_errors.ZcliDiagnostic;
const ResourceLimits = @import("../resource_limits.zig").ResourceLimits;
const ResourceTracker = @import("../resource_limits.zig").ResourceTracker;

/// Parse command-line options into a struct using default field names.
///
/// This function parses command-line flags and options (e.g., --verbose, --output file.txt)
/// into a struct. Option names are derived from struct field names by converting
/// underscores to dashes (e.g., `output_file` becomes `--output-file`).
///
/// ## Parameters
/// - `OptionsType`: Struct type defining expected options with default values
/// - `allocator`: Memory allocator for array options (must call cleanupOptions after use)
/// - `args`: Command-line arguments to parse
///
/// ## Returns
/// `OptionsResult(OptionsType)` containing parsed options and parsing metadata.
///
/// ## Supported Option Types
/// - Boolean flags: `bool` (--flag sets to true)
/// - String options: `[]const u8` (--name value)
/// - Numeric options: `i32`, `u32`, `f64`, etc. (--count 42)
/// - Array options: `[][]const u8`, `[]i32` (--files a.txt b.txt)
/// - Optional options: `?T` for any supported type T
///
/// ### Supported Array Element Types:
/// - `[][]const u8` - Array of strings
/// - `[]i32`, `[]u32`, `[]i64`, `[]u64` - Integer arrays
/// - `[]i16`, `[]u16`, `[]i8`, `[]u8` - Small integer arrays
/// - `[]f32`, `[]f64` - Float arrays
///
/// ## Examples
/// ```zig
/// const Options = struct {
///     verbose: bool = false,        // --verbose
///     output_file: ?[]const u8 = null,  // --output-file path
///     count: u32 = 10,             // --count 42
///     files: [][]const u8 = &.{}, // --files a.txt b.txt
/// };
///
/// // Not re-exported at the package root — reachable via zcli.parseCommandLine,
/// // or directly as parseOptions within this module:
/// const result = try parseOptions(Options, allocator, args, null);
/// defer cleanupOptions(Options, result.options, allocator);
/// ```
///
/// ## Memory Management
/// **IMPORTANT**: Array options allocate memory. Array fields accumulate values and
/// return owned slices that MUST be freed. When commands are executed through the zcli
/// framework, array cleanup is automatic (the generated command registry frees all array
/// fields). When calling `parseOptions` directly, always call `cleanupOptions` when done:
/// ```zig
/// const result = try parseOptions(Options, allocator, args, null);
/// defer cleanupOptions(Options, result.options, allocator);
/// ```
pub fn parseOptions(
    comptime OptionsType: type,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    diag: ?*?ZcliDiagnostic,
) ZcliError!types.OptionsResult(OptionsType) {
    // No meta means no `.env` declarations, so there is nothing to look up.
    return parseOptionsWithMeta(OptionsType, null, allocator, null, args, diag);
}

/// Parse command-line options with custom metadata for option names and descriptions.
///
/// This function is like `parseOptions` but allows customizing option names and behavior
/// through metadata. This is typically used internally by the zcli framework when
/// commands define custom option metadata.
///
/// ## Parameters
/// - `OptionsType`: Struct type defining expected options
/// - `meta`: Optional metadata struct with custom option configurations
/// - `allocator`: Memory allocator for array options
/// - `environ`: Environment map for `.env` fallbacks (threaded from
///   `process.Init` — 0.16 has no ambient getenv). Pass null when the caller
///   has no environment or the meta declares no `.env` names.
/// - `args`: Command-line arguments to parse
///
/// ## Metadata Format
/// The meta parameter can contain option-specific configurations:
/// ```zig
/// const meta = .{
///     .options = .{
///         .output_file = .{ .name = "out", .short = 'o' },
///         .api_key = .{ .env = "MYAPP_API_KEY" },
///         .verbose = .{ .short = 'v' },
///     },
/// };
/// ```
///
/// An `.env` entry names an environment variable used as a fallback when the
/// flag is not passed on the command line. Precedence: CLI > env > default.
///
/// ## Examples
/// ```zig
/// const Options = struct { output_file: ?[]const u8 = null };
/// const meta = .{ .options = .{ .output_file = .{ .name = "out" } } };
///
/// const result = try parseOptionsWithMeta(Options, meta, allocator, environ, args);
/// // Now accepts --out instead of --output-file
/// defer cleanupOptions(Options, result.options, allocator);
/// ```
///
/// ## Usage
/// Most users should use `parseOptions` instead. This function is primarily for
/// internal framework use and advanced customization scenarios.
pub fn parseOptionsWithMeta(
    comptime OptionsType: type,
    comptime meta: anytype,
    allocator: std.mem.Allocator,
    environ: ?*const std.process.Environ.Map,
    args: []const []const u8,
    diag: ?*?ZcliDiagnostic,
) ZcliError!types.OptionsResult(OptionsType) {
    const type_info = @typeInfo(OptionsType);

    if (type_info != .@"struct") {
        @compileError("Options must be a struct type");
    }

    const struct_info = type_info.@"struct";
    var result: OptionsType = undefined;

    // Initialize resource tracker with default limits
    var resource_tracker = ResourceTracker.init(ResourceLimits.getDefault());

    // Track array accumulation for each field
    var array_lists: [struct_info.fields.len]?array_utils.ArrayListUnion = [_]?array_utils.ArrayListUnion{null} ** struct_info.fields.len;
    defer {
        for (&array_lists) |*list| {
            if (list.*) |*l| {
                l.deinit(allocator);
            }
        }
    }

    // Initialize with default values
    inline for (struct_info.fields, 0..) |field, i| {
        if (comptime utils.isArrayType(field.type)) {
            // Initialize array fields with empty arrays of the correct type
            const element_type = @typeInfo(field.type).pointer.child;
            @field(result, field.name) = @as(field.type, &[_]element_type{});
            // Create ArrayList for accumulation based on element type
            array_lists[i] = array_utils.createArrayListUnion(element_type);
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else if (field.type == bool) {
            // Respect a declared default (`bool = true`); absent flag → default,
            // or false when none is declared. `--no-<flag>` is how a default-true
            // bool is set back to false.
            @field(result, field.name) = if (field.default_value_ptr) |default_ptr|
                @as(*const bool, @ptrCast(@alignCast(default_ptr))).*
            else
                false;
        } else if (comptime type_utils.hasDefaultValue(OptionsType, field.name)) {
            // Set the default value from the type definition
            if (field.default_value_ptr) |default_ptr| {
                const default_value: *const field.type = @ptrCast(@alignCast(default_ptr));
                @field(result, field.name) = default_value.*;
            }
        } else {
            // A required option (no absent-flag value): initialize to a defined
            // placeholder so the field is always safe to read. Whether it was
            // actually supplied is tracked in `provided` (env/CLI) plus, later,
            // the config pass — the registry errors if no source set it. The
            // placeholder's value is never surfaced (see requiredPlaceholder).
            @field(result, field.name) = utils.requiredPlaceholder(field.type);
        }
    }

    // One flag per field: set when a value source (env below, or CLI parsing
    // further down) supplies it. The required-option check reads these.
    var provided = [_]bool{false} ** struct_info.fields.len;

    // Apply environment-variable fallbacks declared as meta.options.<field>.env.
    // Running after defaults and before CLI parsing gives the documented
    // precedence — CLI > env > default — without tracking which fields the
    // CLI set. Values come from the environ map threaded down from
    // process.Init; 0.16 has no ambient getenv.
    if (environ) |env_map| {
        inline for (struct_info.fields, 0..) |field, i| {
            if (comptime envNameFor(meta, field.name)) |env_name| {
                if (env_map.get(env_name)) |env_value| {
                    if (applyEnvValue(field.type, &@field(result, field.name), env_value)) provided[i] = true;
                }
            }
        }
    }

    // Parse options, converting any errors to structured errors
    var arg_index: usize = 0;
    var option_counts = std.StringHashMap(u32).init(allocator);
    defer option_counts.deinit();

    while (arg_index < args.len) {
        const arg = args[arg_index];

        // Stop parsing options at "--"
        if (std.mem.eql(u8, arg, "--")) {
            arg_index += 1;
            break;
        }

        // Not an option — a bare word, a negative number (`-5`, `-.5`, `-inf`),
        // or the bare `-` stdin/stdout sentinel: skip it (GNU-style parsing
        // leaves positionals in place). `isOption` is the single source of truth.
        if (!utils.isOption(arg)) {
            arg_index += 1;
            continue;
        }

        // Check resource limits before processing option
        resource_tracker.checkOptionCount() catch {
            if (diag) |d| d.* = .{ .ResourceLimitExceeded = .{
                .limit_type = "total options",
                .limit_value = resource_tracker.limits.max_total_options,
                .actual_value = resource_tracker.option_count,
                .suggestion = null,
            } };
            return ZcliError.ResourceLimitExceeded;
        };

        if (std.mem.startsWith(u8, arg, "--")) {
            // Long option - check option name length
            const option_name = if (std.mem.indexOf(u8, arg[2..], "=")) |eq_pos|
                arg[2 .. 2 + eq_pos]
            else
                arg[2..];

            resource_tracker.checkOptionNameLength(option_name) catch {
                if (diag) |d| d.* = .{ .ResourceLimitExceeded = .{
                    .limit_type = "option name length",
                    .limit_value = resource_tracker.limits.max_option_name_length,
                    .actual_value = option_name.len,
                    .suggestion = null,
                } };
                return ZcliError.ResourceLimitExceeded;
            };

            const consumed = parseLongOptions(OptionsType, meta, &result, &option_counts, args, arg_index, &array_lists, allocator, diag) catch |err| {
                return convertLongOptionError(err);
            };
            arg_index += consumed;
        } else {
            // Short option(s)
            const consumed = parseShortOptionsWithMeta(OptionsType, meta, &result, &option_counts, args, arg_index, &array_lists, allocator, diag) catch |err| {
                return convertShortOptionError(err);
            };
            arg_index += consumed;
        }
    }

    // Fold CLI-set fields into `provided`. `option_counts` is keyed by field
    // name for every option the CLI touched (values, booleans, negations), so
    // its membership is exactly "the CLI set this field".
    inline for (struct_info.fields, 0..) |field, i| {
        if (option_counts.contains(field.name)) provided[i] = true;
    }

    // Finalize array fields by converting ArrayLists to slices. If a later
    // field's conversion fails, the slices already handed to `result` must be
    // freed here — their lists are empty by then, so the deinit defer above
    // no longer owns that memory. (The framework's arena masks this, but the
    // parser is also usable as a library with any allocator.)
    var converted = [_]bool{false} ** struct_info.fields.len;
    errdefer {
        inline for (struct_info.fields, 0..) |field, i| {
            if (comptime utils.isArrayType(field.type)) {
                if (converted[i]) allocator.free(@field(result, field.name));
            }
        }
    }
    inline for (struct_info.fields, 0..) |field, i| {
        if (comptime utils.isArrayType(field.type)) {
            if (array_lists[i]) |*list_union| {
                @field(result, field.name) = array_utils.arrayListUnionToOwnedSlice(field.type, allocator, list_union) catch {
                    return ZcliError.SystemOutOfMemory;
                };
                converted[i] = true;
            }
        }
    }

    return types.OptionsResult(OptionsType){
        .options = result,
        .result = .{ .next_arg_index = arg_index },
        .provided = provided,
    };
}

/// Convert long option parsing errors to structured errors
fn convertLongOptionError(err: anyerror) ZcliError {
    return switch (err) {
        error.UnknownOption => ZcliError.OptionUnknown,
        error.MissingOptionValue => ZcliError.OptionMissingValue,
        error.InvalidOptionValue => ZcliError.OptionInvalidValue,
        error.BooleanOptionWithValue => ZcliError.OptionBooleanWithValue,
        error.DuplicateOption => ZcliError.OptionDuplicate,
        error.OutOfMemory => ZcliError.SystemOutOfMemory,
        // The helpers' error sets are hand-listed above; anything new must be
        // mapped (and given a diagnostic) rather than silently misclassified.
        else => ZcliError.OptionInvalidValue,
    };
}

/// Convert short option parsing errors to structured errors
fn convertShortOptionError(err: anyerror) ZcliError {
    return switch (err) {
        error.UnknownOption => ZcliError.OptionUnknown,
        error.MissingOptionValue => ZcliError.OptionMissingValue,
        error.InvalidOptionValue => ZcliError.OptionInvalidValue,
        error.BooleanOptionWithValue => ZcliError.OptionBooleanWithValue,
        error.DuplicateOption => ZcliError.OptionDuplicate,
        error.OutOfMemory => ZcliError.SystemOutOfMemory,
        // See convertLongOptionError: map new helper errors explicitly.
        else => ZcliError.OptionInvalidValue,
    };
}

/// The environment-variable name declared for a field via
/// `meta.options.<field>.env`, or null when the meta declares none.
fn envNameFor(comptime meta: anytype, comptime field_name: []const u8) ?[]const u8 {
    if (@TypeOf(meta) == @TypeOf(null)) return null;
    if (!@hasField(@TypeOf(meta), "options")) return null;
    if (!@hasField(@TypeOf(meta.options), field_name)) return null;
    const field_meta = @field(meta.options, field_name);
    if (!@hasField(@TypeOf(field_meta), "env")) return null;
    return field_meta.env;
}

/// Apply an environment variable's string value to an option field.
/// Returns true if the value was applied, false if it didn't parse as the
/// field's type (the field keeps its previous value — the default).
fn applyEnvValue(comptime T: type, target: *T, env_value: []const u8) bool {
    if (T == bool) {
        // Common boolean env var spellings; anything else is ignored.
        if (std.mem.eql(u8, env_value, "1") or
            std.ascii.eqlIgnoreCase(env_value, "true") or
            std.ascii.eqlIgnoreCase(env_value, "yes"))
        {
            target.* = true;
            return true;
        }
        if (std.mem.eql(u8, env_value, "0") or
            std.ascii.eqlIgnoreCase(env_value, "false") or
            std.ascii.eqlIgnoreCase(env_value, "no"))
        {
            target.* = false;
            return true;
        }
        return false;
    }

    if (T == []const u8) {
        target.* = env_value;
        return true;
    }

    const type_info = @typeInfo(T);
    if (type_info == .optional) {
        var child_value: type_info.optional.child = undefined;
        if (applyEnvValue(type_info.optional.child, &child_value, env_value)) {
            target.* = child_value;
            return true;
        }
        return false;
    }

    if (type_info == .int) {
        target.* = std.fmt.parseInt(T, env_value, 10) catch return false;
        return true;
    }

    if (type_info == .float) {
        target.* = std.fmt.parseFloat(T, env_value) catch return false;
        return true;
    }

    if (type_info == .@"enum") {
        target.* = std.meta.stringToEnum(T, env_value) orelse return false;
        return true;
    }

    // Custom type: construct from the env string via `pub fn parse`, the same
    // path a CLI value takes. A value that doesn't parse is ignored (default
    // kept), matching how env handles every other unparseable value.
    if (comptime custom_type.isCustomParsed(T)) {
        target.* = T.parse(env_value) catch return false;
        return true;
    }

    // Unsupported type (accumulating arrays, etc.)
    return false;
}

/// Nearest-match long option names for an unknown `--option`, for the
/// OptionUnknown diagnostic's "did you mean" list. Uses the same edit-distance
/// engine as the command not-found plugin. Returns up to `max` names within a
/// small distance, closest first; an empty slice when nothing is close.
///
/// Allocated on `allocator` (the run's arena) — the diagnostic is rendered
/// before that arena is freed, so callers do not free the result.
fn suggestLongOptions(
    comptime OptionsType: type,
    comptime meta: anytype,
    unknown: []const u8,
    allocator: std.mem.Allocator,
) []const []const u8 {
    const max = 3;
    const max_distance = 3;
    const field_count = std.meta.fields(OptionsType).len;
    if (field_count == 0) return &.{};

    const Scored = struct { name: []const u8, distance: usize };
    var scored: [field_count]Scored = undefined;
    var count: usize = 0;

    inline for (@typeInfo(OptionsType).@"struct".fields) |field| {
        const name = comptime utils.effectiveLongName(meta, field.name);
        const distance = levenshtein.editDistance(unknown, name);
        if (distance <= max_distance and distance < name.len) {
            scored[count] = .{ .name = name, .distance = distance };
            count += 1;
        }
    }
    if (count == 0) return &.{};

    std.sort.pdq(Scored, scored[0..count], {}, struct {
        fn lessThan(_: void, a: Scored, b: Scored) bool {
            return a.distance < b.distance;
        }
    }.lessThan);

    const limit = @min(count, max);
    const result = allocator.alloc([]const u8, limit) catch return &.{};
    for (0..limit) |i| result[i] = scored[i].name;
    return result;
}

/// Record a "boolean flag given a value" diagnostic and return its error.
///
/// Shared by every parsing path (long, negated `--no-`, short) so the diagnostic
/// shape stays identical: a boolean flag never takes a value.
fn booleanWithValueError(
    diag: ?*?ZcliDiagnostic,
    option_name: []const u8,
    is_short: bool,
    provided_value: []const u8,
) error{BooleanOptionWithValue} {
    if (diag) |d| d.* = .{ .OptionBooleanWithValue = .{
        .option_name = option_name,
        .is_short = is_short,
        .provided_value = provided_value,
    } };
    return error.BooleanOptionWithValue;
}

/// Enforce at-most-once usage of a boolean flag, marking it seen on success.
///
/// Shared by every parsing path (long, negated `--no-`, bundled short, single
/// short) so the duplicate diagnostic and its bookkeeping can't drift apart.
/// On a repeat it records an `OptionDuplicate` diagnostic and returns the error;
/// otherwise it sets the field's usage count to 1.
fn markBooleanFlagOnce(
    diag: ?*?ZcliDiagnostic,
    option_counts: *std.StringHashMap(u32),
    field_name: []const u8,
    option_name: []const u8,
    is_short: bool,
) !void {
    if ((option_counts.get(field_name) orelse 0) >= 1) {
        if (diag) |d| d.* = .{ .OptionDuplicate = .{
            .option_name = option_name,
            .is_short = is_short,
        } };
        return error.DuplicateOption;
    }
    try option_counts.put(field_name, 1);
}

/// Parse a long option with metadata support (--option or --option=value)
fn parseLongOptions(
    comptime OptionsType: type,
    comptime meta: anytype,
    result: *OptionsType,
    option_counts: *std.StringHashMap(u32),
    args: []const []const u8,
    arg_index: usize,
    array_lists: anytype,
    allocator: std.mem.Allocator,
    diag: ?*?ZcliDiagnostic,
) !usize {
    const arg = args[arg_index];
    const option_part = arg[2..]; // Skip "--"

    var option_name: []const u8 = undefined;
    var option_value: ?[]const u8 = null;

    // Check for --option=value syntax
    if (std.mem.indexOf(u8, option_part, "=")) |eq_index| {
        option_name = option_part[0..eq_index];
        option_value = option_part[eq_index + 1 ..];
    } else {
        option_name = option_part;
    }

    // Generate field matching code at comptime, via the shared resolution
    // rules (options/utils.zig) that the pre-split classifier also uses.
    var found = false;
    inline for (@typeInfo(OptionsType).@"struct".fields, 0..) |field, i| {
        const matches = utils.longNameMatchesField(meta, field.name, option_name);

        if (matches) {
            found = true;

            // Handle boolean flags (bool and ?bool): presence sets true. These
            // never take a value and may appear at most once (a repeated boolean —
            // including the contradictory `--flag --no-flag` pair, which shares this
            // field's count — is a usage error, not last-wins).
            if (comptime utils.isBooleanFlag(field.type)) {
                if (option_value) |val| return booleanWithValueError(diag, option_name, false, val);
                try markBooleanFlagOnce(diag, option_counts, field.name, option_name, false);
                @field(result, field.name) = true;
                return 1;
            }

            // Track usage count for duplicate detection (use field name for tracking)
            const count = option_counts.get(field.name) orelse 0;
            try option_counts.put(field.name, count + 1);

            // Get the value
            const value = blk: {
                if (option_value) |val| {
                    break :blk val;
                } else if (arg_index + 1 < args.len and utils.isValueToken(args[arg_index + 1])) {
                    break :blk args[arg_index + 1];
                } else {
                    if (diag) |d| d.* = .{ .OptionMissingValue = .{
                        .option_name = option_name,
                        .is_short = false,
                        .expected_type = diagnostic_errors.expectedTypeName(field.type),
                    } };
                    return error.MissingOptionValue;
                }
            };

            // Parse and set the value based on field type
            if (comptime utils.isArrayType(field.type)) {
                // Handle array accumulation
                const element_type = @typeInfo(field.type).pointer.child;
                if (array_lists[i]) |*list_union| {
                    try array_utils.appendCsvToArrayListUnion(element_type, allocator, list_union, value, option_name);
                }
            } else {
                // Handle single values
                const parsed_value = utils.parseOptionValue(field.type, value) catch |err| {
                    if (diag) |d| d.* = .{ .OptionInvalidValue = .{
                        .option_name = option_name,
                        .is_short = false,
                        .provided_value = value,
                        .expected_type = diagnostic_errors.expectedTypeName(field.type),
                        .suggestion = diagnostic_errors.nearestEnumValue(field.type, value),
                        .reason = custom_type.describeError(field.type, value),
                    } };
                    return err;
                };
                @field(result, field.name) = parsed_value;
            }

            // Return number of arguments consumed
            return if (option_value != null) 1 else 2;
        } else if (comptime utils.isBooleanFlag(field.type)) {
            // Not the positive name — is it the auto-generated `--no-<flag>`
            // negation? Only boolean flags have one. It sets the field false and,
            // like the positive form, takes no value and must not repeat.
            if (utils.negatedLongNameMatchesField(meta, field.name, option_name)) {
                found = true;
                if (option_value) |val| return booleanWithValueError(diag, option_name, false, val);
                try markBooleanFlagOnce(diag, option_counts, field.name, option_name, false);
                @field(result, field.name) = false;
                return 1;
            }
        }
    }

    if (!found) {
        if (diag) |d| d.* = .{ .OptionUnknown = .{
            .option_name = option_name,
            .is_short = false,
            .suggestions = suggestLongOptions(OptionsType, meta, option_name, allocator),
        } };
        return error.UnknownOption;
    }

    return 1;
}

/// Parse short options with metadata support (-o or -ovalue or -abc)
fn parseShortOptionsWithMeta(
    comptime OptionsType: type,
    comptime meta: anytype,
    result: *OptionsType,
    option_counts: *std.StringHashMap(u32),
    args: []const []const u8,
    arg_index: usize,
    array_lists: anytype,
    allocator: std.mem.Allocator,
    diag: ?*?ZcliDiagnostic,
) !usize {
    const arg = args[arg_index];
    const options_part = arg[1..]; // Skip "-"

    if (options_part.len == 0) {
        if (diag) |d| d.* = .{ .OptionUnknown = .{
            .option_name = options_part,
            .is_short = true,
            .suggestions = &.{},
        } };
        return error.UnknownOption;
    }

    // Try to parse as bundled boolean flags first
    var all_boolean = true;
    for (options_part) |char| {
        var char_field_found = false;
        var char_is_boolean = false;
        inline for (@typeInfo(OptionsType).@"struct".fields) |field| {
            // Get the expected short option character for this field (comptime)
            const expected_char = comptime utils.shortCharForField(meta, field.name);

            const matches = expected_char == char;

            if (matches) {
                char_field_found = true;
                char_is_boolean = comptime utils.isBooleanFlag(field.type);
                break;
            }
        }
        if (!char_field_found or !char_is_boolean) {
            all_boolean = false;
            break;
        }
    }

    if (all_boolean and options_part.len > 1) {
        // Parse as bundled boolean flags
        for (options_part, 0..) |char, ci| {
            inline for (@typeInfo(OptionsType).@"struct".fields, 0..) |field, i| {
                _ = i; // Unused for boolean flags
                const expected_char = comptime utils.shortCharForField(meta, field.name);

                const matches = expected_char == char;

                if (matches) {
                    if (comptime utils.isBooleanFlag(field.type)) {
                        try markBooleanFlagOnce(diag, option_counts, field.name, options_part[ci .. ci + 1], true);
                        @field(result, field.name) = true;
                    }
                    break;
                }
            }
        }
        return 1;
    } else {
        // Parse as single option, possibly with value
        const char = options_part[0];

        var char_found = false;
        inline for (@typeInfo(OptionsType).@"struct".fields, 0..) |field, i| {
            // Get the expected short option character for this field (comptime)
            const expected_char = comptime utils.shortCharForField(meta, field.name);

            const matches = expected_char == char;

            if (matches) {
                char_found = true;

                if (comptime utils.isBooleanFlag(field.type)) {
                    try markBooleanFlagOnce(diag, option_counts, field.name, options_part[0..1], true);
                    @field(result, field.name) = true;
                    return 1;
                } else {
                    // Track usage count for duplicate detection
                    const count = option_counts.get(field.name) orelse 0;
                    try option_counts.put(field.name, count + 1);

                    // Value-taking option
                    var value: []const u8 = undefined;
                    var consumed: usize = 1;

                    if (options_part.len > 1) {
                        // Value attached: -ovalue
                        value = options_part[1..];
                    } else {
                        // Value in the next argument — but only if that token is
                        // a value, not another option (#299). A following flag
                        // (`-t --verbose`) is a missing value, mirroring the long
                        // path; the bare `-` and negative numbers count as values.
                        if (arg_index + 1 >= args.len or !utils.isValueToken(args[arg_index + 1])) {
                            if (diag) |d| d.* = .{ .OptionMissingValue = .{
                                .option_name = options_part[0..1],
                                .is_short = true,
                                .expected_type = diagnostic_errors.expectedTypeName(field.type),
                            } };
                            return error.MissingOptionValue;
                        }
                        value = args[arg_index + 1];
                        consumed = 2;
                    }

                    if (comptime utils.isArrayType(field.type)) {
                        // For array types, accumulate values
                        if (array_lists.*[i]) |*list_union| {
                            const element_type = @typeInfo(field.type).pointer.child;
                            try array_utils.appendCsvToArrayListUnionShort(element_type, allocator, list_union, value, char);
                        }
                    } else {
                        const parsed_value = utils.parseOptionValue(field.type, value) catch |err| {
                            if (diag) |d| d.* = .{ .OptionInvalidValue = .{
                                .option_name = options_part[0..1],
                                .is_short = true,
                                .provided_value = value,
                                .expected_type = diagnostic_errors.expectedTypeName(field.type),
                                .suggestion = diagnostic_errors.nearestEnumValue(field.type, value),
                                .reason = custom_type.describeError(field.type, value),
                            } };
                            return err;
                        };
                        @field(result, field.name) = parsed_value;
                    }

                    return consumed;
                }
            }
        }

        if (!char_found) {
            if (diag) |d| d.* = .{ .OptionUnknown = .{
                .option_name = options_part[0..1],
                .is_short = true,
                .suggestions = &.{},
            } };
            return error.UnknownOption;
        }

        return 1;
    }
}

/// Helper function to clean up array fields in options
/// This function automatically frees memory allocated for array options (e.g., [][]const u8, []i32, etc.)
/// Individual string elements are not freed as they come from command-line args
///
/// ### Manual Usage Example:
/// ```zig
/// const parsed = try parseOptions(Options, allocator, args, null);
/// defer cleanupOptions(Options, parsed.options, allocator);
/// ```
/// Clean up memory allocated for array options by parseOptions/parseOptionsWithMeta.
///
/// This function frees memory allocated for array fields in option structs. It should
/// be called after parsing options when the parsed struct is no longer needed.
/// Individual strings within arrays are not freed as they reference command-line arguments.
///
/// ## Parameters
/// - `OptionsType`: The same struct type used for parsing
/// - `options`: The parsed options struct returned from parseOptions
/// - `allocator`: The same allocator used for parsing
///
/// ## Memory Safety
/// - Only frees array slices (e.g., `[]i32`, `[][]const u8`), not individual elements
/// - String fields (`[]const u8`) are never freed as they reference args
/// - Individual string elements in string arrays are not freed
/// - Safe to call on structs without array fields
///
/// ## Examples
/// ```zig
/// // Not re-exported at the package root — reachable via zcli.parseCommandLine,
/// // or directly as parseOptions within this module:
/// const result = try parseOptions(Options, allocator, args, null);
/// defer cleanupOptions(Options, result.options, allocator);
///
/// // Use result.options safely here
/// for (result.options.files) |file| {
///     std.debug.print("File: {s}\n", .{file});
/// }
/// // Cleanup happens automatically via defer
/// ```
///
/// ## Framework Usage
/// When using commands through the zcli framework, cleanup is automatic.
/// Manual cleanup is only needed when calling parsing functions directly.
pub fn cleanupOptions(comptime OptionsType: type, options: OptionsType, allocator: std.mem.Allocator) void {
    const type_info = @typeInfo(OptionsType);
    if (type_info != .@"struct") return;

    inline for (type_info.@"struct".fields) |field| {
        const field_value = @field(options, field.name);
        const field_type_info = @typeInfo(field.type);

        // Check if this is a slice type (array) but NOT a string
        if (field_type_info == .pointer and
            field_type_info.pointer.size == .slice)
        {
            // Only free arrays, not strings ([]const u8)
            if (field_type_info.pointer.child != u8) {
                // Free the slice itself - works for all array types:
                // [][]const u8, []i32, []u32, []f64, etc.
                // We don't free individual elements as they're either:
                // - Strings from args (not owned)
                // - Primitive values (no allocation)
                if (field_value.len > 0) {
                    allocator.free(field_value);
                }
            }
        }
    }
}

// Tests

test "parseOptions basic" {
    const TestOptions = struct {
        verbose: bool = false,
        name: []const u8 = "default",
        count: u32 = 1,
    };

    const allocator = std.testing.allocator;

    {
        const args = [_][]const u8{ "--verbose", "--name", "test", "--count", "42" };
        const parsed = try parseOptions(TestOptions, allocator, &args, null);
        try std.testing.expect(parsed.options.verbose);
        try std.testing.expectEqualStrings("test", parsed.options.name);
        try std.testing.expectEqual(@as(u32, 42), parsed.options.count);
        try std.testing.expectEqual(@as(usize, 5), parsed.result.next_arg_index);
    }
}

test "parseOptions short flags" {
    const TestOptions = struct {
        verbose: bool = false,
        quiet: bool = false,
    };

    const allocator = std.testing.allocator;

    {
        const args = [_][]const u8{"-vq"};
        const parsed = try parseOptions(TestOptions, allocator, &args, null);
        try std.testing.expect(parsed.options.verbose);
        try std.testing.expect(parsed.options.quiet);
    }
}

test "parseOptions long option with equals" {
    const TestOptions = struct {
        name: []const u8 = "default",
        port: u16 = 8080,
        verbose: bool = false,
    };

    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "--name=myapp", "--port=3000", "--verbose" };
    const parsed = try parseOptions(TestOptions, allocator, &args, null);

    try std.testing.expectEqualStrings("myapp", parsed.options.name);
    try std.testing.expectEqual(@as(u16, 3000), parsed.options.port);
    try std.testing.expect(parsed.options.verbose);
}

test "parseOptions short option with value" {
    const TestOptions = struct {
        name: []const u8 = "default",
        port: u16 = 8080,
    };

    const allocator = std.testing.allocator;

    // Test with space
    {
        const args = [_][]const u8{ "-n", "test", "-p", "9000" };
        const parsed = try parseOptions(TestOptions, allocator, &args, null);
        try std.testing.expectEqualStrings("test", parsed.options.name);
        try std.testing.expectEqual(@as(u16, 9000), parsed.options.port);
    }

    // Test without space
    {
        const args = [_][]const u8{ "-ntest2", "-p9001" };
        const parsed = try parseOptions(TestOptions, allocator, &args, null);
        try std.testing.expectEqualStrings("test2", parsed.options.name);
        try std.testing.expectEqual(@as(u16, 9001), parsed.options.port);
    }
}

test "parseOptions double dash stops parsing" {
    const TestOptions = struct {
        verbose: bool = false,
    };

    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "--verbose", "--", "--not-an-option" };
    const parsed = try parseOptions(TestOptions, allocator, &args, null);

    try std.testing.expect(parsed.options.verbose);
    try std.testing.expectEqual(@as(usize, 2), parsed.result.next_arg_index);
}

test "parseOptions enum types" {
    const LogLevel = enum { debug, info, warn, err };
    const TestOptions = struct {
        level: LogLevel = .info,
        format: enum { json, text } = .text,
    };

    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "--level", "debug", "--format", "json" };
    const parsed = try parseOptions(TestOptions, allocator, &args, null);

    try std.testing.expectEqual(LogLevel.debug, parsed.options.level);
    try std.testing.expectEqual(@as(@TypeOf(parsed.options.format), .json), parsed.options.format);
}

test "parseOptions optional types" {
    const TestOptions = struct {
        config: ?[]const u8 = null,
        port: ?u16 = null,
    };

    const allocator = std.testing.allocator;

    // Test with values provided
    {
        const args = [_][]const u8{ "--config", "app.conf", "--port", "8080" };
        const parsed = try parseOptions(TestOptions, allocator, &args, null);

        try std.testing.expectEqualStrings("app.conf", parsed.options.config.?);
        try std.testing.expectEqual(@as(u16, 8080), parsed.options.port.?);
    }

    // Test with defaults
    {
        const args = [_][]const u8{};
        const parsed = try parseOptions(TestOptions, allocator, &args, null);

        try std.testing.expectEqual(@as(?[]const u8, null), parsed.options.config);
        try std.testing.expectEqual(@as(?u16, null), parsed.options.port);
    }
}

test "negation flags set booleans false" {
    const TestOptions = struct {
        verbose: bool = false,
        color: bool = true,
    };
    const allocator = std.testing.allocator;

    // --no-verbose sets a default-false bool false (redundant but allowed);
    // leaves other fields at their defaults.
    {
        const args = [_][]const u8{"--no-verbose"};
        const parsed = try parseOptions(TestOptions, allocator, &args, null);
        try std.testing.expect(!parsed.options.verbose);
        try std.testing.expect(parsed.options.color);
    }
    // --no-color flips a default-true bool to false (the only way to reach it).
    {
        const args = [_][]const u8{"--no-color"};
        const parsed = try parseOptions(TestOptions, allocator, &args, null);
        try std.testing.expect(!parsed.options.color);
    }
    // Positive forms still set true.
    {
        const args = [_][]const u8{ "--verbose", "--color" };
        const parsed = try parseOptions(TestOptions, allocator, &args, null);
        try std.testing.expect(parsed.options.verbose);
        try std.testing.expect(parsed.options.color);
    }
}

test "optional bool is a three-state flag" {
    const TestOptions = struct {
        verbose: ?bool = null,
    };
    const allocator = std.testing.allocator;

    // Absent -> null.
    {
        const args = [_][]const u8{};
        const parsed = try parseOptions(TestOptions, allocator, &args, null);
        try std.testing.expectEqual(@as(?bool, null), parsed.options.verbose);
    }
    // --verbose -> true.
    {
        const args = [_][]const u8{"--verbose"};
        const parsed = try parseOptions(TestOptions, allocator, &args, null);
        try std.testing.expectEqual(@as(?bool, true), parsed.options.verbose);
    }
    // --no-verbose -> false.
    {
        const args = [_][]const u8{"--no-verbose"};
        const parsed = try parseOptions(TestOptions, allocator, &args, null);
        try std.testing.expectEqual(@as(?bool, false), parsed.options.verbose);
    }
    // A ?bool is a flag, not a value option: a following `false` is a positional
    // (skipped, GNU-style), not consumed as the flag's value.
    {
        const args = [_][]const u8{ "--verbose", "false" };
        const parsed = try parseOptions(TestOptions, allocator, &args, null);
        try std.testing.expectEqual(@as(?bool, true), parsed.options.verbose);
    }
}

test "repeated boolean is a duplicate error" {
    const TestOptions = struct {
        verbose: bool = false,
    };
    const allocator = std.testing.allocator;

    const cases = [_][]const []const u8{
        &.{ "--verbose", "--verbose" }, // positive twice
        &.{ "--no-verbose", "--no-verbose" }, // negation twice
        &.{ "--verbose", "--no-verbose" }, // contradictory
        &.{ "--no-verbose", "--verbose" }, // contradictory, reversed
        &.{ "-v", "-v" }, // short, separate
        &.{"-vv"}, // short, bundled
    };
    for (cases) |args| {
        try std.testing.expectError(ZcliError.OptionDuplicate, parseOptions(TestOptions, allocator, args, null));
    }
}

test "negation flag rejects an attached value" {
    const TestOptions = struct {
        verbose: bool = false,
    };
    const allocator = std.testing.allocator;
    const args = [_][]const u8{"--no-verbose=true"};
    try std.testing.expectError(ZcliError.OptionBooleanWithValue, parseOptions(TestOptions, allocator, &args, null));
}

test "negation does not apply to value options" {
    const TestOptions = struct {
        output: []const u8 = "text",
    };
    const allocator = std.testing.allocator;
    // `--no-output` is not a flag negation (output takes a value) and no field is
    // named `no_output`, so it is simply unknown.
    const args = [_][]const u8{ "--no-output", "x" };
    try std.testing.expectError(ZcliError.OptionUnknown, parseOptions(TestOptions, allocator, &args, null));
}

test "negation respects custom option names" {
    const TestOptions = struct {
        fast: bool = true,
    };
    const meta = .{
        .options = .{
            .fast = .{ .name = "cache" },
        },
    };
    const allocator = std.testing.allocator;

    // Negation is built from the effective (custom) name: --no-cache.
    {
        const args = [_][]const u8{"--no-cache"};
        const parsed = try parseOptionsWithMeta(TestOptions, meta, allocator, null, &args, null);
        try std.testing.expect(!parsed.options.fast);
    }
    // The field-name spelling is shadowed by the custom name, so is its negation.
    {
        const args = [_][]const u8{"--no-fast"};
        try std.testing.expectError(ZcliError.OptionUnknown, parseOptionsWithMeta(TestOptions, meta, allocator, null, &args, null));
    }
}

test "parseOptions dash to underscore conversion" {
    const TestOptions = struct {
        dry_run: bool = false,
        log_level: []const u8 = "info",
        max_retries: u32 = 3,
    };

    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "--dry-run", "--log-level", "debug", "--max-retries", "5" };
    const parsed = try parseOptions(TestOptions, allocator, &args, null);

    try std.testing.expect(parsed.options.dry_run);
    try std.testing.expectEqualStrings("debug", parsed.options.log_level);
    try std.testing.expectEqual(@as(u32, 5), parsed.options.max_retries);
}

test "parseOptions error cases" {
    const TestOptions = struct {
        name: []const u8 = "default",
        count: u32 = 1,
    };

    const allocator = std.testing.allocator;

    // Unknown option
    {
        const args = [_][]const u8{"--unknown"};
        try std.testing.expectError(ZcliError.OptionUnknown, parseOptions(TestOptions, allocator, &args, null));
    }

    // Missing option value
    {
        const args = [_][]const u8{"--name"};
        try std.testing.expectError(ZcliError.OptionMissingValue, parseOptions(TestOptions, allocator, &args, null));
    }

    // Invalid option value
    {
        const args = [_][]const u8{ "--count", "not_a_number" };
        try std.testing.expectError(ZcliError.OptionInvalidValue, parseOptions(TestOptions, allocator, &args, null));
    }

    // Boolean option with value
    {
        const BoolOptions = struct {
            verbose: bool = false,
        };
        const args = [_][]const u8{"--verbose=true"};
        // A boolean flag given a value is its own error (it used to be
        // misclassified as OptionInvalidValue by a catch-all).
        try std.testing.expectError(ZcliError.OptionBooleanWithValue, parseOptions(BoolOptions, allocator, &args, null));
    }
}

test "parseOptions array accumulation" {
    const TestOptions = struct {
        files: [][]const u8 = &.{},
        numbers: []i32 = &.{},
        verbose: bool = false,
    };

    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "--files", "a.txt", "--files", "b.txt", "--numbers", "1", "--numbers", "2", "--verbose" };
    const parsed = try parseOptions(TestOptions, allocator, &args, null);
    defer cleanupOptions(TestOptions, parsed.options, allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.options.files.len);
    try std.testing.expectEqualStrings("a.txt", parsed.options.files[0]);
    try std.testing.expectEqualStrings("b.txt", parsed.options.files[1]);

    try std.testing.expectEqual(@as(usize, 2), parsed.options.numbers.len);
    try std.testing.expectEqual(@as(i32, 1), parsed.options.numbers[0]);
    try std.testing.expectEqual(@as(i32, 2), parsed.options.numbers[1]);

    try std.testing.expect(parsed.options.verbose);
}

test "parseOptions array accumulation with short flags" {
    const TestOptions = struct {
        files: [][]const u8 = &.{},
        numbers: []i32 = &.{},
    };

    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "-f", "first.txt", "-f", "second.txt", "-n", "10", "-n", "20" };
    const parsed = try parseOptions(TestOptions, allocator, &args, null);
    defer cleanupOptions(TestOptions, parsed.options, allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.options.files.len);
    try std.testing.expectEqualStrings("first.txt", parsed.options.files[0]);
    try std.testing.expectEqualStrings("second.txt", parsed.options.files[1]);

    try std.testing.expectEqual(@as(usize, 2), parsed.options.numbers.len);
    try std.testing.expectEqual(@as(i32, 10), parsed.options.numbers[0]);
    try std.testing.expectEqual(@as(i32, 20), parsed.options.numbers[1]);
}

test "parseOptions comma-separated array values" {
    const TestOptions = struct {
        files: [][]const u8 = &.{},
        numbers: []i32 = &.{},
        label: ?[]const u8 = null,
    };

    const allocator = std.testing.allocator;

    // Long, short, attached-short, and equals forms all split on comma; a comma
    // repetition composes; and a comma in a *scalar* option stays literal.
    const args = [_][]const u8{
        "--files", "a.txt,b.txt", // long space form
        "-f", "c.txt", // repetition composes with the comma form
        "--numbers=1,2,3", // equals form
        "-n3,4", // attached short form
        "--label", "x,y", // scalar option — NOT split
    };
    const parsed = try parseOptions(TestOptions, allocator, &args, null);
    defer cleanupOptions(TestOptions, parsed.options, allocator);

    try std.testing.expectEqual(@as(usize, 3), parsed.options.files.len);
    try std.testing.expectEqualStrings("a.txt", parsed.options.files[0]);
    try std.testing.expectEqualStrings("b.txt", parsed.options.files[1]);
    try std.testing.expectEqualStrings("c.txt", parsed.options.files[2]);

    try std.testing.expectEqual(@as(usize, 5), parsed.options.numbers.len);
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3, 3, 4 }, parsed.options.numbers);

    // Scalar option keeps the comma as a literal character.
    try std.testing.expectEqualStrings("x,y", parsed.options.label.?);
}

test "parseOptions comma-separated rejects empty segments" {
    const TestOptions = struct {
        files: [][]const u8 = &.{},
    };

    const allocator = std.testing.allocator;

    // Interior, leading, and trailing empty segments are all invalid.
    inline for (.{ "a,,b", ",a", "a," }) |bad| {
        const args = [_][]const u8{ "--files", bad };
        try std.testing.expectError(ZcliError.OptionInvalidValue, parseOptions(TestOptions, allocator, &args, null));
    }
}

test "parseOptionsWithMeta custom name mapping" {
    const TestOptions = struct {
        files: [][]const u8 = &.{},
        verbose: bool = false,
    };

    const meta = .{
        .options = .{
            .files = .{ .name = "file" },
        },
    };

    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "--file", "test1.txt", "--file", "test2.txt", "--verbose" };
    const parsed = try parseOptionsWithMeta(TestOptions, meta, allocator, null, &args, null);
    defer cleanupOptions(TestOptions, parsed.options, allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.options.files.len);
    try std.testing.expectEqualStrings("test1.txt", parsed.options.files[0]);
    try std.testing.expectEqualStrings("test2.txt", parsed.options.files[1]);
    try std.testing.expect(parsed.options.verbose);

    // Should fail with the field name when custom name is specified
    const fail_args = [_][]const u8{ "--files", "should_fail.txt" };
    try std.testing.expectError(ZcliError.OptionUnknown, parseOptionsWithMeta(TestOptions, meta, allocator, null, &fail_args, null));
}

test "parseOptionsWithMeta custom names are exclusive" {
    const TestOptions = struct {
        output_files: [][]const u8 = &.{},
    };

    // Custom name "file" should be exclusive - can't use both --file and --output-files
    const meta = .{
        .options = .{
            .output_files = .{ .name = "file" },
        },
    };

    const allocator = std.testing.allocator;

    // Should work with custom name
    {
        const args = [_][]const u8{ "--file", "test.txt" };
        const parsed = try parseOptionsWithMeta(TestOptions, meta, allocator, null, &args, null);
        defer cleanupOptions(TestOptions, parsed.options, allocator);

        try std.testing.expectEqual(@as(usize, 1), parsed.options.output_files.len);
        try std.testing.expectEqualStrings("test.txt", parsed.options.output_files[0]);
    }

    // Should fail with field name when custom name is provided
    {
        const args = [_][]const u8{ "--output-files", "test.txt" };
        try std.testing.expectError(ZcliError.OptionUnknown, parseOptionsWithMeta(TestOptions, meta, allocator, null, &args, null));
    }
}

test "cleanupOptions helper function" {
    const TestOptions = struct {
        files: [][]const u8 = &.{},
        counts: []i32 = &.{},
        name: []const u8 = "default",
        verbose: bool = false,
    };

    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "--files", "a.txt", "--files", "b.txt", "--counts", "1", "--counts", "2", "--name", "test" };
    const parsed = try parseOptions(TestOptions, allocator, &args, null);

    // Verify arrays were allocated
    try std.testing.expectEqual(@as(usize, 2), parsed.options.files.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.options.counts.len);

    // This should not fail or leak memory
    cleanupOptions(TestOptions, parsed.options, allocator);
}

test "parseOptions negative numbers" {
    const TestOptions = struct {
        value: i32 = 0,
        verbose: bool = false,
    };

    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "--value", "-42", "--verbose" };
    const parsed = try parseOptions(TestOptions, allocator, &args, null);

    try std.testing.expectEqual(@as(i32, -42), parsed.options.value);
    try std.testing.expect(parsed.options.verbose);
}

test "parseOptions continues through negative numbers (GNU-style)" {
    const TestOptions = struct {
        verbose: bool = false,
    };

    const allocator = std.testing.allocator;

    // Should continue parsing through negative numbers in GNU-style
    const args = [_][]const u8{ "--verbose", "-123", "other", "args" };
    const parsed = try parseOptions(TestOptions, allocator, &args, null);

    try std.testing.expect(parsed.options.verbose);
    try std.testing.expectEqual(@as(usize, 4), parsed.result.next_arg_index);
}

test "parseOptions bundled short options" {
    const TestOptions = struct {
        verbose: bool = false,
        quiet: bool = false,
        force: bool = false,
        all: bool = false,
    };

    const allocator = std.testing.allocator;

    // Test various bundled combinations
    {
        const args = [_][]const u8{"-vqf"};
        const parsed = try parseOptions(TestOptions, allocator, &args, null);

        try std.testing.expect(parsed.options.verbose);
        try std.testing.expect(parsed.options.quiet);
        try std.testing.expect(parsed.options.force);
        try std.testing.expect(!parsed.options.all);
    }

    // Test mixed bundled and separate
    {
        const args = [_][]const u8{ "-vq", "-f", "-a" };
        const parsed = try parseOptions(TestOptions, allocator, &args, null);

        try std.testing.expect(parsed.options.verbose);
        try std.testing.expect(parsed.options.quiet);
        try std.testing.expect(parsed.options.force);
        try std.testing.expect(parsed.options.all);
    }
}

/// Result of parsing options while extracting positional arguments
pub fn ParseOptionsAndArgsResult(comptime OptionsType: type) type {
    return struct {
        options: OptionsType,
        remaining_args: []const []const u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: @This()) void {
            self.allocator.free(self.remaining_args);
        }
    };
}

// OptionsAndArgsParseResult removed - now using ZcliError!ParseOptionsAndArgsResult(T) pattern

/// Helper function to check if an option expects a value
fn optionExpectsValue(comptime OptionsType: type, comptime meta: anytype, option_name: []const u8) bool {
    const struct_info = @typeInfo(OptionsType).@"struct";

    inline for (struct_info.fields) |field| {
        // Get the actual option name (might be customized via metadata)
        const actual_name = if (@hasField(@TypeOf(meta), "options")) blk: {
            const options_meta = @field(meta, "options");
            if (@hasField(@TypeOf(options_meta), field.name)) {
                const field_meta = @field(options_meta, field.name);
                if (@TypeOf(field_meta) != []const u8 and @hasField(@TypeOf(field_meta), "name")) {
                    break :blk field_meta.name;
                }
            }
            break :blk field.name;
        } else field.name;

        if (std.mem.eql(u8, actual_name, option_name)) {
            // Boolean flags (bool and ?bool) don't expect values
            return !utils.isBooleanFlag(field.type);
        }
    }
    return false;
}

/// Helper function to check if a short option expects a value
fn shortOptionExpectsValue(comptime OptionsType: type, comptime meta: anytype, option_char: u8) bool {
    const struct_info = @typeInfo(OptionsType).@"struct";

    inline for (struct_info.fields) |field| {
        // Check if this field has a short option that matches
        if (@hasField(@TypeOf(meta), "options")) {
            const options_meta = @field(meta, "options");
            if (@hasField(@TypeOf(options_meta), field.name)) {
                const field_meta = @field(options_meta, field.name);
                if (@TypeOf(field_meta) != []const u8 and @hasField(@TypeOf(field_meta), "short")) {
                    if (field_meta.short == option_char) {
                        return !utils.isBooleanFlag(field.type);
                    }
                }
            }
        }

        // Default: first character of field name
        if (field.name.len > 0 and field.name[0] == option_char) {
            return !utils.isBooleanFlag(field.type);
        }
    }
    return false;
}

/// Parse options from anywhere in the arguments array, returning the options and remaining positional arguments
pub fn parseOptionsAndArgs(
    comptime OptionsType: type,
    comptime meta: anytype,
    allocator: std.mem.Allocator,
    environ: ?*const std.process.Environ.Map,
    args: []const []const u8,
    diag: ?*?ZcliDiagnostic,
) ZcliError!ParseOptionsAndArgsResult(OptionsType) {
    // Lists to collect options and remaining args
    var option_args = std.ArrayList([]const u8).empty;
    defer option_args.deinit(allocator);
    var remaining_args = std.ArrayList([]const u8).empty;
    defer remaining_args.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];

        // Check if this is an option (not a negative number or bare `-`).
        if (utils.isOption(arg)) {
            option_args.append(allocator, arg) catch {
                return ZcliError.SystemOutOfMemory;
            };

            // Check if this option expects a value
            var expects_value = false;

            if (std.mem.startsWith(u8, arg, "--")) {
                // Long option - check if it expects a value
                const option_name = if (std.mem.indexOf(u8, arg, "=")) |eq_pos|
                    arg[2..eq_pos]
                else
                    arg[2..];

                expects_value = optionExpectsValue(OptionsType, meta, option_name);

                // If option has =value syntax, it's already included
                if (std.mem.indexOf(u8, arg, "=") != null) {
                    expects_value = false; // Already has value embedded
                }
            } else if (arg.len >= 2) {
                // Short option - check if it expects a value
                const option_char = arg[1];
                expects_value = shortOptionExpectsValue(OptionsType, meta, option_char);
            }

            // If option expects a value and next arg exists and isn't an option, consume it
            if (expects_value and i + 1 < args.len) {
                const next_arg = args[i + 1];
                if (utils.isValueToken(next_arg)) {
                    option_args.append(allocator, next_arg) catch {
                        return ZcliError.SystemOutOfMemory;
                    };
                    i += 1;
                }
            }
        } else {
            // This is a positional argument
            remaining_args.append(allocator, arg) catch {
                return ZcliError.SystemOutOfMemory;
            };
        }

        i += 1;
    }

    // Parse the collected options
    const parsed = try parseOptionsWithMeta(OptionsType, meta, allocator, environ, option_args.items, diag);
    const remaining_slice = remaining_args.toOwnedSlice(allocator) catch {
        return ZcliError.SystemOutOfMemory;
    };
    return ParseOptionsAndArgsResult(OptionsType){
        .options = parsed.options,
        .remaining_args = remaining_slice,
        .allocator = allocator,
    };
}

test "resource limits option count basic functionality" {
    const TestOptions = struct {
        verbose: bool = false,
        name: ?[]const u8 = null,
        count: u32 = 0,
        debug: bool = false,
    };

    const allocator = std.testing.allocator;

    // Test that basic functionality still works with resource limits enabled
    const args = [_][]const u8{ "--verbose", "--name", "test", "--count", "42", "--debug" };
    const parsed = try parseOptions(TestOptions, allocator, &args, null);
    defer cleanupOptions(TestOptions, parsed.options, allocator);

    try std.testing.expectEqual(true, parsed.options.verbose);
    try std.testing.expectEqualStrings("test", parsed.options.name.?);
    try std.testing.expectEqual(@as(u32, 42), parsed.options.count);
    try std.testing.expectEqual(true, parsed.options.debug);
}

test "parseOptions default values - no options provided" {
    const TestOptions = struct {
        output: []const u8 = "stdout",
        count: u32 = 42,
        files: []const []const u8 = &.{},
    };

    const allocator = std.testing.allocator;
    const args: [0][]const u8 = .{};

    const result = try parseOptions(TestOptions, allocator, &args, null);
    defer cleanupOptions(TestOptions, result.options, allocator);

    try std.testing.expectEqualStrings("stdout", result.options.output);
    try std.testing.expectEqual(@as(u32, 42), result.options.count);
    try std.testing.expectEqual(@as(usize, 0), result.options.files.len);
}

test "parseOptions default values - some options provided" {
    const TestOptions = struct {
        output: []const u8 = "stdout",
        count: u32 = 42,
        files: []const []const u8 = &.{},
    };

    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--count", "100" };

    const result = try parseOptions(TestOptions, allocator, &args, null);
    defer cleanupOptions(TestOptions, result.options, allocator);

    try std.testing.expectEqualStrings("stdout", result.options.output); // Should use default
    try std.testing.expectEqual(@as(u32, 100), result.options.count); // Should use provided value
    try std.testing.expectEqual(@as(usize, 0), result.options.files.len); // Should be empty
}

// ============================================================================
// Environment Variable Fallback Tests
// ============================================================================

const EnvTestOptions = struct {
    count: u32 = 5,
    name: ?[]const u8 = null,
    debug: bool = false,
    format: enum { json, table } = .table,
};

const env_test_meta = .{
    .options = .{
        .count = .{ .env = "ZCLI_TEST_COUNT" },
        .name = .{ .env = "ZCLI_TEST_NAME" },
        .debug = .{ .env = "ZCLI_TEST_DEBUG" },
        .format = .{ .env = "ZCLI_TEST_FORMAT" },
    },
};

test "env fallback fills unset options from the environ map" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("ZCLI_TEST_COUNT", "42");
    try env.put("ZCLI_TEST_NAME", "from-env");
    try env.put("ZCLI_TEST_DEBUG", "true");
    try env.put("ZCLI_TEST_FORMAT", "json");

    const args = [_][]const u8{};
    const result = try parseOptionsWithMeta(EnvTestOptions, env_test_meta, allocator, &env, &args, null);
    defer cleanupOptions(EnvTestOptions, result.options, allocator);

    try std.testing.expectEqual(@as(u32, 42), result.options.count);
    try std.testing.expectEqualStrings("from-env", result.options.name.?);
    try std.testing.expect(result.options.debug);
    try std.testing.expectEqual(.json, result.options.format);
}

test "env fallback precedence: CLI beats env beats default" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("ZCLI_TEST_COUNT", "42");

    // CLI wins over env.
    const args = [_][]const u8{ "--count", "7" };
    const result = try parseOptionsWithMeta(EnvTestOptions, env_test_meta, allocator, &env, &args, null);
    defer cleanupOptions(EnvTestOptions, result.options, allocator);
    try std.testing.expectEqual(@as(u32, 7), result.options.count);

    // Unset env vars leave the default in place.
    try std.testing.expectEqual(@as(?[]const u8, null), result.options.name);
    try std.testing.expect(!result.options.debug);
}

test "env fallback: unparseable value keeps the default" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("ZCLI_TEST_COUNT", "not-a-number");
    try env.put("ZCLI_TEST_DEBUG", "maybe");

    const args = [_][]const u8{};
    const result = try parseOptionsWithMeta(EnvTestOptions, env_test_meta, allocator, &env, &args, null);
    defer cleanupOptions(EnvTestOptions, result.options, allocator);

    try std.testing.expectEqual(@as(u32, 5), result.options.count); // default kept
    try std.testing.expect(!result.options.debug); // default kept
}

test "env fallback: null environ and metaless parse are no-ops" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{};

    // No environ at all.
    const r1 = try parseOptionsWithMeta(EnvTestOptions, env_test_meta, allocator, null, &args, null);
    defer cleanupOptions(EnvTestOptions, r1.options, allocator);
    try std.testing.expectEqual(@as(u32, 5), r1.options.count);

    // Environ present but meta declares no env names.
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("ZCLI_TEST_COUNT", "42");
    const r2 = try parseOptionsWithMeta(EnvTestOptions, null, allocator, &env, &args, null);
    defer cleanupOptions(EnvTestOptions, r2.options, allocator);
    try std.testing.expectEqual(@as(u32, 5), r2.options.count);
}

test "applyEnvValue boolean spellings" {
    var target: bool = false;
    try std.testing.expect(applyEnvValue(bool, &target, "1"));
    try std.testing.expect(target);
    try std.testing.expect(applyEnvValue(bool, &target, "FALSE"));
    try std.testing.expect(!target);
    try std.testing.expect(applyEnvValue(bool, &target, "Yes"));
    try std.testing.expect(target);
    try std.testing.expect(applyEnvValue(bool, &target, "no"));
    try std.testing.expect(!target);
    try std.testing.expect(!applyEnvValue(bool, &target, "maybe"));
}

test "applyEnvValue numeric, optional, and enum types" {
    var count: u32 = 0;
    try std.testing.expect(applyEnvValue(u32, &count, "100"));
    try std.testing.expectEqual(@as(u32, 100), count);
    try std.testing.expect(!applyEnvValue(u32, &count, "-5"));

    var ratio: f64 = 0;
    try std.testing.expect(applyEnvValue(f64, &ratio, "2.5"));
    try std.testing.expectEqual(@as(f64, 2.5), ratio);

    var maybe: ?i32 = null;
    try std.testing.expect(applyEnvValue(?i32, &maybe, "123"));
    try std.testing.expectEqual(@as(i32, 123), maybe.?);

    const Mode = enum { fast, slow };
    var mode: Mode = .slow;
    try std.testing.expect(applyEnvValue(Mode, &mode, "fast"));
    try std.testing.expectEqual(Mode.fast, mode);
    try std.testing.expect(!applyEnvValue(Mode, &mode, "warp"));
}

test "applyEnvValue builds a custom type, and keeps the default when it won't parse" {
    const Port = struct {
        value: u16,
        pub fn parse(s: []const u8) error{Bad}!@This() {
            const n = std.fmt.parseInt(u16, s, 10) catch return error.Bad;
            if (n == 0) return error.Bad;
            return .{ .value = n };
        }
    };
    var port: ?Port = null;
    try std.testing.expect(applyEnvValue(?Port, &port, "8080"));
    try std.testing.expectEqual(@as(u16, 8080), port.?.value);
    // Unparseable env value is ignored — the default (null) stays, matching how
    // env treats every other type. No invalid value is ever injected.
    port = null;
    try std.testing.expect(!applyEnvValue(?Port, &port, "0"));
    try std.testing.expect(port == null);
}

test "diagnostics: option error sites fill precise context" {
    const allocator = std.testing.allocator;
    const Options = struct {
        count: u32 = 0,
        verbose: bool = false,
    };

    // Unknown long option.
    {
        var diag: ?ZcliDiagnostic = null;
        const args = [_][]const u8{"--bogus"};
        try std.testing.expectError(ZcliError.OptionUnknown, parseOptions(Options, allocator, &args, &diag));
        try std.testing.expectEqualStrings("bogus", diag.?.OptionUnknown.option_name);
        try std.testing.expect(!diag.?.OptionUnknown.is_short);
    }

    // Unknown short option.
    {
        var diag: ?ZcliDiagnostic = null;
        const args = [_][]const u8{"-x"};
        try std.testing.expectError(ZcliError.OptionUnknown, parseOptions(Options, allocator, &args, &diag));
        try std.testing.expectEqualStrings("x", diag.?.OptionUnknown.option_name);
        try std.testing.expect(diag.?.OptionUnknown.is_short);
    }

    // Missing value.
    {
        var diag: ?ZcliDiagnostic = null;
        const args = [_][]const u8{"--count"};
        try std.testing.expectError(ZcliError.OptionMissingValue, parseOptions(Options, allocator, &args, &diag));
        try std.testing.expectEqualStrings("count", diag.?.OptionMissingValue.option_name);
        try std.testing.expectEqualStrings("u32", diag.?.OptionMissingValue.expected_type);
    }

    // Invalid value.
    {
        var diag: ?ZcliDiagnostic = null;
        const args = [_][]const u8{ "--count", "many" };
        try std.testing.expectError(ZcliError.OptionInvalidValue, parseOptions(Options, allocator, &args, &diag));
        try std.testing.expectEqualStrings("count", diag.?.OptionInvalidValue.option_name);
        try std.testing.expectEqualStrings("many", diag.?.OptionInvalidValue.provided_value);
    }

    // Boolean flag given a value.
    {
        var diag: ?ZcliDiagnostic = null;
        const args = [_][]const u8{"--verbose=yes"};
        try std.testing.expectError(ZcliError.OptionBooleanWithValue, parseOptions(Options, allocator, &args, &diag));
        try std.testing.expectEqualStrings("verbose", diag.?.OptionBooleanWithValue.option_name);
        try std.testing.expectEqualStrings("yes", diag.?.OptionBooleanWithValue.provided_value);
    }
}

test "required option: provided flags track CLI and env sources" {
    const allocator = std.testing.allocator;
    const Options = struct {
        region: []const u8, // required — no default, not bool/optional/array
        verbose: bool = false,
    };
    const meta = .{ .options = .{ .region = .{ .env = "ZCLI_TEST_REQ_REGION" } } };

    // Absent from every source: not provided (and zero-initialized, not undefined).
    {
        const args = [_][]const u8{};
        const r = try parseOptionsWithMeta(Options, meta, allocator, null, &args, null);
        try std.testing.expect(!r.provided[0]);
    }
    // CLI supplies it.
    {
        const args = [_][]const u8{ "--region", "us-east-1" };
        const r = try parseOptionsWithMeta(Options, meta, allocator, null, &args, null);
        try std.testing.expect(r.provided[0]);
        try std.testing.expectEqualStrings("us-east-1", r.options.region);
    }
    // env supplies it.
    {
        var env = std.process.Environ.Map.init(allocator);
        defer env.deinit();
        try env.put("ZCLI_TEST_REQ_REGION", "eu-west-1");
        const args = [_][]const u8{};
        const r = try parseOptionsWithMeta(Options, meta, allocator, &env, &args, null);
        try std.testing.expect(r.provided[0]);
        try std.testing.expectEqualStrings("eu-west-1", r.options.region);
    }
}

test "required option: provided flag distinguishes the zero enum variant from unset" {
    const allocator = std.testing.allocator;
    const Options = struct { env: enum { dev, staging, prod } };

    // `dev` is the zero variant — its value equals std.mem.zeroes, so only the
    // provided flag can tell "explicitly chose dev" from "never set".
    const set = try parseOptions(Options, allocator, &.{ "--env", "dev" }, null);
    try std.testing.expect(set.provided[0]);
    try std.testing.expectEqual(.dev, set.options.env);

    const unset = try parseOptions(Options, allocator, &.{}, null);
    try std.testing.expect(!unset.provided[0]);
}

test "required enum option: a non-zero-tag enum is safe and tracked" {
    const allocator = std.testing.allocator;
    const Mode = enum(u8) { fast = 1, slow = 2 }; // no tag with value 0
    const Options = struct { mode: Mode };

    // Unset: the placeholder (first variant) holds, and provided is false.
    const unset = try parseOptions(Options, allocator, &.{}, null);
    try std.testing.expect(!unset.provided[0]);

    // Set to the first variant: provided is true even though value == placeholder.
    const set = try parseOptions(Options, allocator, &.{ "--mode", "fast" }, null);
    try std.testing.expect(set.provided[0]);
    try std.testing.expectEqual(Mode.fast, set.options.mode);
}

test "enum option invalid value carries a did-you-mean suggestion" {
    const allocator = std.testing.allocator;
    const Options = struct { level: enum { debug, info, warn } = .info };
    var diag: ?ZcliDiagnostic = null;
    const args = [_][]const u8{ "--level", "inof" };
    try std.testing.expectError(ZcliError.OptionInvalidValue, parseOptions(Options, allocator, &args, &diag));
    try std.testing.expectEqualStrings("info", diag.?.OptionInvalidValue.suggestion.?);
}

test "diagnostics: resource-limit sites report which cap tripped" {
    const allocator = std.testing.allocator;
    const Options = struct { enabled: bool = false };

    var diag: ?ZcliDiagnostic = null;
    const long_name = "--" ++ ("a" ** 300);
    const args = [_][]const u8{long_name};
    try std.testing.expectError(ZcliError.ResourceLimitExceeded, parseOptions(Options, allocator, &args, &diag));
    try std.testing.expectEqualStrings("option name length", diag.?.ResourceLimitExceeded.limit_type);
    try std.testing.expectEqual(@as(usize, 300), diag.?.ResourceLimitExceeded.actual_value);
}
