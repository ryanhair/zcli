const zcli = @import("zcli");
pub const error_codes = [_]zcli.failure.ErrorRule{
    .{ .cause = error.NotFound, .code = 9, .command = "check", .message = "record missing" },
};
