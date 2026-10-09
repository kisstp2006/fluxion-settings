// SPDX-License-Identifier: BSD-2-Clause

//! Choosing a file or a folder, the desktop's way: the file chooser of
//! xdg-desktop-portal, on the session bus - the dialog the person's other
//! apps open too - for a picture to be the wallpaper, or a folder of them
//! for a slideshow.
//!
//! The portal answers later, with a signal on a request object whose path
//! is known ahead - `/org/freedesktop/portal/desktop/request/SENDER/TOKEN` -
//! so it is listened for before the call is made, and the answer cannot be
//! missed.

const std = @import("std");
const dbus = @import("fluxion_dbus");
const Value = dbus.Value;

const Portal = @This();

const log = std.log.scoped(.portal);

pub const Want = enum { picture, folder };

/// What to do with the path chosen.
pub const Done = struct {
    context: *anyopaque,
    call: *const fn (context: *anyopaque, want: Want, path: []const u8) void,
};

gpa: std.mem.Allocator,
bus: ?*dbus.Connection = null,
/// The question asked and not yet answered.
asking: ?Want = null,
request_path: [256]u8 = undefined,
request_len: usize = 0,
next_token: u32 = 1,
done: ?Done = null,

/// The session bus, connected the first time it is wanted. Its descriptor
/// is for the caller to watch.
pub fn connect(self: *Portal) ?*dbus.Connection {
    if (self.bus) |b| return b;
    self.bus = dbus.Connection.open(self.gpa, .session) catch |err| {
        log.warn("no session bus: {t}", .{err});
        return null;
    };
    return self.bus;
}

pub fn deinit(self: *Portal) void {
    if (self.bus) |b| b.close();
}

/// Ask for a picture or a folder; `done` hears of it if one is chosen.
pub fn choose(self: *Portal, want: Want, title: []const u8, done: Done) void {
    const bus = self.connect() orelse return;
    if (self.asking != null) bus.unsubscribe(self);
    self.done = done;
    var token_buffer: [32]u8 = undefined;
    const token = std.fmt.bufPrint(&token_buffer, "fluxion{d}", .{self.next_token}) catch return;
    self.next_token += 1;
    // ":1.42" is "1_42" in the request's path.
    var sender: [64]u8 = undefined;
    var n: usize = 0;
    for (bus.unique_name) |c| {
        if (c == ':' or n == sender.len) continue;
        sender[n] = if (c == '.') '_' else c;
        n += 1;
    }
    const path = std.fmt.bufPrint(&self.request_path, "/org/freedesktop/portal/desktop/request/{s}/{s}", .{ sender[0..n], token }) catch return;
    self.request_len = path.len;
    bus.subscribe(.{ .path = path, .interface = "org.freedesktop.portal.Request", .member = "Response" }, .{ .context = self, .call = responded }) catch return;
    self.asking = want;

    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const options = buildOptions(a, want, token) catch return;
    _ = bus.call(.{
        .destination = "org.freedesktop.portal.Desktop",
        .path = "/org/freedesktop/portal/desktop",
        .interface = "org.freedesktop.portal.FileChooser",
        .member = "OpenFile",
        .signature = "ssa{sv}",
        .args = &.{ .{ .string = "" }, .{ .string = title }, options },
    }, null) catch |err| log.warn("could not ask the portal: {t}", .{err});
}

fn entry(a: std.mem.Allocator, key: []const u8, signature: []const u8, value: Value) !Value {
    const pair = try a.create([2]Value);
    pair.* = .{ .{ .string = key }, try Value.wrap(a, signature, value) };
    return .{ .dict_entry = pair };
}

fn buildOptions(a: std.mem.Allocator, want: Want, token: []const u8) !Value {
    var list: std.ArrayList(Value) = .empty;
    try list.append(a, try entry(a, "handle_token", "s", .{ .string = token }));
    try list.append(a, try entry(a, "modal", "b", .{ .boolean = true }));
    switch (want) {
        .folder => try list.append(a, try entry(a, "directory", "b", .{ .boolean = true })),
        .picture => {
            // One filter: pictures, by their MIME type.
            const rule = try a.alloc(Value, 2);
            rule[0] = .{ .uint32 = 1 };
            rule[1] = .{ .string = "image/*" };
            const rules = try a.alloc(Value, 1);
            rules[0] = .{ .structure = rule };
            const filter = try a.alloc(Value, 2);
            filter[0] = .{ .string = "Pictures" };
            filter[1] = .{ .array = .{ .element = "(us)", .items = rules } };
            const filters = try a.alloc(Value, 1);
            filters[0] = .{ .structure = filter };
            try list.append(a, try entry(a, "filters", "a(sa(us))", .{ .array = .{ .element = "(sa(us))", .items = filters } }));
        },
    }
    return .{ .array = .{ .element = "{sv}", .items = list.items } };
}

fn responded(context: *anyopaque, bus: *dbus.Connection, message: *const dbus.Message) void {
    const self: *Portal = @ptrCast(@alignCast(context));
    bus.unsubscribe(self);
    const want = self.asking orelse return;
    self.asking = null;
    // 0 is chosen; 1 cancelled; 2 otherwise ended.
    const code = (message.arg(0) orelse return).asInt() orelse return;
    if (code != 0) return;
    const results = message.arg(1) orelse return;
    const uris = (results.lookup("uris") orelse return).unwrap().asArray() orelse return;
    if (uris.len == 0) return;
    const uri = uris[0].asString() orelse return;
    var buffer: [1024]u8 = undefined;
    const path = pathOf(uri, &buffer) orelse return;
    if (self.done) |d| d.call(d.context, want, path);
}

/// A `file://` URI as a path, its `%XX`s decoded.
pub fn pathOf(uri: []const u8, buffer: []u8) ?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    const rest = uri[prefix.len..];
    var n: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (n == buffer.len) return null;
        if (rest[i] == '%' and i + 2 < rest.len) {
            buffer[n] = std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16) catch return null;
            i += 2;
        } else buffer[n] = rest[i];
        n += 1;
    }
    return buffer[0..n];
}

test "a file URI is its path, decoded" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/home/me/Képek/a b.jpg", pathOf("file:///home/me/K%C3%A9pek/a%20b.jpg", &buffer).?);
    try std.testing.expectEqual(@as(?[]const u8, null), pathOf("https://example.org/a.jpg", &buffer));
}
