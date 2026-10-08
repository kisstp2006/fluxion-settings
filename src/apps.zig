// SPDX-License-Identifier: BSD-2-Clause

//! The installed applications: every `.desktop` file the freedesktop menu
//! specification says to look at, read once, and launched on request.
//!
//! **Where they are** is `$XDG_DATA_HOME/applications` and then each of
//! `$XDG_DATA_DIRS`'s `applications` directories, in that order, the first
//! file with a given name winning - which is how a user's own copy of a
//! desktop file hides the system's.
//!
//! **What is shown** is what the file says should be: not one marked
//! `NoDisplay` or `Hidden`, and not one whose `OnlyShowIn` names other
//! desktops - GNOME's settings panels, which open nothing on this one.
//!
//! **Names are the reader's language**: `Name[hu_HU]`, then `Name[hu]`,
//! then `Name`, from `LC_MESSAGES` or `LANG`.

const std = @import("std");

const log = std.log.scoped(.apps);

pub const App = struct {
    /// The desktop file's name, `org.gnome.TextEditor.desktop`: what a
    /// pinned app is remembered by.
    id: []const u8,
    name: []const u8,
    generic_name: []const u8 = "",
    comment: []const u8 = "",
    keywords: []const u8 = "",
    exec: []const u8 = "",
    icon: []const u8 = "",
    wm_class: []const u8 = "",
    terminal: bool = false,
    /// What else it offers to do, in the order it lists them: a new private
    /// window, a new message - what its button's menu on the taskbar shows
    /// above its own entries, as Windows' jump list does.
    actions: []const Action = &.{},

    pub const Action = struct {
        /// The `[Desktop Action id]` it is.
        id: []const u8,
        name: []const u8,
        exec: []const u8,
        icon: []const u8 = "",
    };

    /// The id without `.desktop`: what most applications use as their
    /// Wayland app id.
    pub fn stem(self: *const App) []const u8 {
        return if (std.mem.endsWith(u8, self.id, ".desktop")) self.id[0 .. self.id.len - 8] else self.id;
    }
};

pub const Apps = struct {
    arena: std.heap.ArenaAllocator,
    /// Sorted by name, as an all-apps list shows them.
    list: []App = &.{},

    pub fn deinit(self: *Apps) void {
        self.arena.deinit();
    }

    pub fn find(self: *const Apps, id: []const u8) ?*const App {
        for (self.list) |*app| if (std.mem.eql(u8, app.id, id)) return app;
        return null;
    }

    /// The app a window belongs to, from the app id it gave: the desktop
    /// file of that name, or one whose `StartupWMClass` is it.
    pub fn forAppId(self: *const Apps, app_id: []const u8) ?*const App {
        if (app_id.len == 0) return null;
        for (self.list) |*app| {
            if (std.ascii.eqlIgnoreCase(app.stem(), app_id)) return app;
        }
        for (self.list) |*app| {
            if (app.wm_class.len > 0 and std.ascii.eqlIgnoreCase(app.wm_class, app_id)) return app;
        }
        // "org.gnome.TextEditor" against "gnome-text-editor" and the like:
        // the last part of a reverse-domain id, against the whole name.
        const last = if (std.mem.lastIndexOfScalar(u8, app_id, '.')) |dot| app_id[dot + 1 ..] else app_id;
        for (self.list) |*app| {
            const app_last = if (std.mem.lastIndexOfScalar(u8, app.stem(), '.')) |dot| app.stem()[dot + 1 ..] else app.stem();
            if (std.ascii.eqlIgnoreCase(app_last, last)) return app;
        }
        return null;
    }
};

/// Read every desktop file there is.
pub fn load(gpa: std.mem.Allocator, io: std.Io) !Apps {
    var apps: Apps = .{ .arena = .init(gpa) };
    errdefer apps.deinit();
    const arena = apps.arena.allocator();

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var list: std.ArrayList(App) = .empty;
    const locales = localeKeys(arena);

    var dirs: std.ArrayList([]const u8) = .empty;
    if (std.c.getenv("XDG_DATA_HOME")) |home| {
        try dirs.append(arena, try std.fmt.allocPrint(arena, "{s}/applications", .{std.mem.span(home)}));
    } else if (std.c.getenv("HOME")) |home| {
        try dirs.append(arena, try std.fmt.allocPrint(arena, "{s}/.local/share/applications", .{std.mem.span(home)}));
    }
    const data_dirs = if (std.c.getenv("XDG_DATA_DIRS")) |d| std.mem.span(d) else "/usr/local/share:/usr/share";
    var it = std.mem.tokenizeScalar(u8, data_dirs, ':');
    while (it.next()) |dir| try dirs.append(arena, try std.fmt.allocPrint(arena, "{s}/applications", .{dir}));

    for (dirs.items) |dir| {
        try readDirectory(arena, io, dir, "", locales, &seen, &list);
    }

    std.mem.sort(App, list.items, {}, struct {
        fn less(_: void, a: App, b: App) bool {
            return nameLessThan(a.name, b.name);
        }
    }.less);
    apps.list = list.items;
    log.info("{d} applications", .{apps.list.len});
    return apps;
}

/// The letter a name is listed under: its first, in capitals and without
/// its accent - "Órák" among the O's, where a reader looks for it - or `#`
/// for a digit and `&` for anything else.
pub fn initial(name: []const u8) u8 {
    var it: Folded = .{ .bytes = name };
    const c = it.next() orelse return '&';
    if (c >= 'a' and c <= 'z') return @intCast(c - 'a' + 'A');
    if (c >= '0' and c <= '9') return '#';
    return '&';
}

/// The order an all-apps list reads in: `&`, then `#`, then the letters,
/// each name beside the others under its letter whatever its accents, and
/// the same name with and without them in a fixed order.
pub fn nameLessThan(a: []const u8, b: []const u8) bool {
    const ra = groupRank(initial(a));
    const rb = groupRank(initial(b));
    if (ra != rb) return ra < rb;
    var ia: Folded = .{ .bytes = a };
    var ib: Folded = .{ .bytes = b };
    while (true) {
        const ca = ia.next() orelse return ib.next() != null or std.mem.order(u8, a, b) == .lt;
        const cb = ib.next() orelse return false;
        if (ca != cb) return ca < cb;
    }
}

fn groupRank(letter: u8) u8 {
    return switch (letter) {
        '&' => 0,
        '#' => 1,
        else => 2 + letter - 'A',
    };
}

/// A name's characters as they are compared: lower case, and a Latin
/// letter with an accent as the letter it is written on.
const Folded = struct {
    bytes: []const u8,
    at: usize = 0,

    fn next(self: *Folded) ?u21 {
        if (self.at >= self.bytes.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(self.bytes[self.at]) catch 1;
        const end = @min(self.bytes.len, self.at + len);
        const cp = std.unicode.utf8Decode(self.bytes[self.at..end]) catch 0xFFFD;
        self.at = end;
        return fold(cp);
    }
};

fn fold(cp: u21) u21 {
    if (cp < 0x80) return std.ascii.toLower(@intCast(cp));
    const base: u8 = switch (cp) {
        0xC0...0xC5, 0xE0...0xE5, 0x100...0x105 => 'a',
        0xC7, 0xE7, 0x106...0x10D => 'c',
        0xD0, 0xF0, 0x10E...0x111 => 'd',
        0xC8...0xCB, 0xE8...0xEB, 0x112...0x11B => 'e',
        0x11C...0x123 => 'g',
        0x124...0x127 => 'h',
        0xCC...0xCF, 0xEC...0xEF, 0x128...0x133 => 'i',
        0x134, 0x135 => 'j',
        0x136...0x138 => 'k',
        0x139...0x142 => 'l',
        0xD1, 0xF1, 0x143...0x14B => 'n',
        0xD2...0xD6, 0xD8, 0xF2...0xF6, 0xF8, 0x14C...0x153 => 'o',
        0x154...0x159 => 'r',
        0xDF, 0x15A...0x161, 0x17F => 's',
        0x162...0x167 => 't',
        0xD9...0xDC, 0xF9...0xFC, 0x168...0x173 => 'u',
        0x174, 0x175 => 'w',
        0xDD, 0xFD, 0xFF, 0x176...0x178 => 'y',
        0x179...0x17E => 'z',
        else => return cp,
    };
    return base;
}

test "a name is listed under its letter, accent or not" {
    try std.testing.expectEqual(@as(u8, 'O'), initial("Órák"));
    try std.testing.expectEqual(@as(u8, 'U'), initial("űrlap"));
    try std.testing.expectEqual(@as(u8, 'C'), initial("calculator"));
    try std.testing.expectEqual(@as(u8, '#'), initial("7-Zip"));
    try std.testing.expectEqual(@as(u8, '&'), initial("(Beta)"));
    try std.testing.expectEqual(@as(u8, '&'), initial(""));
}

test "the list reads &, #, then A to Z, accents among their letters" {
    var names = [_][]const u8{ "Zene", "Órák", "alma", "Ora", "3D", "Óra", "(x)", "Ellenőrző", "Élő" };
    std.mem.sort([]const u8, &names, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return nameLessThan(a, b);
        }
    }.less);
    const want = [_][]const u8{ "(x)", "3D", "alma", "Ellenőrző", "Élő", "Ora", "Óra", "Órák", "Zene" };
    for (want, names) |w, n| try std.testing.expectEqualStrings(w, n);
}

/// One directory of desktop files, and the ones under it - whose ids join
/// the directory names with dashes, as the specification says.
fn readDirectory(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    prefix: []const u8,
    locales: []const []const u8,
    seen: *std.StringHashMapUnmanaged(void),
    list: *std.ArrayList(App),
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = dir.iterate();
    while (walker.next(io) catch null) |entry| {
        switch (entry.kind) {
            .directory => {
                const sub = try std.fmt.allocPrint(arena, "{s}/{s}", .{ path, entry.name });
                const sub_prefix = try std.fmt.allocPrint(arena, "{s}{s}-", .{ prefix, entry.name });
                try readDirectory(arena, io, sub, sub_prefix, locales, seen, list);
            },
            .file, .sym_link => {
                if (!std.mem.endsWith(u8, entry.name, ".desktop")) continue;
                const id = try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, entry.name });
                if (seen.contains(id)) continue;
                try seen.put(arena, id, {});
                const text = dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20)) catch continue;
                if (parse(arena, id, text, locales)) |app| try list.append(arena, app);
            },
            else => {},
        }
    }
}

/// The keys a localised value is looked up by, best first: `hu_HU`, `hu`.
fn localeKeys(arena: std.mem.Allocator) []const []const u8 {
    const raw = blk: {
        inline for (.{ "LC_ALL", "LC_MESSAGES", "LANG" }) |name| {
            if (std.c.getenv(name)) |value| {
                const v = std.mem.span(value);
                if (v.len > 0) break :blk v;
            }
        }
        break :blk "";
    };
    // "hu_HU.UTF-8@euro" -> "hu_HU", "hu".
    const no_modifier = if (std.mem.indexOfScalar(u8, raw, '@')) |at| raw[0..at] else raw;
    const no_encoding = if (std.mem.indexOfScalar(u8, no_modifier, '.')) |dot| no_modifier[0..dot] else no_modifier;
    if (no_encoding.len == 0 or std.mem.eql(u8, no_encoding, "C") or std.mem.eql(u8, no_encoding, "POSIX")) return &.{};
    const language = if (std.mem.indexOfScalar(u8, no_encoding, '_')) |u| no_encoding[0..u] else no_encoding;
    const keys = arena.alloc([]const u8, if (language.len == no_encoding.len) 1 else 2) catch return &.{};
    keys[0] = no_encoding;
    if (keys.len == 2) keys[1] = language;
    return keys;
}

/// The `[Desktop Entry]` group of a desktop file, and its actions' groups,
/// or null when it is not an application this desktop shows.
fn parse(arena: std.mem.Allocator, id: []const u8, text: []const u8, locales: []const []const u8) ?App {
    var app: App = .{ .id = id, .name = "" };
    var name_rank: usize = std.math.maxInt(usize);
    var is_application = false;
    // The actions the entry lists, and every action group there is.
    var listed: []const u8 = "";
    var actions: std.ArrayList(App.Action) = .empty;
    var action_ranks: std.ArrayList(usize) = .empty;
    const Group = union(enum) { entry, action: usize, other };
    var group: Group = .other;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            const action_prefix = "[Desktop Action ";
            if (std.mem.eql(u8, line, "[Desktop Entry]")) {
                group = .entry;
            } else if (std.mem.startsWith(u8, line, action_prefix) and line[line.len - 1] == ']') {
                actions.append(arena, .{ .id = line[action_prefix.len .. line.len - 1], .name = "", .exec = "" }) catch return null;
                action_ranks.append(arena, std.math.maxInt(usize)) catch return null;
                group = .{ .action = actions.items.len - 1 };
            } else group = .other;
            continue;
        }
        if (group == .other) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const full_key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        // "Name[hu]" -> "Name", "hu".
        const bracket = std.mem.indexOfScalar(u8, full_key, '[');
        const key = if (bracket) |b| full_key[0..b] else full_key;
        const locale: ?[]const u8 = if (bracket) |b| std.mem.trimEnd(u8, full_key[b + 1 ..], "]") else null;
        // How well a value's locale fits: 0 is the best key, the plain
        // value comes after every locale, and a locale not wanted not at all.
        const rank: ?usize = if (locale) |l| for (locales, 0..) |wanted, i| {
            if (std.mem.eql(u8, l, wanted)) break i;
        } else null else locales.len;
        if (rank == null) continue;

        if (group == .action) {
            const i = group.action;
            if (std.mem.eql(u8, key, "Name")) {
                if (rank.? < action_ranks.items[i]) {
                    actions.items[i].name = unescape(arena, value);
                    action_ranks.items[i] = rank.?;
                }
            } else if (std.mem.eql(u8, key, "Exec")) {
                actions.items[i].exec = value;
            } else if (std.mem.eql(u8, key, "Icon")) {
                actions.items[i].icon = value;
            }
            continue;
        }

        if (std.mem.eql(u8, key, "Actions")) {
            listed = value;
        } else if (std.mem.eql(u8, key, "Type")) {
            is_application = std.mem.eql(u8, value, "Application");
        } else if (std.mem.eql(u8, key, "Name")) {
            if (rank.? < name_rank) {
                app.name = unescape(arena, value);
                name_rank = rank.?;
            }
        } else if (std.mem.eql(u8, key, "GenericName")) {
            if (locale == null or rank.? == 0) app.generic_name = unescape(arena, value);
        } else if (std.mem.eql(u8, key, "Comment")) {
            if (locale == null or rank.? == 0) app.comment = unescape(arena, value);
        } else if (std.mem.eql(u8, key, "Keywords")) {
            if (locale == null or rank.? == 0) app.keywords = unescape(arena, value);
        } else if (std.mem.eql(u8, key, "Exec")) {
            app.exec = value;
        } else if (std.mem.eql(u8, key, "Icon")) {
            app.icon = value;
        } else if (std.mem.eql(u8, key, "StartupWMClass")) {
            app.wm_class = value;
        } else if (std.mem.eql(u8, key, "Terminal")) {
            app.terminal = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "NoDisplay") or std.mem.eql(u8, key, "Hidden")) {
            if (std.mem.eql(u8, value, "true")) return null;
        } else if (std.mem.eql(u8, key, "OnlyShowIn")) {
            if (!listHas(value, "Fluxion")) return null;
        } else if (std.mem.eql(u8, key, "NotShowIn")) {
            if (listHas(value, "Fluxion")) return null;
        }
    }
    if (!is_application or app.name.len == 0 or app.exec.len == 0) return null;
    // The ones listed, in the order listed, that say what they are and do.
    var ordered: std.ArrayList(App.Action) = .empty;
    var it = std.mem.tokenizeScalar(u8, listed, ';');
    while (it.next()) |wanted| {
        for (actions.items) |a| {
            if (!std.mem.eql(u8, a.id, wanted) or a.name.len == 0 or a.exec.len == 0) continue;
            ordered.append(arena, a) catch break;
            break;
        }
    }
    app.actions = ordered.items;
    return app;
}

test "a desktop file's actions, in the order it lists them, in the reader's language" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Firefox
        \\Exec=firefox %u
        \\Actions=new-window;new-private-window;missing;
        \\
        \\[Desktop Action new-private-window]
        \\Name=New Private Window
        \\Name[hu]=Új privát ablak
        \\Exec=firefox --private-window %u
        \\
        \\[Desktop Action new-window]
        \\Name=New Window
        \\Exec=firefox --new-window %u
        \\
        \\[Desktop Action unlisted]
        \\Name=Not this one
        \\Exec=firefox --nothing
    ;
    const app = parse(arena.allocator(), "firefox.desktop", text, &.{"hu"}).?;
    try std.testing.expectEqualStrings("Firefox", app.name);
    try std.testing.expectEqual(@as(usize, 2), app.actions.len);
    try std.testing.expectEqualStrings("New Window", app.actions[0].name);
    try std.testing.expectEqualStrings("Új privát ablak", app.actions[1].name);
    try std.testing.expectEqualStrings("firefox --private-window %u", app.actions[1].exec);
}

fn listHas(list: []const u8, wanted: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ';');
    while (it.next()) |item| if (std.mem.eql(u8, item, wanted)) return true;
    return false;
}

/// `\s`, `\n`, `\t`, `\\` in a string value.
fn unescape(arena: std.mem.Allocator, value: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, value, '\\') == null) return value;
    var out = std.ArrayList(u8).initCapacity(arena, value.len) catch return value;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (value[i] == '\\' and i + 1 < value.len) {
            i += 1;
            out.appendAssumeCapacity(switch (value[i]) {
                's' => ' ',
                'n' => '\n',
                't' => '\t',
                else => value[i],
            });
        } else out.appendAssumeCapacity(value[i]);
    }
    return out.items;
}

/// Start an application: its `Exec` line with the field codes taken out -
/// there are no files to open it with - through the shell, which knows the
/// specification's quoting.
/// Start `app`. `token` is an activation token from the compositor, which
/// the app hands back to have its window brought forward: an app already
/// running that is asked for another window, rather than opening one,
/// comes forward with it.
pub fn launch(gpa: std.mem.Allocator, io: std.Io, app: *const App, action: ?*const App.Action, token: ?[]const u8) void {
    const exec = if (action) |a| a.exec else app.exec;
    const line = commandLine(gpa, exec) catch return;
    defer gpa.free(line);
    run(gpa, io, if (action) |a| a.name else app.name, line, token);
}

/// An `Exec` line with its field codes taken out - there are no files to
/// open it with - for the shell to run, which knows the specification's
/// quoting.
pub fn commandLine(gpa: std.mem.Allocator, exec: []const u8) ![]u8 {
    var command: std.ArrayList(u8) = .empty;
    errdefer command.deinit(gpa);
    var i: usize = 0;
    while (i < exec.len) : (i += 1) {
        if (exec[i] == '%' and i + 1 < exec.len) {
            i += 1;
            if (exec[i] == '%') try command.append(gpa, '%');
            // Every other field code - %f %F %u %U %i %c %k and the
            // deprecated ones - stands for something there is none of.
            continue;
        }
        try command.append(gpa, exec[i]);
    }
    const trimmed = std.mem.trim(u8, command.items, " ");
    const out = try gpa.dupe(u8, trimmed);
    command.deinit(gpa);
    return out;
}

/// Run a shell command line in the background, as an app is started:
/// `what` names it in the log.
pub fn run(gpa: std.mem.Allocator, io: std.Io, what: []const u8, line: []const u8, token: ?[]const u8) void {
    log.info("starting {s}: {s}", .{ what, line });
    // The app runs in the background of a shell that ends at once: waiting
    // for that shell is all the waiting there is, and the app, left without
    // a parent, is the system's to take back - it outlives this one too.
    // A shell the compositor started was handed its connection as
    // WAYLAND_SOCKET; an app is not, and finds the display by its name.
    // The token goes by both of its names: the Wayland one, and the one X11
    // toolkits read.
    var token_line: [256]u8 = undefined;
    const export_token = if (token) |t| std.fmt.bufPrint(&token_line, "export XDG_ACTIVATION_TOKEN='{s}' DESKTOP_STARTUP_ID='{s}'", .{ t, t }) catch "" else "";
    const script = std.fmt.allocPrint(gpa, "(\nunset WAYLAND_SOCKET\n{s}\n{s}\n) &", .{ export_token, line }) catch return;
    defer gpa.free(script);
    var child = std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", script } }) catch |err| {
        log.err("could not start {s}: {t}", .{ what, err });
        return;
    };
    _ = child.wait(io) catch {};
}

/// How well `query` matches an app, or null for not at all: the start of
/// its name best, then the start of a word in it, then anywhere in its
/// name, then its other names and keywords - and last, the letters of the
/// query found in its name in order with others between ("ffx" in
/// "Firefox"), better the more of them are together or start a word.
pub fn score(app: *const App, query: []const u8) ?u32 {
    if (query.len == 0) return 0;
    if (startsWithIgnoreCase(app.name, query)) return 1000;
    var words = std.mem.tokenizeAny(u8, app.name, " -_.");
    while (words.next()) |word| if (startsWithIgnoreCase(word, query)) return 800;
    if (std.ascii.indexOfIgnoreCase(app.name, query) != null) return 600;
    if (std.ascii.indexOfIgnoreCase(app.generic_name, query) != null) return 400;
    if (std.ascii.indexOfIgnoreCase(app.keywords, query) != null) return 300;
    if (std.ascii.indexOfIgnoreCase(app.stem(), query) != null) return 200;
    if (fuzzy(app.name, query)) |s| return s;
    return null;
}

/// The letters of `query` in `text` in order, scored under 200: a point for
/// each, more for one right after the last or at the start of a word, less
/// the further the match is spread. Null when they are not all there.
pub fn fuzzy(text: []const u8, query: []const u8) ?u32 {
    if (query.len < 2) return null;
    var points: u32 = 0;
    var at: usize = 0;
    var last: ?usize = null;
    for (query) |wanted| {
        if (wanted == ' ') continue;
        const found = while (at < text.len) : (at += 1) {
            if (std.ascii.toLower(text[at]) == std.ascii.toLower(wanted)) break at;
        } else return null;
        points += 1;
        if (last) |l| {
            if (found == l + 1) points += 3;
        }
        if (found == 0 or std.mem.indexOfScalar(u8, " -_.", text[found - 1]) != null) points += 4;
        last = found;
        at = found + 1;
    }
    const spread: u32 = @intCast(@min(at, 60));
    return @min(199, 100 + points * 4 -| spread);
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

test "a desktop entry is read in the reader's language, and hidden ones are not" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Text Editor
        \\Name[hu]=Szövegszerkesztő
        \\Exec=gnome-text-editor %U
        \\Icon=org.gnome.TextEditor
        \\
        \\[Desktop Action new-window]
        \\Name=New Window
    ;
    const app = parse(a, "org.gnome.TextEditor.desktop", text, &.{ "hu_HU", "hu" }).?;
    try std.testing.expectEqualStrings("Szövegszerkesztő", app.name);
    try std.testing.expectEqualStrings("org.gnome.TextEditor", app.icon);
    try std.testing.expectEqualStrings("org.gnome.TextEditor", app.stem());

    try std.testing.expect(parse(a, "x.desktop", "[Desktop Entry]\nType=Application\nName=X\nExec=x\nNoDisplay=true\n", &.{}) == null);
    try std.testing.expect(parse(a, "y.desktop", "[Desktop Entry]\nType=Application\nName=Y\nExec=y\nOnlyShowIn=GNOME;\n", &.{}) == null);
}

test "a search finds the start of a name before the middle of one" {
    const editor: App = .{ .id = "e.desktop", .name = "Text Editor", .exec = "e" };
    try std.testing.expect(score(&editor, "text").? > score(&editor, "edit").?);
    try std.testing.expect(score(&editor, "itor") != null);
    try std.testing.expect(score(&editor, "zzz") == null);
}

test "a few letters of a name in order find it, and better together" {
    const firefox: App = .{ .id = "f.desktop", .name = "Firefox", .exec = "f" };
    const editor: App = .{ .id = "e.desktop", .name = "Text Editor", .exec = "e" };
    try std.testing.expect(score(&firefox, "ffx") != null);
    try std.testing.expect(score(&firefox, "ffx").? < score(&firefox, "fire").?);
    try std.testing.expect(score(&editor, "txed") != null);
    try std.testing.expect(score(&editor, "xyz") == null);
    // Letters that start words count for more than ones in the middle.
    try std.testing.expect(fuzzy("Text Editor", "te").? > fuzzy("Text Editor", "xt").?);
}
