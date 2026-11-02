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

//! Displays. CoreGraphics and Accessibility both put the origin at the
//! TOP-left of the primary display with y down; Cocoa (NSScreen) uses the
//! BOTTOM-left with y up, so what we take from it is flipped.
const std = @import("std");
const c = @import("c");
const objc = @import("objc");
const cocoa = @import("cocoa.zig");
const types = @import("types.zig");

pub const Info = struct {
    id: u32, // CGDirectDisplayID
    screen: types.Rect,
    area: types.Rect, // minus menu bar and Dock
};

/// Fill `out` with the displays, sorted left to right. Returns how many.
/// Returns 0 when macOS reports no displays (they all sleep during system
/// sleep); callers must keep their old state in that case.
///
/// Which displays exist and where they are comes from CoreGraphics, asked
/// afresh every time: AppKit's NSScreen keeps its own copy that can go stale
/// in a process that does not pump AppKit events. CoreGraphics already uses
/// the top-left, y-down convention, so nothing needs flipping. AppKit is only
/// asked for what CoreGraphics cannot say: the area left by the menu bar and Dock.
pub fn list(out: []Info) usize {
    var ids: [16]c.CGDirectDisplayID = undefined;
    var count: u32 = 0;
    if (c.CGGetActiveDisplayList(ids.len, &ids, &count) != c.kCGErrorSuccess) return 0;

    var n: usize = 0;
    for (ids[0..@min(count, ids.len)]) |id| {
        if (n == out.len) break;
        const screen = fromCG(c.CGDisplayBounds(id));
        out[n] = .{ .id = id, .screen = screen, .area = visibleArea(id, screen) };
        n += 1;
    }
    sortLeftToRight(out[0..n]);
    return n;
}

fn sortLeftToRight(out: []Info) void {
    // Insertion sort: n is tiny.
    var i: usize = 1;
    while (i < out.len) : (i += 1) {
        const v = out[i];
        var j = i;
        while (j > 0 and before(v, out[j - 1])) : (j -= 1) out[j] = out[j - 1];
        out[j] = v;
    }
}

/// The part of `screen` not covered by the menu bar or Dock, in the same
/// top-left convention. AppKit answers in bottom-left coordinates relative to
/// the primary display, so flip with the primary display's height. If AppKit
/// does not know this display (yet), the whole screen is usable.
fn visibleArea(id: c.CGDirectDisplayID, screen: types.Rect) types.Rect {
    const screens = cocoa.class("NSScreen").msgSend(objc.Object, "screens", .{});
    const count = screens.msgSend(usize, "count", .{});
    const primary_h = c.CGDisplayBounds(c.CGMainDisplayID()).size.height;
    const key = cocoa.nsString("NSScreenNumber");
    for (0..count) |i| {
        const s = screens.msgSend(objc.Object, "objectAtIndex:", .{i});
        const desc = s.msgSend(objc.Object, "deviceDescription", .{});
        const num = desc.msgSend(objc.Object, "objectForKey:", .{key});
        if (num.msgSend(u32, "unsignedIntValue", .{}) != id) continue;
        const area = flip(s.msgSend(cocoa.NSRect, "visibleFrame", .{}), primary_h);
        // Trust it only if it still lies within the screen CoreGraphics reports
        // (it would not, if AppKit's copy is out of date).
        if (area.x >= screen.x and area.y >= screen.y and
            area.x + area.w <= screen.x + screen.w and area.y + area.h <= screen.y + screen.h) return area;
        break;
    }
    return screen;
}

fn fromCG(r: c.CGRect) types.Rect {
    return .{ .x = toInt(r.origin.x), .y = toInt(r.origin.y), .w = toInt(r.size.width), .h = toInt(r.size.height) };
}

fn before(a: Info, b: Info) bool {
    if (a.screen.x != b.screen.x) return a.screen.x < b.screen.x;
    return a.screen.y < b.screen.y;
}

fn toInt(v: f64) i32 {
    return @intFromFloat(@round(v));
}

fn flip(r: cocoa.NSRect, primary_h: f64) types.Rect {
    return .{
        .x = toInt(r.origin.x),
        .y = toInt(primary_h - (r.origin.y + r.size.height)),
        .w = toInt(r.size.width),
        .h = toInt(r.size.height),
    };
}

test "flip converts bottom-left to top-left origin" {
    const r = flip(.{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 100, .height = 50 } }, 1000);
    try std.testing.expectEqual(@as(i32, 950), r.y);
}

test "displays are sorted left to right, then top to bottom" {
    var a = [_]Info{
        .{ .id = 2, .screen = .{ .x = 1000, .y = 0, .w = 10, .h = 10 }, .area = .{ .x = 0, .y = 0, .w = 0, .h = 0 } },
        .{ .id = 3, .screen = .{ .x = 0, .y = 500, .w = 10, .h = 10 }, .area = .{ .x = 0, .y = 0, .w = 0, .h = 0 } },
        .{ .id = 1, .screen = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .area = .{ .x = 0, .y = 0, .w = 0, .h = 0 } },
    };
    sortLeftToRight(&a);
    try std.testing.expectEqual(@as(u32, 1), a[0].id);
    try std.testing.expectEqual(@as(u32, 3), a[1].id);
    try std.testing.expectEqual(@as(u32, 2), a[2].id);
}
