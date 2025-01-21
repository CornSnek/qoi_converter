# QOI Encoder/Decoder in Zig
QOI (Quite Ok Image format) encoder/decoder based on the specification from https://qoiformat.org.

For this module, it requires at least Zig 0.13.0 to build.

# Example
```zig
pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var data: Data(RGBAPixel) = undefined;
    {
        const file = try std.fs.cwd().openFile("file_to_open.qoi", .{});
        defer file.close();
        data = try Decoder.decode(RGBAPixel, file.reader().any(), allocator, .rgba);
    }
    defer data.deinit(allocator);
    std.debug.print("w:{}, h:{}, c:{}, cs:{}\n", .{ data.width, data.height, data.channels, data.colorspace });
    // Use data.pixels here...
}
```