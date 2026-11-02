// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 zwm contributors
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License, version 3, as published
// by the Free Software Foundation.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details. You should have received a copy of it along with this
// program (the file LICENSE); if not, see <https://www.gnu.org/licenses/>.

//! Timers on the main run loop. zwm is single-threaded: everything (hotkeys,
//! window notifications, timers) is delivered by the main thread's run loop,
//! one callback at a time, so there are no locks anywhere.
const std = @import("std");
const c = @import("c");

// Timer jobs are tiny and may still be pending at quit, so they use plain
// malloc and not the leak-checking allocator in mem.zig.
const gpa = std.heap.c_allocator;

const Job = struct { func: *const fn (usize) void, arg: usize };

fn onceFired(_: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(info));
    const j = job.*;
    gpa.destroy(job);
    j.func(j.arg);
}

fn addTimer(first_in: f64, interval: f64, cb: c.CFRunLoopTimerCallBack, info: ?*anyopaque) void {
    var ctx = c.CFRunLoopTimerContext{ .version = 0, .info = info, .retain = null, .release = null, .copyDescription = null };
    const t = c.CFRunLoopTimerCreate(null, c.CFAbsoluteTimeGetCurrent() + first_in, interval, 0, 0, cb, &ctx);
    c.CFRunLoopAddTimer(c.CFRunLoopGetMain(), t, c.kCFRunLoopCommonModes);
    c.CFRelease(t); // the run loop keeps its own reference
}

/// Run `func(arg)` once, `seconds` from now (0 = next trip round the loop).
pub fn after(seconds: f64, func: *const fn (usize) void, arg: usize) void {
    const job = gpa.create(Job) catch return;
    job.* = .{ .func = func, .arg = arg };
    addTimer(seconds, 0, onceFired, job);
}

fn everyFired(_: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const f: *const fn () void = @ptrCast(@alignCast(info));
    f();
}

/// Run `func()` every `seconds`, forever.
pub fn every(seconds: f64, func: *const fn () void) void {
    addTimer(seconds, seconds, everyFired, @ptrCast(@constCast(func)));
}

pub fn now() f64 {
    return c.CFAbsoluteTimeGetCurrent();
}
