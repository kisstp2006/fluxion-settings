// SPDX-License-Identifier: BSD-2-Clause

//! Application icons from the icon theme, loaded once and kept as pictures
//! the renderer can draw: an icon is a texture number, an index into
//! `images`.
//!
//! **Which file** is the freedesktop icon theme specification's answer: the
//! theme's directories that match the size, then the nearest size it has,
//! then the themes it inherits from, then `hicolor`, then `/usr/share/pixmaps`.
//! The theme is the desktop's - `org.gnome.desktop.interface icon-theme`
//! until there is a settings app of its own.
//!
//! **How it becomes pixels**: a PNG is decoded by Fluxion Image and scaled
//! to the size by averaging, so a 256-pixel icon drawn at 24 is not a
//! shimmer of every eleventh pixel; an SVG - most of a modern theme - is
//! drawn at exactly the size by the system's librsvg, opened at run time so
//! a desktop without it still runs, with PNGs only.

const std = @import("std");
const raster = @import("fluxion_ui_raster");
const image = @import("fluxion_image");

const Icons = @This();

const log = std.log.scoped(.icons);

gpa: std.mem.Allocator,
io: std.Io,
/// What a texture number means, in the order the icons were loaded. Never
/// reordered, so a number handed out stays good.
images: std.ArrayList(raster.Image) = .empty,
/// Counted up whenever a picture is put: a drawing that shows pictures by
/// number tells from it that one may have changed.
generation: u64 = 0,
/// How many screen pixels each of the window's is: an icon asked for at 24
/// is read at 36 for 150 %, and drawn into its 24 - which the drawing makes
/// 36 - without being stretched.
scale: f32 = 1,

/// What was found for each name at each size, found or not, so a missing
/// icon is looked for once.
cache: std.StringHashMapUnmanaged(?u32) = .empty,
arena: std.heap.ArenaAllocator,
/// The theme and everything it inherits, in the order they are asked.
themes: std.ArrayList(Theme) = .empty,
/// Where themes are looked for: `~/.icons`, `$XDG_DATA_HOME/icons`,
/// `$XDG_DATA_DIRS/icons`.
bases: std.ArrayList([]const u8) = .empty,
svg: ?Svg = null,

const Theme = struct {
    name: []const u8,
    directories: []Directory,
};

const Directory = struct {
    path: []const u8,
    size: u32,
    scale: u32 = 1,
    kind: enum { fixed, scalable, threshold } = .threshold,
    min: u32,
    max: u32,
    threshold: u32 = 2,

    fn matches(self: Directory, size: u32) bool {
        return switch (self.kind) {
            .fixed => self.size == size,
            .scalable => self.min <= size and size <= self.max,
            .threshold => self.size -| self.threshold <= size and size <= self.size + self.threshold,
        };
    }

    fn distance(self: Directory, size: u32) u32 {
        return switch (self.kind) {
            .fixed => if (self.size > size) self.size - size else size - self.size,
            .scalable => if (size < self.min) self.min - size else if (size > self.max) size - self.max else 0,
            .threshold => if (size < self.size -| self.threshold)
                self.min -| size
            else if (size > self.size + self.threshold)
                size -| self.max
            else
                0,
        };
    }
};

/// The icons of `theme_name`, or of the desktop's theme when it is null.
pub fn init(gpa: std.mem.Allocator, io: std.Io, wanted: ?[]const u8) Icons {
    var self: Icons = .{ .gpa = gpa, .io = io, .arena = .init(gpa) };
    const theme_name = wanted orelse systemThemeName(self.arena.allocator(), io);
    log.info("icon theme {s}", .{theme_name});
    self.svg = Svg.open();
    if (self.svg == null) log.warn("no librsvg: SVG icons will be missing", .{});
    self.findBases() catch {};
    self.loadTheme(theme_name, 0) catch {};
    if (!self.hasTheme("hicolor")) self.loadTheme("hicolor", 0) catch {};
    return self;
}

pub fn deinit(self: *Icons) void {
    for (self.images.items) |*picture| picture.deinit(self.gpa);
    self.images.deinit(self.gpa);
    self.cache.deinit(self.gpa);
    if (self.svg) |*svg| svg.close();
    self.arena.deinit();
}

/// The theme a GNOME desktop is set to, for want of a setting of our own.
pub fn systemThemeName(arena: std.mem.Allocator, io: std.Io) []const u8 {
    if (std.c.getenv("FLUXION_ICON_THEME")) |name| return std.mem.span(name);
    const result = std.process.run(arena, io, .{
        .argv = &.{ "gsettings", "get", "org.gnome.desktop.interface", "icon-theme" },
    }) catch return "hicolor";
    const trimmed = std.mem.trim(u8, result.stdout, " \n'\"");
    return if (trimmed.len > 0) trimmed else "hicolor";
}

/// The texture number of `name` at `size` pixels, or null when the theme
/// has no such icon. A full path is read as it is.
pub fn lookup(self: *Icons, name: []const u8, logical_size: u32) ?u32 {
    if (name.len == 0) return null;
    const size = self.screenPixels(logical_size);
    var key_buffer: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buffer, "{s}@{d}", .{ name, size }) catch return null;
    if (self.cache.get(key)) |found| return found;

    const found = self.find(name, size);
    const owned = self.arena.allocator().dupe(u8, key) catch return found;
    self.cache.put(self.gpa, owned, found) catch {};
    return found;
}

/// An icon from a folder of an app's own - a tray icon's `IconThemePath` -
/// before the theme's.
pub fn lookupIn(self: *Icons, dir: []const u8, name: []const u8, logical_size: u32) ?u32 {
    if (dir.len == 0 or name.len == 0) return self.lookup(name, logical_size);
    const size = self.screenPixels(logical_size);
    var key_buffer: [1024]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buffer, "{s}/{s}@{d}", .{ dir, name, size }) catch return self.lookup(name, logical_size);
    if (self.cache.get(key)) |found| return found orelse self.lookup(name, logical_size);
    const found: ?u32 = for ([_][]const u8{ ".png", ".svg" }) |ext| {
        if (std.mem.eql(u8, ext, ".svg") and self.svg == null) continue;
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buffer, "{s}/{s}{s}", .{ dir, name, ext }) catch continue;
        if (std.c.access(path.ptr, std.c.F_OK) == 0) break self.load(path, size);
    } else null;
    const owned = self.arena.allocator().dupe(u8, key) catch return found orelse self.lookup(name, logical_size);
    self.cache.put(self.gpa, owned, found) catch {};
    return found orelse self.lookup(name, logical_size);
}

/// `size` in the window's pixels, in the screen's.
fn screenPixels(self: *const Icons, size: u32) u32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(size)) * self.scale));
}

/// Keep a picture the shell made itself - a tray icon's pixels - as an
/// image: in `slot`, in place of the one there, or in a new one.
pub fn put(self: *Icons, slot: ?u32, picture: raster.Image) ?u32 {
    self.generation +%= 1;
    if (slot) |at| {
        self.images.items[at].deinit(self.gpa);
        self.images.items[at] = picture;
        return at;
    }
    self.images.append(self.gpa, picture) catch {
        var p = picture;
        p.deinit(self.gpa);
        return null;
    };
    return @intCast(self.images.items.len - 1);
}

fn find(self: *Icons, name: []const u8, size: u32) ?u32 {
    if (name[0] == '/') return self.load(name, size);
    const path = self.findPath(name, size) orelse return null;
    return self.load(path, size);
}

/// The specification's lookup: in each theme, a directory that matches the
/// size; failing that, the nearest one; then the next theme.
fn findPath(self: *Icons, name: []const u8, size: u32) ?[]const u8 {
    const extensions = [_][]const u8{ ".png", ".svg" };
    for (self.themes.items) |theme| {
        var nearest: ?[]const u8 = null;
        var nearest_distance: u32 = std.math.maxInt(u32);
        for (theme.directories) |dir| {
            const matches = dir.matches(size);
            const d = dir.distance(size);
            if (!matches and d >= nearest_distance) continue;
            for (self.bases.items) |base| for (extensions) |ext| {
                if (std.mem.eql(u8, ext, ".svg") and self.svg == null) continue;
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const path = std.fmt.bufPrintZ(&buffer, "{s}/{s}/{s}/{s}{s}", .{ base, theme.name, dir.path, name, ext }) catch continue;
                if (std.c.access(path.ptr, std.c.F_OK) != 0) continue;
                const owned = self.arena.allocator().dupe(u8, path) catch return null;
                if (matches) return owned;
                nearest = owned;
                nearest_distance = d;
            };
        }
        if (nearest) |path| return path;
    }
    for ([_][]const u8{ ".png", ".svg" }) |ext| {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buffer, "/usr/share/pixmaps/{s}{s}", .{ name, ext }) catch continue;
        if (std.c.access(path.ptr, std.c.F_OK) == 0) return self.arena.allocator().dupe(u8, path) catch null;
    }
    return null;
}

/// Read a file into a picture `size` pixels square and keep it.
fn load(self: *Icons, path: []const u8, size: u32) ?u32 {
    const picture = (if (std.mem.endsWith(u8, path, ".svg"))
        self.loadSvg(path, size)
    else
        self.loadPng(path, size)) orelse return null;
    self.images.append(self.gpa, picture) catch return null;
    return @intCast(self.images.items.len - 1);
}

fn loadPng(self: *Icons, path: []const u8, size: u32) ?raster.Image {
    const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(16 << 20)) catch return null;
    defer self.gpa.free(bytes);
    var decoded = image.decode(self.gpa, bytes) catch return null;
    defer decoded.deinit(self.gpa);
    var full = raster.Image.fromRgba(self.gpa, decoded.pixels, decoded.width, decoded.height) catch return null;
    if (full.width <= size * 2 and full.height <= size * 2) return full;
    defer full.deinit(self.gpa);
    return shrink(self.gpa, full, size) catch null;
}

fn loadSvg(self: *Icons, path: []const u8, size: u32) ?raster.Image {
    const svg = &(self.svg orelse return null);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buffer, "{s}", .{path}) catch return null;
    return svg.render(self.gpa, z, size) catch null;
}

/// A picture made `size` pixels square by averaging the pixels each new
/// one covers: what makes a large icon small without losing its strokes.
fn shrink(gpa: std.mem.Allocator, source: raster.Image, size: u32) !raster.Image {
    const pixels = try gpa.alloc(raster.Pixel, @as(usize, size) * size);
    for (0..size) |y| for (0..size) |x| {
        const x0 = x * source.width / size;
        const x1 = @max(x0 + 1, (x + 1) * source.width / size);
        const y0 = y * source.height / size;
        const y1 = @max(y0 + 1, (y + 1) * source.height / size);
        var sum: [4]u64 = @splat(0);
        for (y0..y1) |sy| for (x0..x1) |sx| {
            const p = source.pixels[sy * source.width + sx];
            inline for (0..4) |c| sum[c] += (p >> (c * 8)) & 0xFF;
        };
        const n = (x1 - x0) * (y1 - y0);
        var out: u32 = 0;
        inline for (0..4) |c| out |= @as(u32, @intCast((sum[c] + n / 2) / n)) << (c * 8);
        pixels[y * size + x] = out;
    };
    return .{ .pixels = pixels, .width = size, .height = size };
}

// -------------------------------------------------------------------------
// Themes
// -------------------------------------------------------------------------

fn findBases(self: *Icons) !void {
    const arena = self.arena.allocator();
    if (std.c.getenv("HOME")) |home| try self.bases.append(arena, try std.fmt.allocPrint(arena, "{s}/.icons", .{std.mem.span(home)}));
    if (std.c.getenv("XDG_DATA_HOME")) |data| {
        try self.bases.append(arena, try std.fmt.allocPrint(arena, "{s}/icons", .{std.mem.span(data)}));
    } else if (std.c.getenv("HOME")) |home| {
        try self.bases.append(arena, try std.fmt.allocPrint(arena, "{s}/.local/share/icons", .{std.mem.span(home)}));
    }
    const data_dirs = if (std.c.getenv("XDG_DATA_DIRS")) |d| std.mem.span(d) else "/usr/local/share:/usr/share";
    var it = std.mem.tokenizeScalar(u8, data_dirs, ':');
    while (it.next()) |dir| try self.bases.append(arena, try std.fmt.allocPrint(arena, "{s}/icons", .{dir}));
}

fn hasTheme(self: *const Icons, name: []const u8) bool {
    for (self.themes.items) |theme| if (std.mem.eql(u8, theme.name, name)) return true;
    return false;
}

/// Read a theme's `index.theme` - its directories and what it inherits -
/// and the themes it inherits, depth first.
fn loadTheme(self: *Icons, name: []const u8, depth: u32) !void {
    if (depth > 8 or self.hasTheme(name)) return;
    const arena = self.arena.allocator();
    const text = for (self.bases.items) |base| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}/index.theme", .{ base, name });
        break std.Io.Dir.cwd().readFileAlloc(self.io, path, arena, .limited(1 << 20)) catch continue;
    } else return;

    var directories: std.ArrayList(Directory) = .empty;
    var inherits: []const u8 = "";
    var listed: []const u8 = "";

    // Two passes: the header names the directories, and each has a group.
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            section = std.mem.trim(u8, line, "[]");
            continue;
        }
        if (!std.mem.eql(u8, section, "Icon Theme")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " ");
        const value = std.mem.trim(u8, line[eq + 1 ..], " ");
        if (std.mem.eql(u8, key, "Inherits")) inherits = value;
        if (std.mem.eql(u8, key, "Directories")) listed = value;
    }

    var names = std.mem.tokenizeScalar(u8, listed, ',');
    while (names.next()) |dir_name| {
        if (parseDirectory(text, dir_name)) |dir| try directories.append(arena, dir);
    }
    try self.themes.append(arena, .{ .name = try arena.dupe(u8, name), .directories = directories.items });

    var parents = std.mem.tokenizeScalar(u8, inherits, ',');
    while (parents.next()) |parent| try self.loadTheme(std.mem.trim(u8, parent, " "), depth + 1);
}

fn parseDirectory(text: []const u8, name: []const u8) ?Directory {
    var dir: Directory = .{ .path = name, .size = 0, .min = 0, .max = 0 };
    var have_min = false;
    var have_max = false;
    var in_section = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            in_section = std.mem.eql(u8, std.mem.trim(u8, line, "[]"), name);
            continue;
        }
        if (!in_section) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " ");
        const value = std.mem.trim(u8, line[eq + 1 ..], " ");
        const number = std.fmt.parseInt(u32, value, 10) catch 0;
        if (std.mem.eql(u8, key, "Size")) dir.size = number;
        if (std.mem.eql(u8, key, "Scale")) dir.scale = @max(1, number);
        if (std.mem.eql(u8, key, "MinSize")) {
            dir.min = number;
            have_min = true;
        }
        if (std.mem.eql(u8, key, "MaxSize")) {
            dir.max = number;
            have_max = true;
        }
        if (std.mem.eql(u8, key, "Threshold")) dir.threshold = number;
        if (std.mem.eql(u8, key, "Type")) {
            dir.kind = if (std.mem.eql(u8, value, "Fixed")) .fixed else if (std.mem.eql(u8, value, "Scalable")) .scalable else .threshold;
        }
    }
    if (dir.size == 0) return null;
    // A theme drawn for twice the density is for a scaled screen; this one
    // is drawn at one pixel a pixel.
    if (dir.scale != 1) return null;
    if (!have_min) dir.min = dir.size;
    if (!have_max) dir.max = dir.size;
    return dir;
}

// -------------------------------------------------------------------------
// SVG, through the system's librsvg
// -------------------------------------------------------------------------

const Svg = struct {
    rsvg: std.DynLib,
    cairo: std.DynLib,
    gobject: std.DynLib,

    new_from_file: *const fn (path: [*:0]const u8, err: ?*?*anyopaque) callconv(.c) ?*anyopaque,
    render_document: *const fn (handle: *anyopaque, cr: *anyopaque, viewport: *const Rect, err: ?*?*anyopaque) callconv(.c) c_int,
    unref: *const fn (object: *anyopaque) callconv(.c) void,
    surface_create: *const fn (data: [*]u8, format: c_int, width: c_int, height: c_int, stride: c_int) callconv(.c) ?*anyopaque,
    surface_flush: *const fn (surface: *anyopaque) callconv(.c) void,
    surface_destroy: *const fn (surface: *anyopaque) callconv(.c) void,
    create: *const fn (surface: *anyopaque) callconv(.c) ?*anyopaque,
    destroy: *const fn (cr: *anyopaque) callconv(.c) void,

    const Rect = extern struct { x: f64, y: f64, width: f64, height: f64 };
    /// Cairo's ARGB32: premultiplied `0xAARRGGBB` in a native `u32` - the
    /// renderer's own pixel, so the drawing needs no conversion.
    const format_argb32 = 0;

    fn open() ?Svg {
        var rsvg = std.DynLib.open("librsvg-2.so.2") catch return null;
        var cairo = std.DynLib.open("libcairo.so.2") catch {
            rsvg.close();
            return null;
        };
        const gobject = std.DynLib.open("libgobject-2.0.so.0") catch {
            rsvg.close();
            cairo.close();
            return null;
        };
        var self: Svg = undefined;
        self.rsvg = rsvg;
        self.cairo = cairo;
        self.gobject = gobject;
        inline for (.{
            .{ "new_from_file", &self.rsvg, "rsvg_handle_new_from_file" },
            .{ "render_document", &self.rsvg, "rsvg_handle_render_document" },
            .{ "unref", &self.gobject, "g_object_unref" },
            .{ "surface_create", &self.cairo, "cairo_image_surface_create_for_data" },
            .{ "surface_flush", &self.cairo, "cairo_surface_flush" },
            .{ "surface_destroy", &self.cairo, "cairo_surface_destroy" },
            .{ "create", &self.cairo, "cairo_create" },
            .{ "destroy", &self.cairo, "cairo_destroy" },
        }) |entry| {
            @field(self, entry[0]) = entry[1].lookup(@FieldType(Svg, entry[0]), entry[2]) orelse {
                self.close();
                return null;
            };
        }
        return self;
    }

    fn close(self: *Svg) void {
        self.rsvg.close();
        self.cairo.close();
        self.gobject.close();
    }

    fn render(self: *Svg, gpa: std.mem.Allocator, path: [:0]const u8, size: u32) !raster.Image {
        const handle = self.new_from_file(path.ptr, null) orelse return error.BadSvg;
        defer self.unref(handle);
        const pixels = try gpa.alloc(raster.Pixel, @as(usize, size) * size);
        errdefer gpa.free(pixels);
        @memset(pixels, 0);
        const surface = self.surface_create(@ptrCast(pixels.ptr), format_argb32, @intCast(size), @intCast(size), @intCast(size * 4)) orelse return error.NoSurface;
        defer self.surface_destroy(surface);
        const cr = self.create(surface) orelse return error.NoContext;
        defer self.destroy(cr);
        const viewport: Rect = .{ .x = 0, .y = 0, .width = @floatFromInt(size), .height = @floatFromInt(size) };
        if (self.render_document(handle, cr, &viewport, null) == 0) return error.BadSvg;
        self.surface_flush(surface);
        return .{ .pixels = pixels, .width = size, .height = size };
    }
};
