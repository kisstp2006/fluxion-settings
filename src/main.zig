// SPDX-License-Identifier: BSD-2-Clause

//! fluxion-settings: Settings for Fluxion Desktop.
//!
//! ```bash
//! fluxion-settings              # System
//! fluxion-settings display      # opened at a page: display, sound,
//!                               # notifications, power, about, bluetooth,
//!                               # wifi, network, background, colors, apps,
//!                               # accounts, datetime, region
//! ```

const std = @import("std");

const Settings = @import("Settings.zig");

pub const std_options: std.Options = .{ .log_level = .info };

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var settings: Settings = undefined;
    try settings.init(gpa, init.io);
    defer settings.deinit();
    if (args.len > 1) settings.openAt(args[1]) else settings.go(.system, .none);
    settings.window.run() catch |err| switch (err) {
        // The compositor has gone, and the window with it: nothing is left
        // to do.
        error.ConnectionLost => {},
        else => return err,
    };
}

test {
    _ = @import("Store.zig");
    _ = @import("ImageFile.zig");
    _ = @import("pages/system.zig");
    _ = @import("Displays.zig");
    _ = @import("apps.zig");
    _ = @import("Sun.zig");
    _ = @import("Portal.zig");
}
