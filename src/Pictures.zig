// SPDX-License-Identifier: BSD-2-Clause

//! The wallpapers there are to choose from, small: the person's own, in
//! `~/Pictures/Wallpapers`, first, then every picture under
//! `/usr/share/backgrounds` - read and shrunk on a thread of its own, a
//! photo the size of a 4K screen taking a while to read, and handed over a
//! few at a time as they are ready.
//!
//! A thumbnail, once made, is kept in `$XDG_CACHE_HOME/fluxion/wallpapers`,
//! named for the picture's path, size and the time it was last changed: the
//! second time the page is opened they are all there at once, and a picture
//! changed since is another name, made again.

const std = @import("std");
const raster = @import("fluxion_ui_raster");
const image = @import("fluxion_image");

const Icons = @import("Icons.zig");
const ImageFile = @import("ImageFile.zig");

const Pictures = @This();

const log = std.log.scoped(.pictures);

pub const thumb_w = 192;
pub const thumb_h = 108;
/// The most offered.
const most = 96;

pub const Picture = struct {
    path: []const u8,
    /// The shrunk picture, written by the thread before it says `ready`.
    small: ?raster.Image = null,
    /// Taken: its slot among the window's images.
    texture: ?u32 = null,
    failed: bool = false,
    /// Set by the thread once `small` - or `failed` - is written.
    ready: std.atomic.Value(bool) = .init(false),
};

gpa: std.mem.Allocator,
io: std.Io,
arena: std.heap.ArenaAllocator,
list: []Picture = &.{},
thread: ?std.Thread = null,
stop: std.atomic.Value(bool) = .init(false),
/// Written to as each is ready, to wake the window's loop.
wake: [2]std.c.fd_t = .{ -1, -1 },

pub fn init(self: *Pictures, gpa: std.mem.Allocator, io: std.Io) void {
    self.* = .{ .gpa = gpa, .io = io, .arena = .init(gpa) };
    _ = std.c.pipe(&self.wake);
}

pub fn deinit(self: *Pictures) void {
    self.stop.store(true, .release);
    if (self.thread) |t| t.join();
    for (self.list) |*p| if (p.small) |*s| s.deinit(self.gpa);
    for (self.wake) |fd| if (fd >= 0) {
        _ = std.c.close(fd);
    };
    self.arena.deinit();
}

/// Find them, and start reading them: once.
pub fn start(self: *Pictures) void {
    if (self.thread != null) return;
    var found: std.ArrayList(Picture) = .empty;
    const a = self.arena.allocator();
    if (std.c.getenv("HOME")) |home| {
        const own = std.fmt.allocPrint(a, "{s}/Pictures/Wallpapers", .{std.mem.span(home)}) catch "";
        self.find(a, &found, own, 0);
    }
    const owned = found.items.len;
    self.find(a, &found, "/usr/share/backgrounds", 0);
    // A folder is listed in no order; its name is one a person knows.
    std.mem.sort(Picture, found.items[0..owned], {}, byPath);
    std.mem.sort(Picture, found.items[owned..], {}, byPath);
    self.list = found.items;
    self.thread = std.Thread.spawn(.{}, run, .{self}) catch null;
}

fn find(self: *Pictures, a: std.mem.Allocator, found: *std.ArrayList(Picture), path: []const u8, depth: u32) void {
    if (depth > 3 or found.items.len >= most) return;
    var dir = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch return;
    defer dir.close(self.io);
    var it = dir.iterate();
    while (it.next(self.io) catch null) |entry| {
        if (found.items.len >= most) return;
        const full = std.fmt.allocPrint(a, "{s}/{s}", .{ path, entry.name }) catch return;
        switch (entry.kind) {
            .directory => self.find(a, found, full, depth + 1),
            .file, .sym_link => if (ImageFile.named(entry.name)) {
                found.append(a, .{ .path = full }) catch return;
            },
            else => {},
        }
    }
}

fn byPath(_: void, a: Picture, b: Picture) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn run(self: *Pictures) void {
    for (self.list) |*p| {
        if (self.stop.load(.acquire)) return;
        const small = shrink(self.gpa, self.io, p.path) catch null;
        if (small) |s| p.small = s else p.failed = true;
        p.ready.store(true, .release);
        _ = std.c.write(self.wake[1], "p", 1);
    }
}

/// Take the ones ready into the window's images. True when any came.
pub fn collect(self: *Pictures, icons: *Icons) bool {
    var drain: [64]u8 = undefined;
    _ = std.c.read(self.wake[0], &drain, drain.len);
    var any = false;
    for (self.list) |*p| {
        if (!p.ready.load(.acquire)) continue;
        const small = p.small orelse continue;
        p.texture = icons.put(null, small);
        p.small = null;
        any = true;
    }
    return any;
}

fn shrink(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !raster.Image {
    var name_buffer: [1024]u8 = undefined;
    const kept = keptAt(&name_buffer, io, path);
    if (kept) |file| if (readKept(gpa, io, file)) |small| return small;
    var source = ImageFile.read(gpa, io, path) catch |err| {
        log.info("could not read {s}: {t}", .{ path, err });
        return err;
    };
    defer source.deinit(gpa);
    const small = try fill(gpa, source, thumb_w, thumb_h);
    if (kept) |file| keep(gpa, io, file, small);
    return small;
}

/// Where the thumbnail of the picture at `path` is kept.
fn keptAt(buffer: []u8, io: std.Io, path: []const u8) ?[]const u8 {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    var hash: std.hash.Wyhash = .init(0);
    hash.update(path);
    hash.update(std.mem.asBytes(&stat.size));
    const changed: i128 = stat.mtime.nanoseconds;
    hash.update(std.mem.asBytes(&changed));
    if (std.c.getenv("XDG_CACHE_HOME")) |dir| {
        return std.fmt.bufPrint(buffer, "{s}/fluxion/wallpapers/{x:0>16}.png", .{ std.mem.span(dir), hash.final() }) catch null;
    }
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/.cache/fluxion/wallpapers/{x:0>16}.png", .{ std.mem.span(home), hash.final() }) catch null;
}

fn readKept(gpa: std.mem.Allocator, io: std.Io, file: []const u8) ?raster.Image {
    var decoded = image.readFile(gpa, io, file, .{}) catch return null;
    defer decoded.deinit(gpa);
    if (decoded.width != thumb_w or decoded.height != thumb_h) return null;
    return raster.Image.fromRgba(gpa, decoded.pixels, decoded.width, decoded.height) catch null;
}

/// Keep `small`: written beside its place and renamed into it, so another
/// reading it never finds half of it.
fn keep(gpa: std.mem.Allocator, io: std.Io, file: []const u8, small: raster.Image) void {
    const rgba = gpa.alloc(u8, small.pixels.len * 4) catch return;
    defer gpa.free(rgba);
    // Opaque, so premultiplied is as it is.
    for (small.pixels, 0..) |p, i| rgba[i * 4 ..][0..4].* = .{ @truncate(p >> 16), @truncate(p >> 8), @truncate(p), 0xFF };
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, std.fs.path.dirname(file) orelse return) catch return;
    var temp_buffer: [1040]u8 = undefined;
    const temp = std.fmt.bufPrint(&temp_buffer, "{s}.new", .{file}) catch return;
    image.png.writeFile(gpa, io, temp, .{
        .width = small.width,
        .height = small.height,
        .pixels = rgba,
        .row_pitch = @as(usize, small.width) * 4,
    }, .{}) catch return;
    std.Io.Dir.rename(cwd, temp, cwd, file, io) catch {};
}

/// `source` scaled to cover `width` by `height`, its middle kept, each new
/// pixel the average of those it covers.
pub fn fill(gpa: std.mem.Allocator, source: raster.Image, width: u32, height: u32) !raster.Image {
    const pixels = try gpa.alloc(raster.Pixel, @as(usize, width) * height);
    errdefer gpa.free(pixels);
    const sw: f64 = @floatFromInt(source.width);
    const sh: f64 = @floatFromInt(source.height);
    const scale = @max(@as(f64, @floatFromInt(width)) / sw, @as(f64, @floatFromInt(height)) / sh);
    const shown_w = @as(f64, @floatFromInt(width)) / scale;
    const shown_h = @as(f64, @floatFromInt(height)) / scale;
    const left = (sw - shown_w) / 2;
    const top = (sh - shown_h) / 2;
    const step = 1 / scale;
    for (0..height) |y| {
        const fy0 = top + @as(f64, @floatFromInt(y)) * step;
        const y0: usize = @intFromFloat(@floor(fy0));
        const y1 = @min(source.height, @max(y0 + 1, @as(usize, @intFromFloat(@ceil(fy0 + step)))));
        for (0..width) |x| {
            const fx0 = left + @as(f64, @floatFromInt(x)) * step;
            const x0: usize = @intFromFloat(@floor(fx0));
            const x1 = @min(source.width, @max(x0 + 1, @as(usize, @intFromFloat(@ceil(fx0 + step)))));
            var sum: [4]u64 = @splat(0);
            for (y0..y1) |sy| for (x0..x1) |sx| {
                const p = source.pixels[sy * source.width + sx];
                inline for (0..4) |c| sum[c] += (p >> (c * 8)) & 0xFF;
            };
            const n = (x1 - x0) * (y1 - y0);
            var out: u32 = 0;
            inline for (0..4) |c| out |= @as(u32, @intCast((sum[c] + n / 2) / n)) << (c * 8);
            pixels[y * width + x] = out | 0xFF000000;
        }
    }
    return .{ .pixels = pixels, .width = width, .height = height };
}
