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

//! zwm: a dwm-style tiling window manager for macOS.
//!
//! This file is the public face of the program. `config.zig` imports it as
//! `@import("zwm")` to get the types and actions it needs to build its tables.
const std = @import("std");
const c = @import("c");
const cocoa = @import("cocoa.zig");
const hotkeys = @import("hotkeys.zig");
const runloop = @import("runloop.zig");
const system = @import("system.zig");
const wm = @import("wm.zig");
const bar = @import("bar.zig");
const ax = @import("ax.zig");
const config = @import("config");
const log = @import("log.zig");

// ---- what config.zig may use ----------------------------------------------
pub const Mod = @import("keys.zig").Mod;
pub const Key = @import("keys.zig").Key;
pub const types = @import("types.zig");
pub const Action = types.Action;
pub const Bind = types.Bind;
pub const Layout = types.Layout;
pub const Params = types.Params;
pub const Rect = types.Rect;
pub const Rule = types.Rule;
pub const Tag = types.Tag;
pub const layouts = @import("layouts.zig"); // tile, monocle, centeredmaster, deck

/// An action that runs a command through /bin/sh (so `~`, pipes etc. work).
pub fn sh(comptime cmd: []const u8) Action {
    return .{ .spawn = &.{ "/bin/sh", "-c", cmd } };
}

// ---- startup ---------------------------------------------------------------

fn isTrusted(prompt: bool) bool {
    const k = [_]?*const anyopaque{c.kAXTrustedCheckOptionPrompt};
    const v = [_]?*const anyopaque{if (prompt) c.kCFBooleanTrue else c.kCFBooleanFalse};
    const dict = c.CFDictionaryCreate(null, @ptrCast(@constCast(&k)), @ptrCast(@constCast(&v)), 1, &c.kCFTypeDictionaryKeyCallBacks, &c.kCFTypeDictionaryValueCallBacks);
    defer c.CFRelease(dict);
    return c.AXIsProcessTrustedWithOptions(dict) != 0;
}

/// C's signal() with the handler as a plain integer, so we can pass SIG_IGN (1).
extern "c" fn signal(sig: c_int, handler: usize) usize;
const ignoringSignal = signal;

var print_keys_mode = false;

fn start() void {
    if (print_keys_mode) {
        if (!hotkeys.start()) std.debug.print("zwm: could not create the key tap\n", .{});
        std.debug.print("zwm: press keys to see their codes (Ctrl-C to stop)\n", .{});
        return;
    }
    ax.setGlobalTimeout(config.ax_timeout);
    system.start();
    wm.updateGeometry();
    if (!hotkeys.start()) std.debug.print("zwm: could not create the key tap; hotkeys disabled\n", .{});
    wm.reconcile();
    wm.refreshBar();
    std.debug.print("zwm: running\n", .{});
}

fn waitForTrust(_: usize) void {
    if (isTrusted(false)) start() else runloop.after(1.0, waitForTrust, 0);
}

/// See `wm.emergencyRestore`; main.zig calls this from the panic handler.
pub const emergencyRestore = wm.emergencyRestore;

pub const Options = struct {
    /// `--print-keys`: show key codes instead of managing windows.
    print_keys: bool = false,
    /// `--verbose` (or ZWM_LOG=1): log what zwm is doing.
    verbose: bool = false,
};

pub fn run(options: Options) !void {
    log.enabled = options.verbose;
    print_keys_mode = options.print_keys;
    hotkeys.print_keys = options.print_keys;

    const app = cocoa.sharedApplication();
    // Policy 1 = "accessory": no Dock icon, no app menu, just the status item.
    _ = app.msgSend(bool, "setActivationPolicy:", .{@as(isize, 1)});

    // Children we spawn must not become zombies.
    _ = ignoringSignal(c.SIGCHLD, 1); // 1 == SIG_IGN

    if (isTrusted(true)) {
        start();
    } else {
        std.debug.print(
            \\zwm: needs the Accessibility permission to move windows and read hotkeys.
            \\     System Settings > Privacy & Security > Accessibility: enable the app
            \\     you launched zwm from (e.g. Terminal). Waiting...
            \\
        , .{});
        runloop.after(1.0, waitForTrust, 0);
    }
    app.msgSend(void, "run", .{}); // never returns
}

test {
    _ = @import("keys.zig");
    _ = @import("types.zig");
    _ = @import("model.zig");
    _ = @import("layouts.zig");
    _ = @import("screens.zig");
}
