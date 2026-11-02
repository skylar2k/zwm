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

//! Keyboard vocabulary: which physical key (`Key`) and which modifiers (`Mod`).
const std = @import("std");

/// Modifier bits. Unlike X11's single Mod1Mask, every physical modifier key has
/// its own bit, so left and right Option can be bound separately:
///
///     Mod.lopt            only LEFT option
///     Mod.ropt            only RIGHT option
///     Mod.opt             EITHER option (left or right)
///     Mod.lopt | Mod.shift   left option + any shift
///
/// Matching rule (see `matches`): for each family (shift/ctrl/opt/cmd) the
/// binding says "none", "left", "right" or "either"; the keys you hold must
/// satisfy that exactly. So a `lopt` binding does NOT fire if you also hold
/// right option.
pub const Mod = struct {
    pub const lshift: u16 = 1 << 0;
    pub const rshift: u16 = 1 << 1;
    pub const lctrl: u16 = 1 << 2;
    pub const rctrl: u16 = 1 << 3;
    pub const lopt: u16 = 1 << 4;
    pub const ropt: u16 = 1 << 5;
    pub const lcmd: u16 = 1 << 6;
    pub const rcmd: u16 = 1 << 7;

    pub const shift: u16 = lshift | rshift;
    pub const ctrl: u16 = lctrl | rctrl;
    pub const opt: u16 = lopt | ropt;
    pub const cmd: u16 = lcmd | rcmd;

    const families = [_]u16{ shift, ctrl, opt, cmd };
};

/// Does the set of held modifiers (`held`) satisfy a binding's `want`?
pub fn matches(want: u16, held: u16) bool {
    for (Mod.families) |family| {
        const w = want & family;
        const h = held & family;
        if (w == 0) {
            if (h != 0) return false; // binding wants none of this family
        } else if (w == family) {
            if (h == 0) return false; // "either": at least one must be held
        } else {
            if (h != w) return false; // exactly this side, and only it
        }
    }
    return true;
}

/// Convert CGEventFlags into our `Mod` bits. The low bits of CGEventFlags are
/// the "device dependent" IOKit masks (NX_DEVICELSHIFTKEYMASK, ...), which is
/// what tells left from right.
pub fn modsFromFlags(flags: u64) u16 {
    const table = [_]struct { device: u64, bit: u16 }{
        .{ .device = 0x00000002, .bit = Mod.lshift },
        .{ .device = 0x00000004, .bit = Mod.rshift },
        .{ .device = 0x00000001, .bit = Mod.lctrl },
        .{ .device = 0x00002000, .bit = Mod.rctrl },
        .{ .device = 0x00000020, .bit = Mod.lopt },
        .{ .device = 0x00000040, .bit = Mod.ropt },
        .{ .device = 0x00000008, .bit = Mod.lcmd },
        .{ .device = 0x00000010, .bit = Mod.rcmd },
    };
    var out: u16 = 0;
    for (table) |e| {
        if (flags & e.device != 0) out |= e.bit;
    }
    return out;
}

/// macOS virtual key codes (kVK_ANSI_*). These name PHYSICAL keys by their
/// position on an ANSI keyboard, not the letter printed on them, so bindings
/// stay put on a Norwegian layout. Run `zwm --print-keys` to discover a code.
pub const Key = enum(u16) {
    a = 0x00, s = 0x01, d = 0x02, f = 0x03, h = 0x04, g = 0x05, z = 0x06,
    x = 0x07, c = 0x08, v = 0x09, b = 0x0B, q = 0x0C, w = 0x0D, e = 0x0E,
    r = 0x0F, y = 0x10, t = 0x11, @"1" = 0x12, @"2" = 0x13, @"3" = 0x14,
    @"4" = 0x15, @"6" = 0x16, @"5" = 0x17, equal = 0x18, @"9" = 0x19,
    @"7" = 0x1A, minus = 0x1B, @"8" = 0x1C, @"0" = 0x1D, rbracket = 0x1E,
    o = 0x1F, u = 0x20, lbracket = 0x21, i = 0x22, p = 0x23, @"return" = 0x24,
    l = 0x25, j = 0x26, quote = 0x27, k = 0x28, semicolon = 0x29,
    backslash = 0x2A, comma = 0x2B, slash = 0x2C, n = 0x2D, m = 0x2E,
    period = 0x2F, tab = 0x30, space = 0x31, grave = 0x32, delete = 0x33,
    escape = 0x35, left = 0x7B, right = 0x7C, down = 0x7D, up = 0x7E,
    _,
};

test "left/right option are told apart" {
    try std.testing.expect(matches(Mod.lopt, Mod.lopt));
    try std.testing.expect(!matches(Mod.lopt, Mod.ropt));
    try std.testing.expect(!matches(Mod.lopt, Mod.lopt | Mod.ropt));
    try std.testing.expect(matches(Mod.opt, Mod.ropt));
    try std.testing.expect(matches(Mod.opt, Mod.lopt));
    try std.testing.expect(!matches(Mod.opt, 0));
}

test "extra modifiers must not be held" {
    try std.testing.expect(matches(Mod.lopt | Mod.shift, Mod.lopt | Mod.rshift));
    try std.testing.expect(!matches(Mod.lopt, Mod.lopt | Mod.lshift));
    try std.testing.expect(!matches(Mod.lopt | Mod.shift, Mod.lopt));
}

test "device flags map to our bits" {
    // left option held: NX_DEVICELALTKEYMASK (0x20) | alternate (0x80000)
    try std.testing.expectEqual(Mod.lopt, modsFromFlags(0x80020));
    try std.testing.expectEqual(Mod.ropt | Mod.lshift, modsFromFlags(0x80040 | 0x2));
}
