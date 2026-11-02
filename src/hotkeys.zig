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

//! Global hotkeys via a CGEventTap: macOS lets us look at every key press
//! before any app does, and either pass it on or swallow it.
//!
//! Why not Carbon's RegisterEventHotKey? It cannot tell LEFT option from RIGHT
//! option. An event tap sees the raw modifier flags, so it can.
//!
//! Needs the Accessibility permission, same as moving windows.
const std = @import("std");
const c = @import("c");
const config = @import("config");
const keys = @import("keys.zig");
const types = @import("types.zig");
const runloop = @import("runloop.zig");

var tap: c.CFMachPortRef = null;

/// Set by system.zig while the machine sleeps / the session is locked.
pub var suspended = false;
/// Runs just before every action. wm uses it to re-read which window really has
/// focus, so an action never works on a stale selection.
pub var before_action: *const fn () void = noop;
fn noop() void {}

/// `zwm --print-keys`: print key codes instead of acting on them.
pub var print_keys = false;

/// Key presses are the point of the tap. Releasing the left mouse button is
/// also reported (the event is passed on untouched): it is the moment a window
/// drag ends, and the only moment zwm can reliably look at where it ended up.
const event_mask: u64 = (@as(u64, 1) << @intCast(c.kCGEventKeyDown)) | (@as(u64, 1) << @intCast(c.kCGEventLeftMouseUp));

/// Called when the left mouse button is released. Set by system.zig.
pub var mouse_released: *const fn () void = ignoreMouse;
fn ignoreMouse() void {}

/// Does what a binding says. Set by system.zig (it is `wm.run`).
pub var run_action: *const fn (types.Action) void = ignore;
fn ignore(_: types.Action) void {}

fn runBinding(index: usize) void {
    before_action();
    run_action(config.keys[index].action);
}

fn callback(_: c.CGEventTapProxy, kind: c.CGEventType, event: c.CGEventRef, _: ?*anyopaque) callconv(.c) c.CGEventRef {
    // macOS switches a tap off if our callback is ever too slow. Switch it back on.
    if (kind == c.kCGEventTapDisabledByTimeout or kind == c.kCGEventTapDisabledByUserInput) {
        if (tap != null) c.CGEventTapEnable(tap, true);
        return event;
    }
    if (kind == c.kCGEventLeftMouseUp) {
        mouse_released();
        return event;
    }
    if (kind != c.kCGEventKeyDown) return event;

    const code: u16 = @intCast(c.CGEventGetIntegerValueField(event, c.kCGKeyboardEventKeycode));
    const flags: u64 = c.CGEventGetFlags(event);
    const held = keys.modsFromFlags(flags);
    // True for the extra key-down events macOS sends while a key is held.
    const is_repeat = c.CGEventGetIntegerValueField(event, c.kCGKeyboardEventAutorepeat) != 0;

    if (print_keys) {
        std.debug.print("keycode 0x{x:0>2} ({d})  flags 0x{x}  mods 0x{x:0>2}{s}\n", .{ code, code, flags, held, if (is_repeat) "  (auto-repeat)" else "" });
        return event;
    }
    if (suspended) return event;

    for (config.keys, 0..) |b, i| {
        if (@intFromEnum(b.key) == code and keys.matches(b.mod, held)) {
            // A held key: swallow the repeats, but only act again if repeating
            // makes sense for this action.
            if (is_repeat and !b.action.repeatable()) return null;
            // Don't do the work inside the tap (it must return quickly):
            // schedule it for the next turn of the run loop and swallow the key.
            runloop.after(0, runBinding, i);
            return null;
        }
    }
    return event;
}

/// Create the tap. Fails (false) until the Accessibility permission is granted.
pub fn start() bool {
    if (tap != null) return true;
    tap = c.CGEventTapCreate(c.kCGSessionEventTap, c.kCGHeadInsertEventTap, c.kCGEventTapOptionDefault, event_mask, callback, null);
    if (tap == null) return false;
    const src = c.CFMachPortCreateRunLoopSource(null, tap, 0);
    c.CFRunLoopAddSource(c.CFRunLoopGetMain(), src, c.kCFRunLoopCommonModes);
    c.CFRelease(src);
    c.CGEventTapEnable(tap, true);
    return true;
}

/// Called after wake-up and by the heartbeat: make sure the tap is alive.
pub fn ensureEnabled() void {
    if (tap == null) {
        _ = start();
    } else if (!c.CGEventTapIsEnabled(tap)) {
        c.CGEventTapEnable(tap, true);
    }
}
