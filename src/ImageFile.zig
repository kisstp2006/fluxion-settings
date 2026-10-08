// SPDX-License-Identifier: BSD-2-Clause

//! A picture file, whatever it was saved as. A PNG or a JPEG is read here;
//! the forms the system's own wallpapers come in - WebP, JPEG XL and SVG -
//! by the libraries that know them, looked for when a picture needs one.
//! Fedora's backgrounds are nearly all JPEG XL and WebP: a desktop that
//! read only the first two would offer two pictures.
//!
//! Which kind a file is, its first bytes say - not its name, which a person
//! can get wrong. A library that is not installed is a picture that cannot
//! be read, not a program that cannot start.
//!
//! A library, once opened, is kept: it is opened again for each picture,
//! which finds it loaded, and never closed - a decoder written in C++ does
//! not always come apart cleanly.

const std = @import("std");
const raster = @import("fluxion_ui_raster");
const image = @import("fluxion_image");

const log = std.log.scoped(.image_file);

pub const Kind = enum { png, jpeg, webp, jxl, svg };

/// The most pixels a picture may have: 8K by 8K. A file that says it is
/// bigger is not a wallpaper.
const most_pixels = 8192 * 8192;

/// The picture at `path`, at its own size.
pub fn read(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !raster.Image {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20));
    defer gpa.free(bytes);
    return decode(gpa, bytes);
}

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) !raster.Image {
    return switch (kindOf(bytes) orelse return error.UnknownFormat) {
        .png, .jpeg => {
            var decoded = try image.decode(gpa, bytes);
            defer decoded.deinit(gpa);
            return raster.Image.fromRgba(gpa, decoded.pixels, decoded.width, decoded.height);
        },
        .webp => webp(gpa, bytes),
        .jxl => jxl(gpa, bytes),
        .svg => svg(gpa, bytes),
    };
}

/// What the first bytes say a file is.
pub fn kindOf(bytes: []const u8) ?Kind {
    if (image.kindOf(bytes)) |kind| return switch (kind) {
        .png => .png,
        .jpeg => .jpeg,
    };
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return .webp;
    // A bare codestream, or one in a container.
    if (std.mem.startsWith(u8, bytes, "\xFF\x0A")) return .jxl;
    if (std.mem.startsWith(u8, bytes, "\x00\x00\x00\x0CJXL \x0D\x0A\x87\x0A")) return .jxl;
    // XML, with an <svg> near the top: past a declaration, a comment, a
    // doctype.
    const head = std.mem.trimStart(u8, bytes[0..@min(bytes.len, 4096)], " \t\r\n\xEF\xBB\xBF");
    if (std.mem.startsWith(u8, head, "<") and std.mem.indexOf(u8, head, "<svg") != null) return .svg;
    return null;
}

/// Whether a file's name is one of a picture this reads - for a list of
/// them, before any is opened.
pub fn named(name: []const u8) bool {
    const extensions = [_][]const u8{ ".png", ".jpg", ".jpeg", ".webp", ".jxl", ".svg" };
    for (extensions) |extension| {
        if (name.len >= extension.len and std.ascii.eqlIgnoreCase(name[name.len - extension.len ..], extension)) return true;
    }
    return false;
}

/// The first of `names` there is.
fn library(comptime names: []const [:0]const u8) ?std.DynLib {
    inline for (names) |name| {
        if (std.DynLib.open(name)) |lib| return lib else |_| {}
    }
    return null;
}

fn lookup(lib: *std.DynLib, comptime T: type, name: [:0]const u8) !T {
    return lib.lookup(T, name) orelse {
        log.warn("{s} is missing", .{name});
        return error.LibraryMissing;
    };
}

fn checked(width: c_int, height: c_int) !struct { u32, u32 } {
    if (width <= 0 or height <= 0) return error.BadSize;
    const w: u32 = @intCast(width);
    const h: u32 = @intCast(height);
    if (@as(u64, w) * h > most_pixels) return error.TooLarge;
    return .{ w, h };
}

fn webp(gpa: std.mem.Allocator, bytes: []const u8) !raster.Image {
    var lib = library(&.{ "libwebp.so.7", "libwebp.so" }) orelse return error.LibraryMissing;
    const decodeRgba = try lookup(&lib, *const fn (data: [*]const u8, size: usize, width: *c_int, height: *c_int) callconv(.c) ?[*]u8, "WebPDecodeRGBA");
    const free = try lookup(&lib, *const fn (pointer: ?*anyopaque) callconv(.c) void, "WebPFree");
    var width: c_int = 0;
    var height: c_int = 0;
    const rgba = decodeRgba(bytes.ptr, bytes.len, &width, &height) orelse return error.BadWebP;
    defer free(rgba);
    const w, const h = try checked(width, height);
    return raster.Image.fromRgba(gpa, rgba[0 .. @as(usize, w) * h * 4], w, h);
}

const Jxl = struct {
    /// JxlDecoderStatus, those of it this waits on.
    const success = 0;
    const need_image_out_buffer = 5;
    const basic_info = 0x40;
    const full_image = 0x1000;

    const PixelFormat = extern struct {
        num_channels: u32,
        /// JXL_TYPE_UINT8.
        data_type: c_int = 2,
        /// JXL_NATIVE_ENDIAN.
        endianness: c_int = 0,
        alignment: usize = 0,
    };

    /// JxlBasicInfo is larger than this reads, and grows: room for it, and
    /// the fields at their offsets.
    const Info = extern struct {
        bytes: [512]u8 align(8) = @splat(0),

        fn int(self: *const Info, offset: usize) u32 {
            return std.mem.readInt(u32, self.bytes[offset..][0..4], .little);
        }
        fn width(self: *const Info) u32 {
            return self.int(4);
        }
        fn height(self: *const Info) u32 {
            return self.int(8);
        }
        /// EXIF's: 5 to 8 are turned a quarter, so the picture as it comes
        /// out is as wide as the file says it is high.
        fn orientation(self: *const Info) u32 {
            return self.int(48);
        }
    };

    const Runner = *const fn (opaque_: ?*anyopaque, jpegxl_opaque: ?*anyopaque, init: ?*anyopaque, func: ?*anyopaque, start: u32, end: u32) callconv(.c) c_int;
};

fn jxl(gpa: std.mem.Allocator, bytes: []const u8) !raster.Image {
    var lib = library(&.{ "libjxl.so.0.11", "libjxl.so.0.12", "libjxl.so.0.13", "libjxl.so.0.10", "libjxl.so" }) orelse return error.LibraryMissing;
    const create = try lookup(&lib, *const fn (memory: ?*anyopaque) callconv(.c) ?*anyopaque, "JxlDecoderCreate");
    const destroy = try lookup(&lib, *const fn (decoder: *anyopaque) callconv(.c) void, "JxlDecoderDestroy");
    const subscribe = try lookup(&lib, *const fn (decoder: *anyopaque, events: c_int) callconv(.c) c_int, "JxlDecoderSubscribeEvents");
    const setInput = try lookup(&lib, *const fn (decoder: *anyopaque, data: [*]const u8, size: usize) callconv(.c) c_int, "JxlDecoderSetInput");
    const closeInput = try lookup(&lib, *const fn (decoder: *anyopaque) callconv(.c) void, "JxlDecoderCloseInput");
    const process = try lookup(&lib, *const fn (decoder: *anyopaque) callconv(.c) c_int, "JxlDecoderProcessInput");
    const basicInfo = try lookup(&lib, *const fn (decoder: *anyopaque, info: *Jxl.Info) callconv(.c) c_int, "JxlDecoderGetBasicInfo");
    const outSize = try lookup(&lib, *const fn (decoder: *anyopaque, format: *const Jxl.PixelFormat, size: *usize) callconv(.c) c_int, "JxlDecoderImageOutBufferSize");
    const setOut = try lookup(&lib, *const fn (decoder: *anyopaque, format: *const Jxl.PixelFormat, buffer: [*]u8, size: usize) callconv(.c) c_int, "JxlDecoderSetImageOutBuffer");
    const setRunner = try lookup(&lib, *const fn (decoder: *anyopaque, runner: Jxl.Runner, runner_opaque: ?*anyopaque) callconv(.c) c_int, "JxlDecoderSetParallelRunner");

    const decoder = create(null) orelse return error.OutOfMemory;
    defer destroy(decoder);

    // A large picture comes apart a good deal faster on every core.
    var threads = library(&.{ "libjxl_threads.so.0.11", "libjxl_threads.so.0.12", "libjxl_threads.so.0.13", "libjxl_threads.so.0.10", "libjxl_threads.so" });
    var runner: ?*anyopaque = null;
    var runnerDestroy: ?*const fn (runner: *anyopaque) callconv(.c) void = null;
    if (threads) |*t| threaded: {
        const runnerCreate = t.lookup(*const fn (memory: ?*anyopaque, workers: usize) callconv(.c) ?*anyopaque, "JxlThreadParallelRunnerCreate") orelse break :threaded;
        const workers = t.lookup(*const fn () callconv(.c) usize, "JxlThreadParallelRunnerDefaultNumWorkerThreads") orelse break :threaded;
        const run = t.lookup(Jxl.Runner, "JxlThreadParallelRunner") orelse break :threaded;
        runnerDestroy = t.lookup(*const fn (runner: *anyopaque) callconv(.c) void, "JxlThreadParallelRunnerDestroy") orelse break :threaded;
        runner = runnerCreate(null, workers());
        if (runner) |r| _ = setRunner(decoder, run, r);
    }
    defer if (runner) |r| runnerDestroy.?(r);

    if (subscribe(decoder, Jxl.basic_info | Jxl.full_image) != Jxl.success) return error.BadJxl;
    if (setInput(decoder, bytes.ptr, bytes.len) != Jxl.success) return error.BadJxl;
    closeInput(decoder);

    const format: Jxl.PixelFormat = .{ .num_channels = 4 };
    var width: u32 = 0;
    var height: u32 = 0;
    var rgba: ?[]u8 = null;
    defer if (rgba) |pixels| gpa.free(pixels);
    while (true) switch (process(decoder)) {
        Jxl.basic_info => {
            var info: Jxl.Info = .{};
            if (basicInfo(decoder, &info) != Jxl.success) return error.BadJxl;
            const turned = info.orientation() >= 5;
            width = if (turned) info.height() else info.width();
            height = if (turned) info.width() else info.height();
            _ = try checked(@intCast(@min(width, std.math.maxInt(c_int))), @intCast(@min(height, std.math.maxInt(c_int))));
        },
        Jxl.need_image_out_buffer => {
            var size: usize = 0;
            if (outSize(decoder, &format, &size) != Jxl.success) return error.BadJxl;
            if (size != @as(usize, width) * height * 4 or rgba != null) return error.BadJxl;
            const pixels = try gpa.alloc(u8, size);
            rgba = pixels;
            if (setOut(decoder, &format, pixels.ptr, size) != Jxl.success) return error.BadJxl;
        },
        // The first frame, of an animation too.
        Jxl.full_image => break,
        else => return error.BadJxl,
    };
    return raster.Image.fromRgba(gpa, rgba orelse return error.BadJxl, width, height);
}

fn svg(gpa: std.mem.Allocator, bytes: []const u8) !raster.Image {
    var rsvg = library(&.{ "librsvg-2.so.2", "librsvg-2.so" }) orelse return error.LibraryMissing;
    var cairo = library(&.{ "libcairo.so.2", "libcairo.so" }) orelse return error.LibraryMissing;
    var gobject = library(&.{ "libgobject-2.0.so.0", "libgobject-2.0.so" }) orelse return error.LibraryMissing;
    const fromData = try lookup(&rsvg, *const fn (data: [*]const u8, size: usize, err: ?*?*anyopaque) callconv(.c) ?*anyopaque, "rsvg_handle_new_from_data");
    const intrinsic = try lookup(&rsvg, *const fn (handle: *anyopaque, width: *f64, height: *f64) callconv(.c) c_int, "rsvg_handle_get_intrinsic_size_in_pixels");
    const render = try lookup(&rsvg, *const fn (handle: *anyopaque, cr: *anyopaque, viewport: *const [4]f64, err: ?*?*anyopaque) callconv(.c) c_int, "rsvg_handle_render_document");
    const unref = try lookup(&gobject, *const fn (object: *anyopaque) callconv(.c) void, "g_object_unref");
    const surfaceCreate = try lookup(&cairo, *const fn (data: [*]u8, format: c_int, width: c_int, height: c_int, stride: c_int) callconv(.c) ?*anyopaque, "cairo_image_surface_create_for_data");
    const surfaceFlush = try lookup(&cairo, *const fn (surface: *anyopaque) callconv(.c) void, "cairo_surface_flush");
    const surfaceDestroy = try lookup(&cairo, *const fn (surface: *anyopaque) callconv(.c) void, "cairo_surface_destroy");
    const cairoCreate = try lookup(&cairo, *const fn (surface: *anyopaque) callconv(.c) ?*anyopaque, "cairo_create");
    const cairoDestroy = try lookup(&cairo, *const fn (cr: *anyopaque) callconv(.c) void, "cairo_destroy");

    const handle = fromData(bytes.ptr, bytes.len, null) orelse return error.BadSvg;
    defer unref(handle);
    // Its own size; a drawing that names none is drawn as a screen is.
    var w: f64 = 1920;
    var h: f64 = 1080;
    if (intrinsic(handle, &w, &h) == 0 or w < 1 or h < 1) {
        w = 1920;
        h = 1080;
    }
    // Large enough for a 4K screen and no larger: it is drawn, not read.
    const scale = @min(1, 3840 / @max(w, h));
    const width: u32 = @intFromFloat(@max(1, @round(w * scale)));
    const height: u32 = @intFromFloat(@max(1, @round(h * scale)));
    const pixels = try gpa.alloc(raster.Pixel, @as(usize, width) * height);
    errdefer gpa.free(pixels);
    @memset(pixels, 0);
    // Cairo's ARGB32 is the renderer's own pixel: premultiplied 0xAARRGGBB
    // in a native u32.
    const surface = surfaceCreate(@ptrCast(pixels.ptr), 0, @intCast(width), @intCast(height), @intCast(width * 4)) orelse return error.OutOfMemory;
    defer surfaceDestroy(surface);
    const cr = cairoCreate(surface) orelse return error.OutOfMemory;
    const viewport: [4]f64 = .{ 0, 0, @floatFromInt(width), @floatFromInt(height) };
    const drawn = render(handle, cr, &viewport, null);
    cairoDestroy(cr);
    surfaceFlush(surface);
    if (drawn == 0) return error.BadSvg;
    return .{ .pixels = pixels, .width = width, .height = height };
}

test "what a file is, its first bytes say" {
    try std.testing.expectEqual(Kind.webp, kindOf("RIFF\x10\x00\x00\x00WEBPVP8 ").?);
    try std.testing.expectEqual(Kind.jxl, kindOf("\xFF\x0A\xFA\x7F").?);
    try std.testing.expectEqual(Kind.jxl, kindOf("\x00\x00\x00\x0CJXL \x0D\x0A\x87\x0A\x00\x00").?);
    try std.testing.expectEqual(Kind.svg, kindOf("<?xml version=\"1.0\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\"/>").?);
    try std.testing.expectEqual(Kind.png, kindOf("\x89PNG\r\n\x1a\n").?);
    try std.testing.expectEqual(@as(?Kind, null), kindOf("BM6\x00"));
    try std.testing.expect(named("Lake.JPG"));
    try std.testing.expect(named("adwaita-d.jxl"));
    try std.testing.expect(!named("f45.xml"));
}
