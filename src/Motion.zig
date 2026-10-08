// SPDX-License-Identifier: BSD-2-Clause

//! A change the shell shows over a moment rather than at once: a menu
//! opening, a list turning into its letters. It is started, and asked how
//! far along it is each time the panel is drawn; whoever draws with it
//! asks for the next frame while it runs.
//!
//! The curves are the compositor's, Fluent's: `decelerate` for what comes
//! in - quick, then settling into place - `accelerate` for what goes, and
//! `point_to_point` for what moves from one place to another.

const std = @import("std");

const Motion = @This();

pub const Ease = enum { decelerate, accelerate, point_to_point, popup };

/// How long it takes, in milliseconds.
duration: u32,
ease: Ease = .decelerate,
/// When it started; nought for one never started, which is at its end.
start_ms: i64 = 0,

pub fn begin(self: *Motion) void {
    self.start_ms = nowMs();
}

/// Whether it is still on its way: the panel is to be drawn again.
pub fn running(self: *const Motion) bool {
    return self.start_ms != 0 and nowMs() - self.start_ms < self.duration;
}

/// How far along it is, from nought to one, along its curve: one once it
/// has ended, or for one never started.
pub fn progress(self: *const Motion) f32 {
    if (self.start_ms == 0) return 1;
    const ms: f32 = @floatFromInt(nowMs() - self.start_ms);
    const t = std.math.clamp(ms / @as(f32, @floatFromInt(@max(1, self.duration))), 0, 1);
    return curve(self.ease, t);
}

/// How far along it is in time alone, nought to one, with no curve: for a
/// fade that runs straight through, or over part of it.
pub fn elapsed(self: *const Motion) f32 {
    if (self.start_ms == 0) return 1;
    const ms: f32 = @floatFromInt(nowMs() - self.start_ms);
    return std.math.clamp(ms / @as(f32, @floatFromInt(@max(1, self.duration))), 0, 1);
}

/// Fluent's fade: straight through, over `fade_ms` of the motion's time,
/// from `from_ms` on.
pub fn fade(self: *const Motion, from_ms: f32, fade_ms: f32) f32 {
    const ms = self.elapsed() * @as(f32, @floatFromInt(self.duration));
    return std.math.clamp((ms - from_ms) / fade_ms, 0, 1);
}

/// From `a` to `b`, `t` of the way.
pub fn mix(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub fn curve(ease: Ease, t: f32) f32 {
    return switch (ease) {
        // cubic-bezier(0, 0, 0, 1)
        .decelerate => bezier(0, 0, 0, 1, t),
        // cubic-bezier(1, 0, 1, 1)
        .accelerate => bezier(1, 0, 1, 1, t),
        // cubic-bezier(0.55, 0.55, 0, 1)
        .point_to_point => bezier(0.55, 0.55, 0, 1, t),
        // cubic-bezier(0.1, 0.9, 0.2, 1): the system's for what pops up,
        // and the lock screen's curtain.
        .popup => bezier(0.1, 0.9, 0.2, 1, t),
    };
}

/// A CSS-style cubic Bézier's y for its x, found by bisection.
fn bezier(x1: f32, y1: f32, x2: f32, y2: f32, x: f32) f32 {
    const at = struct {
        fn f(a: f32, b: f32, s: f32) f32 {
            const u = 1 - s;
            return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s;
        }
    }.f;
    var lo: f32 = 0;
    var hi: f32 = 1;
    for (0..24) |_| {
        const mid = (lo + hi) / 2;
        if (at(x1, x2, mid) < x) lo = mid else hi = mid;
    }
    return at(y1, y2, (lo + hi) / 2);
}

pub fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

test "the curves start at nought and end at one" {
    inline for (.{ Ease.decelerate, Ease.accelerate, Ease.point_to_point, Ease.popup }) |ease| {
        try std.testing.expectApproxEqAbs(@as(f32, 0), curve(ease, 0), 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 1), curve(ease, 1), 0.001);
    }
    // Coming in, most of the way is gone early.
    try std.testing.expect(curve(.decelerate, 0.25) > 0.6);
    try std.testing.expect(curve(.accelerate, 0.25) < 0.1);
}

test "a motion never started is at its end" {
    const m: Motion = .{ .duration = 200 };
    try std.testing.expect(!m.running());
    try std.testing.expectEqual(@as(f32, 1), m.progress());
}
