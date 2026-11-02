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
// This file contains code derived from dwm (MIT/X Consortium License) and from
// AeroSpace (MIT License); see THIRD_PARTY_NOTICES.

//! The data model: what zwm remembers about windows and monitors, and the pure
//! state changes you can make to it (switch tags, change a tag's layout...).
//! Nothing here talks to macOS, so all of it can be unit-tested.
const std = @import("std");
const c = @import("c");
const config = @import("config");
const types = @import("types.zig");

const Rect = types.Rect;
const Subrole = types.Subrole;

/// How long to leave an app alone after it stopped answering. A config may
/// omit this setting (`@hasDecl` checks at compile time), so old configs
/// keep working when zwm gains a new option.
pub const backoff_seconds: f64 = if (@hasDecl(config, "unresponsive_backoff")) config.unresponsive_backoff else 5.0;

pub const ntags = config.tags.len;
/// All valid tag bits set.
pub const tagmask: u32 = (1 << ntags) - 1;

/// Where a window physically is, as far as we know. One value instead of a
/// pile of flags, so contradictory combinations cannot exist.
pub const Placement = union(enum) {
    /// Never placed, or we want it placed again no matter what.
    unknown,
    /// Moved off-screen because its tag isn't shown.
    parked,
    /// Last rectangle we sent to the OS.
    shown: Rect,
};

pub const Client = struct {
    window: c.AXUIElementRef, // retained
    app: c.AXUIElementRef, // retained
    pid: i32,
    id: u32, // CGWindowID, stable for the life of the window
    /// The display this window belongs to (its CGDirectDisplayID). Normally the
    /// display of `mon`. If that display is unplugged or asleep the window is
    /// shown on another monitor for a while, but remembers its home and goes
    /// back when the display returns. Only the user moving it changes the home.
    home: u32 = 0,
    /// Index into the monitor array.
    mon: u8,
    tags: u32,
    floating: bool,
    /// Where it belongs while shown (tiled: the layout decides).
    rect: Rect,
    placement: Placement = .unknown,
    /// Smallest size the app accepted, learned by watching it (0 = unknown).
    min_w: i32 = 0,
    min_h: i32 = 0,
    /// Bigger = focused more recently. The "selected" window of a monitor is
    /// simply the visible one with the biggest number: nothing to keep in sync.
    focus_tick: u64 = 0,
    verifying: bool = false, // a delayed size check is pending
    seen: bool = false, // scratch flag used while reconciling
    /// The window exists but cannot be seen right now: its app is hidden
    /// (Cmd-H) or macOS does not list it (another Space, a background tab). It
    /// takes no tile and cannot be focused until it is back.
    away: bool = false,
    /// The frame the app showed right after we last corrected a window the user
    /// moved. Apps that snap to a grid never end up exactly where asked; this
    /// stops us correcting them again and again.
    accepted: ?Rect = null,
};

/// What each tag remembers, per monitor.
pub const TagSettings = struct {
    layout: u8, // index into config.layouts
    prev_layout: u8,
    mfact: u32, // thousandths
    nmaster: u32,
};

pub fn layoutIndex(name: []const u8) ?u8 {
    for (config.layouts, 0..) |l, i| {
        if (std.mem.eql(u8, l.name, name)) return @intCast(i);
    }
    return null;
}

pub const Monitor = struct {
    display_id: u32,
    screen: Rect, // whole display
    area: Rect, // usable part (no menu bar / Dock)
    /// Tags currently shown (a bitmask, never 0) and the ones before.
    view: u32 = 1,
    prev_view: u32 = 1,
    /// Layout, master size and master count of EACH tag.
    tag: [ntags]TagSettings,

    pub fn init(display_id: u32, screen: Rect, area: Rect) Monitor {
        var m = Monitor{ .display_id = display_id, .screen = screen, .area = area, .tag = undefined };
        const other: u8 = @intCast(1 % config.layouts.len);
        for (config.tags, 0..) |t, i| {
            const lt: u8 = if (t.layout) |name| layoutIndex(name).? else 0;
            m.tag[i] = .{
                .layout = lt,
                .prev_layout = if (lt == other) 0 else other,
                .mfact = @intCast(types.toThousandths(t.mfact orelse config.mfact)),
                .nmaster = t.nmaster orelse config.nmaster,
            };
        }
        return m;
    }

    /// The settings in effect: those of the LOWEST shown tag. (With several
    /// tags shown at once there is only one layout, and this picks which.)
    pub fn settings(self: *Monitor) *TagSettings {
        return &self.tag[@ctz(self.view)];
    }

    pub fn layout(self: *const Monitor) *const types.Layout {
        return &config.layouts[self.tag[@ctz(self.view)].layout];
    }

    pub fn params(self: *const Monitor) types.Params {
        const s = self.tag[@ctz(self.view)];
        return .{ .mfact = s.mfact, .nmaster = s.nmaster };
    }

    // Each change returns true if something actually changed.

    pub fn viewTo(self: *Monitor, mask: u32) bool {
        const new = mask & tagmask;
        if (new == 0 or new == self.view) return false;
        self.prev_view = self.view;
        self.view = new;
        return true;
    }

    pub fn viewPrevious(self: *Monitor) bool {
        if (self.prev_view == self.view) return false;
        std.mem.swap(u32, &self.view, &self.prev_view);
        return true;
    }

    pub fn toggleView(self: *Monitor, mask: u32) bool {
        const new = self.view ^ (mask & tagmask);
        if (new == 0) return false; // never show nothing
        self.view = new;
        return true;
    }

    pub fn setLayout(self: *Monitor, index: u8) bool {
        const s = self.settings();
        if (index == s.layout) return false;
        s.prev_layout = s.layout;
        s.layout = index;
        return true;
    }

    pub fn lastLayout(self: *Monitor) bool {
        const s = self.settings();
        if (s.layout == s.prev_layout) return false;
        std.mem.swap(u8, &s.layout, &s.prev_layout);
        return true;
    }

    pub fn incNmaster(self: *Monitor, delta: i32) bool {
        const s = self.settings();
        const new: u32 = @intCast(@max(@as(i32, @intCast(s.nmaster)) + delta, 0));
        if (new == s.nmaster) return false;
        s.nmaster = new;
        return true;
    }

    /// `delta` is in thousandths (50 = 5%). Refuses to leave 5%..95%.
    pub fn incMfact(self: *Monitor, delta: i32) bool {
        const s = self.settings();
        const new = @as(i32, @intCast(s.mfact)) + delta;
        if (new < types.mfact_min or new > types.mfact_max) return false;
        s.mfact = @intCast(new);
        return true;
    }
};

/// What identifies a display when matching the displays we knew to the ones
/// macOS lists now.
pub const DisplayKey = struct { id: u32, w: i32, h: i32 };

/// Displays disappear and come back all the time (sleep, wake, a cable, a dock),
/// so zwm must not forget a monitor the moment it is missing. For every display
/// listed NOW (`now`), say which display we KNEW (`known`: connected ones, then
/// ones remembered from earlier) it is, as an index into `known`, or null if it
/// is new. First by display id; a re-plugged display often gets a NEW id, so
/// any still-unmatched ones are paired by size (first come, first served).
pub fn matchDisplays(known: []const DisplayKey, now: []const DisplayKey, out: []?usize) void {
    var taken: [32]bool = @splat(false);
    for (now, 0..) |n, i| {
        out[i] = null;
        for (known, 0..) |k, j| {
            if (!taken[j] and k.id == n.id) {
                out[i] = j;
                taken[j] = true;
                break;
            }
        }
    }
    for (now, 0..) |n, i| {
        if (out[i] != null) continue;
        for (known, 0..) |k, j| {
            if (!taken[j] and k.w == n.w and k.h == n.h) {
                out[i] = j;
                taken[j] = true;
                break;
            }
        }
    }
}

/// What zwm remembers about a window it lost track of, so that if the SAME
/// window (same window id) shows up again, it gets its tags, monitor and size
/// limits back instead of being treated as a brand-new window. This is the
/// safety net for when macOS's Accessibility answers wrongly (the lock screen,
/// for one): it works whatever the timing, like AeroSpace's closed-windows
/// cache. Entries never expire: window ids are not reused while the Mac is up,
/// so a returning id IS that window, and an entry nobody asks for costs nothing.
pub const Tomb = struct {
    id: u32,
    tags: u32,
    home: u32,
    floating: bool,
    min_w: i32,
    min_h: i32,
};

pub const Graveyard = struct {
    tombs: [256]Tomb = undefined,
    count: usize = 0,
    next: usize = 0, // where the next one goes once the ring is full (oldest first)

    pub fn bury(self: *Graveyard, t: Tomb) void {
        for (self.tombs[0..self.count]) |*existing| {
            if (existing.id == t.id) {
                existing.* = t;
                return;
            }
        }
        if (self.count < self.tombs.len) {
            self.tombs[self.count] = t;
            self.count += 1;
        } else {
            self.tombs[self.next] = t;
            self.next = (self.next + 1) % self.tombs.len;
        }
    }

    /// Take back what was remembered about window `id`, if anything was.
    pub fn exhume(self: *Graveyard, id: u32) ?Tomb {
        for (self.tombs[0..self.count], 0..) |t, i| {
            if (t.id != id) continue;
            self.tombs[i] = self.tombs[self.count - 1]; // remove it
            self.count -= 1;
            return t;
        }
        return null;
    }
};

/// What `floatsByDefault` looks at: which of the window's title-bar buttons
/// exist and are enabled.
pub const WindowTraits = struct {
    bundle_id: []const u8,
    fullscreen_button: bool,
    close_button: bool,
    minimize_button: bool,
};

/// What zwm does with a window.
pub const Kind = enum {
    tile,
    float,
    /// Not really a window (a menu, a tooltip, a popup pill): leave it alone.
    ignore,
};

/// Everything `classify` looks at, read from Accessibility by the caller so that
/// the decision itself is a plain function that can be tested.
pub const WindowAttrs = struct {
    bundle_id: []const u8,
    title: []const u8,
    identifier: []const u8,
    subrole: Subrole,
    size_settable: bool,
    /// The title-bar buttons that exist (whether enabled or not).
    has_close: bool,
    has_fullscreen: bool,
    has_zoom: bool,
    has_minimize: bool,
    /// ... and which of them are enabled.
    close_enabled: bool,
    fullscreen_enabled: bool,
    minimize_enabled: bool,
    /// The window is focused, is its app's main window, or its focused window.
    active: bool,
    /// The layer macOS draws it at (0 = ordinary windows).
    layer: i32 = 0,
};

/// Apps for which a window not on the ordinary layer is an overlay or panel,
/// not a window (AeroSpace's list of cases found in the wild).
const layer_checked_apps = [_][]const u8{
    "com.tinyspeck.slackmacgap", "com.google.Chrome",   "org.mozilla.firefox", "org.mozilla.nightly",
    "app.zen-browser",           "com.brave.Browser",   "com.timpler.screenstudio", "pl.maketheweb.cleanshotx",
    "com.googlecode.iterm2",     "com.microsoft.Outlook", "com.openai.codex", "com.electron.wispr-flow",
};

/// Does `classify` want the window layer for this app? (Reading it costs a call.)
pub fn checksLayer(bundle_id: []const u8) bool {
    for (layer_checked_apps) |app| {
        if (std.mem.startsWith(u8, bundle_id, app)) return true;
    }
    return false;
}

/// Is this a popup rather than a window? Menus, tooltips, the Sonoma keyboard
/// layout switcher, screen-sharing pills, Emacs child frames, quick terminals.
/// They have no title-bar buttons and are not the window you are working in; a
/// real window with no buttons (a file picker, an image viewer) is the one you
/// are working in. (AeroSpace's `isWindowHeuristic`, which lists the real cases
/// each line is for.)
fn isPopup(a: WindowAttrs) bool {
    const id = a.bundle_id;
    if (a.layer != 0 and checksLayer(id)) return true;
    // Position and size of these are managed by the apps themselves.
    if (std.mem.eql(u8, id, "com.mitchellh.ghostty") and std.mem.eql(u8, a.identifier, "com.mitchellh.ghostty.quickTerminal")) return true;
    if (std.mem.eql(u8, id, "com.apple.dt.Xcode") and std.mem.eql(u8, a.identifier, "open_quickly")) return true;
    if (std.mem.startsWith(u8, id, "com.googlecode.iterm2") and !a.has_fullscreen) return true;
    if (std.mem.eql(u8, id, "org.gnu.Emacs") and a.subrole == .floating) return true;

    const any_button = a.has_close or a.has_fullscreen or a.has_zoom or a.has_minimize;
    const firefox = std.mem.startsWith(u8, id, "org.mozilla.firefox") or
        std.mem.startsWith(u8, id, "org.mozilla.nightly") or std.mem.startsWith(u8, id, "app.zen-browser");
    // Firefox tooltips and menus look like any subrole: judge by buttons and focus.
    if (firefox) return !(any_button or a.active or a.subrole == .standard);

    // A window with no buttons, not in use, not standard, and with no real
    // title (the screen-share pill is titled "Window") is a popup.
    if (!any_button and !a.active and a.subrole != .standard and (a.title.len == 0 or std.mem.eql(u8, a.title, "Window"))) return true;
    return switch (a.subrole) {
        .standard, .dialog, .floating, .system_dialog => false,
        .quick_look => !std.mem.eql(u8, id, "com.apple.finder"),
        .other => true, // Chrome's find bar and the login window are "AXUnknown"
    };
}

/// Tile, float or ignore? Dialogs, fixed-size windows and windows not meant to
/// be big float (like dwm's transients); popups are left alone. A rule can
/// still override each of these.
pub fn classify(a: WindowAttrs) Kind {
    if (isPopup(a)) return .ignore;
    if (a.subrole != .standard or !a.size_settable) return .float;
    const floats = floatsByDefault(.{
        .bundle_id = a.bundle_id,
        .fullscreen_button = a.fullscreen_enabled,
        .close_button = a.close_enabled,
        .minimize_button = a.minimize_enabled,
    });
    return if (floats) .float else .tile;
}

/// Tabs of a native tabbed window are windows of their own: switching tab, the
/// old one drops out of the app's window list and the new one appears. Exactly
/// one of each in a single scan is a tab switch, not a window closing and
/// another opening: the new one takes over the old one's place.
pub fn isTabSwap(vanished: usize, appeared: usize) bool {
    return vanished == 1 and appeared == 1;
}

fn attrs(id: []const u8, subrole: Subrole) WindowAttrs {
    return .{
        .bundle_id = id, .title = "", .identifier = "", .subrole = subrole, .size_settable = true,
        .has_close = true, .has_fullscreen = true, .has_zoom = true, .has_minimize = true,
        .close_enabled = true, .fullscreen_enabled = true, .minimize_enabled = true, .active = false,
    };
}

fn buttonless(a: WindowAttrs) WindowAttrs {
    var b = a;
    b.has_close = false;
    b.has_fullscreen = false;
    b.has_zoom = false;
    b.has_minimize = false;
    b.close_enabled = false;
    b.fullscreen_enabled = false;
    b.minimize_enabled = false;
    return b;
}

test "ordinary windows tile; fixed-size and dialog windows float" {
    try std.testing.expectEqual(Kind.tile, classify(attrs("com.apple.Safari", .standard)));
    var fixed = attrs("com.apple.Safari", .standard);
    fixed.size_settable = false;
    try std.testing.expectEqual(Kind.float, classify(fixed));
    try std.testing.expectEqual(Kind.float, classify(attrs("com.apple.TextEdit", .dialog)));
    var settings = attrs("com.apple.systempreferences", .standard);
    settings.fullscreen_enabled = false;
    try std.testing.expectEqual(Kind.float, classify(settings));
}

test "popups with no buttons that nobody is using are ignored" {
    // Sonoma keyboard layout switcher, IntelliJ context menu: AXDialog, no buttons, no title.
    try std.testing.expectEqual(Kind.ignore, classify(buttonless(attrs("com.apple.controlcenter", .dialog))));
    // Screen-sharing pill: titled "Window".
    var pill = buttonless(attrs("com.apple.screencaptureui", .dialog));
    pill.title = "Window";
    try std.testing.expectEqual(Kind.ignore, classify(pill));
    // Chrome's find bar and the login window are AXUnknown.
    try std.testing.expectEqual(Kind.ignore, classify(attrs("com.google.Chrome", .other)));
}

test "buttonless windows you are working in stay windows" {
    // macOS file picker: AXDialog, in use.
    var picker = buttonless(attrs("com.apple.TextEdit", .dialog));
    picker.active = true;
    try std.testing.expectEqual(Kind.float, classify(picker));
    // Telegram's image viewer: AXFloatingWindow, in use.
    var viewer = buttonless(attrs("ru.keepcoder.Telegram", .floating));
    viewer.active = true;
    try std.testing.expectEqual(Kind.float, classify(viewer));
    // Finder's Quick Look preview.
    var ql = buttonless(attrs("com.apple.finder", .quick_look));
    ql.active = true;
    try std.testing.expectEqual(Kind.float, classify(ql));
    try std.testing.expectEqual(Kind.ignore, classify(buttonless(attrs("com.example.other", .quick_look))));
    // A buttonless standard window (a terminal with a hidden title bar) tiles if the app is known for it.
    var term = buttonless(attrs("org.alacritty", .standard));
    term.title = "zsh";
    try std.testing.expectEqual(Kind.tile, classify(term));
}

test "app-specific popups" {
    var quick = attrs("com.mitchellh.ghostty", .standard);
    quick.identifier = "com.mitchellh.ghostty.quickTerminal";
    try std.testing.expectEqual(Kind.ignore, classify(quick));
    try std.testing.expectEqual(Kind.tile, classify(attrs("com.mitchellh.ghostty", .standard)));
    var emacs = attrs("org.gnu.Emacs", .floating);
    emacs.has_close = false;
    try std.testing.expectEqual(Kind.ignore, classify(emacs));
    var xcode = attrs("com.apple.dt.Xcode", .standard);
    xcode.identifier = "open_quickly";
    try std.testing.expectEqual(Kind.ignore, classify(xcode));
    // An overlay layer in Chrome is not a window; in an unlisted app the layer is not consulted.
    var overlay = attrs("com.google.Chrome", .standard);
    overlay.layer = 25;
    try std.testing.expectEqual(Kind.ignore, classify(overlay));
    var other = attrs("com.apple.Safari", .standard);
    other.layer = 25;
    try std.testing.expectEqual(Kind.tile, classify(other));
    // Firefox: a tooltip is ignored, picture-in-picture floats.
    try std.testing.expectEqual(Kind.ignore, classify(buttonless(attrs("org.mozilla.firefox", .other))));
    var pip = attrs("org.mozilla.firefox", .standard);
    pip.minimize_enabled = false;
    try std.testing.expectEqual(Kind.float, classify(pip));
}

test "a tab switch is one window gone and one appeared" {
    try std.testing.expect(isTabSwap(1, 1));
    try std.testing.expect(!isTabSwap(0, 1)); // a new window
    try std.testing.expect(!isTabSwap(1, 0)); // a closed window
    try std.testing.expect(!isTabSwap(2, 1));
    try std.testing.expect(!isTabSwap(1, 2));
}

/// Apps whose windows have no (enabled) fullscreen button although they are
/// ordinary windows: they hide the title bar, or are built that way. Taken from
/// AeroSpace's list of cases found in the wild.
const no_fullscreen_button_ok = [_][]const u8{
    "org.gimp", "com.google.Chrome", "com.apple.ActivityMonitor", "org.alacritty",
    "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.qutebrowser", "com.googlecode.iterm2",
    "org.gnu.Emacs", "com.microsoft.VSCode", "com.vscodium", "com.valvesoftware.steam",
};

/// A standard window that is not meant to be big floats: settings panes, "About"
/// boxes, copy dialogs, the calculator. The tell is a missing or disabled
/// fullscreen button. (AeroSpace's `isDialogHeuristic`; a rule with `.floating`
/// overrides this.)
pub fn floatsByDefault(t: WindowTraits) bool {
    const id = t.bundle_id;
    // Firefox's picture-in-picture window is the one without a minimize button.
    const firefox = std.mem.startsWith(u8, id, "org.mozilla.firefox") or
        std.mem.startsWith(u8, id, "org.mozilla.nightly") or std.mem.startsWith(u8, id, "app.zen-browser");
    if (firefox and !t.minimize_button) return true;
    // Ghostty can hide its title bar (no buttons at all): that is a normal
    // window. A window with a close button but no fullscreen button is a popup.
    if (std.mem.eql(u8, id, "com.mitchellh.ghostty")) return !t.fullscreen_button and t.close_button;
    if (t.fullscreen_button) return false;
    for (no_fullscreen_button_ok) |ok| {
        if (std.mem.startsWith(u8, id, ok)) return false;
    }
    return true;
}

test "windows without a fullscreen button float, except known buttonless apps" {
    const t = struct {
        fn of(id: []const u8, fs: bool, close: bool, min: bool) WindowTraits {
            return .{ .bundle_id = id, .fullscreen_button = fs, .close_button = close, .minimize_button = min };
        }
    }.of;
    try std.testing.expect(!floatsByDefault(t("com.apple.Safari", true, true, true)));
    try std.testing.expect(floatsByDefault(t("com.apple.systempreferences", false, true, true)));
    try std.testing.expect(floatsByDefault(t("com.apple.calculator", false, true, true)));
    try std.testing.expect(!floatsByDefault(t("org.alacritty", false, false, false))); // buttonless terminal
    try std.testing.expect(!floatsByDefault(t("com.google.Chrome", false, true, true)));
    // Ghostty: hidden title bar tiles, a dialog-like window floats.
    try std.testing.expect(!floatsByDefault(t("com.mitchellh.ghostty", false, false, false)));
    try std.testing.expect(floatsByDefault(t("com.mitchellh.ghostty", false, true, true)));
    try std.testing.expect(!floatsByDefault(t("com.mitchellh.ghostty", true, true, true)));
    // Firefox picture-in-picture
    try std.testing.expect(floatsByDefault(t("org.mozilla.firefox", true, true, false)));
    try std.testing.expect(!floatsByDefault(t("org.mozilla.firefox", true, true, true)));
}

/// Where programs started by zwm look for programs. Apps started from the
/// bundle or a login item get a minimal PATH, which would hide tools you
/// installed yourself (zmenu, for one), so: zwm's own folder first (programs
/// installed next to it), then the PATH zwm got, then the usual places for
/// user-installed tools if they are not in it already.
pub fn searchPath(a: std.mem.Allocator, exe_dir: []const u8, current: ?[]const u8, home: []const u8) ![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const add = struct {
        fn f(list: *std.ArrayList(u8), alloc: std.mem.Allocator, dir: []const u8) !void {
            if (dir.len == 0) return;
            var it = std.mem.tokenizeScalar(u8, list.items, ':');
            while (it.next()) |have| {
                if (std.mem.eql(u8, have, dir)) return;
            }
            if (list.items.len > 0) try list.append(alloc, ':');
            try list.appendSlice(alloc, dir);
        }
    }.f;
    try add(&out, a, exe_dir);
    // The existing PATH is kept as it is, entry by entry.
    var it = std.mem.tokenizeScalar(u8, current orelse "/usr/bin:/bin:/usr/sbin:/sbin", ':');
    while (it.next()) |dir| try add(&out, a, dir);
    if (home.len > 0) {
        const local = try std.fmt.allocPrint(a, "{s}/.local/bin", .{home});
        defer a.free(local);
        try add(&out, a, local);
    }
    try add(&out, a, "/opt/homebrew/bin");
    try add(&out, a, "/usr/local/bin");
    return out.toOwnedSliceSentinel(a, 0);
}

test "programs started by zwm find tools installed in the usual places" {
    const a = std.testing.allocator;
    const p = try searchPath(a, "/Apps/zwm.app/Contents/MacOS", "/usr/bin:/bin", "/Users/me");
    defer a.free(p);
    try std.testing.expectEqualStrings("/Apps/zwm.app/Contents/MacOS:/usr/bin:/bin:/Users/me/.local/bin:/opt/homebrew/bin:/usr/local/bin", p);
}

test "searchPath adds nothing twice and copes with a missing PATH or HOME" {
    const a = std.testing.allocator;
    const p = try searchPath(a, "/opt/homebrew/bin", "/usr/local/bin:/opt/homebrew/bin:/bin", "");
    defer a.free(p);
    try std.testing.expectEqualStrings("/opt/homebrew/bin:/usr/local/bin:/bin", p);
    const q = try searchPath(a, "", null, "");
    defer a.free(q);
    try std.testing.expectEqualStrings("/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", q);
}

pub const max_monitors = 8;

/// A display as macOS lists it now.
pub const Display = struct { id: u32, screen: Rect, area: Rect };

/// After `applyDisplays`: where each display we knew (by its OLD id) is now.
pub const Remap = struct {
    from_id: [2 * max_monitors]u32 = undefined,
    to_index: [2 * max_monitors]u8 = undefined,
    count: usize = 0,

    /// Index of the monitor now standing for the display that used to have `old_id`,
    /// or null if that display is not connected.
    pub fn find(self: *const Remap, old_id: u32) ?usize {
        for (self.from_id[0..self.count], self.to_index[0..self.count]) |f, t| {
            if (f == old_id) return t;
        }
        return null;
    }
};

/// Update the list of connected monitors (`live`) from the displays macOS lists
/// now, without forgetting displays that are only missing for a moment:
/// a monitor that did not come back moves to `ghosts` with all its settings, and
/// is brought back, settings and all, when its display returns (matched by id,
/// else by size; see `matchDisplays`).
pub fn applyDisplays(
    live: *[max_monitors]Monitor,
    nlive: *usize,
    ghosts: *[max_monitors]Monitor,
    nghosts: *usize,
    displays: []const Display,
    remap: *Remap,
) void {
    // Everything we know about: connected monitors, then remembered ones.
    var cand: [2 * max_monitors]Monitor = undefined;
    var nc: usize = 0;
    for (live[0..nlive.*]) |m| {
        cand[nc] = m;
        nc += 1;
    }
    for (ghosts[0..nghosts.*]) |m| {
        cand[nc] = m;
        nc += 1;
    }
    var known: [2 * max_monitors]DisplayKey = undefined;
    for (cand[0..nc], 0..) |m, j| known[j] = .{ .id = m.display_id, .w = m.screen.w, .h = m.screen.h };
    var now: [max_monitors]DisplayKey = undefined;
    for (displays, 0..) |d, i| now[i] = .{ .id = d.id, .w = d.screen.w, .h = d.screen.h };
    var match: [max_monitors]?usize = undefined;
    matchDisplays(known[0..nc], now[0..displays.len], match[0..displays.len]);

    remap.count = 0;
    var used: [2 * max_monitors]bool = @splat(false);
    for (displays, 0..) |d, i| {
        if (match[i]) |j| {
            used[j] = true;
            remap.from_id[remap.count] = cand[j].display_id;
            remap.to_index[remap.count] = @intCast(i);
            remap.count += 1;
            live[i] = cand[j]; // keeps its view and per-tag settings
            live[i].display_id = d.id;
            live[i].screen = d.screen;
            live[i].area = d.area;
        } else {
            live[i] = Monitor.init(d.id, d.screen, d.area);
        }
    }
    nlive.* = displays.len;

    nghosts.* = 0;
    for (cand[0..nc], 0..) |m, j| {
        if (used[j] or nghosts.* == max_monitors) continue;
        ghosts[nghosts.*] = m;
        nghosts.* += 1;
    }
}

/// Which monitor does a window that zwm has just noticed belong to?
///
///  * A rule with a valid `.monitor` wins.
///  * A window that appears while zwm is running goes to the SELECTED monitor,
///    wherever macOS happened to draw it (this is dwm's behaviour: new windows
///    open on the monitor you are working on). So after "focus next monitor"
///    a newly started program opens there, even if macOS put it elsewhere.
///  * Windows that already exist when zwm starts stay on the monitor they are
///    on (`on_monitor`), or the selected one if they are off every display.
pub fn monitorForNewWindow(
    startup_scan: bool,
    selected: usize,
    on_monitor: ?usize,
    rule_monitor: i32,
    monitor_count: usize,
) usize {
    if (rule_monitor >= 0 and @as(usize, @intCast(rule_monitor)) < monitor_count) return @intCast(rule_monitor);
    if (startup_scan) return on_monitor orelse selected;
    return selected;
}

// ---- the config is checked while compiling ---------------------------------
// A typo in config.zig becomes a compile error with a readable message
// instead of a key that silently does nothing.
comptime {
    @setEvalBranchQuota(200_000);
    if (ntags == 0 or ntags > 31) @compileError("config.tags needs between 1 and 31 tags");
    if (config.layouts.len == 0) @compileError("config.layouts needs at least one layout");
    const global_mfact = types.toThousandths(config.mfact);
    if (global_mfact < types.mfact_min or global_mfact > types.mfact_max)
        @compileError("config.mfact must be between 0.05 and 0.95");
    for (config.tags) |t| {
        if (t.layout) |name| {
            if (layoutIndex(name) == null) @compileError("tag \"" ++ t.name ++ "\" uses an unknown layout: " ++ name);
        }
    }
    for (config.keys, 0..) |b, i| {
        switch (b.action) {
            .set_layout => |name| {
                if (layoutIndex(name) == null) @compileError("a key binding uses an unknown layout: " ++ name);
            },
            else => {},
        }
        for (config.keys[0..i]) |earlier| {
            if (earlier.mod == b.mod and earlier.key == b.key)
                @compileError("two key bindings use the same keys: " ++ @tagName(b.key));
        }
    }
}

// ---- tests -------------------------------------------------------------------

fn testMonitor() Monitor {
    const r = Rect{ .x = 0, .y = 0, .w = 1000, .h = 600 };
    return Monitor.init(1, r, r);
}

test "every tag has its own layout" {
    var m = testMonitor();
    const tile = layoutIndex("tile").?;
    const monocle = layoutIndex("monocle").?;
    try std.testing.expectEqual(tile, m.settings().layout);

    try std.testing.expect(m.setLayout(monocle)); // tag 1 -> monocle
    try std.testing.expectEqual(monocle, m.settings().layout);

    try std.testing.expect(m.viewTo(2)); // go to tag 2
    try std.testing.expectEqual(tile, m.settings().layout); // still the default

    try std.testing.expect(m.viewTo(1)); // back to tag 1
    try std.testing.expectEqual(monocle, m.settings().layout); // remembered
}

test "every tag has its own master size and count" {
    var m = testMonitor();
    try std.testing.expect(m.incMfact(100));
    try std.testing.expect(m.incNmaster(2));
    const here = m.params();
    _ = m.viewTo(4); // tag 3
    try std.testing.expect(m.params().mfact != here.mfact);
    try std.testing.expect(m.params().nmaster != here.nmaster);
    _ = m.viewTo(1);
    try std.testing.expectEqual(here, m.params());
}

test "with several tags shown, the lowest tag's settings apply" {
    var m = testMonitor();
    const monocle = layoutIndex("monocle").?;
    _ = m.viewTo(4); // tag 3
    _ = m.setLayout(monocle);
    _ = m.viewTo(2 | 4); // tags 2 and 3 together
    try std.testing.expect(m.layout().arrange != null);
    try std.testing.expectEqual(layoutIndex("tile").?, m.settings().layout); // tag 2's
    _ = m.viewTo(4 | 8); // tags 3 and 4: lowest is 3
    try std.testing.expectEqual(monocle, m.settings().layout);
}

test "viewing: previous, toggle, never empty" {
    var m = testMonitor();
    _ = m.viewTo(4);
    try std.testing.expect(m.viewPrevious());
    try std.testing.expectEqual(@as(u32, 1), m.view);
    try std.testing.expect(m.viewPrevious());
    try std.testing.expectEqual(@as(u32, 4), m.view);
    try std.testing.expect(m.toggleView(1));
    try std.testing.expectEqual(@as(u32, 5), m.view);
    try std.testing.expect(m.toggleView(1));
    try std.testing.expect(!m.toggleView(4)); // would leave nothing shown
    try std.testing.expectEqual(@as(u32, 4), m.view);
    try std.testing.expect(!m.viewTo(0));
    try std.testing.expect(!m.viewTo(4));
}

test "last layout swaps back and forth" {
    var m = testMonitor();
    const monocle = layoutIndex("monocle").?;
    const tile = layoutIndex("tile").?;
    _ = m.setLayout(monocle);
    try std.testing.expect(m.lastLayout());
    try std.testing.expectEqual(tile, m.settings().layout);
    try std.testing.expect(m.lastLayout());
    try std.testing.expectEqual(monocle, m.settings().layout);
}

test "master size never drifts and stays within limits" {
    var m = testMonitor();
    const start = m.settings().mfact;
    for (0..7) |_| _ = m.incMfact(50);
    for (0..7) |_| _ = m.incMfact(-50);
    try std.testing.expectEqual(start, m.settings().mfact); // exact, unlike floats
    while (m.incMfact(50)) {}
    try std.testing.expect(m.settings().mfact <= types.mfact_max);
    try std.testing.expect(!m.incMfact(50));
}

test "nmaster cannot go below zero" {
    var m = testMonitor();
    _ = m.incNmaster(-5);
    try std.testing.expectEqual(@as(u32, 0), m.settings().nmaster);
    try std.testing.expect(!m.incNmaster(-1));
}

fn key(id: u32, w: i32, h: i32) DisplayKey {
    return .{ .id = id, .w = w, .h = h };
}

test "displays are matched by id" {
    const known = [_]DisplayKey{ key(1, 1512, 982), key(19, 5120, 1440) };
    var out: [2]?usize = undefined;
    matchDisplays(&known, &.{ key(19, 5120, 1440), key(1, 1512, 982) }, &out); // listed in another order
    try std.testing.expectEqual(@as(?usize, 1), out[0]);
    try std.testing.expectEqual(@as(?usize, 0), out[1]);
}

test "a display that went away is remembered, and recognised when it returns" {
    // Built-in (1) and external (19) were known; right now only the built-in is listed.
    const known = [_]DisplayKey{ key(1, 1512, 982), key(19, 5120, 1440) };
    var out: [1]?usize = undefined;
    matchDisplays(&known, &.{key(1, 1512, 982)}, &out);
    try std.testing.expectEqual(@as(?usize, 0), out[0]); // the external is simply not matched (it becomes a memory)
    // Later it returns: the remembered one is found again.
    const remembered = [_]DisplayKey{ key(1, 1512, 982), key(19, 5120, 1440) };
    var back: [2]?usize = undefined;
    matchDisplays(&remembered, &.{ key(1, 1512, 982), key(19, 5120, 1440) }, &back);
    try std.testing.expectEqual(@as(?usize, 1), back[1]);
}

test "a re-plugged display with a NEW id is still the same monitor if the size matches" {
    const known = [_]DisplayKey{ key(1, 1512, 982), key(19, 5120, 1440) };
    var out: [2]?usize = undefined;
    matchDisplays(&known, &.{ key(1, 1512, 982), key(42, 5120, 1440) }, &out);
    try std.testing.expectEqual(@as(?usize, 0), out[0]);
    try std.testing.expectEqual(@as(?usize, 1), out[1]); // id 42 is the old 19
}

test "a genuinely different display is new" {
    const known = [_]DisplayKey{key(1, 1512, 982)};
    var out: [2]?usize = undefined;
    matchDisplays(&known, &.{ key(1, 1512, 982), key(7, 2560, 1440) }, &out);
    try std.testing.expectEqual(@as(?usize, 0), out[0]);
    try std.testing.expectEqual(@as(?usize, null), out[1]);
}

test "an id match always beats a size match" {
    // Two identical monitors: ids decide, sizes are only the fallback.
    const known = [_]DisplayKey{ key(5, 1920, 1080), key(6, 1920, 1080) };
    var out: [2]?usize = undefined;
    matchDisplays(&known, &.{ key(6, 1920, 1080), key(9, 1920, 1080) }, &out);
    try std.testing.expectEqual(@as(?usize, 1), out[0]); // id 6 is the old 6
    try std.testing.expectEqual(@as(?usize, 0), out[1]); // the new one takes the remaining old 5
}

fn rect(x: i32, y: i32, w: i32, h: i32) Rect {
    return .{ .x = x, .y = y, .w = w, .h = h };
}

fn builtin() Display {
    return .{ .id = 1, .screen = rect(0, 0, 1512, 982), .area = rect(0, 33, 1512, 949) };
}

fn external(id: u32) Display {
    return .{ .id = id, .screen = rect(1512, 0, 5120, 1440), .area = rect(1512, 30, 5120, 1410) };
}

const Rig = struct {
    live: [max_monitors]Monitor = undefined,
    nlive: usize = 0,
    ghosts: [max_monitors]Monitor = undefined,
    nghosts: usize = 0,
    remap: Remap = .{},

    fn update(self: *Rig, displays: []const Display) void {
        applyDisplays(&self.live, &self.nlive, &self.ghosts, &self.nghosts, displays, &self.remap);
    }
};

test "a display that disappears is remembered with its settings, and restored when it returns" {
    var rig = Rig{};
    rig.update(&.{ builtin(), external(19) });
    try std.testing.expectEqual(@as(usize, 2), rig.nlive);

    // Give the external its own state: showing tag 3 with the monocle layout.
    rig.live[1].view = 4;
    _ = rig.live[1].setLayout(layoutIndex("monocle").?);

    rig.update(&.{builtin()}); // the external goes away (sleep, cable...)
    try std.testing.expectEqual(@as(usize, 1), rig.nlive);
    try std.testing.expectEqual(@as(usize, 1), rig.nghosts);
    try std.testing.expectEqual(@as(?usize, null), rig.remap.find(19)); // windows homed on 19 have no monitor now
    try std.testing.expectEqual(@as(?usize, 0), rig.remap.find(1));

    rig.update(&.{ builtin(), external(19) }); // it comes back
    try std.testing.expectEqual(@as(usize, 2), rig.nlive);
    try std.testing.expectEqual(@as(usize, 0), rig.nghosts);
    try std.testing.expectEqual(@as(u32, 4), rig.live[1].view); // still showing tag 3
    try std.testing.expectEqual(layoutIndex("monocle").?, rig.live[1].settings().layout);
    try std.testing.expectEqual(@as(?usize, 1), rig.remap.find(19)); // windows homed on 19 are back
}

test "a returning display with a new id is the same monitor: settings and windows come back" {
    var rig = Rig{};
    rig.update(&.{ builtin(), external(19) });
    rig.live[1].view = 8;
    rig.update(&.{builtin()});
    rig.update(&.{ builtin(), external(42) }); // new id, same size
    try std.testing.expectEqual(@as(u32, 8), rig.live[1].view);
    try std.testing.expectEqual(@as(u32, 42), rig.live[1].display_id);
    try std.testing.expectEqual(@as(?usize, 1), rig.remap.find(19)); // windows homed on the OLD id find it
}

test "a window keeps its home across several changes in a row" {
    // What wake-up looks like: the external flickers away and back more than once.
    var rig = Rig{};
    rig.update(&.{ builtin(), external(19) });
    var home: u32 = 19; // a window whose home is the external
    for (0..3) |_| {
        rig.update(&.{builtin()});
        try std.testing.expectEqual(@as(?usize, null), rig.remap.find(home)); // away: shown elsewhere...
        rig.update(&.{ builtin(), external(19) });
        const back = rig.remap.find(home).?; // ...but home again
        home = rig.live[back].display_id;
    }
    try std.testing.expectEqual(@as(u32, 19), home);
    try std.testing.expectEqual(@as(usize, 2), rig.nlive);
}

test "the first call (nothing known yet) just creates the monitors" {
    var rig = Rig{};
    rig.update(&.{ builtin(), external(19) });
    try std.testing.expectEqual(@as(usize, 2), rig.nlive);
    try std.testing.expectEqual(@as(usize, 0), rig.nghosts);
    try std.testing.expectEqual(@as(u32, 1), rig.live[0].view); // fresh defaults
    try std.testing.expectEqual(@as(i32, 33), rig.live[0].area.y);
}

fn tomb(id: u32) Tomb {
    return .{ .id = id, .tags = @as(u32, 1) << @intCast(id % 9), .home = 19, .floating = false, .min_w = 0, .min_h = 400 };
}

test "a window that comes back gets its old state back, however much later" {
    var g = Graveyard{};
    g.bury(.{ .id = 7, .tags = 1 << 8, .home = 19, .floating = true, .min_w = 300, .min_h = 200 });
    const t = g.exhume(7).?;
    try std.testing.expectEqual(@as(u32, 1 << 8), t.tags);
    try std.testing.expectEqual(@as(u32, 19), t.home);
    try std.testing.expect(t.floating);
    try std.testing.expectEqual(@as(i32, 200), t.min_h);
    try std.testing.expect(g.exhume(7) == null); // used up
}

test "unknown windows and re-burying the same window" {
    var g = Graveyard{};
    try std.testing.expect(g.exhume(1) == null);
    g.bury(tomb(5));
    g.bury(.{ .id = 5, .tags = 2, .home = 1, .floating = false, .min_w = 0, .min_h = 0 });
    try std.testing.expectEqual(@as(usize, 1), g.count); // one entry per window
    try std.testing.expectEqual(@as(u32, 2), g.exhume(5).?.tags); // the latest
}

test "the graveyard keeps the most recent 256 and forgets the oldest" {
    var g = Graveyard{};
    for (0..300) |i| g.bury(tomb(@intCast(i)));
    try std.testing.expectEqual(@as(usize, 256), g.count);
    try std.testing.expect(g.exhume(0) == null); // the oldest were overwritten
    try std.testing.expect(g.exhume(299) != null);
}

test "a new window goes to the selected monitor, not where macOS drew it" {
    // zwm is running; monitor 0 is selected, but the window appeared on monitor 1.
    try std.testing.expectEqual(@as(usize, 0), monitorForNewWindow(false, 0, 1, -1, 2));
    try std.testing.expectEqual(@as(usize, 1), monitorForNewWindow(false, 1, 0, -1, 2));
}

test "windows that exist at startup stay on their own monitor" {
    try std.testing.expectEqual(@as(usize, 1), monitorForNewWindow(true, 0, 1, -1, 2));
    try std.testing.expectEqual(@as(usize, 0), monitorForNewWindow(true, 0, null, -1, 2)); // off-screen
}

test "a rule's monitor wins, an invalid one is ignored" {
    try std.testing.expectEqual(@as(usize, 1), monitorForNewWindow(false, 0, 0, 1, 2));
    try std.testing.expectEqual(@as(usize, 1), monitorForNewWindow(true, 0, 0, 1, 2));
    try std.testing.expectEqual(@as(usize, 0), monitorForNewWindow(false, 0, 1, 5, 2)); // no monitor 5
}

test "layoutIndex finds layouts by name" {
    try std.testing.expect(layoutIndex("tile") != null);
    try std.testing.expect(layoutIndex("no such layout") == null);
}
