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

//! zwm configuration. Like dwm's config.h, this file is compiled into the
//! program: edit it, run `zig build`, restart zwm. Mistakes (an unknown layout
//! name, two bindings on the same keys) are compile errors that say what is
//! wrong.
//!
//! Do not edit config.def.zig itself: `zig build` copies it to `config.zig`
//! the first time, and `config.zig` is the one you change.
const zwm = @import("zwm");
const Mod = zwm.Mod;

// ---- general ---------------------------------------------------------------

/// Space (in points) between windows and around them.
pub const gappx: i32 = 4;

/// Respect windows that refuse to get as small as the layout wants (dwm's
/// `resizehints`). zwm learns each window's minimum size by watching it.
pub const resizehints = true;

/// How long (seconds) to wait on an unresponsive app before giving up.
pub const ax_timeout: f32 = 0.5;

/// Safety-net full rescan interval (seconds). Window events only rescan the
/// app they came from; this catches anything a notification missed, and
/// detects waking from sleep.
pub const heartbeat: f64 = 5.0;

/// After an app stops answering, leave it alone for this long (seconds) so a
/// frozen app can't stall the window manager.
pub const unresponsive_backoff: f64 = 5.0;

/// Wait this long (seconds) after a window event so bursts are handled once.
pub const debounce: f64 = 0.05;

// ---- layouts ---------------------------------------------------------------
// The first layout is the default. Names are how tags and key bindings refer
// to a layout, so keep them unique.
pub const layouts = [_]zwm.Layout{
    .{ .name = "tile", .symbol = "[]=", .arrange = zwm.layouts.tile },
    .{ .name = "float", .symbol = "><>", .arrange = null },
    // `count` shows a window count instead of the symbol: .all = [3] (all tiled
    // windows), .stack = [2] (windows beyond the master area), .none = never.
    .{ .name = "monocle", .symbol = "[M]", .arrange = zwm.layouts.monocle, .overlap = true, .count = .all },
    .{ .name = "centered", .symbol = "|M|", .arrange = zwm.layouts.centeredmaster },
    // Master on the left, every other window a "card" piled on the right.
    .{ .name = "deck", .symbol = "[D]", .arrange = zwm.layouts.deck, .overlap = true, .count = .stack },
};

/// Starting master size (0.05 .. 0.95) and master window count of every tag.
pub const mfact: f32 = 0.55;
pub const nmaster: u32 = 1;

// ---- tags ------------------------------------------------------------------
// Shown in the menu-bar item. EVERY tag remembers its own layout, master size
// and master count (per monitor), so you can switch layout on one tag without
// disturbing the others. Optionally give a tag different starting values:
//     .{ .name = "web", .layout = "monocle" },
//     .{ .name = "term", .mfact = 0.7, .nmaster = 2 },
// Up to 9 tags are bound to keys below.
pub const tags = [_]zwm.Tag{
    .{ .name = "1" }, .{ .name = "2" }, .{ .name = "3" },
    .{ .name = "4" }, .{ .name = "5" }, .{ .name = "6" },
    .{ .name = "7" }, .{ .name = "8" }, .{ .name = "9" },
};

// ---- rules -----------------------------------------------------------------
// Matched against every new window. Find a bundle id with:
//     osascript -e 'id of app "Safari"'
// A field left out matches everything; all matching rules apply.
pub const rules = [_]zwm.Rule{
    // .bundle_id / .app_name / .title   .tags (mask)   .floating (true/false)   .monitor (0-based)
    // .startup = false: only for windows opened while zwm runs, not the ones already open when it
    //                   starts (so restarting zwm does not move them again); true: only the latter.
    // .ignore = true: never manage matching windows (they stay exactly as they are).
    // Popups, menus and tooltips that apps draw as windows are ignored automatically.
    // Windows with no fullscreen button (settings panes, About boxes, copy dialogs) float by
    // default; `.floating = false` in a rule makes one tile anyway.
    .{ .bundle_id = "com.apple.systempreferences", .floating = true },
    .{ .bundle_id = "com.apple.calculator", .floating = true },
    .{ .bundle_id = "org.mozilla.firefox", .tags = 1 << 8 }, // tag 9
};

// ---- keys ------------------------------------------------------------------
// MODKEY is a bitmask. Pick ONE of:
//     Mod.lopt   left Option only        Mod.ropt   right Option only
//     Mod.opt    either Option key       Mod.lcmd / Mod.rcmd / Mod.cmd, Mod.lctrl ...
// Combine with `|`, e.g. Mod.lopt | Mod.shift (shift may be either side).
// A binding fires only if EXACTLY the modifiers you list are held.
const MODKEY = Mod.ropt;

// Key names are physical key positions (US layout names). Run
//     zig-out/bin/zwm --print-keys
// and press a key to see its code if you are unsure.

const terminal = zwm.sh("open -a Terminal ~");

const base_keys = [_]zwm.Bind{
    // mod                       key         what it does
    .{ .mod = MODKEY | Mod.shift, .key = .@"return", .action = terminal },
    // zmenu, a dmenu-style launcher (a separate project: install it next to zwm
    // or in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin; without it these
    // two bindings do nothing). -a lists applications; -c is the centered box.
    // The menu appears on the monitor you are working on.
    .{ .mod = MODKEY, .key = .p, .action = zwm.sh("zmenu -a") },
    .{ .mod = MODKEY | Mod.shift, .key = .p, .action = zwm.sh("zmenu -a -c") },
    // Left and right Option are separate: to bind the RIGHT one, use Mod.ropt, e.g.
    //   .{ .mod = Mod.ropt, .key = .n, .action = zwm.sh("open -a Notes") },
    .{ .mod = MODKEY, .key = .b, .action = .toggle_bar },
    .{ .mod = MODKEY, .key = .j, .action = .{ .focus_stack = 1 } },
    .{ .mod = MODKEY, .key = .k, .action = .{ .focus_stack = -1 } },
    .{ .mod = MODKEY, .key = .i, .action = .{ .inc_nmaster = 1 } },
    .{ .mod = MODKEY, .key = .d, .action = .{ .inc_nmaster = -1 } },
    .{ .mod = MODKEY, .key = .h, .action = .{ .inc_mfact = -50 } }, // -5%
    .{ .mod = MODKEY, .key = .l, .action = .{ .inc_mfact = 50 } }, // +5%
    .{ .mod = MODKEY, .key = .@"return", .action = .zoom },
    .{ .mod = MODKEY, .key = .tab, .action = .view_previous },
    .{ .mod = MODKEY | Mod.shift, .key = .c, .action = .kill_client },
    .{ .mod = MODKEY, .key = .t, .action = .{ .set_layout = "tile" } },
    .{ .mod = MODKEY, .key = .f, .action = .{ .set_layout = "float" } },
    .{ .mod = MODKEY, .key = .m, .action = .{ .set_layout = "monocle" } },
    .{ .mod = MODKEY, .key = .u, .action = .{ .set_layout = "centered" } },
    .{ .mod = MODKEY, .key = .r, .action = .{ .set_layout = "deck" } },
    .{ .mod = MODKEY, .key = .space, .action = .last_layout },
    .{ .mod = MODKEY | Mod.shift, .key = .space, .action = .toggle_floating },
    .{ .mod = MODKEY, .key = .@"0", .action = .{ .view = ~@as(u32, 0) } }, // every tag
    .{ .mod = MODKEY | Mod.shift, .key = .@"0", .action = .{ .tag = ~@as(u32, 0) } },
    .{ .mod = MODKEY, .key = .comma, .action = .{ .focus_monitor = -1 } },
    .{ .mod = MODKEY, .key = .period, .action = .{ .focus_monitor = 1 } },
    .{ .mod = MODKEY | Mod.shift, .key = .comma, .action = .{ .tag_monitor = -1 } },
    .{ .mod = MODKEY | Mod.shift, .key = .period, .action = .{ .tag_monitor = 1 } },
    .{ .mod = MODKEY | Mod.shift, .key = .q, .action = .quit },
};

/// dwm's TAGKEYS macro, as a function that runs while compiling: four
/// bindings (view, toggle view, tag, toggle tag) for each tag.
fn tagKeys() [tags.len * 4]zwm.Bind {
    const digits = [_]zwm.Key{ .@"1", .@"2", .@"3", .@"4", .@"5", .@"6", .@"7", .@"8", .@"9" };
    var out: [tags.len * 4]zwm.Bind = undefined;
    for (0..tags.len) |i| {
        const bit: u32 = @as(u32, 1) << @intCast(i);
        out[i * 4 + 0] = .{ .mod = MODKEY, .key = digits[i], .action = .{ .view = bit } };
        out[i * 4 + 1] = .{ .mod = MODKEY | Mod.ctrl, .key = digits[i], .action = .{ .toggle_view = bit } };
        out[i * 4 + 2] = .{ .mod = MODKEY | Mod.shift, .key = digits[i], .action = .{ .tag = bit } };
        out[i * 4 + 3] = .{ .mod = MODKEY | Mod.ctrl | Mod.shift, .key = digits[i], .action = .{ .toggle_tag = bit } };
    }
    return out;
}

pub const keys = base_keys ++ tagKeys();
