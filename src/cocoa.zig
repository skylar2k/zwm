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

//! The little that zwm needs on top of `zig-objc`.
//!
//! zig-objc sends the messages: `object.msgSend(ReturnType, "selector:", .{args})`.
//! It checks the argument types while compiling (an untyped `5` is an error, you
//! write `@as(i32, 5)`), works out the call's ABI, and derives the type encoding
//! of the methods we add to classes. What is here: the structs Cocoa passes by
//! value, strings, and lookups that several files need.
const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");

comptime {
    if (builtin.cpu.arch != .aarch64) @compileError("zwm supports Apple silicon only");
}

/// The raw types of an Objective-C method's first two parameters: use these in
/// the signature of a Zig function that Cocoa will call.
pub const id = objc.c.id;
pub const SEL = objc.c.SEL;

// Structs that Cocoa passes by value. `extern` = laid out like in C.
pub const NSRange = extern struct { location: usize, length: usize };
pub const NSPoint = extern struct { x: f64, y: f64 };
pub const NSSize = extern struct { width: f64, height: f64 };
pub const NSRect = extern struct { origin: NSPoint, size: NSSize };

/// A class by name. The names used in this program are all AppKit classes, so a
/// miss means a typo: stop with a message instead of sending messages to nil.
pub fn class(comptime name: [:0]const u8) objc.Class {
    return objc.getClass(name) orelse @panic("no Objective-C class " ++ name);
}

/// An autoreleased NSString from UTF-8 bytes (must be NUL-terminated).
pub fn nsString(s: [*:0]const u8) objc.Object {
    return class("NSString").msgSend(objc.Object, "stringWithUTF8String:", .{s});
}

/// Copy an NSString into `buf` as UTF-8. Returns the slice, or null.
pub fn utf8(ns: objc.Object, buf: []u8) ?[]const u8 {
    if (ns.value == null) return null;
    const p = ns.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return null;
    const s = std.mem.span(p);
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

/// Is this object nil?
pub fn isNil(o: objc.Object) bool {
    return o.value == null;
}

/// The NSApplication of this process.
pub fn sharedApplication() objc.Object {
    return class("NSApplication").msgSend(objc.Object, "sharedApplication", .{});
}

pub fn sharedWorkspace() objc.Object {
    return class("NSWorkspace").msgSend(objc.Object, "sharedWorkspace", .{});
}

/// The NSRunningApplication with this process id, or null if there is none.
pub fn runningApplication(pid: i32) ?objc.Object {
    const app = class("NSRunningApplication").msgSend(objc.Object, "runningApplicationWithProcessIdentifier:", .{pid});
    return if (isNil(app)) null else app;
}
