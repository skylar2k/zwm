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

//! The status bar: a macOS menu-bar item (NSStatusItem) that shows dwm's tags
//! and the layout symbol of the SELECTED monitor.
//!
//!     1 2 3 4 5 6 7 8 9  []=
//!
//! Selected tags are bold, tags that hold windows are normal, empty tags are
//! dimmed. Everything here is Objective-C message sends (see cocoa.zig).
const std = @import("std");
const config = @import("config");
const objc = @import("objc");
const cocoa = @import("cocoa.zig");

extern "c" const NSForegroundColorAttributeName: cocoa.id;
extern "c" const NSFontAttributeName: cocoa.id;

var item: objc.Object = .{ .value = null }; // NSStatusItem
var button: objc.Object = .{ .value = null }; // NSStatusBarButton (the clickable text)
var visible = true;

/// `target` receives menu actions (it needs an `onQuit:` method).
pub fn init(target: objc.Object) void {
    const bar = cocoa.class("NSStatusBar").msgSend(objc.Object, "systemStatusBar", .{});
    // -1.0 = NSVariableStatusItemLength: as wide as the text needs.
    item = bar.msgSend(objc.Object, "statusItemWithLength:", .{@as(f64, -1.0)});
    _ = item.retain();
    button = item.msgSend(objc.Object, "button", .{});

    const menu = cocoa.class("NSMenu").msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    const quit = cocoa.class("NSMenuItem").msgSend(objc.Object, "alloc", .{}).msgSend(
        objc.Object,
        "initWithTitle:action:keyEquivalent:",
        .{ cocoa.nsString("Quit zwm"), objc.sel("onQuit:"), cocoa.nsString("") },
    );
    quit.msgSend(void, "setTarget:", .{target});
    menu.msgSend(void, "addItem:", .{quit});
    item.msgSend(void, "setMenu:", .{menu});
}

pub fn toggle() void {
    visible = !visible;
    item.msgSend(void, "setVisible:", .{visible});
}

/// What the bar shows, worked out by the window manager.
pub const Info = struct {
    view: u32, // tags shown (bitmask)
    occupied: u32, // tags that hold at least one window (bitmask)
    symbol: []const u8, // layout symbol of the shown tag
};

/// Redraw for the selected monitor.
pub fn update(info: Info) void {
    if (cocoa.isNil(button)) return;

    var text: [512]u8 = undefined;
    var len: usize = 0;
    const Span = struct { start: usize, len: usize, selected: bool, empty: bool };
    var spans: [config.tags.len]Span = undefined;
    var utf16_pos: usize = 0;

    inline for (config.tags, 0..) |t, i| {
        const tag = t.name;
        const bit: u32 = 1 << i;
        const u16len = std.unicode.calcUtf16LeLen(tag) catch tag.len;
        spans[i] = .{ .start = utf16_pos, .len = u16len, .selected = info.view & bit != 0, .empty = info.occupied & bit == 0 };
        len = append(&text, len, tag);
        len = append(&text, len, " ");
        utf16_pos += u16len + 1;
    }
    len = append(&text, len, " ");
    len = append(&text, len, info.symbol);
    text[len] = 0;

    const str = cocoa.class("NSMutableAttributedString").msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithString:", .{cocoa.nsString(@ptrCast(&text))});
    defer str.release();

    const NSFont = cocoa.class("NSFont");
    const NSColor = cocoa.class("NSColor");
    const font_norm = NSFont.msgSend(objc.Object, "menuBarFontOfSize:", .{@as(f64, 0)});
    const font_bold = NSFont.msgSend(objc.Object, "boldSystemFontOfSize:", .{@as(f64, 13)});
    const label = NSColor.msgSend(objc.Object, "labelColor", .{});
    const dim = NSColor.msgSend(objc.Object, "tertiaryLabelColor", .{});

    for (spans) |s| {
        const range = cocoa.NSRange{ .location = s.start, .length = s.len };
        str.msgSend(void, "addAttribute:value:range:", .{ NSFontAttributeName, if (s.selected) font_bold else font_norm, range });
        str.msgSend(void, "addAttribute:value:range:", .{ NSForegroundColorAttributeName, if (s.empty and !s.selected) dim else label, range });
    }
    button.msgSend(void, "setAttributedTitle:", .{str});
}

fn append(buf: []u8, at: usize, s: []const u8) usize {
    const n = @min(s.len, buf.len - 1 - at);
    @memcpy(buf[at..][0..n], s[0..n]);
    return at + n;
}
