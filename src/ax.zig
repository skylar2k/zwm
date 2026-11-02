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

//! Thin wrappers over the macOS Accessibility (AX) C API. This is the ONLY way
//! a normal program can move, resize and focus other apps' windows.
//!
//! Memory rule of thumb: any C function with "Copy" or "Create" in its name
//! hands you something you own and must `CFRelease`.
const std = @import("std");
const c = @import("c");
const objc = @import("objc");
const cocoa = @import("cocoa.zig");
const types = @import("types.zig");

const Rect = types.Rect;

/// Private-but-widely-used API (AeroSpace, yabai, Rectangle all use it) that
/// maps an AX window to its CGWindowID, a stable id for the window.
extern "c" fn _AXUIElementGetWindow(el: c.AXUIElementRef, id: *c.CGWindowID) c.AXError;

/// CFString from a comptime literal, created once and cached forever.
/// (The `kAX...` constants in the headers are C macros that translate-c
/// can't import, so we make the strings ourselves.)
pub fn cfs(comptime s: [:0]const u8) c.CFStringRef {
    const S = struct {
        const key = s; // ties the cache to this string
        var cached: c.CFStringRef = null;
    };
    if (S.cached == null) S.cached = c.CFStringCreateWithCString(null, s, c.kCFStringEncodingUTF8);
    return S.cached;
}

fn copyAttr(el: c.AXUIElementRef, comptime name: [:0]const u8) ?c.CFTypeRef {
    var v: c.CFTypeRef = null;
    if (c.AXUIElementCopyAttributeValue(el, cfs(name), &v) != c.kAXErrorSuccess) return null;
    return v;
}

pub fn getBool(el: c.AXUIElementRef, comptime name: [:0]const u8) ?bool {
    const v = copyAttr(el, name) orelse return null;
    defer c.CFRelease(v);
    if (c.CFGetTypeID(v) != c.CFBooleanGetTypeID()) return null;
    return c.CFBooleanGetValue(@ptrCast(v)) != 0;
}

fn setBool(el: c.AXUIElementRef, comptime name: [:0]const u8, value: bool) void {
    _ = c.AXUIElementSetAttributeValue(el, cfs(name), if (value) c.kCFBooleanTrue else c.kCFBooleanFalse);
}

pub fn subroleIs(el: c.AXUIElementRef, comptime name: [:0]const u8) bool {
    const v = copyAttr(el, "AXSubrole") orelse return false;
    defer c.CFRelease(v);
    return c.CFEqual(v, cfs(name)) != 0;
}

pub fn subrole(win: c.AXUIElementRef) types.Subrole {
    if (subroleIs(win, "AXStandardWindow")) return .standard;
    if (subroleIs(win, "AXDialog")) return .dialog;
    if (subroleIs(win, "AXFloatingWindow")) return .floating;
    if (subroleIs(win, "AXSystemDialog")) return .system_dialog;
    if (subroleIs(win, "Quick Look")) return .quick_look;
    return .other;
}

/// Does the element have this attribute at all (e.g. a title-bar button)?
pub fn hasAttr(el: c.AXUIElementRef, comptime name: [:0]const u8) bool {
    const v = copyAttr(el, name) orelse return false;
    c.CFRelease(v);
    return true;
}

/// The window's AXIdentifier (apps use it to name special windows), or "".
pub fn identifier(el: c.AXUIElementRef, buf: []u8) []const u8 {
    return stringAttr(el, "AXIdentifier", buf);
}

/// The window layer macOS draws it at: 0 for ordinary windows, higher for
/// floating panels, overlays and menus. Null if macOS does not say.
pub fn windowLayer(id: u32) ?i32 {
    const list = c.CGWindowListCopyWindowInfo(c.kCGWindowListOptionIncludingWindow, id) orelse return null;
    defer c.CFRelease(list);
    if (c.CFArrayGetCount(list) < 1) return null;
    const dict: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(list, 0));
    const num = c.CFDictionaryGetValue(dict, c.kCGWindowLayer) orelse return null;
    var layer: i32 = 0;
    if (c.CFNumberGetValue(@ptrCast(num), c.kCFNumberSInt32Type, &layer) == 0) return null;
    return layer;
}

pub fn title(el: c.AXUIElementRef, buf: []u8) []const u8 {
    return stringAttr(el, "AXTitle", buf);
}

fn stringAttr(el: c.AXUIElementRef, comptime name: [:0]const u8, buf: []u8) []const u8 {
    const v = copyAttr(el, name) orelse return "";
    defer c.CFRelease(v);
    if (c.CFGetTypeID(v) != c.CFStringGetTypeID()) return "";
    if (c.CFStringGetCString(@ptrCast(v), buf.ptr, @intCast(buf.len), c.kCFStringEncodingUTF8) == 0) return "";
    return std.mem.sliceTo(buf, 0);
}

pub fn windowId(el: c.AXUIElementRef) ?u32 {
    var id: c.CGWindowID = 0;
    if (_AXUIElementGetWindow(el, &id) != c.kAXErrorSuccess or id == 0) return null;
    return id;
}

/// False once the window (or its app) is gone.
pub fn alive(el: c.AXUIElementRef) bool {
    var v: c.CFTypeRef = null;
    const err = c.AXUIElementCopyAttributeValue(el, cfs("AXRole"), &v);
    if (v != null) c.CFRelease(v);
    return err != c.kAXErrorInvalidUIElement;
}

/// Does the window have this title-bar button (AXFullScreenButton,
/// AXCloseButton, AXMinimizeButton), and is it enabled?
pub fn buttonEnabled(win: c.AXUIElementRef, comptime button: [:0]const u8) bool {
    const b = copyAttr(win, button) orelse return false;
    defer c.CFRelease(b);
    return getBool(@ptrCast(b), "AXEnabled") orelse false;
}

pub fn sizeIsSettable(el: c.AXUIElementRef) bool {
    var settable: c.Boolean = 0;
    if (c.AXUIElementIsAttributeSettable(el, cfs("AXSize"), &settable) != c.kAXErrorSuccess) return false;
    return settable != 0;
}

/// macOS gives fractional values; we round to whole points here, once.
fn toInt(v: f64) i32 {
    return @intFromFloat(@round(v));
}

pub fn getFrame(el: c.AXUIElementRef) ?Rect {
    const pv = copyAttr(el, "AXPosition") orelse return null;
    defer c.CFRelease(pv);
    const sv = copyAttr(el, "AXSize") orelse return null;
    defer c.CFRelease(sv);
    var p: c.CGPoint = undefined;
    var s: c.CGSize = undefined;
    if (c.AXValueGetValue(@ptrCast(pv), c.kAXValueTypeCGPoint, &p) == 0) return null;
    if (c.AXValueGetValue(@ptrCast(sv), c.kAXValueTypeCGSize, &s) == 0) return null;
    return .{ .x = toInt(p.x), .y = toInt(p.y), .w = toInt(s.width), .h = toInt(s.height) };
}

pub fn setPosition(el: c.AXUIElementRef, x: i32, y: i32) void {
    var p = c.CGPoint{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    const v = c.AXValueCreate(c.kAXValueTypeCGPoint, &p) orelse return;
    defer c.CFRelease(v);
    _ = c.AXUIElementSetAttributeValue(el, cfs("AXPosition"), v);
}

pub fn setSize(el: c.AXUIElementRef, w: i32, h: i32) void {
    var s = c.CGSize{ .width = @floatFromInt(w), .height = @floatFromInt(h) };
    const v = c.AXValueCreate(c.kAXValueTypeCGSize, &s) orelse return;
    defer c.CFRelease(v);
    _ = c.AXUIElementSetAttributeValue(el, cfs("AXSize"), v);
}

/// Move + resize. Size, position, size again: the first resize makes it fit on
/// the destination display, the second applies if the move clamped it.
/// Some apps animate frame changes while "AXEnhancedUserInterface" is on
/// (it makes everything laggy), so switch it off for the duration.
pub fn setFrame(app: c.AXUIElementRef, win: c.AXUIElementRef, r: Rect) void {
    const enhanced = getBool(app, "AXEnhancedUserInterface") orelse false;
    if (enhanced) setBool(app, "AXEnhancedUserInterface", false);
    setSize(win, r.w, r.h);
    setPosition(win, r.x, r.y);
    setSize(win, r.w, r.h);
    if (enhanced) setBool(app, "AXEnhancedUserInterface", true);
}

pub fn raise(win: c.AXUIElementRef) void {
    _ = c.AXUIElementPerformAction(win, cfs("AXRaise"));
}

pub fn isMinimized(win: c.AXUIElementRef) bool {
    return getBool(win, "AXMinimized") orelse false;
}

pub fn isFullscreen(win: c.AXUIElementRef) bool {
    return getBool(win, "AXFullScreen") orelse false;
}

/// Make `win` the focused window of its app and bring the app to the front.
/// `raise_it` = also pull the window above others. zwm passes false for floating
/// windows: it never reorders them.
pub fn focusWindow(app: c.AXUIElementRef, win: c.AXUIElementRef, pid: i32, raise_it: bool) void {
    setBool(win, "AXMain", true);
    if (raise_it) _ = c.AXUIElementPerformAction(win, cfs("AXRaise"));
    // Two independent ways to bring the app forward. NSRunningApplication's
    // activate sometimes doesn't take (Electron apps, in our measurements);
    // asking through Accessibility catches those.
    setBool(app, "AXFrontmost", true);
    activateApp(pid);
}

pub fn activateApp(pid: i32) void {
    const app = cocoa.runningApplication(pid) orelse return;
    // 2 = NSApplicationActivateIgnoringOtherApps
    _ = app.msgSend(bool, "activateWithOptions:", .{@as(usize, 2)});
}

/// Politely ask the window to close (press its red button).
pub fn closeWindow(win: c.AXUIElementRef) void {
    const btn = copyAttr(win, "AXCloseButton") orelse return;
    defer c.CFRelease(btn);
    _ = c.AXUIElementPerformAction(@ptrCast(btn), cfs("AXPress"));
}

pub const Windows = union(enum) {
    /// The app's windows. The caller releases the array.
    list: c.CFArrayRef,
    /// The app did not answer in time (frozen, or busy).
    unresponsive,
    /// Any other failure (e.g. the app is still starting up).
    failed,
};

/// Windows of an application.
pub fn windowsOf(app: c.AXUIElementRef) Windows {
    var v: c.CFTypeRef = null;
    const err = c.AXUIElementCopyAttributeValue(app, cfs("AXWindows"), &v);
    if (err == c.kAXErrorCannotComplete) return .unresponsive;
    if (err != c.kAXErrorSuccess) return .failed;
    if (c.CFGetTypeID(v) != c.CFArrayGetTypeID()) {
        c.CFRelease(v);
        return .failed;
    }
    return .{ .list = @ptrCast(v) };
}

/// pid of the frontmost application, if any.
pub fn frontmostPid() ?i32 {
    const front = cocoa.sharedWorkspace().msgSend(objc.Object, "frontmostApplication", .{});
    if (cocoa.isNil(front)) return null;
    return front.msgSend(i32, "processIdentifier", .{});
}

/// The focused window of application `pid` (we only learn its id).
/// Like AeroSpace: ask THAT app. (The system-wide "focused element" query looks
/// simpler but comes back empty for some apps, e.g. Electron apps right after
/// activation.)
pub fn focusedWindowId(pid: i32) ?u32 {
    const app = c.AXUIElementCreateApplication(pid);
    defer c.CFRelease(app);
    const win = copyAttr(app, "AXFocusedWindow") orelse return null;
    defer c.CFRelease(win);
    return windowId(@ptrCast(win));
}

pub fn setTimeout(el: c.AXUIElementRef, seconds: f32) void {
    _ = c.AXUIElementSetMessagingTimeout(el, seconds);
}

/// How long ANY Accessibility call may wait for an app before giving up.
/// Setting it on the system-wide element makes it the default for every
/// element we ever touch (the built-in default is 6 seconds!).
pub fn setGlobalTimeout(seconds: f32) void {
    const sys = c.AXUIElementCreateSystemWide();
    defer c.CFRelease(sys);
    _ = c.AXUIElementSetMessagingTimeout(sys, seconds);
}
