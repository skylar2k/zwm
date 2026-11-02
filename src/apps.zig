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

//! Running applications and their Accessibility observers. For every regular
//! app we create an `AXObserver`, which tells us (through the run loop) when
//! the app opens, closes, minimizes or focuses a window.
//!
//! Notifications are only a hint ("something changed"): they are known to be
//! unreliable, so we never act on the details. We just ask the window manager
//! to reconcile with reality (see `wm.reconcile`).
const std = @import("std");
const c = @import("c");
const config = @import("config");
const ax = @import("ax.zig");
const objc = @import("objc");
const cocoa = @import("cocoa.zig");

const gpa = @import("mem.zig").gpa;

pub const App = struct {
    pid: i32,
    el: c.AXUIElementRef, // owned
    observer: c.AXObserverRef = null, // owned
    subscribed: bool = false,
    hidden: bool = false, // Cmd-H
    /// Don't talk to this app before this time (it stopped answering).
    backoff_until: f64 = 0,
    bundle_id: []u8,
    name: []u8,
};

pub var list: std.ArrayList(*App) = .empty;

/// Called (from the run loop) whenever an observed app reports a change.
/// The argument is the pid of that app.
pub var on_event: *const fn (pid: i32) void = noop;
fn noop(_: i32) void {}

/// The pid rides along with every notification as its "refcon" (an arbitrary
/// pointer-sized value the callback gets back), so we know which app spoke.
fn refcon(pid: i32) ?*anyopaque {
    return @ptrFromInt(@as(usize, @intCast(pid)));
}

pub fn find(pid: i32) ?*App {
    for (list.items) |a| {
        if (a.pid == pid) return a;
    }
    return null;
}

fn observerCallback(_: c.AXObserverRef, _: c.AXUIElementRef, _: c.CFStringRef, ref: ?*anyopaque) callconv(.c) void {
    on_event(@intCast(@intFromPtr(ref)));
}

/// Watch for new/closing windows of `app`. Also called again later for apps
/// that weren't ready (AX answers "cannot complete" right after launch).
fn subscribe(app: *App) void {
    if (app.observer == null) {
        var obs: c.AXObserverRef = null;
        if (c.AXObserverCreate(app.pid, observerCallback, &obs) != c.kAXErrorSuccess) return;
        app.observer = obs;
        c.CFRunLoopAddSource(c.CFRunLoopGetMain(), c.AXObserverGetRunLoopSource(obs), c.kCFRunLoopCommonModes);
    }
    const names = [_]c.CFStringRef{ ax.cfs("AXWindowCreated"), ax.cfs("AXFocusedWindowChanged"), ax.cfs("AXMainWindowChanged") };
    var ok = true;
    for (names) |n| {
        const err = c.AXObserverAddNotification(app.observer, app.el, n, refcon(app.pid));
        if (err != c.kAXErrorSuccess and err != c.kAXErrorNotificationAlreadyRegistered) ok = false;
    }
    app.subscribed = ok;
}

/// Watch one window for destruction / minimizing.
pub fn watchWindow(app: *App, win: c.AXUIElementRef) void {
    if (app.observer == null) return;
    const names = [_]c.CFStringRef{ ax.cfs("AXUIElementDestroyed"), ax.cfs("AXWindowMiniaturized"), ax.cfs("AXWindowDeminiaturized") };
    for (names) |n| _ = c.AXObserverAddNotification(app.observer, win, n, refcon(app.pid));
}

fn dupe(ns: objc.Object) []u8 {
    var buf: [256]u8 = undefined;
    const s = cocoa.utf8(ns, &buf) orelse "";
    return gpa.dupe(u8, s) catch &.{};
}

fn destroy(app: *App) void {
    if (app.observer != null) {
        c.CFRunLoopRemoveSource(c.CFRunLoopGetMain(), c.AXObserverGetRunLoopSource(app.observer), c.kCFRunLoopCommonModes);
        c.CFRelease(app.observer);
    }
    c.CFRelease(app.el);
    gpa.free(app.bundle_id);
    gpa.free(app.name);
    gpa.destroy(app);
}

/// Forget every app (used at quit, so leak checking sees a clean slate).
pub fn deinit() void {
    for (list.items) |app| destroy(app);
    list.deinit(gpa);
}

/// Sync our list with the apps that are running right now.
pub fn refresh() void {
    const running = cocoa.sharedWorkspace().msgSend(objc.Object, "runningApplications", .{});
    const count = running.msgSend(usize, "count", .{});
    const me = c.getpid();

    // 1. add apps we haven't seen
    for (0..count) |i| {
        const ra = running.msgSend(objc.Object, "objectAtIndex:", .{i});
        // activationPolicy 0 = "regular": has a Dock icon and normal windows
        if (ra.msgSend(isize, "activationPolicy", .{}) != 0) continue;
        if (ra.msgSend(bool, "isTerminated", .{})) continue;
        const pid = ra.msgSend(i32, "processIdentifier", .{});
        if (pid == me) continue;

        const app = find(pid) orelse blk: {
            const a = gpa.create(App) catch continue;
            a.* = .{
                .pid = pid,
                .el = c.AXUIElementCreateApplication(pid),
                .bundle_id = dupe(ra.msgSend(objc.Object, "bundleIdentifier", .{})),
                .name = dupe(ra.msgSend(objc.Object, "localizedName", .{})),
            };
            ax.setTimeout(a.el, config.ax_timeout);
            list.append(gpa, a) catch {
                destroy(a);
                continue;
            };
            break :blk a;
        };
        app.hidden = ra.msgSend(bool, "isHidden", .{});
        if (!app.subscribed) subscribe(app);
    }

    // 2. drop apps that quit
    var i: usize = 0;
    while (i < list.items.len) {
        const app = list.items[i];
        const running_app = cocoa.runningApplication(app.pid);
        if (running_app == null or running_app.?.msgSend(bool, "isTerminated", .{})) {
            _ = list.swapRemove(i);
            destroy(app);
        } else i += 1;
    }
}
