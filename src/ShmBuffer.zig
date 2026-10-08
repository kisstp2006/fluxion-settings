// SPDX-License-Identifier: BSD-2-Clause

//! A buffer of pixels shared with the compositor: memory from `memfd_create`,
//! mapped here and handed over as a `wl_buffer`.
//!
//! The pixels are what Fluxion UI's CPU renderer draws - premultiplied,
//! `0xAARRGGBB` in a `u32` - which is Wayland's `argb8888` exactly, so a
//! frame is drawn straight into the memory the compositor reads, with no
//! copy.
//!
//! **A buffer is busy from the moment it is attached until the compositor
//! releases it.** Drawing into it then would change a frame the compositor
//! may still be showing, so a panel keeps three and draws into whichever is
//! free, in turn.

const std = @import("std");
const posix = std.posix;
const wl = @import("wayland").client.wl;

const ShmBuffer = @This();

wl_buffer: *wl.Buffer,
memory: []align(std.heap.page_size_min) u8,
pixels: []u32,
width: u32,
height: u32,
busy: bool = false,

pub fn create(gpa: std.mem.Allocator, shm: *wl.Shm, width: u32, height: u32) !*ShmBuffer {
    const stride = width * 4;
    const size: usize = @as(usize, stride) * height;
    const fd = try posix.memfd_create("fluxion-shell", 0);
    defer _ = std.c.close(fd);
    if (std.c.ftruncate(fd, @intCast(size)) != 0) return error.TruncateFailed;
    const memory = try posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    errdefer posix.munmap(memory);

    const pool = try shm.createPool(fd, @intCast(size));
    defer pool.destroy();
    const wl_buffer = try pool.createBuffer(0, @intCast(width), @intCast(height), @intCast(stride), .argb8888);

    const self = try gpa.create(ShmBuffer);
    self.* = .{
        .wl_buffer = wl_buffer,
        .memory = memory,
        .pixels = @alignCast(std.mem.bytesAsSlice(u32, memory)),
        .width = width,
        .height = height,
    };
    wl_buffer.setListener(*ShmBuffer, listener, self);
    return self;
}

pub fn destroy(self: *ShmBuffer, gpa: std.mem.Allocator) void {
    self.wl_buffer.destroy();
    posix.munmap(self.memory);
    gpa.destroy(self);
}

fn listener(_: *wl.Buffer, event: wl.Buffer.Event, self: *ShmBuffer) void {
    switch (event) {
        .release => self.busy = false,
    }
}
