// SPDX-License-Identifier: BSD-2-Clause

//! When the sun sets and rises where the person is: what night light's
//! "Sunset to sunrise" schedule follows, as Windows' does.
//!
//! Where they are is where their time zone is: `/etc/localtime` names it -
//! `Europe/Budapest` - and the tz database's `zone1970.tab` gives the place
//! it is named after, to the minute of a degree. Close enough for a
//! sunset: a hundred kilometres east or west moves it by about seven
//! minutes. No location service is asked.
//!
//! The times are NOAA's approximation - the equation of time and the sun's
//! declination for the day, and the hour angle at which its top edge
//! meets the horizon, refraction allowed for.

const std = @import("std");

pub const Place = struct { latitude: f64, longitude: f64 };

/// Minutes after local midnight.
pub const Times = struct { rise: i32, set: i32 };

/// The place the system's time zone is named after.
pub fn placeOfTimeZone(io: std.Io) ?Place {
    var link_buffer: [512]u8 = undefined;
    const n = std.Io.Dir.cwd().readLink(io, "/etc/localtime", &link_buffer) catch return null;
    const target = link_buffer[0..n];
    const marker = "zoneinfo/";
    const at = std.mem.indexOf(u8, target, marker) orelse return null;
    const zone = target[at + marker.len ..];
    var table_buffer: [64 * 1024]u8 = undefined;
    const table = std.Io.Dir.cwd().readFile(io, "/usr/share/zoneinfo/zone1970.tab", &table_buffer) catch return null;
    return placeIn(table, zone);
}

/// `zone`'s place in a `zone1970.tab`.
pub fn placeIn(table: []const u8, zone: []const u8) ?Place {
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        _ = fields.next() orelse continue;
        const coordinates = fields.next() orelse continue;
        const name = fields.next() orelse continue;
        if (!std.mem.eql(u8, name, zone)) continue;
        return parseCoordinates(coordinates);
    }
    return null;
}

/// ISO 6709 as the table writes it: `+4730+01905`, or with seconds,
/// `+404251-0740023`.
fn parseCoordinates(text: []const u8) ?Place {
    // Where the longitude's sign is.
    var split: usize = 1;
    while (split < text.len and text[split] != '+' and text[split] != '-') split += 1;
    if (split >= text.len) return null;
    const latitude = parseAngle(text[0..split], 2) orelse return null;
    const longitude = parseAngle(text[split..], 3) orelse return null;
    return .{ .latitude = latitude, .longitude = longitude };
}

fn parseAngle(text: []const u8, degree_digits: usize) ?f64 {
    if (text.len < 1 + degree_digits + 2) return null;
    const sign: f64 = if (text[0] == '-') -1 else 1;
    const digits = text[1..];
    const degrees = std.fmt.parseInt(u32, digits[0..degree_digits], 10) catch return null;
    const minutes = std.fmt.parseInt(u32, digits[degree_digits .. degree_digits + 2], 10) catch return null;
    const seconds = if (digits.len >= degree_digits + 4) std.fmt.parseInt(u32, digits[degree_digits + 2 .. degree_digits + 4], 10) catch 0 else 0;
    return sign * (@as(f64, @floatFromInt(degrees)) + @as(f64, @floatFromInt(minutes)) / 60 + @as(f64, @floatFromInt(seconds)) / 3600);
}

/// When the sun rises and sets at `place` on day `day_of_year` (from 0),
/// in minutes after local midnight for a zone `utc_offset` minutes ahead
/// of UTC - or null where it does neither that day.
pub fn times(place: Place, day_of_year: u16, utc_offset: i32) ?Times {
    const tau = 2 * std.math.pi;
    const g = tau / 365.0 * @as(f64, @floatFromInt(day_of_year));
    const eqtime = 229.18 * (0.000075 + 0.001868 * @cos(g) - 0.032077 * @sin(g) - 0.014615 * @cos(2 * g) - 0.040849 * @sin(2 * g));
    const decl = 0.006918 - 0.399912 * @cos(g) + 0.070257 * @sin(g) - 0.006758 * @cos(2 * g) + 0.000907 * @sin(2 * g) - 0.002697 * @cos(3 * g) + 0.00148 * @sin(3 * g);
    const lat = place.latitude * std.math.pi / 180.0;
    const zenith: f64 = 90.833 * std.math.pi / 180.0;
    const c = @cos(zenith) / (@cos(lat) * @cos(decl)) - @tan(lat) * @tan(decl);
    if (c < -1 or c > 1) return null;
    const ha = std.math.acos(c) * 180 / std.math.pi;
    const rise = 720 - 4 * (place.longitude + ha) - eqtime;
    const set = 720 - 4 * (place.longitude - ha) - eqtime;
    return .{
        .rise = @mod(@as(i32, @intFromFloat(@round(rise))) + utc_offset, 24 * 60),
        .set = @mod(@as(i32, @intFromFloat(@round(set))) + utc_offset, 24 * 60),
    };
}

/// Whether `now` - minutes after midnight - is within the night from `on`
/// to `off`, which may run past midnight.
pub fn within(now: i32, on: i32, off: i32) bool {
    if (on == off) return false;
    return if (on < off) now >= on and now < off else now >= on or now < off;
}

test "the time zone's place is read from the table" {
    const table = "# comment\nHU\t+4730+01905\tEurope/Budapest\nUS\t+404251-0740023\tAmerica/New_York\n";
    const budapest = placeIn(table, "Europe/Budapest").?;
    try std.testing.expectApproxEqAbs(@as(f64, 47.5), budapest.latitude, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 19.0833333), budapest.longitude, 1e-6);
    const new_york = placeIn(table, "America/New_York").?;
    try std.testing.expectApproxEqAbs(@as(f64, -74.0063889), new_york.longitude, 1e-6);
    try std.testing.expectEqual(@as(?Place, null), placeIn(table, "Mars/Olympus"));
}

test "Budapest's sun sets and rises when it does" {
    // The 9th of October, summer time (UTC+2): about 06:54 and 18:13.
    const t = times(.{ .latitude = 47.5, .longitude = 19.0833 }, 281, 120).?;
    try std.testing.expect(@abs(t.rise - (6 * 60 + 54)) <= 6);
    try std.testing.expect(@abs(t.set - (18 * 60 + 13)) <= 6);
    // Midsummer in the far north: no setting at all.
    try std.testing.expectEqual(@as(?Times, null), times(.{ .latitude = 78.2, .longitude = 15.6 }, 171, 120));
}

test "a night running past midnight contains its small hours" {
    try std.testing.expect(within(23 * 60, 21 * 60, 7 * 60));
    try std.testing.expect(within(3 * 60, 21 * 60, 7 * 60));
    try std.testing.expect(!within(12 * 60, 21 * 60, 7 * 60));
    try std.testing.expect(within(10 * 60, 9 * 60, 17 * 60));
}
