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
//
// This file contains code derived from dwm (MIT/X Consortium License);
// see THIRD_PARTY_NOTICES.

//! Types shared between the config file and the window manager: geometry,
//! layouts, tags, rules and key bindings. Everything a `config.zig` needs to
//! describe itself lives here (re-exported by zwm.zig).
//!
//! Coordinates are whole points in "AX space": origin at the top-left of the
//! primary display, y grows downwards. Whole numbers on purpose: layout maths
//! is then exact, with no rounding surprises (see learning/design.md).
const std = @import("std");
const keys = @import("keys.zig");

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn eql(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
    }
    /// Shrink by `d` on every side.
    pub fn inset(r: Rect, d: i32) Rect {
        return .{ .x = r.x + d, .y = r.y + d, .w = @max(r.w - 2 * d, 1), .h = @max(r.h - 2 * d, 1) };
    }
    pub fn contains(r: Rect, px: i32, py: i32) bool {
        return px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h;
    }
    /// Area shared by two rectangles (0 if they don't touch).
    pub fn overlapArea(a: Rect, b: Rect) i64 {
        const w = @min(a.x + a.w, b.x + b.w) - @max(a.x, b.x);
        const h = @min(a.y + a.h, b.y + b.h) - @max(a.y, b.y);
        if (w <= 0 or h <= 0) return 0;
        return @as(i64, w) * h;
    }
};

/// The settings a layout gets (they differ per tag).
pub const Params = struct {
    /// Master-area size in THOUSANDTHS of the width (550 = 55%). A whole number
    /// so `width * mfact / 1000` is exact; floats are not (0.65 is stored as
    /// 0.6499999...), and repeatedly adding 0.05 drifts.
    mfact: u32,
    /// How many windows live in the master area.
    nmaster: u32,
};

pub const mfact_min: u32 = 50; // 5%
pub const mfact_max: u32 = 950; // 95%

/// 0.55 -> 550. The only place a float becomes an integer; rounding to the
/// nearest thousandth removes the float's tiny error.
pub fn toThousandths(f: f32) i32 {
    return @intFromFloat(@round(f * 1000));
}

/// A layout is a PURE function: given the usable area, how many windows are
/// tiled and the settings, fill `out[0..n]` with one rectangle per window (in
/// order, master first). It never touches windows or macOS.
pub const ArrangeFn = *const fn (area: Rect, n: usize, p: Params, out: []Rect) void;

/// Whether (and how) a layout shows a window count in the bar.
pub const Count = enum {
    /// Always the plain symbol.
    none,
    /// The number of tiled windows: "[3]" (monocle).
    all,
    /// The number of windows beyond the master area, once there are any:
    /// "[2]" (deck). With none, the plain symbol.
    stack,
};

pub const Layout = struct {
    /// Used by key bindings and tags to refer to the layout, e.g. "monocle".
    name: []const u8,
    /// Shown in the menu-bar item, e.g. "[]=".
    symbol: []const u8,
    /// `null` = floating: zwm doesn't touch window positions.
    arrange: ?ArrangeFn,
    /// True if windows overlap (monocle): the focused one must be raised.
    overlap: bool = false,
    /// Show a window count instead of the symbol? See `Count`.
    count: Count = .none,

    /// The text for the bar, for `tiled` tiled windows and `nmaster` master slots.
    pub fn displaySymbol(self: *const Layout, tiled: usize, nmaster: u32, buf: []u8) []const u8 {
        const shown: usize = switch (self.count) {
            .none => return self.symbol,
            .all => if (tiled > 0) tiled else return self.symbol,
            .stack => if (tiled > nmaster) tiled - nmaster else return self.symbol,
        };
        return std.fmt.bufPrint(buf, "[{d}]", .{shown}) catch self.symbol;
    }
};

/// One tag (dwm's "workspace"-like label). Each tag has its OWN layout,
/// master size and master count on every monitor; the fields here are only
/// the starting values. Anything left out uses the global default.
pub const Tag = struct {
    name: []const u8,
    layout: ?[]const u8 = null, // a Layout.name
    mfact: ?f32 = null,
    nmaster: ?u32 = null,
};

/// Window rules. A match field left `null` matches everything.
pub const Rule = struct {
    /// Bundle identifier, e.g. "com.apple.finder" (substring match).
    bundle_id: ?[]const u8 = null,
    /// Localized app name, e.g. "Finder" (substring match).
    app_name: ?[]const u8 = null,
    /// Window title (substring match).
    title: ?[]const u8 = null,
    /// Tags mask to put the window on (0 = the current view).
    tags: u32 = 0,
    /// Force tiled (false) or floating (true). `null` = let zwm decide
    /// (dialogs and fixed-size windows float, everything else tiles).
    floating: ?bool = null,
    /// Monitor number (0-based, left to right), or -1 for "current".
    monitor: i32 = -1,
    /// `false`: only for windows that open while zwm is running (not the ones
    /// already open when it starts, so a restart does not move them again).
    /// `true`: only for windows already open at startup. `null`: always.
    startup: ?bool = null,
    /// Never manage matching windows: they are left exactly as they are
    /// (not tiled, not hidden on tag switches, not focus targets).
    ignore: bool = false,
};

/// What macOS says a window is (its AXSubrole), as far as zwm cares.
pub const Subrole = enum { standard, dialog, floating, system_dialog, quick_look, other };

/// Everything a key can do. Each action carries exactly the kind of value it
/// needs, and the compiler checks it: `.{ .view = 1 }` is fine, but
/// `.{ .focus_stack = "x" }` does not compile.
pub const Action = union(enum) {
    /// Run a program: program name followed by its arguments.
    spawn: []const []const u8,
    /// Show these tags (a bitmask: tag 1 = 1, tag 2 = 2, tag 3 = 4, ...).
    view: u32,
    /// Go back to the previously shown tags.
    view_previous,
    /// Add/remove these tags from what is shown.
    toggle_view: u32,
    /// Move the focused window to these tags.
    tag: u32,
    /// Add/remove these tags on the focused window.
    toggle_tag: u32,
    /// Focus the next (+1) or previous (-1) window.
    focus_stack: i32,
    /// Focus the next (+1) or previous (-1) monitor.
    focus_monitor: i32,
    /// Send the focused window to the next/previous monitor.
    tag_monitor: i32,
    /// Change the number of master windows by this much.
    inc_nmaster: i32,
    /// Change the master size by this many THOUSANDTHS (50 = 5%).
    inc_mfact: i32,
    /// Switch this tag to the layout with this name.
    set_layout: []const u8,
    /// Switch back to this tag's previous layout.
    last_layout,
    /// Swap the focused window with the master.
    zoom,
    toggle_floating,
    toggle_bar,
    kill_client,
    quit,
    /// Your own function.
    custom: *const fn () void,

    /// May holding the key down repeat this action? Only the harmless,
    /// "step by step" ones. Repeating `kill_client` would close window after
    /// window for as long as the key is held.
    pub fn repeatable(self: Action) bool {
        return switch (self) {
            .focus_stack, .focus_monitor, .inc_nmaster, .inc_mfact => true,
            else => false,
        };
    }
};

/// A key binding: hold `mod`, press `key`, do `action`.
pub const Bind = struct {
    mod: u16,
    key: keys.Key,
    action: Action,
};

test "toThousandths removes float error" {
    try std.testing.expectEqual(@as(i32, 550), toThousandths(0.55));
    try std.testing.expectEqual(@as(i32, 650), toThousandths(0.65));
}

test "only step-by-step actions repeat when a key is held" {
    try std.testing.expect((Action{ .focus_stack = 1 }).repeatable());
    try std.testing.expect((Action{ .inc_mfact = 50 }).repeatable());
    try std.testing.expect(!(Action{ .kill_client = {} }).repeatable());
    try std.testing.expect(!(Action{ .zoom = {} }).repeatable());
    try std.testing.expect(!(Action{ .view = 2 }).repeatable());
}

test "layout symbols: plain, monocle count, deck count" {
    var buf: [16]u8 = undefined;
    const plain = Layout{ .name = "t", .symbol = "[]=", .arrange = null };
    const monocle = Layout{ .name = "m", .symbol = "[M]", .arrange = null, .count = .all };
    const deck = Layout{ .name = "d", .symbol = "[D]", .arrange = null, .count = .stack };
    try std.testing.expectEqualStrings("[]=", plain.displaySymbol(5, 1, &buf));
    try std.testing.expectEqualStrings("[M]", monocle.displaySymbol(0, 1, &buf));
    try std.testing.expectEqualStrings("[3]", monocle.displaySymbol(3, 1, &buf));
    try std.testing.expectEqualStrings("[D]", deck.displaySymbol(1, 1, &buf)); // all fit in master
    try std.testing.expectEqualStrings("[D]", deck.displaySymbol(2, 2, &buf));
    try std.testing.expectEqualStrings("[3]", deck.displaySymbol(4, 1, &buf)); // 4 - 1 in the deck
}

test "rect helpers" {
    const a = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try std.testing.expectEqual(@as(i64, 25), a.overlapArea(.{ .x = 5, .y = 5, .w = 10, .h = 10 }));
    try std.testing.expectEqual(@as(i64, 0), a.overlapArea(.{ .x = 10, .y = 0, .w = 5, .h = 5 }));
    try std.testing.expect(a.contains(0, 0) and !a.contains(10, 5));
}
