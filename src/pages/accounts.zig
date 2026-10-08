// SPDX-License-Identifier: BSD-2-Clause

//! Accounts: who is signed in - their name, their account, and whether it
//! is an administrator's.

const std = @import("std");

const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Settings = @import("../Settings.zig");

const Passwd = extern struct {
    name: ?[*:0]const u8,
    passwd: ?[*:0]const u8,
    uid: u32,
    gid: u32,
    gecos: ?[*:0]const u8,
    dir: ?[*:0]const u8,
    shell: ?[*:0]const u8,
};
extern fn getpwuid(uid: u32) ?*const Passwd;

pub const Person = struct {
    user: []const u8,
    full: []const u8,
    initials_buffer: [2]u8 = undefined,
    initials_len: usize = 0,

    pub fn display(self: *const Person) []const u8 {
        return if (self.full.len > 0) self.full else self.user;
    }

    pub fn initials(self: *const Person) []const u8 {
        return self.initials_buffer[0..self.initials_len];
    }
};

/// Who is signed in, from the account database.
pub fn person() Person {
    const account = getpwuid(std.c.getuid());
    const user = if (account) |a| std.mem.span(a.name orelse "") else if (std.c.getenv("USER")) |u| std.mem.span(u) else "";
    // The full name is the first field of the comment.
    const gecos = if (account) |a| std.mem.span(a.gecos orelse "") else "";
    const full = if (std.mem.indexOfScalar(u8, gecos, ',')) |c| gecos[0..c] else gecos;
    var p: Person = .{ .user = user, .full = full };
    var words = std.mem.tokenizeAny(u8, p.display(), " ._-");
    while (words.next()) |word| {
        if (p.initials_len == 2) break;
        p.initials_buffer[p.initials_len] = std.ascii.toUpper(word[0]);
        p.initials_len += 1;
    }
    return p;
}

/// Whether the account is in `wheel`, the group that may administer.
fn administrator(user: []const u8) bool {
    const fd = std.c.open("/etc/group", .{});
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    var buffer: [16384]u8 = undefined;
    const n = std.c.read(fd, &buffer, buffer.len);
    if (n <= 0) return false;
    var lines = std.mem.splitScalar(u8, buffer[0..@intCast(n)], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "wheel:")) continue;
        const members = line[(std.mem.lastIndexOfScalar(u8, line, ':') orelse continue) + 1 ..];
        var it = std.mem.tokenizeScalar(u8, members, ',');
        while (it.next()) |m| if (std.mem.eql(u8, m, user)) return true;
    }
    return false;
}

pub fn draw(app: *Settings, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const who = person();
    {
        u.open(.{ .width = .grow, .padding = .trbl(4, 4, 24, 4), .gap = 24, .align_y = .center });
        defer u.close();
        {
            u.open(.{ .width = .fixed(96), .height = .fixed(96), .corner_radius = .all(48), .background_color = p.accent, .align_x = .center, .align_y = .center });
            defer u.close();
            kit.label(who.initials(), .title, p.text_on_accent);
        }
        u.open(.{ .direction = .top_to_bottom, .gap = 2 });
        defer u.close();
        kit.label(who.display(), .subtitle, p.text_primary);
        kit.label(who.user, .body, p.text_secondary);
        kit.label(if (administrator(who.user)) "Administrator" else "Standard user", .body, p.text_secondary);
    }
    if (app.sub == .none) {
        app.linkCard(kit, .info, .person, "Your name, your account");
        return;
    }
    Settings.infoCard(kit, "account/name", .person, "Name", who.display());
    Settings.infoCard(kit, "account/user", .people, "User name", who.user);
    Settings.infoCard(kit, "account/kind", .shield, "Account type", if (administrator(who.user)) "Administrator" else "Standard user");
}
