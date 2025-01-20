const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    var one_test_failed: bool = false;
    for (builtin.test_functions) |t| {
        std.testing.allocator_instance = .{};
        try std.fmt.format(out, "Starting test '{s}'\n", .{t.name});
        const start = std.time.milliTimestamp();
        const result = t.func();
        const elapsed = std.time.milliTimestamp() - start;
        if (std.testing.allocator_instance.deinit() == .leak) {
            try std.fmt.format(out, "'{s}' leaked memory\n", .{t.name});
        }

        if (result) |_| {
            try std.fmt.format(out, "Test '{s}' passed - ({d}ms)\n\n", .{ t.name, elapsed });
        } else |err| {
            try std.fmt.format(out, "Test '{s}' failed - {}\n\n", .{ t.name, err });
            one_test_failed = true;
        }
    }
    if (one_test_failed) std.process.exit(1);
}
