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

//! Optional debug log. Off by default; turn it on with `zwm --verbose` or by
//! setting the environment variable ZWM_LOG=1. Lines go to stderr.
//!
//! For a snapshot of everything zwm knows, send it SIGUSR1:
//!     pkill -USR1 zwm
const std = @import("std");

pub var enabled = false;

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (!enabled) return;
    std.debug.print("[zwm] " ++ fmt ++ "\n", args);
}
