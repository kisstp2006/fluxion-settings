// SPDX-License-Identifier: BSD-2-Clause

//! Keyboard layouts as people know them: XKB's codes - "us", "hu" - with
//! the three letters the taskbar shows, as Windows' input indicator does
//! ("ENG", "HUN"), and the name a list shows ("Hungarian").

const std = @import("std");

pub const Known = struct { code: []const u8, short: []const u8, name: []const u8 };

pub const known = [_]Known{
    .{ .code = "us", .short = "ENG", .name = "English (US)" },
    .{ .code = "gb", .short = "ENG", .name = "English (UK)" },
    .{ .code = "hu", .short = "HUN", .name = "Hungarian" },
    .{ .code = "de", .short = "DEU", .name = "German" },
    .{ .code = "fr", .short = "FRA", .name = "French" },
    .{ .code = "es", .short = "ESP", .name = "Spanish" },
    .{ .code = "it", .short = "ITA", .name = "Italian" },
    .{ .code = "pl", .short = "POL", .name = "Polish" },
    .{ .code = "cz", .short = "CES", .name = "Czech" },
    .{ .code = "sk", .short = "SLK", .name = "Slovak" },
    .{ .code = "ro", .short = "ROM", .name = "Romanian" },
    .{ .code = "at", .short = "DEU", .name = "German (Austria)" },
    .{ .code = "ch", .short = "DEU", .name = "German (Switzerland)" },
    .{ .code = "nl", .short = "NLD", .name = "Dutch" },
    .{ .code = "pt", .short = "POR", .name = "Portuguese" },
    .{ .code = "br", .short = "POR", .name = "Portuguese (Brazil)" },
    .{ .code = "se", .short = "SWE", .name = "Swedish" },
    .{ .code = "no", .short = "NOR", .name = "Norwegian" },
    .{ .code = "dk", .short = "DAN", .name = "Danish" },
    .{ .code = "fi", .short = "FIN", .name = "Finnish" },
    .{ .code = "ru", .short = "RUS", .name = "Russian" },
    .{ .code = "ua", .short = "UKR", .name = "Ukrainian" },
    .{ .code = "tr", .short = "TRK", .name = "Turkish" },
    .{ .code = "gr", .short = "ELL", .name = "Greek" },
    .{ .code = "jp", .short = "JPN", .name = "Japanese" },
};

/// The layout code of "de:nodeadkeys" - "de".
pub fn codeOf(entry: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, entry, ':') orelse return entry;
    return entry[0..colon];
}

pub fn find(code: []const u8) ?Known {
    for (known) |k| if (std.mem.eql(u8, k.code, codeOf(code))) return k;
    return null;
}

/// Three letters for the taskbar: known ones as Windows writes them, the
/// rest the code in capitals.
pub fn short(code: []const u8, buffer: []u8) []const u8 {
    if (find(code)) |k| return k.short;
    const c = codeOf(code);
    const n = @min(c.len, buffer.len);
    for (c[0..n], buffer[0..n]) |from, *to| to.* = std.ascii.toUpper(from);
    return buffer[0..n];
}

/// The name a list shows.
pub fn name(code: []const u8) []const u8 {
    if (find(code)) |k| return k.name;
    return codeOf(code);
}

test "layouts are named as Windows names them" {
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("HUN", short("hu", &buffer));
    try std.testing.expectEqualStrings("DEU", short("de:nodeadkeys", &buffer));
    try std.testing.expectEqualStrings("XYZ", short("xyz", &buffer));
    try std.testing.expectEqualStrings("English (US)", name("us"));
}
