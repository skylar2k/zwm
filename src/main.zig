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

const std = @import("std");
const zwm = @import("zwm");

/// If zwm panics (a bug), put parked windows back before crashing. This is
/// how a program replaces Zig's default panic behaviour: the root file
/// declares `panic`.
pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    zwm.emergencyRestore();
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var options = zwm.Options{ .verbose = std.c.getenv("ZWM_LOG") != null };
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--print-keys")) options.print_keys = true;
        if (std.mem.eql(u8, arg, "--verbose")) options.verbose = true;
    }
    try zwm.run(options);
}
