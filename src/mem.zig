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

//! The allocator used by zwm. In debug builds it is Zig's DebugAllocator,
//! which remembers every allocation: when zwm quits (the menu item or the
//! quit key) anything that was never freed is reported with a stack trace,
//! and freeing something twice is caught. Release builds use plain malloc.
const std = @import("std");
const builtin = @import("builtin");

var debug_state: std.heap.DebugAllocator(.{}) = .init;

pub const gpa: std.mem.Allocator = if (builtin.mode == .debug)
    debug_state.allocator()
else
    std.heap.c_allocator;

/// Call once, at the very end, after everything has been freed.
pub fn reportLeaks() void {
    if (builtin.mode != .debug) return;
    if (debug_state.deinit() == .leak) {
        std.debug.print("zwm: memory leaks detected (see above)\n", .{});
    } else {
        std.debug.print("zwm: no memory leaks\n", .{});
    }
}
