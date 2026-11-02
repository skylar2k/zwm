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

//! Layout algorithms. Each is a pure function from (area, window count,
//! settings) to one rectangle per window, so they are simple to read, to write
//! your own, and to test. They know nothing about windows or macOS; `wm.arrange`
//! feeds them the tiled windows and applies the answers (plus the gap).
const std = @import("std");
const types = @import("types.zig");

const Rect = types.Rect;
const Params = types.Params;

/// Width of the master column: `mfact` thousandths of the width, rounded down.
fn masterWidth(width: i32, mfact: u32) i32 {
    return @intCast(@divFloor(@as(i64, width) * mfact, 1000));
}

/// Master area on the left, the rest stacked on the right: "[]="
pub fn tile(area: Rect, n: usize, p: Params, out: []Rect) void {
    const nmaster: usize = p.nmaster;
    const mw: i32 = if (n > nmaster)
        (if (nmaster > 0) masterWidth(area.w, p.mfact) else 0)
    else
        area.w;

    var my: i32 = 0; // y used so far in the master column
    var ty: i32 = 0; // ... and in the stack column
    for (out[0..n], 0..) |*r, i| {
        if (i < nmaster) {
            const h = @divFloor(area.h - my, @as(i32, @intCast(@min(n, nmaster) - i)));
            r.* = .{ .x = area.x, .y = area.y + my, .w = mw, .h = h };
            my += h;
        } else {
            const h = @divFloor(area.h - ty, @as(i32, @intCast(n - i)));
            r.* = .{ .x = area.x + mw, .y = area.y + ty, .w = area.w - mw, .h = h };
            ty += h;
        }
    }
}

/// The master window(s) in the middle column, the rest split between a left
/// and a right column: "|M|". Port of dwm's `centeredmaster` patch
/// (references/dwm/patches/centeredmaster.diff). With exactly one stack window
/// it behaves like `tile`. See learning/centeredmaster.md.
pub fn centeredmaster(area: Rect, n: usize, p: Params, out: []Rect) void {
    if (n == 0) return;
    const nmaster: usize = p.nmaster;

    // The three columns: [left stack] [master] [right stack]
    var mw = area.w; // master column width
    var mx: i32 = 0; // master column x offset (= width of the left column)
    var tw = mw; // width of each stack column

    if (n > nmaster) {
        // Master gets mfact of the width; the rest is shared by the stacks.
        mw = if (nmaster > 0) masterWidth(area.w, p.mfact) else 0;
        tw = area.w - mw;
        if (n - nmaster > 1) {
            // More than one stack window: use BOTH sides, centring the master.
            mx = @divFloor(area.w - mw, 2);
            tw = @divFloor(area.w - mw, 2);
        }
    }

    var my: i32 = 0; // y used so far in the master column
    var ety: i32 = 0; // ... in the left stack column
    var oty: i32 = 0; // ... in the right stack column
    for (out[0..n], 0..) |*r, i| {
        if (i < nmaster) {
            // Master windows are stacked vertically in the middle.
            const h = @divFloor(area.h - my, @as(i32, @intCast(@min(n, nmaster) - i)));
            r.* = .{ .x = area.x + mx, .y = area.y + my, .w = mw, .h = h };
            my += h;
        } else {
            // Stack windows alternate: first to the right, then left, ...
            // (1 + n - i) / 2 = how many windows are still to come in the
            // column this window is in, itself included.
            const in_column: i32 = @intCast((1 + n - i) / 2);
            if ((i - nmaster) % 2 == 1) {
                const h = @divFloor(area.h - ety, in_column);
                r.* = .{ .x = area.x, .y = area.y + ety, .w = tw, .h = h };
                ety += h;
            } else {
                const h = @divFloor(area.h - oty, in_column);
                r.* = .{ .x = area.x + mx + mw, .y = area.y + oty, .w = tw, .h = h };
                oty += h;
            }
        }
    }
}

/// The master window(s) on the left; every other window is a card in a deck on
/// the right, all in the same spot with the focused one on top: "[D]", or
/// "[k]" for k cards in the deck. Port of dwm's `deck` patch
/// (references/dwm/patches/dwm-deck-6.2.diff). See learning/deck.md.
pub fn deck(area: Rect, n: usize, p: Params, out: []Rect) void {
    const nmaster: usize = p.nmaster;
    const mw: i32 = if (n > nmaster)
        (if (nmaster > 0) masterWidth(area.w, p.mfact) else 0)
    else
        area.w;

    var my: i32 = 0; // y used so far in the master column
    for (out[0..n], 0..) |*r, i| {
        if (i < nmaster) {
            const h = @divFloor(area.h - my, @as(i32, @intCast(@min(n, nmaster) - i)));
            r.* = .{ .x = area.x, .y = area.y + my, .w = mw, .h = h };
            my += h;
        } else {
            // Every card gets the whole right-hand side.
            r.* = .{ .x = area.x + mw, .y = area.y, .w = area.w - mw, .h = area.h };
        }
    }
}

/// Every window fills the area; the focused one is raised on top: "[n]"
pub fn monocle(area: Rect, n: usize, _: Params, out: []Rect) void {
    for (out[0..n]) |*r| r.* = area;
}

// ---- tests (run with `zig build test`) ----

const screen = Rect{ .x = 0, .y = 0, .w = 1000, .h = 600 };

fn rect(x: i32, y: i32, w: i32, h: i32) Rect {
    return .{ .x = x, .y = y, .w = w, .h = h };
}

fn expectRects(want: []const Rect, f: types.ArrangeFn, nmaster: u32, mfact: u32) !void {
    var out: [8]Rect = undefined;
    f(screen, want.len, .{ .mfact = mfact, .nmaster = nmaster }, &out);
    try std.testing.expectEqualSlices(Rect, want, out[0..want.len]);
}

test "tile: one master, two in the stack" {
    try expectRects(&.{ rect(0, 0, 500, 600), rect(500, 0, 500, 300), rect(500, 300, 500, 300) }, tile, 1, 500);
}

test "tile: a lone window uses everything" {
    try expectRects(&.{rect(0, 0, 1000, 600)}, tile, 1, 500);
}

test "tile: nmaster = 0 puts everything in the stack" {
    try expectRects(&.{ rect(0, 0, 1000, 300), rect(0, 300, 1000, 300) }, tile, 0, 500);
}

test "tile: leftover pixels go to the last window, nothing is lost" {
    var out: [3]Rect = undefined;
    tile(.{ .x = 0, .y = 0, .w = 1000, .h = 601 }, 3, .{ .mfact = 500, .nmaster = 1 }, &out);
    try std.testing.expectEqual(@as(i32, 601), out[1].h + out[2].h);
}

test "monocle: everything fills the area" {
    try expectRects(&.{ screen, screen, screen }, monocle, 1, 500);
}

test "centeredmaster: one window fills the area" {
    try expectRects(&.{screen}, centeredmaster, 1, 500);
}

test "centeredmaster: one stack window behaves like tile" {
    try expectRects(&.{ rect(0, 0, 500, 600), rect(500, 0, 500, 600) }, centeredmaster, 1, 500);
}

test "centeredmaster: two stack windows go either side of the master" {
    try expectRects(&.{
        rect(250, 0, 500, 600), // master, centre
        rect(750, 0, 250, 600), // first stack window: right
        rect(0, 0, 250, 600), // second: left
    }, centeredmaster, 1, 500);
}

test "centeredmaster: stack windows alternate right, left, right, left" {
    try expectRects(&.{
        rect(250, 0, 500, 600),
        rect(750, 0, 250, 300),
        rect(0, 0, 250, 300),
        rect(750, 300, 250, 300),
        rect(0, 300, 250, 300),
    }, centeredmaster, 1, 500);
}

test "centeredmaster: an odd stack count leaves the left column one shorter" {
    try expectRects(&.{
        rect(250, 0, 500, 600),
        rect(750, 0, 250, 300),
        rect(0, 0, 250, 600),
        rect(750, 300, 250, 300),
    }, centeredmaster, 1, 500);
}

test "centeredmaster: nmaster = 2 stacks the masters in the middle" {
    try expectRects(&.{
        rect(250, 0, 500, 300),
        rect(250, 300, 500, 300),
        rect(750, 0, 250, 600),
        rect(0, 0, 250, 600),
    }, centeredmaster, 2, 500);
}

test "centeredmaster: nmaster = 0 splits everything between two columns" {
    try expectRects(&.{ rect(500, 0, 500, 300), rect(0, 0, 500, 600), rect(500, 300, 500, 300) }, centeredmaster, 0, 500);
}

test "deck: everything fits in the master area" {
    try expectRects(&.{screen}, deck, 1, 500);
}

test "deck: the other windows are cards piled on the right" {
    try expectRects(&.{
        rect(0, 0, 500, 600), // master
        rect(500, 0, 500, 600), // card
        rect(500, 0, 500, 600), // card (same spot)
    }, deck, 1, 500);
}

test "deck: nmaster = 2 stacks two masters, the rest are cards" {
    try expectRects(&.{
        rect(0, 0, 500, 300),
        rect(0, 300, 500, 300),
        rect(500, 0, 500, 600),
        rect(500, 0, 500, 600),
    }, deck, 2, 500);
}

test "deck: nmaster = 0 makes every window a full-size card" {
    try expectRects(&.{ screen, screen }, deck, 0, 500);
}

test "master width is exact where dwm's float maths is a pixel off" {
    // 0.65 * 180 is exactly 117. dwm's 32-bit float gives 116, because 0.65 is
    // stored as 0.64999998. In whole thousandths it is exact.
    try std.testing.expectEqual(@as(i32, 117), masterWidth(180, 650));
    try std.testing.expectEqual(@as(i32, 950), masterWidth(1000, 950));
    try std.testing.expectEqual(@as(i32, 1126), masterWidth(2048, 550));
}
