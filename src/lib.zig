//! QOI format based on the specification from https://qoiformat.org/qoi-specification.pdf
const std = @import("std");

/// Byte format is `LSB = first letter` to `MSB = last letter`.
///
/// Format is not part of the QOI format. It is used for encoding/decoding pixels by different ordering.
pub const Format = enum(u8) { rgba, abgr, bgra, argb };

pub const RGBA = extern struct { r: u8, g: u8, b: u8, a: u8 };
pub const Pixel = extern union {
    pub const ARGB = extern struct { a: u8, r: u8, g: u8, b: u8 };
    pub const BGRA = extern struct { b: u8, g: u8, r: u8, a: u8 };
    pub const ABGR = extern struct { a: u8, b: u8, g: u8, r: u8 };
    rgba: RGBA,
    abgr: ABGR,
    bgra: BGRA,
    argb: ARGB,
    array: [4]u8,
    ///This is used for zero-setting and equal-checking
    raw: u32,
    pub fn init(format: Format, r: u8, g: u8, b: u8, a: u8) Pixel {
        return switch (format) {
            inline else => |T| @unionInit(Pixel, @tagName(T), .{ .r = r, .g = g, .b = b, .a = a }),
        };
    }
    pub fn change(self: *Pixel, from: Format, to: Format) void {
        const rgba = self.getRGBABytes(from);
        self.* = Pixel.init(to, rgba[0], rgba[1], rgba[2], rgba[3]);
    }
    pub fn get(self: Pixel, format: Format, comptime p: []const u8) u8 {
        return switch (format) {
            inline else => |T| @field(@field(self, @tagName(T)), p),
        };
    }
    pub fn getRGBABytes(self: Pixel, format: Format) [4]u8 {
        return switch (format) {
            inline else => |T| .{
                @field(@field(self, @tagName(T)), "r"),
                @field(@field(self, @tagName(T)), "g"),
                @field(@field(self, @tagName(T)), "b"),
                @field(@field(self, @tagName(T)), "a"),
            },
        };
    }
    pub fn getRGBBytes(self: Pixel, format: Format) [3]u8 {
        return switch (format) {
            inline else => |T| .{
                @field(@field(self, @tagName(T)), "r"),
                @field(@field(self, @tagName(T)), "g"),
                @field(@field(self, @tagName(T)), "b"),
            },
        };
    }
    pub fn eq(self: Pixel, other: Pixel) bool {
        return self.raw == other.raw;
    }
    pub fn zero() Pixel {
        return .{ .raw = 0 };
    }
};
///Encoder and Decoder requires a struct with init, get, getRGBABytes, getRGBBytes, eq, and zero
pub const RGBAPixel = extern union {
    rgba: RGBA,
    array: [4]u8,
    raw: u32,
    pub fn init(_: Format, r: u8, g: u8, b: u8, a: u8) RGBAPixel {
        return .{ .rgba = .{ .r = r, .g = g, .b = b, .a = a } };
    }
    pub inline fn get(self: RGBAPixel, _: Format, comptime p: []const u8) u8 {
        return @field(self.rgba, p);
    }
    pub inline fn getRGBABytes(self: RGBAPixel, _: Format) [4]u8 {
        return self.array;
    }
    pub inline fn getRGBBytes(self: RGBAPixel, _: Format) [3]u8 {
        return [_]u8{ self.rgba.r, self.rgba.g, self.rgba.b };
    }
    pub inline fn eq(self: RGBAPixel, other: RGBAPixel) bool {
        return self.raw == other.raw;
    }
    pub inline fn zero() RGBAPixel {
        return .{ .raw = 0 };
    }
};
const OP_RGB: u8 = 0b11111110;
const OP_RGBA: u8 = 0b11111111;
const OP_DIFF_TAG: u8 = 0b01 << 6;
const OP_LUMA_TAG: u8 = 0b10 << 6;
const OP_RUN_TAG: u8 = 0b11 << 6;
const OP_INDEX_TAG: u8 = 0;
pub const Channels = enum(u8) {
    rgb = 3,
    rgba = 4,
};
pub const ColorSpace = enum(u8) {
    srgb_with_linear_alpha = 0,
    all_channels_linear = 1,
};
pub fn Data(PType: type) type {
    return struct {
        pub const PixelType = PType;
        width: u32,
        height: u32,
        channels: Channels,
        colorspace: ColorSpace,
        pixels: []PType,
        pub fn deinit(self: Data(PType), allocator: std.mem.Allocator) void {
            allocator.free(self.pixels);
        }
    };
}
fn seen_hash(comptime PType: type, p: PType, format: Format) u8 {
    const rgba = p.getRGBABytes(format);
    return (rgba[0] *% 3 +% rgba[1] *% 5 +% rgba[2] *% 7 +% rgba[3] *% 11) & 0b00111111;
}
pub const Encoder = struct {
    pub const Error = error{DimensionsMismatchPixelsLength};
    ///PType as Pixel data structure. See `RGBAPixel` for minimum requirements.
    pub fn encode(comptime PType: type, writer: std.io.AnyWriter, format: Format, data: *const Data(PType)) !void {
        TestEqualityP(PType).add_expected_data(data);
        const w_times_h: usize = @as(usize, @intCast(data.width)) * @as(usize, @intCast(data.height));
        if (w_times_h != data.pixels.len) return Error.DimensionsMismatchPixelsLength;
        //header
        try writer.writeAll("qoif");
        try writer.writeInt(u32, data.width, .big);
        try writer.writeInt(u32, data.height, .big);
        try writer.writeInt(u8, @intFromEnum(data.channels), .big);
        try writer.writeInt(u8, @intFromEnum(data.colorspace), .big);
        //pixel encoding
        var last_pixel: PType = PType.init(format, 0, 0, 0, 0xff);
        var pixels_seen: [64]PType = [1]PType{PType.zero()} ** 64;
        var run_mult: u8 = 0;
        for (data.pixels) |this_pixel| {
            if (this_pixel.eq(last_pixel)) {
                run_mult += 1;
                if (run_mult == 62) {
                    try TestEqualityP(PType).add_encode_op(.run);
                    try writer.writeByte(OP_RUN_TAG | (run_mult - 1));
                    run_mult = 0;
                }
                continue;
            }
            if (run_mult != 0) {
                try TestEqualityP(PType).add_encode_op(.run);
                try writer.writeByte(OP_RUN_TAG | (run_mult - 1));
                run_mult = 0;
            }
            defer last_pixel = this_pixel;
            const seen_i = seen_hash(PType, this_pixel, format);
            if (pixels_seen[seen_i].eq(this_pixel)) {
                try TestEqualityP(PType).add_encode_op(.index);
                try writer.writeByte(seen_i);
                continue;
            }
            defer pixels_seen[seen_i] = this_pixel;
            const alpha_unchanged: bool = this_pixel.get(format, "a") == last_pixel.get(format, "a");
            if (alpha_unchanged) {
                const this_rgb = this_pixel.getRGBBytes(format);
                const last_rgb = last_pixel.getRGBBytes(format);
                const dr: i8 = @bitCast(this_rgb[0] -% last_rgb[0]);
                const dg: i8 = @bitCast(this_rgb[1] -% last_rgb[1]);
                const db: i8 = @bitCast(this_rgb[2] -% last_rgb[2]);
                if (dr <= 1 and dr >= -2 and dg <= 1 and dg >= -2 and db <= 1 and db >= -2) {
                    try TestEqualityP(PType).add_encode_op(.diff);
                    const enc_dr: u8 = (@as(u8, @bitCast(dr + 2)) & 0b11) << 4;
                    const enc_dg: u8 = (@as(u8, @bitCast(dg + 2)) & 0b11) << 2;
                    const enc_db: u8 = @as(u8, @bitCast(db + 2)) & 0b11;
                    try writer.writeByte(OP_DIFF_TAG | enc_dr | enc_dg | enc_db);
                    continue;
                }
                const drmdg: i8 = dr -% dg;
                const dbmdg: i8 = db -% dg;
                if (drmdg <= 7 and drmdg >= -8 and dg <= 31 and dg >= -32 and dbmdg <= 7 and dbmdg >= -8) {
                    try TestEqualityP(PType).add_encode_op(.luma);
                    const enc_drmdg: u8 = (@as(u8, @bitCast(drmdg + 8)) & 0b1111) << 4;
                    const enc_dg: u8 = @as(u8, @bitCast(dg + 32)) & 0b111111;
                    const enc_dbmdg: u8 = @as(u8, @bitCast(dbmdg + 8)) & 0b1111;
                    try writer.writeAll(&[2]u8{ OP_LUMA_TAG | enc_dg, enc_drmdg | enc_dbmdg });
                    continue;
                }
                try TestEqualityP(PType).add_encode_op(.rgb);
                try writer.writeByte(OP_RGB);
                try writer.writeAll(&this_pixel.getRGBBytes(format));
            } else {
                try TestEqualityP(PType).add_encode_op(.rgba);
                try writer.writeByte(OP_RGBA);
                try writer.writeAll(&this_pixel.getRGBABytes(format));
            }
        }
        if (run_mult != 0) {
            try writer.writeByte(OP_RUN_TAG | (run_mult - 1));
            run_mult = 0;
        }
        //end
        try writer.writeAll(&([1]u8{0x00} ** 7 ++ [1]u8{0x01}));
    }
};
pub const Decoder = struct {
    pub const Error = error{
        InvalidQOIHeader,
        InvalidValueInHeader,
        ReadingMorePixels,
        MissingEndBytes,
    };
    ///PType as Pixel data structure. See `RGBAPixel` for minimum requirements.
    pub fn decode(comptime PType: type, reader: std.io.AnyReader, allocator: std.mem.Allocator, format: Format) !Data(PType) {
        const qoif_magic: u32 = @bitCast(try reader.readBytesNoEof(4));
        if (qoif_magic != @as(u32, @bitCast([4]u8{ 'q', 'o', 'i', 'f' }))) return Error.InvalidQOIHeader;
        var data: Data(PType) = undefined;
        data.width = reader.readInt(u32, .big) catch return Error.InvalidValueInHeader;
        data.height = reader.readInt(u32, .big) catch return Error.InvalidValueInHeader;
        data.channels = reader.readEnum(Channels, .big) catch return Error.InvalidValueInHeader;
        data.colorspace = reader.readEnum(ColorSpace, .big) catch return Error.InvalidValueInHeader;
        var pixels_list: std.ArrayListUnmanaged(PType) = .{};
        defer pixels_list.deinit(allocator);
        const w_times_h: usize = @as(usize, @intCast(data.width)) * @as(usize, @intCast(data.height));
        try pixels_list.ensureTotalCapacityPrecise(allocator, w_times_h);
        var last_pixel: PType = PType.init(format, 0, 0, 0, 0xff);
        var pixels_seen: [64]PType = [1]PType{PType.zero()} ** 64;
        var found_end: bool = false;
        while (reader.readByte()) |byte| {
            if (byte == OP_RGB) {
                if (pixels_list.items.len == w_times_h) return Error.ReadingMorePixels;
                try TestEqualityP(PType).check_op(.rgb);
                const r = try reader.readByte();
                const g = try reader.readByte();
                const b = try reader.readByte();
                const px = PType.init(format, r, g, b, last_pixel.get(format, "a"));
                pixels_list.items.len += 1;
                pixels_list.items[pixels_list.items.len - 1] = px;
                last_pixel = px;
                pixels_seen[seen_hash(PType, last_pixel, format)] = px;
            } else if (byte == OP_RGBA) {
                if (pixels_list.items.len == w_times_h) return Error.ReadingMorePixels;
                try TestEqualityP(PType).check_op(.rgba);
                const r = try reader.readByte();
                const g = try reader.readByte();
                const b = try reader.readByte();
                const a = try reader.readByte();
                const px = PType.init(format, r, g, b, a);
                pixels_list.items.len += 1;
                pixels_list.items[pixels_list.items.len - 1] = px;
                last_pixel = px;
                pixels_seen[seen_hash(PType, last_pixel, format)] = px;
            } else if (byte & (0b11 << 6) == OP_RUN_TAG) {
                const run_num = (byte & 0b00111111) + 1;
                if (pixels_list.items.len + run_num > w_times_h) return Error.ReadingMorePixels;
                try TestEqualityP(PType).check_op(.run);
                pixels_list.items.len += run_num;
                @memset(pixels_list.items[pixels_list.items.len - run_num .. pixels_list.items.len], last_pixel);
            } else if (byte & (0b11 << 6) == OP_INDEX_TAG) {
                if (pixels_list.items.len == w_times_h) {
                    //Check for u8{0,0,0,0,0,0,0,1} ending
                    if (byte == 0) {
                        const last_bytes: [7]u8 = reader.readBytesNoEof(7) catch return Error.MissingEndBytes;
                        if (std.mem.eql(u8, &last_bytes, &([1]u8{0} ** 6 ++ [1]u8{1}))) {
                            found_end = true;
                            break;
                        } else return Error.MissingEndBytes;
                    } else return Error.MissingEndBytes;
                }
                try TestEqualityP(PType).check_op(.index);
                last_pixel = pixels_seen[byte];
                pixels_list.items.len += 1;
                pixels_list.items[pixels_list.items.len - 1] = last_pixel;
            } else if (byte & (0b11 << 6) == OP_DIFF_TAG) {
                if (pixels_list.items.len == w_times_h) return Error.ReadingMorePixels;
                try TestEqualityP(PType).check_op(.diff);
                const dr: u8 = ((byte >> 4) & 0b00000011) -% 2;
                const dg: u8 = ((byte >> 2) & 0b00000011) -% 2;
                const db: u8 = (byte & 0b00000011) -% 2;
                const rgba = last_pixel.getRGBABytes(format);
                const px = PType.init(
                    format,
                    rgba[0] +% dr,
                    rgba[1] +% dg,
                    rgba[2] +% db,
                    rgba[3],
                );
                pixels_list.items.len += 1;
                pixels_list.items[pixels_list.items.len - 1] = px;
                last_pixel = px;
                pixels_seen[seen_hash(PType, last_pixel, format)] = px;
            } else //if (byte & (0b11 << 6) == OP_LUMA_TAG) {
            {
                if (pixels_list.items.len == w_times_h) return Error.ReadingMorePixels;
                try TestEqualityP(PType).check_op(.luma);
                const byte2: u8 = try reader.readByte();
                const dg: u8 = (byte & 0b00111111) -% 32;
                const drmdg: u8 = ((byte2 & 0b11110000) >> 4) -% 8;
                const dbmdg: u8 = (byte2 & 0b00001111) -% 8;
                const rgba = last_pixel.getRGBABytes(format);
                const px = PType.init(
                    format,
                    rgba[0] +% drmdg +% dg,
                    rgba[1] +% dg,
                    rgba[2] +% dbmdg +% dg,
                    rgba[3],
                );
                pixels_list.items.len += 1;
                pixels_list.items[pixels_list.items.len - 1] = px;
                last_pixel = px;
                pixels_seen[seen_hash(PType, last_pixel, format)] = px;
            }
        } else |_| {}
        if (!found_end) return error.MissingEndBytes;
        try TestEqualityP(PType).check_same_ops();
        data.pixels = try pixels_list.toOwnedSlice(allocator);
        try TestEqualityP(PType).check_expected_data(&data, allocator);
        return data;
    }
};
///Test Encoder/Decoder internally if all operations and pixel data are the same.
pub fn TestEqualityP(PType: type) type {
    return struct {
        const allocator = std.testing.allocator;
        const OP = enum { rgb, rgba, run, index, diff, luma };
        var op_checker: std.ArrayListUnmanaged(OP) = .{};
        var expected_data: ?*const Data(PType) = null;
        var check_i: usize = 0;
        var enable: bool = true;
        fn add_encode_op(op: OP) !void {
            if (@import("builtin").is_test and enable) try op_checker.append(allocator, op);
        }
        fn add_expected_data(data: *const Data(PType)) void {
            if (@import("builtin").is_test and enable) expected_data = data;
        }
        fn check_op(op: OP) !void {
            if (@import("builtin").is_test and enable) {
                if (op_checker.items[check_i] != op) {
                    try std.io.getStdErr().writer().print("In i={}, decode operation ({s}) differs from encode operation ({s})\n", .{
                        check_i,
                        @tagName(op),
                        @tagName(op_checker.items[check_i]),
                    });
                    return error.DecodeDifferentFromEncode;
                }
                check_i += 1;
            }
        }
        fn check_same_ops() !void {
            if (@import("builtin").is_test and enable) if (check_i < op_checker.items.len) return error.NumberOfDecodeOperationsLessThanEncodeOperations;
        }
        fn check_expected_data(data: *const Data(PType), pxallocator: std.mem.Allocator) !void {
            if (@import("builtin").is_test and enable) {
                errdefer data.deinit(pxallocator);
                try std.testing.expect(expected_data != null);
                try std.testing.expectEqual(expected_data.?.width, data.width);
                try std.testing.expectEqual(expected_data.?.height, data.height);
                try std.testing.expectEqual(expected_data.?.channels, data.channels);
                try std.testing.expectEqual(expected_data.?.colorspace, data.colorspace);
                if (data.pixels.len != expected_data.?.pixels.len) return error.PixelsLengthExpectedAndDecodedNotEqual;
                for (data.pixels, expected_data.?.pixels, 0..) |dpx, epx, i| {
                    if (!dpx.eq(epx)) {
                        try std.io.getStdErr().writer().print("In i={}, decoded pixel differs from expected pixel\n", .{i});
                        return error.PixelsExpectedAndDecodedNotEqual;
                    }
                }
            }
        }
        fn done() void {
            if (@import("builtin").is_test) {
                expected_data = null;
                op_checker.clearAndFree(allocator);
                check_i = 0;
            }
        }
    };
}
test "Encoder and Decoder small" {
    TestEqualityP(Pixel).enable = true;
    defer TestEqualityP(Pixel).done();
    const allocator = std.testing.allocator;
    // zig fmt: off
    var pixels = [1]Pixel{.{ .rgba = .{ .r = 0x12, .g = 0x34, .b = 0x56, .a = 0x78 } }} ** 10
        ++ [1]Pixel{.{ .raw = 0x79563412 }}
        ++ [1]Pixel{.{ .rgba = .{ .r = 0x0f, .g = 0x37, .b = 0x58, .a = 0x78 } }}
        ++ [1]Pixel{.{ .rgba = .{ .r = 0x0d, .g = 0x38, .b = 0x56, .a = 0x78 } }}
        ++ [1]Pixel{.{ .rgba = .{ .r = 0x10, .g = 0x3b, .b = 0x5a, .a = 0x78 } }}
        ++ [1]Pixel{.{ .rgba = .{ .r = 0x0f, .g = 0x37, .b = 0x58, .a = 0x78 } }}
        ++ [1]Pixel{.{ .raw = 0x79563412 }};
    // zig fmt: on
    const data = Data(Pixel){
        .width = 1,
        .height = 16,
        .channels = .rgba,
        .colorspace = .all_channels_linear,
        .pixels = &pixels,
    };
    var qoif_bytes: std.ArrayListUnmanaged(u8) = .{};
    defer qoif_bytes.deinit(allocator);
    try Encoder.encode(Pixel, qoif_bytes.writer(allocator).any(), .rgba, &data);
    var fba = std.io.fixedBufferStream(qoif_bytes.items);
    const decoded_data = try Decoder.decode(Pixel, fba.reader().any(), allocator, .rgba);
    defer decoded_data.deinit(allocator);
}
test "Encoder and Decoder large random pixels" {
    const allocator = std.testing.allocator;
    var rnd = std.rand.DefaultPrng.init(0);
    const width = 250;
    const height = 250;
    var expected_pixels: std.ArrayListUnmanaged(Pixel) = .{};
    defer expected_pixels.deinit(allocator);
    try expected_pixels.ensureTotalCapacityPrecise(allocator, width * height);
    expected_pixels.items.len = width * height;
    var qoif_bytes: std.ArrayListUnmanaged(u8) = .{};
    defer qoif_bytes.deinit(allocator);
    TestEqualityP(Pixel).enable = true;
    for (0..100) |_| {
        const all_opaque = rnd.random().boolean(); //Check probable op_diff and op_luma as they require consistent alpha channels.
        defer {
            TestEqualityP(Pixel).done();
            qoif_bytes.clearRetainingCapacity();
        }
        for (0..width * height) |i| {
            expected_pixels.items[i] = .{ .raw = rnd.random().int(u32) };
            if (all_opaque) expected_pixels.items[i].rgba.a = 0xff;
        }
        const data = Data(Pixel){
            .width = width,
            .height = height,
            .channels = .rgba,
            .colorspace = .all_channels_linear,
            .pixels = expected_pixels.items,
        };
        try Encoder.encode(Pixel, qoif_bytes.writer(allocator).any(), .rgba, &data);
        var fba = std.io.fixedBufferStream(qoif_bytes.items);
        const decoded_data = try Decoder.decode(Pixel, fba.reader().any(), allocator, .rgba);
        defer decoded_data.deinit(allocator);
    }
}
test "Decoder errors" {
    TestEqualityP(Pixel).enable = false; //Disable operation/pixel checking
    const allocator = std.testing.allocator;
    // zig fmt: off
    var pixels = [1]Pixel{.{ .rgba = .{ .r = 0x12, .g = 0x34, .b = 0x56, .a = 0x78 } }} ** 2
        ++ [1]Pixel{.{ .rgba = .{ .r = 0xff, .g = 0x34, .b = 0x56, .a = 0x78 } }}
        ++ [1]Pixel{.{ .rgba = .{ .r = 0x12, .g = 0x34, .b = 0x56, .a = 0x78 } }}
        ++ [1]Pixel{.{ .rgba = .{ .r = 0x10, .g = 0x32, .b = 0x54, .a = 0x78 } }}
        ++ [1]Pixel{.{ .rgba = .{ .r = 0x13, .g = 0x35, .b = 0x57, .a = 0x78 } }};
    // zig fmt: on
    const data = Data(Pixel){
        .width = 1,
        .height = 6,
        .channels = .rgba,
        .colorspace = .all_channels_linear,
        .pixels = &pixels,
    };
    var qoif_bytes: std.ArrayListUnmanaged(u8) = .{};
    defer qoif_bytes.deinit(allocator);
    try Encoder.encode(Pixel, qoif_bytes.writer(allocator).any(), .rgba, &data);
    var qb_wrong: std.ArrayListUnmanaged(u8) = try qoif_bytes.clone(allocator);
    defer qb_wrong.deinit(allocator);
    //qoif_bytes should be
    //71 6f 69 66 00 00 00 01 00 00 00 06 04 01
    //ff 12 34 56 78 c0 fe ff 34 56 3c 40 a3 88
    //00 00 00 00 00 00 00 01
    //Editing this to check if errors work correctly

    //'qoif' is edited
    qb_wrong.items[0] -= 1;
    var fba = std.io.fixedBufferStream(qb_wrong.items);
    var res = Decoder.decode(Pixel, fba.reader().any(), allocator, .rgba);
    defer if (res) |r| {
        r.deinit(allocator);
    } else |_| {};
    try std.testing.expectError(Decoder.Error.InvalidQOIHeader, res);
    qb_wrong.items[0] += 1;
    fba.reset();

    //channels/colorspace invalid enums
    qb_wrong.items[12] = 0xff;
    res = Decoder.decode(Pixel, fba.reader().any(), allocator, .rgba);
    try std.testing.expectError(Decoder.Error.InvalidValueInHeader, res);
    qb_wrong.items[12] = qoif_bytes.items[12];
    fba.reset();
    qb_wrong.items[13] = 0xff;
    res = Decoder.decode(Pixel, fba.reader().any(), allocator, .rgba);
    try std.testing.expectError(Decoder.Error.InvalidValueInHeader, res);
    qb_wrong.items[13] = qoif_bytes.items[13];
    fba.reset();

    //missing end
    fba.buffer.len -= 1;
    res = Decoder.decode(Pixel, fba.reader().any(), allocator, .rgba);
    try std.testing.expectError(Decoder.Error.MissingEndBytes, res);
    fba.reset();
    fba.buffer.len -= 7;
    res = Decoder.decode(Pixel, fba.reader().any(), allocator, .rgba);
    try std.testing.expectError(Decoder.Error.MissingEndBytes, res);
    fba.buffer.len += 8;
    fba.reset();

    qb_wrong.items[qb_wrong.items.len - 1] += 1;
    res = Decoder.decode(Pixel, fba.reader().any(), allocator, .rgba);
    try std.testing.expectError(Decoder.Error.MissingEndBytes, res);
    qb_wrong.items[qb_wrong.items.len - 1] -= 1;
    fba.reset();

    qb_wrong.items[qb_wrong.items.len - 8] += 1;
    res = Decoder.decode(Pixel, fba.reader().any(), allocator, .rgba);
    try std.testing.expectError(Decoder.Error.MissingEndBytes, res);
    qb_wrong.items[qb_wrong.items.len - 8] -= 1;
    fba.reset();

    //Reading more pixel bytes
    qb_wrong.items[qb_wrong.items.len - 8] = 0xff;
    res = Decoder.decode(Pixel, fba.reader().any(), allocator, .rgba);
    try std.testing.expectError(Decoder.Error.ReadingMorePixels, res);
    qb_wrong.items[qb_wrong.items.len - 8] = qoif_bytes.items[qoif_bytes.items.len - 8];
    fba.reset();
}

///Decorator function that counts the execution time of the function AnyFn(AnyFnArgs...).
///Use ParentOfAnyFn to get the name of a pub function (optional).
///Use time_output to get the nanoseconds passed when calling AnyFn (optional).
pub fn TimeFn(
    comptime CallMod: std.builtin.CallModifier,
    comptime AnyFn: anytype,
    comptime ParentOfAnyFn: ?type,
    AnyFnArgs: anytype,
    time_output: ?*i128,
) @TypeOf(@call(CallMod, AnyFn, AnyFnArgs)) {
    const FnName = if (ParentOfAnyFn == null) "(anonymous function)" else inline for (@typeInfo(ParentOfAnyFn.?).Struct.decls) |d| {
        const Field = @field(ParentOfAnyFn.?, d.name);
        if (@TypeOf(Field) == @TypeOf(AnyFn)) break d.name;
    } else @compileError("AnyFn function not found or not pub in ParentOfAnyFn struct.");
    if (time_output == null) std.debug.print("Calling function '{s}'...\n", .{FnName});
    const begin_nts = std.time.nanoTimestamp();
    const ret = @call(CallMod, AnyFn, AnyFnArgs);
    const end_nts = std.time.nanoTimestamp();
    if (time_output == null) {
        std.debug.print("{d} ns has passed after calling function '{s}'...\n ", .{ end_nts - begin_nts, FnName });
    } else {
        time_output.?.* = end_nts - begin_nts;
    }
    return ret;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var rnd = std.rand.DefaultPrng.init(0);
    const width = 5000;
    const height = 5000;
    var expected_pixels: std.ArrayListUnmanaged(RGBAPixel) = .{};
    defer expected_pixels.deinit(allocator);
    try expected_pixels.ensureTotalCapacityPrecise(allocator, width * height);
    expected_pixels.items.len = width * height;
    var qoif_bytes: std.ArrayListUnmanaged(u8) = .{};
    defer qoif_bytes.deinit(allocator);
    var it: usize = 0;
    var de_times: std.ArrayListUnmanaged(struct { e: i128, d: i128 }) = .{};
    defer de_times.deinit(allocator);
    var time_ns_encode_min: i128 = std.math.maxInt(i128);
    var time_ns_decode_min: i128 = std.math.maxInt(i128);
    while (true) : (it += 1) {
        defer {
            qoif_bytes.clearRetainingCapacity();
        }
        var time_ns_encode: i128 = undefined;
        var time_ns_decode: i128 = undefined;
        for (0..width * height) |i|
            expected_pixels.items[i] = .{ .raw = rnd.random().int(u32) };
        const data = Data(RGBAPixel){
            .width = width,
            .height = height,
            .channels = .rgba,
            .colorspace = .all_channels_linear,
            .pixels = expected_pixels.items,
        };
        try TimeFn(.auto, Encoder.encode, Encoder, .{ RGBAPixel, qoif_bytes.writer(allocator).any(), .rgba, &data }, &time_ns_encode);
        var fba = std.io.fixedBufferStream(qoif_bytes.items);
        const decoded_data =
            try TimeFn(.auto, Decoder.decode, Decoder, .{ RGBAPixel, fba.reader().any(), allocator, .rgba }, &time_ns_decode);
        defer decoded_data.deinit(allocator);
        try de_times.append(allocator, .{ .e = time_ns_encode, .d = time_ns_decode });
        std.debug.print("Iteration #{}\n      E: {} ns, {} us or {} ms, ", .{
            it + 1,
            time_ns_encode,
            @divFloor(time_ns_encode, std.time.ns_per_us),
            @divFloor(time_ns_encode, std.time.ns_per_ms),
        });
        std.debug.print("      D: {} ns, {} us or {} ms\n", .{
            time_ns_decode,
            @divFloor(time_ns_decode, std.time.ns_per_us),
            @divFloor(time_ns_decode, std.time.ns_per_ms),
        });

        var time_ns_encode_avg: i128 = 0;
        var time_ns_decode_avg: i128 = 0;
        for (de_times.items) |arr| {
            time_ns_encode_avg += arr.e;
            time_ns_decode_avg += arr.d;
        }
        time_ns_encode_avg = @divFloor(time_ns_encode_avg, de_times.items.len);
        time_ns_decode_avg = @divFloor(time_ns_decode_avg, de_times.items.len);
        time_ns_encode_min = @min(time_ns_encode, time_ns_encode_min);
        time_ns_decode_min = @min(time_ns_decode, time_ns_decode_min);

        std.debug.print("E (avg): {} ns, {} us or {} ms, ", .{
            time_ns_encode,
            @divFloor(time_ns_encode_avg, std.time.ns_per_us),
            @divFloor(time_ns_encode_avg, std.time.ns_per_ms),
        });
        std.debug.print("D (avg): {} ns, {} us or {} ms\n", .{
            time_ns_decode,
            @divFloor(time_ns_decode_avg, std.time.ns_per_us),
            @divFloor(time_ns_decode_avg, std.time.ns_per_ms),
        });

        std.debug.print("E (min): {} ns, {} us or {} ms, ", .{
            time_ns_encode_min,
            @divFloor(time_ns_encode_min, std.time.ns_per_us),
            @divFloor(time_ns_encode_min, std.time.ns_per_ms),
        });
        std.debug.print("D (min): {} ns, {} us or {} ms\n", .{
            time_ns_decode_min,
            @divFloor(time_ns_decode_min, std.time.ns_per_us),
            @divFloor(time_ns_decode_min, std.time.ns_per_ms),
        });
    }
}
