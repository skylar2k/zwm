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

//! Everything about living inside macOS: sleep and wake, screen lock, display
//! changes, app launches, Ctrl-C, and the Objective-C object that receives
//! all those notifications.
//!
//! Sleep handling in one paragraph: when the Mac sleeps, the screens turn off,
//! the screen is locked or the session is switched away, we `pause` (no window
//! is touched, because the AX API can hang or fail then). When everything is
//! back we `wake`: re-arm the hotkey tap, wait a second for displays to
//! return, re-read the geometry and reconcile the windows. A heartbeat timer
//! is the safety net if a notification is ever missed.
//!
//! The screen lock deserves its own reason: while it is up, Accessibility
//! reports every window as gone (no windows, no window ids). Waking with the
//! lock screen still showing, and believing that, forgets every window. AeroSpace
//! documents the same trap. The lock can last minutes, so it is a state to
//! wait out, not a delay to time.
const std = @import("std");
const c = @import("c");
const config = @import("config");
const objc = @import("objc");
const cocoa = @import("cocoa.zig");
const apps = @import("apps.zig");
const bar = @import("bar.zig");
const hotkeys = @import("hotkeys.zig");
const log = @import("log.zig");
const runloop = @import("runloop.zig");
const wm = @import("wm.zig");


// Notification names. These are constants exported by AppKit.
extern "c" const NSWorkspaceWillSleepNotification: cocoa.id;
extern "c" const NSWorkspaceDidWakeNotification: cocoa.id;
extern "c" const NSWorkspaceScreensDidSleepNotification: cocoa.id;
extern "c" const NSWorkspaceScreensDidWakeNotification: cocoa.id;
extern "c" const NSWorkspaceSessionDidResignActiveNotification: cocoa.id;
extern "c" const NSWorkspaceSessionDidBecomeActiveNotification: cocoa.id;
extern "c" const NSWorkspaceDidLaunchApplicationNotification: cocoa.id;
extern "c" const NSWorkspaceDidTerminateApplicationNotification: cocoa.id;
extern "c" const NSWorkspaceDidActivateApplicationNotification: cocoa.id;
extern "c" const NSWorkspaceDidHideApplicationNotification: cocoa.id;
extern "c" const NSWorkspaceDidUnhideApplicationNotification: cocoa.id;
extern "c" const NSWorkspaceActiveSpaceDidChangeNotification: cocoa.id;

// ---- "why are we paused?" bookkeeping -------------------------------------
// The machine can be asleep, have dark screens AND a locked session at the
// same time, and these end in any order. We only wake once ALL are over.
const asleep: u8 = 1;
const screens_off: u8 = 2;
const session_away: u8 = 4; // fast user switching
const locked: u8 = 8; // the lock screen
var reasons: u8 = 0;

fn setReason(bit: u8, on: bool) void {
    const was_paused = reasons != 0;
    const before = reasons;
    if (on) reasons |= bit else reasons &= ~bit;
    if (reasons != before) log.debug("pause reasons: {b:0>4}", .{reasons});
    if (reasons != 0 and !was_paused) wm.pause();
    if (reasons == 0 and was_paused) {
        // The lock notification can arrive after the wake one: ask directly.
        if (screenLocked()) {
            log.debug("woke up, but the screen is locked: staying paused", .{});
            reasons |= locked;
            return;
        }
        wm.wake();
    }
}

/// Is the lock screen up? Asked of the session directly, so it does not depend
/// on a notification having arrived. The key is only present while locked.
fn screenLocked() bool {
    const dict = c.CGSessionCopyCurrentDictionary() orelse return false;
    defer c.CFRelease(dict);
    const key: c.CFStringRef = @ptrCast(cocoa.nsString("CGSSessionScreenIsLocked").value);
    const value = c.CFDictionaryGetValue(dict, key) orelse return false;
    return c.CFBooleanGetValue(@ptrCast(value)) != 0;
}

/// The heartbeat: first notice a lock (or unlock) that no notification told us
/// about, then do the window manager's own periodic work.
fn beat() void {
    setReason(locked, screenLocked());
    wm.heartbeat();
}

// ---- Objective-C methods ---------------------------------------------------
// Cocoa calls methods as fn(self, _cmd, argument). This manufactures one such
// function per (reason, on/off) pair at compile time; zig-objc works out the
// method's type encoding from the function's signature.
fn Reason(comptime bit: u8, comptime on: bool) type {
    return struct {
        fn f(_: cocoa.id, _: cocoa.SEL, _: cocoa.id) callconv(.c) void {
            setReason(bit, on);
        }
    };
}

fn onChange(_: cocoa.id, _: cocoa.SEL, _: cocoa.id) callconv(.c) void {
    wm.requestReconcile();
}

fn onActivate(_: cocoa.id, _: cocoa.SEL, _: cocoa.id) callconv(.c) void {
    wm.requestFocusSync();
}

fn onQuit(_: cocoa.id, _: cocoa.SEL, _: cocoa.id) callconv(.c) void {
    wm.quit();
}

fn observe(center: objc.Object, delegate: objc.Object, selector: [:0]const u8, name: objc.Object) void {
    center.msgSend(void, "addObserver:selector:name:object:", .{ delegate, objc.sel(selector), name, @as(cocoa.id, null) });
}

/// A notification name that AppKit exports as a global constant.
fn named(constant: cocoa.id) objc.Object {
    return .{ .value = constant };
}

// ---- displays --------------------------------------------------------------
fn displayChanged(_: c.CGDirectDisplayID, flags: c.CGDisplayChangeSummaryFlags, _: ?*anyopaque) callconv(.c) void {
    // Called once before and once after each change; act on the "after".
    if (flags & c.kCGDisplayBeginConfigurationFlag != 0) return;
    wm.requestGeometry();
}

// ---- signals ---------------------------------------------------------------
// A signal handler may only do trivial things. So it just pokes a run-loop
// source, and the real work (putting windows back!) happens on the main loop.
var signal_source: c.CFRunLoopSourceRef = null;
var dump_source: c.CFRunLoopSourceRef = null;

fn onUsr1(_: c_int) callconv(.c) void {
    c.CFRunLoopSourceSignal(dump_source);
    c.CFRunLoopWakeUp(c.CFRunLoopGetMain());
}

fn dumpPerform(_: ?*anyopaque) callconv(.c) void {
    wm.dump();
}

fn onSignal(_: c_int) callconv(.c) void {
    c.CFRunLoopSourceSignal(signal_source);
    c.CFRunLoopWakeUp(c.CFRunLoopGetMain());
}

fn signalPerform(_: ?*anyopaque) callconv(.c) void {
    wm.quit();
}

pub fn start() void {
    const delegate_class = objc.allocateClassPair(cocoa.class("NSObject"), "ZwmDelegate").?;
    inline for (.{
        .{ "onQuit:", onQuit },
        .{ "onChange:", onChange },
        .{ "onActivate:", onActivate },
        .{ "willSleep:", Reason(asleep, true).f },
        .{ "didWake:", Reason(asleep, false).f },
        .{ "screensSleep:", Reason(screens_off, true).f },
        .{ "screensWake:", Reason(screens_off, false).f },
        .{ "sessionResign:", Reason(session_away, true).f },
        .{ "sessionActive:", Reason(session_away, false).f },
        .{ "screenLocked:", Reason(locked, true).f },
        .{ "screenUnlocked:", Reason(locked, false).f },
    }) |m| {
        if (!delegate_class.addMethod(m[0], m[1])) @panic("could not add " ++ m[0]);
    }
    objc.registerClassPair(delegate_class);
    const delegate = delegate_class.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});

    bar.init(delegate);

    const center = cocoa.sharedWorkspace().msgSend(objc.Object, "notificationCenter", .{});
    observe(center, delegate, "willSleep:", named(NSWorkspaceWillSleepNotification));
    observe(center, delegate, "didWake:", named(NSWorkspaceDidWakeNotification));
    observe(center, delegate, "screensSleep:", named(NSWorkspaceScreensDidSleepNotification));
    observe(center, delegate, "screensWake:", named(NSWorkspaceScreensDidWakeNotification));
    observe(center, delegate, "sessionResign:", named(NSWorkspaceSessionDidResignActiveNotification));
    observe(center, delegate, "sessionActive:", named(NSWorkspaceSessionDidBecomeActiveNotification));
    // The lock screen is announced on the system-wide ("distributed") center.
    const distributed = cocoa.class("NSDistributedNotificationCenter").msgSend(objc.Object, "defaultCenter", .{});
    observe(distributed, delegate, "screenLocked:", cocoa.nsString("com.apple.screenIsLocked"));
    observe(distributed, delegate, "screenUnlocked:", cocoa.nsString("com.apple.screenIsUnlocked"));
    observe(center, delegate, "onChange:", named(NSWorkspaceDidLaunchApplicationNotification));
    observe(center, delegate, "onChange:", named(NSWorkspaceDidTerminateApplicationNotification));
    observe(center, delegate, "onActivate:", named(NSWorkspaceDidActivateApplicationNotification));
    observe(center, delegate, "onChange:", named(NSWorkspaceDidHideApplicationNotification));
    observe(center, delegate, "onChange:", named(NSWorkspaceDidUnhideApplicationNotification));
    observe(center, delegate, "onChange:", named(NSWorkspaceActiveSpaceDidChangeNotification));

    _ = c.CGDisplayRegisterReconfigurationCallback(displayChanged, null);

    // Quit cleanly on Ctrl-C / `kill`, so parked windows come back.
    var ctx = std.mem.zeroes(c.CFRunLoopSourceContext);
    ctx.perform = signalPerform;
    signal_source = c.CFRunLoopSourceCreate(null, 0, &ctx);
    c.CFRunLoopAddSource(c.CFRunLoopGetMain(), signal_source, c.kCFRunLoopCommonModes);
    _ = c.signal(c.SIGINT, onSignal);
    _ = c.signal(c.SIGTERM, onSignal);
    _ = c.signal(c.SIGHUP, onSignal);

    // `pkill -USR1 zwm` prints a snapshot of the state (see log.zig).
    var dump_ctx = std.mem.zeroes(c.CFRunLoopSourceContext);
    dump_ctx.perform = dumpPerform;
    dump_source = c.CFRunLoopSourceCreate(null, 0, &dump_ctx);
    c.CFRunLoopAddSource(c.CFRunLoopGetMain(), dump_source, c.kCFRunLoopCommonModes);
    _ = c.signal(c.SIGUSR1, onUsr1);

    apps.on_event = wm.requestApp;
    hotkeys.before_action = wm.refreshFocus;
    hotkeys.run_action = wm.run;
    hotkeys.mouse_released = wm.mouseReleased;
    runloop.every(config.heartbeat, beat);
}
