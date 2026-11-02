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
// This file contains code derived from dwm (MIT/X Consortium License) and
// follows techniques from AeroSpace (MIT License); see THIRD_PARTY_NOTICES.

//! The window manager proper. The ideas come from dwm (tags, master/stack
//! layouts, monitors) but the design is zwm's own:
//!
//!  * ONE list of windows (`clients`) in tiling order. A window knows which
//!    monitor it is on; a monitor does not own windows.
//!  * Focus is a counter: every focus stamps the window with a bigger number,
//!    and a monitor's "selected" window is the visible one with the biggest
//!    stamp (`selected`). There is no separate focus stack or `sel` pointer to
//!    keep in sync.
//!  * Every tag remembers its own layout, master size and master count.
//!  * What the user can do is a typed `Action` (see `run`).
//!
//! How macOS differs from X11, and what we do about it:
//!  * No "hide a window": we park it in the bottom-right corner, off-screen.
//!  * No reliable events: we reconcile() with the real window list whenever
//!    something might have changed (and every few seconds, as a safety net).
//!  * No restacking: we never raise floating windows (see `focus`).
const std = @import("std");
const c = @import("c");
const config = @import("config");
const types = @import("types.zig");
const model = @import("model.zig");
const ax = @import("ax.zig");
const apps = @import("apps.zig");
const screens = @import("screens.zig");
const bar = @import("bar.zig");
const hotkeys = @import("hotkeys.zig");
const runloop = @import("runloop.zig");
const cocoa = @import("cocoa.zig");
const log = @import("log.zig");
const mem = @import("mem.zig");

const Rect = types.Rect;
const Action = types.Action;
const Client = model.Client;
const Monitor = model.Monitor;
const tagmask = model.tagmask;

const gpa = @import("mem.zig").gpa;

const max_monitors = model.max_monitors;

// ------------------------------------------------------------------ state
// One program, one window manager: this state is global, like dwm's.

var mons: [max_monitors]Monitor = undefined; // only [0..nmons] are valid
var nmons: usize = 0;
/// Monitors whose display is gone for now (unplugged, asleep). Their settings are
/// remembered, and their windows remember them, so everything comes back when
/// the display does. See `updateGeometry`.
var ghosts: [max_monitors]Monitor = undefined;
var nghosts: usize = 0;
/// Windows we lost track of; see model.Graveyard.
var graveyard = model.Graveyard{};
/// When the left mouse button was last seen down (see `userIsDragging`).
var mouse_last_down: f64 = 0;
var selmon: usize = 0; // index of the monitor that has the focus
var clients: std.ArrayList(*Client) = .empty; // tiling order, all monitors
var focus_counter: u64 = 0;
/// False until the first full scan has run: windows found by that scan already
/// existed when zwm started; later ones are new (see model.monitorForNewWindow).
var startup_scan_done = false;

var paused = false; // asleep / locked: don't touch any windows
/// A focus change we asked the OS for and haven't seen it carry out yet.
/// Until it shows up (or `deadline` passes) the OS's answers are stale, so
/// `syncFocus` ignores them instead of undoing our request.
const PendingFocus = struct { id: u32, deadline: f64 };
var pending_focus: ?PendingFocus = null;
var focus_check_scheduled = false;
const focus_patience = 0.6; // seconds we wait for the OS to follow
var last_beat: f64 = 0;

// ---------------------------------------------------------------- queries

fn monOf(cl: *const Client) *Monitor {
    return &mons[cl.mon];
}

/// On a tag that is currently shown on its monitor.
fn visible(cl: *const Client) bool {
    return cl.tags & monOf(cl).view != 0;
}

fn parked(cl: *const Client) bool {
    return cl.placement == .parked;
}

/// Positioned by a layout algorithm (not floating, and the layout tiles).
fn tiled(cl: *const Client) bool {
    return !cl.floating and !cl.away and monOf(cl).layout().arrange != null;
}

/// The window that has (or should get) focus on monitor `mi`: the visible one
/// that was focused most recently.
fn selected(mi: usize) ?*Client {
    var best: ?*Client = null;
    for (clients.items) |cl| {
        if (cl.mon != mi or !visible(cl) or parked(cl) or cl.away) continue;
        if (best == null or cl.focus_tick > best.?.focus_tick) best = cl;
    }
    return best;
}

fn appName(pid: i32) []const u8 {
    return if (apps.find(pid)) |a| a.name else "?";
}

fn findClient(id: u32) ?*Client {
    for (clients.items) |cl| {
        if (cl.id == id) return cl;
    }
    return null;
}

/// Monitor with the largest overlap with `r`, or null if off every display.
fn monitorFor(r: Rect) ?usize {
    var best: ?usize = null;
    var best_area: i64 = 0;
    for (mons[0..nmons], 0..) |m, i| {
        const a = r.overlapArea(m.screen);
        if (a > best_area) {
            best_area = a;
            best = i;
        }
    }
    return best;
}

/// The monitor the mouse pointer is on (in the same top-left coordinates as
/// everything else), if any.
fn pointerMonitor() ?usize {
    const event = c.CGEventCreate(null) orelse return null;
    defer c.CFRelease(event);
    const p = c.CGEventGetLocation(event);
    const found = monitorFor(.{ .x = @intFromFloat(@floor(p.x)), .y = @intFromFloat(@floor(p.y)), .w = 1, .h = 1 });
    log.debug("pointer at ({d:.0},{d:.0}) -> monitor {?d}", .{ p.x, p.y, found });
    return found;
}

/// Where hidden windows live: just inside the bottom-right corner of the
/// bounding box of all displays, so (almost) all of the window is off-screen.
fn parkPoint() struct { x: i32, y: i32 } {
    var x: i32 = 0;
    var y: i32 = 0;
    for (mons[0..nmons]) |m| {
        x = @max(x, m.screen.x + m.screen.w);
        y = @max(y, m.screen.y + m.screen.h);
    }
    return .{ .x = x - 1, .y = y - 1 };
}

// --------------------------------------------------------------- monitors

/// A floating window stays where the user left it: read its frame, and if that is
/// on the window's own display make it the window's remembered position.
fn adoptFloatingFrame(cl: *Client) void {
    if (!responsive(cl.pid)) return;
    const f = ax.getFrame(cl.window) orelse return;
    if (mons[cl.mon].screen.contains(f.x + @divFloor(f.w, 2), f.y + @divFloor(f.h, 2))) {
        cl.rect = f;
        cl.placement = .{ .shown = f };
    }
}

/// Re-read the displays. Called at startup, when displays are
/// plugged/unplugged/rearranged and after wake-up.
///
/// Displays come and go (sleep, wake, cables, docks), often only for a moment,
/// so a display that is missing is NOT forgotten:
///  * its monitor (tags, layouts, master sizes) is remembered as a "ghost";
///  * its windows are shown on monitor 0 meanwhile, but keep it as their `home`;
///  * when the display comes back, even with a new display id, its settings and
///    its windows return.
/// Only the user moving a window (or `tag_monitor`) changes its home.
pub fn updateGeometry() void {
    var infos: [max_monitors]screens.Info = undefined;
    const n = screens.list(&infos);
    if (n == 0) return; // displays are asleep; keep what we have

    log.debug("geometry: {d} display(s)", .{n});
    const old_sel_id: ?u32 = if (nmons > 0) mons[selmon].display_id else null;

    var displays: [max_monitors]model.Display = undefined;
    for (infos[0..n], 0..) |info, i| displays[i] = .{ .id = info.id, .screen = info.screen, .area = info.area };
    var remap = model.Remap{};
    model.applyDisplays(&mons, &nmons, &ghosts, &nghosts, displays[0..n], &remap);
    if (nghosts > 0) log.debug("{d} display(s) remembered while disconnected", .{nghosts});

    // At startup, like dwm, the selected monitor is the one under the mouse
    // pointer. (Later it follows the focused window and focus_monitor.)
    selmon = pointerMonitor() orelse 0;
    if (old_sel_id) |id| {
        if (remap.find(id)) |t| selmon = t;
    }

    // Put each window on its home display if that exists; otherwise on monitor 0
    // for now (it stays "homed" on the missing one, and returns with it).
    for (clients.items) |cl| {
        const home_monitor = remap.find(cl.home);
        const target: usize = home_monitor orelse 0;
        if (home_monitor != null) {
            cl.home = mons[target].display_id; // follows a changed display id
        } else if (cl.home != 0) {
            // Its display is away: show it on monitor 0, inside that monitor.
            const area = mons[0].area;
            cl.rect.w = @min(cl.rect.w, area.w);
            cl.rect.h = @min(cl.rect.h, area.h);
            cl.rect.x = area.x + @divFloor(area.w - cl.rect.w, 2);
            cl.rect.y = area.y + @divFloor(area.h - cl.rect.h, 2);
        } else {
            cl.home = mons[0].display_id; // a window with no home yet
        }
        cl.mon = @intCast(target);
        if (!parked(cl)) {
            // macOS may have moved the window while displays changed: place it
            // again. A floating window the user positioned is the exception: keep
            // where it is now, if that is still on its own display.
            cl.placement = .unknown;
            if (home_monitor != null and !tiled(cl)) adoptFloatingFrame(cl);
        }
    }

    // The parking spot may have moved: re-park, then lay everything out again.
    for (0..nmons) |i| showhide(i, true);
    arrangeAll();
}

// ------------------------------------------------------------- arranging

fn park(cl: *Client) void {
    if (!responsive(cl.pid)) return; // retried by the next arrange
    if (!parked(cl) and !tiled(cl)) {
        // Remember where the user left a floating window.
        if (ax.getFrame(cl.window)) |f| cl.rect = f;
    }
    const p = parkPoint();
    ax.setPosition(cl.window, p.x, p.y);
    cl.placement = .parked;
}

fn showhide(mi: usize, repark: bool) void {
    for (clients.items) |cl| {
        if (cl.mon == mi and !visible(cl) and (!parked(cl) or repark)) park(cl);
    }
}

/// Apply what we learned about the window's minimum size, and keep a window
/// that is bigger than its cell from hanging off the edge of the display.
fn fit(cl: *const Client, r: Rect) Rect {
    var out = r;
    out.w = @max(out.w, cl.min_w);
    out.h = @max(out.h, cl.min_h);
    const area = monOf(cl).area;
    out.x = @max(@min(out.x, area.x + area.w - out.w), area.x);
    out.y = @max(@min(out.y, area.y + area.h - out.h), area.y);
    return out;
}

/// dwm's `resizehints` for macOS. X11 windows publish size hints; macOS
/// windows don't, so we LEARN them: place the window, read back what it really
/// became, and if it is bigger than we asked it MAY have a minimum size.
/// A freshly opened window can still be settling (animating, restoring its
/// saved size), so we never trust a single reading: `verifySize` asks again a
/// moment later and only then remembers the minimum. (Windows that came out
/// SMALLER, e.g. terminals snapping to whole characters, need no limit.)
const size_tolerance = 1;

fn learn(cl: *Client, asked: Rect) void {
    if (cl.verifying) return;
    const got = ax.getFrame(cl.window) orelse return;
    if (got.w <= asked.w + size_tolerance and got.h <= asked.h + size_tolerance) return;
    cl.verifying = true;
    runloop.after(0.4, verifySize, cl.id);
}

fn verifySize(id: usize) void {
    const cl = findClient(@intCast(id)) orelse return;
    cl.verifying = false;
    if (paused or parked(cl) or !visible(cl)) return;
    const asked = fit(cl, cl.rect);
    ax.setSize(cl.window, asked.w, asked.h); // ask once more
    const got = ax.getFrame(cl.window) orelse return;
    // A "minimum" that fills nearly the whole area is not a real minimum: the
    // window is maximized or still animating. Don't remember that.
    const area = monOf(cl).area;
    var learned = false;
    if (got.w > asked.w + size_tolerance and got.w < @divFloor(area.w * 9, 10)) {
        cl.min_w = got.w;
        learned = true;
    }
    if (got.h > asked.h + size_tolerance and got.h < @divFloor(area.h * 9, 10)) {
        cl.min_h = got.h;
        learned = true;
    }
    if (learned) {
        log.debug("learned minimum size of id {d} ({s}): {d}x{d}", .{ cl.id, appName(cl.pid), cl.min_w, cl.min_h });
        cl.placement = .unknown; // force a re-place that honours the new minimum
        arrange(cl.mon);
    }
}

/// Push `cl.rect` to the OS, but only if it changed.
fn place(cl: *Client) void {
    if (!responsive(cl.pid)) return; // retried by the next arrange
    switch (cl.placement) {
        .shown => |r| {
            if (r.eql(cl.rect)) return;
        },
        else => {},
    }
    const want = if (config.resizehints) fit(cl, cl.rect) else cl.rect;
    ax.setFrame(cl.app, cl.window, want);
    if (config.resizehints) learn(cl, want);
    cl.placement = .{ .shown = cl.rect };
}

/// Lay out monitor `mi`: park what isn't shown, run the tag's layout over the
/// tiled windows, send the results to macOS.
pub fn arrange(mi: usize) void {
    const m = &mons[mi];
    const lt = m.layout();

    if (lt.arrange) |layoutFn| {
        var list: std.ArrayList(*Client) = .empty;
        defer list.deinit(gpa);
        for (clients.items) |cl| {
            if (cl.mon == mi and visible(cl) and tiled(cl)) list.append(gpa, cl) catch return;
        }
        const rects = gpa.alloc(Rect, list.items.len) catch return;
        defer gpa.free(rects);
        layoutFn(m.area, list.items.len, m.params(), rects);
        for (list.items, rects) |cl, r| cl.rect = r.inset(config.gappx);
        log.debug("arrange monitor {d}: view={b} layout={s} tiled={d}", .{ mi, m.view, lt.name, list.items.len });
    }

    for (clients.items) |cl| {
        if (cl.mon == mi and visible(cl)) place(cl);
    }
    // Hide what is no longer shown only AFTER the new windows are in place, so
    // a tag switch never shows an empty screen in between.
    showhide(mi, false);
    // Overlapping layouts (monocle): keep the focused window on top.
    if (lt.overlap) {
        if (selected(mi)) |s| {
            if (tiled(s)) ax.raise(s.window);
        }
    }
    if (mi == selmon) refreshBar();
}

pub fn arrangeAll() void {
    for (0..nmons) |i| arrange(i);
}

/// Redraw the menu-bar item for the selected monitor.
pub fn refreshBar() void {
    if (nmons == 0) return;
    const m = &mons[selmon];
    var occupied: u32 = 0;
    var count: usize = 0;
    for (clients.items) |cl| {
        if (cl.mon != selmon) continue;
        occupied |= cl.tags;
        if (visible(cl) and tiled(cl)) count += 1;
    }
    var buf: [24]u8 = undefined;
    const symbol = m.layout().displaySymbol(count, m.params().nmaster, &buf);
    bar.update(.{ .view = m.view, .occupied = occupied, .symbol = symbol });
}

// ----------------------------------------------------------------- focus

fn activateSelf() void {
    // Nothing to focus: make zwm itself frontmost (it has no windows) so
    // keystrokes don't go to a window that is parked off-screen.
    cocoa.sharedApplication().msgSend(void, "activateIgnoringOtherApps:", .{true});
}

fn stamp(cl: *Client) void {
    focus_counter += 1;
    cl.focus_tick = focus_counter;
}

/// Focus `target`, or the most recently used visible window of the selected
/// monitor when `target` is null / not visible.
pub fn focus(target: ?*Client) void {
    var cl = target;
    if (cl == null or !visible(cl.?)) cl = selected(selmon);
    pending_focus = null;
    if (cl) |w| {
        log.debug("focus id {d} ({s}) on monitor {d}", .{ w.id, appName(w.pid), w.mon });
        selmon = w.mon;
        stamp(w);
        // The "don't raise floating windows" rule lives here: only windows that
        // are tiled by a layout get raised. Floating ones just receive focus.
        ax.focusWindow(w.app, w.window, w.pid, tiled(w));
        pending_focus = .{ .id = w.id, .deadline = runloop.now() + focus_patience };
        scheduleFocusCheck();
    } else {
        log.debug("focus: nothing to focus on monitor {d}, activating zwm itself", .{selmon});
        activateSelf();
    }
    refreshBar();
}

/// The user focused a window themselves (click, Cmd-Tab). Adopt that, without
/// sending any commands back to the OS.
fn syncFocus() void {
    if (pending_focus) |p| {
        if (runloop.now() >= p.deadline) {
            log.debug("the OS never focused id {d}: believing the OS from now on", .{p.id});
            pending_focus = null;
        }
    }
    const pid = ax.frontmostPid() orelse return;
    if (!responsive(pid)) return; // can't ask a frozen app; keep what we have
    const id = ax.focusedWindowId(pid) orelse return;
    if (pending_focus) |p| {
        if (id != p.id) return; // the OS hasn't caught up with our request yet
        pending_focus = null; // it has: our idea and the OS now agree
    }
    const cl = findClient(id) orelse return;
    if (parked(cl) or !visible(cl)) {
        // The OS focused a window that is parked off-screen (an app was
        // activated through Cmd-Tab, the Dock, `open`, ... and picked its own
        // last window, which lives on another tag). Focus must never rest on a
        // window you cannot see: hand it back to something visible, or to zwm
        // itself when the tag is empty. Switch tags to reach hidden windows.
        log.debug("focus landed on a parked window (id {d}, {s}): handing it back", .{ cl.id, appName(cl.pid) });
        focus(selected(selmon));
        return;
    }
    if (selmon == cl.mon and selected(cl.mon) == cl) return;
    log.debug("user focused id {d} ({s}) on monitor {d}", .{ cl.id, appName(cl.pid), cl.mon });
    selmon = cl.mon;
    stamp(cl);
    refreshBar();
}

/// While a focus request is pending, look again shortly, until the OS has
/// followed or we give up.
fn scheduleFocusCheck() void {
    if (focus_check_scheduled) return;
    focus_check_scheduled = true;
    runloop.after(0.1, checkPendingFocus, 0);
}

fn checkPendingFocus(_: usize) void {
    focus_check_scheduled = false;
    if (pending_focus == null or paused) return;
    syncFocus();
    if (pending_focus != null) scheduleFocusCheck();
}

/// Re-read the focused window from the OS (used right before a hotkey acts).
pub fn refreshFocus() void {
    if (paused or nmons == 0) return;
    syncFocus();
}

// ------------------------------------------------------- managing windows

fn matches(haystack: []const u8, needle: ?[]const u8) bool {
    const n = needle orelse return true;
    return std.mem.indexOf(u8, haystack, n) != null;
}

/// Read what `model.classify` needs from Accessibility.
fn windowAttrs(app: *apps.App, win: c.AXUIElementRef, id: u32, title: []const u8, ident: []const u8) model.WindowAttrs {
    return .{
        .bundle_id = app.bundle_id,
        .title = title,
        .identifier = ident,
        .subrole = ax.subrole(win),
        .size_settable = ax.sizeIsSettable(win),
        .has_close = ax.hasAttr(win, "AXCloseButton"),
        .has_fullscreen = ax.hasAttr(win, "AXFullScreenButton"),
        .has_zoom = ax.hasAttr(win, "AXZoomButton"),
        .has_minimize = ax.hasAttr(win, "AXMinimizeButton"),
        .close_enabled = ax.buttonEnabled(win, "AXCloseButton"),
        .fullscreen_enabled = ax.buttonEnabled(win, "AXFullScreenButton"),
        .minimize_enabled = ax.buttonEnabled(win, "AXMinimizeButton"),
        .active = (ax.getBool(win, "AXFocused") orelse false) or (ax.getBool(win, "AXMain") orelse false) or
            ax.focusedWindowId(app.pid) == id,
        .layer = if (model.checksLayer(app.bundle_id)) (ax.windowLayer(id) orelse 0) else 0,
    };
}

/// Start managing a window. `replace`: the tracked window this one takes over
/// from (a native tab switch): it keeps all of that window's state.
fn manage(app: *apps.App, win: c.AXUIElementRef, replace: ?*Client) void {
    const id = ax.windowId(win) orelse return;
    if (ax.isMinimized(win) or ax.isFullscreen(win)) return;
    var title_buf: [256]u8 = undefined;
    const title = ax.title(win, &title_buf);
    var ident_buf: [128]u8 = undefined;
    // Popups are not windows. They are looked at again on every scan, because
    // their attributes are often not ready yet when they appear.
    const kind = model.classify(windowAttrs(app, win, id, title, ax.identifier(win, &ident_buf)));
    if (kind == .ignore) return;
    var frame = ax.getFrame(win) orelse return;

    var mi: usize = model.monitorForNewWindow(!startup_scan_done, selmon, monitorFor(frame), -1, nmons);
    var tags: u32 = 0;
    var floating = kind == .float;

    const at_startup = !startup_scan_done;
    for (config.rules) |r| {
        if (r.startup) |only_startup| {
            if (only_startup != at_startup) continue;
        }
        if (!matches(app.bundle_id, r.bundle_id) or !matches(app.name, r.app_name) or !matches(title, r.title)) continue;
        if (r.ignore) return;
        if (r.floating) |f| floating = f;
        tags |= r.tags;
        mi = model.monitorForNewWindow(!startup_scan_done, selmon, monitorFor(frame), r.monitor, nmons);
    }
    if (replace) |old| {
        log.debug("tab switch in {s}: id {d} takes over from id {d}", .{ app.name, id, old.id });
        c.CFRelease(old.window);
        old.window = @ptrCast(c.CFRetain(win));
        old.id = id;
        old.placement = .unknown; // the new tab's window is placed afresh
        old.accepted = null;
        old.seen = true;
        old.away = false;
        apps.watchWindow(app, win);
        return;
    }
    // A window we lost track of a moment ago (it did not necessarily close:
    // our questions to macOS can fail) comes back with everything it had.
    const tomb = graveyard.exhume(id);
    if (tomb) |t| {
        log.debug("window id {d} is back: restoring its tags, monitor and size limits", .{id});
        tags = t.tags;
        floating = t.floating;
        for (mons[0..nmons], 0..) |m, i| {
            if (m.display_id == t.home) mi = i;
        }
    }
    tags &= tagmask;
    if (tags == 0) tags = mons[mi].view;

    // Off every display (e.g. left parked by a crashed zwm), or moved to
    // another display by a rule: put it in the middle of its monitor.
    var placement: model.Placement = if (floating) .{ .shown = frame } else .unknown;
    if (monitorFor(frame) != mi) {
        const area = mons[mi].area;
        frame.w = @min(frame.w, area.w);
        frame.h = @min(frame.h, area.h);
        frame.x = area.x + @divFloor(area.w - frame.w, 2);
        frame.y = area.y + @divFloor(area.h - frame.h, 2);
        placement = .unknown;
    }

    const cl = gpa.create(Client) catch return;
    cl.* = .{
        .window = @ptrCast(c.CFRetain(win)),
        .app = @ptrCast(c.CFRetain(app.el)),
        .pid = app.pid,
        .id = id,
        .home = if (tomb) |t| t.home else mons[mi].display_id,
        .min_w = if (tomb) |t| t.min_w else 0,
        .min_h = if (tomb) |t| t.min_h else 0,
        .mon = @intCast(mi),
        .tags = tags,
        .floating = floating,
        .rect = frame,
        .placement = placement,
        .seen = true,
    };
    log.debug("manage id {d} ({s}) \"{s}\" mon={d} tags={b} floating={}", .{ id, app.name, title, mi, tags, floating });
    stamp(cl); // a new window is the most recently used one
    // New windows go to the front (master).
    clients.insert(gpa, 0, cl) catch {
        c.CFRelease(cl.window);
        c.CFRelease(cl.app);
        gpa.destroy(cl);
        return;
    };
    apps.watchWindow(app, win);
}

/// Returns true if this was the selected window of the selected monitor.
fn unmanage(cl: *Client) bool {
    const was_selected = cl.mon == selmon and selected(selmon) == cl;
    log.debug("unmanage id {d} ({s})", .{ cl.id, appName(cl.pid) });
    graveyard.bury(.{ .id = cl.id, .tags = cl.tags, .home = cl.home, .floating = cl.floating, .min_w = cl.min_w, .min_h = cl.min_h });
    if (std.mem.indexOfScalar(*Client, clients.items, cl)) |i| _ = clients.orderedRemove(i);
    c.CFRelease(cl.window);
    c.CFRelease(cl.app);
    gpa.destroy(cl);
    return was_selected;
}

/// What a scan found; applied afterwards so we never edit the list we iterate.
const Scan = struct {
    changed: bool = false,
    gone: std.ArrayList(*Client) = .empty,
};

fn markSeen(pid: i32) void {
    for (clients.items) |cl| {
        if (cl.pid == pid) cl.seen = true;
    }
}

/// False while an app is being left alone because it stopped answering.
fn responsive(pid: i32) bool {
    const app = apps.find(pid) orelse return true;
    return runloop.now() >= app.backoff_until;
}

/// Look at one app's windows: manage new ones, mark known ones as seen, note
/// minimized / fullscreen ones as gone.
fn scanApp(app: *apps.App, scan: *Scan) void {
    if (app.hidden) {
        // Cmd-H'd apps don't report their windows reliably: leave them be, but
        // give their tiles back until they are shown again.
        markSeen(app.pid);
        for (clients.items) |cl| {
            if (cl.pid == app.pid and !cl.away) {
                cl.away = true;
                scan.changed = true;
            }
        }
        return;
    }
    const now = runloop.now();
    if (now < app.backoff_until) {
        markSeen(app.pid); // its windows are still there, we just can't ask
        return;
    }
    switch (ax.windowsOf(app.el)) {
        .failed => {
            // We could not ask (right after waking, or the app is starting up):
            // that is not the same as "its windows are gone". Keep them.
            log.debug("{s}: could not list its windows; keeping what we know", .{app.name});
            markSeen(app.pid);
        },
        .unresponsive => {
            log.debug("{s} is not responding: leaving it alone for {d:.0}s", .{ app.name, model.backoff_seconds });
            app.backoff_until = now + model.backoff_seconds;
            markSeen(app.pid);
        },
        .list => |arr| {
            defer c.CFRelease(arr);
            if (app.backoff_until != 0) {
                log.debug("{s} is responding again", .{app.name});
                app.backoff_until = 0;
                scan.changed = true; // windows we skipped may need placing
            }
            var fresh: [16]c.AXUIElementRef = undefined; // listed windows we do not track yet
            var nfresh: usize = 0;
            var i: c.CFIndex = 0;
            while (i < c.CFArrayGetCount(arr)) : (i += 1) {
                const win: c.AXUIElementRef = @ptrCast(@constCast(c.CFArrayGetValueAtIndex(arr, i)));
                const id = ax.windowId(win) orelse continue;
                if (findClient(id)) |cl| {
                    cl.seen = true;
                    if (cl.away) {
                        cl.away = false;
                        scan.changed = true;
                    }
                    if (ax.isMinimized(win) or ax.isFullscreen(win)) scan.gone.append(gpa, cl) catch {};
                } else {
                    // A window that appears while the mouse button is down is
                    // usually a tab being dragged out of a browser: wait until
                    // it is dropped (the release triggers a scan).
                    if (mouseButtonDown()) {
                        log.debug("{s}: new window waits for the mouse button to go up", .{app.name});
                        continue;
                    }
                    if (nfresh < fresh.len) {
                        fresh[nfresh] = win;
                        nfresh += 1;
                    }
                }
            }
            if (nfresh == 0) return;
            scan.changed = true;
            // Tracked, was listed last time, not listed now?
            var vanished: ?*Client = null;
            var nvanished: usize = 0;
            for (clients.items) |cl| {
                if (cl.pid == app.pid and !cl.seen and !cl.away) {
                    vanished = cl;
                    nvanished += 1;
                }
            }
            if (model.isTabSwap(nvanished, nfresh)) {
                manage(app, fresh[0], vanished);
            } else {
                for (fresh[0..nfresh]) |win| manage(app, win, null);
            }
        },
    }
}

/// Windows no longer listed. Unlisted-but-valid ones (other Space, hidden app)
/// are kept, so they don't lose their tags. But a window whose APP has quit is
/// always gone: asking a dead app about its window does not say "invalid
/// element", it says "cannot complete", which looks like a frozen app, so the
/// window would otherwise stay forever and keep a tile slot reserved.
fn sweep(scan: *Scan, only_pid: ?i32) void {
    for (clients.items) |cl| {
        if (only_pid) |p| {
            if (cl.pid != p) continue;
        }
        if (cl.seen) continue;
        if (apps.find(cl.pid) == null) {
            log.debug("id {d}: its app quit", .{cl.id});
            scan.gone.append(gpa, cl) catch {};
        } else if (!ax.alive(cl.window)) {
            scan.gone.append(gpa, cl) catch {};
        } else if (!cl.away) {
            // Valid but not listed: another Space, or a background tab. It
            // keeps its tags but takes no tile until it is listed again.
            cl.away = true;
            scan.changed = true;
        }
    }
}

/// Apply what a scan found.
fn finishScan(scan: *Scan, only_pid: ?i32) void {
    var lost_selected = false;
    for (scan.gone.items) |cl| {
        if (unmanage(cl)) lost_selected = true;
        scan.changed = true;
    }
    followDrags(only_pid);
    healDrift(only_pid);
    syncFocus();
    if (scan.changed) arrangeAll();
    if (lost_selected) focus(null);
}

/// Compare our idea of the world with the real one, for ALL apps, and fix the
/// differences: new windows get managed, closed / minimized / fullscreen ones
/// forgotten, windows dragged to another display follow, focus is adopted.
/// Costs a few Accessibility calls per window, so events use `reconcileApp`;
/// this runs for app launches/quits and as the heartbeat safety net.
pub fn reconcile() void {
    if (paused or nmons == 0) return;
    const t0 = runloop.now();
    apps.refresh();
    var scan = Scan{};
    defer scan.gone.deinit(gpa);

    for (clients.items) |cl| cl.seen = false;
    for (apps.list.items) |app| scanApp(app, &scan);
    sweep(&scan, null);
    finishScan(&scan, null);
    startup_scan_done = true;
    log.debug("full reconcile: {d} app(s), {d} window(s), {d:.0} ms", .{ apps.list.items.len, clients.items.len, (runloop.now() - t0) * 1000 });
}

/// The same, for one app only: what an Accessibility event about that app
/// needs. Much cheaper than `reconcile` when many windows are open.
pub fn reconcileApp(pid: i32) void {
    if (paused or nmons == 0) return;
    const app = apps.find(pid) orelse {
        reconcile(); // an app we don't know yet
        return;
    };
    const t0 = runloop.now();
    var scan = Scan{};
    defer scan.gone.deinit(gpa);

    for (clients.items) |cl| {
        if (cl.pid == pid) cl.seen = false;
    }
    scanApp(app, &scan);
    sweep(&scan, pid);
    finishScan(&scan, pid);
    log.debug("reconcile {s}: {d:.0} ms", .{ app.name, (runloop.now() - t0) * 1000 });
}

/// A window whose centre now lies on another display was dragged there by the
/// user: hand it to that monitor (the user-driven version of `tag_monitor`).
///
/// Only windows zwm has already placed are looked at, and only if they are not
/// where zwm put them. A window that has just appeared (not placed yet) may
/// still be on another display than the one zwm is about to move it to: that
/// is not a drag, and treating it as one would send it straight back.
/// Is the user dragging something? The left button is down, or was a moment
/// ago (the scan that follows a release runs a few milliseconds later). Only
/// then can a window that is not where zwm put it have been moved BY THE USER;
/// otherwise macOS moved it (a display going away, waking up) and zwm puts it
/// back. AeroSpace asks the same question before treating a move as a drag.
fn userIsDragging() bool {
    if (mouseButtonDown()) return true;
    return runloop.now() - mouse_last_down < 1.0;
}

fn mouseButtonDown() bool {
    if (!c.CGEventSourceButtonState(c.kCGEventSourceStateCombinedSessionState, c.kCGMouseButtonLeft)) return false;
    mouse_last_down = runloop.now();
    return true;
}

/// Just after a drag or click ended: the moment to look at where windows ended up.
fn justReleased() bool {
    return !mouseButtonDown() and runloop.now() - mouse_last_down < 1.0;
}

/// A tiled window the user moved or resized by hand goes back to its tile
/// (AeroSpace does the same; moving between monitors is `followDrags`). Only
/// looks right after the mouse is released, so a window being dragged is left
/// alone and nothing is read on every scan.
fn healDrift(only_pid: ?i32) void {
    if (!justReleased()) return;
    for (clients.items) |cl| {
        if (!tiled(cl) or !visible(cl) or parked(cl)) continue;
        if (only_pid) |p| {
            if (cl.pid != p) continue;
        }
        if (!responsive(cl.pid)) continue;
        const placed = switch (cl.placement) {
            .shown => |r| r,
            else => continue,
        };
        const f = ax.getFrame(cl.window) orelse continue;
        if (f.eql(placed)) continue;
        if (cl.accepted) |a| {
            if (f.eql(a)) continue; // the app's own idea of our rectangle
        }
        log.debug("id {d} ({s}) was moved or resized by hand: putting it back", .{ cl.id, appName(cl.pid) });
        const want = if (config.resizehints) fit(cl, cl.rect) else cl.rect;
        ax.setFrame(cl.app, cl.window, want);
        cl.accepted = ax.getFrame(cl.window);
    }
}

fn followDrags(only_pid: ?i32) void {
    if (nmons < 2 or !userIsDragging()) return;
    var moves: [16]struct { cl: *Client, to: usize } = undefined;
    var n: usize = 0;
    for (clients.items) |cl| {
        if (parked(cl) or !visible(cl) or n == moves.len) continue;
        if (only_pid) |p| {
            if (cl.pid != p) continue;
        }
        if (!responsive(cl.pid)) continue;
        const placed = switch (cl.placement) {
            .shown => |r| r,
            else => continue, // never placed yet (or parked): nothing to compare with
        };
        const f = ax.getFrame(cl.window) orelse continue;
        if (f.eql(placed)) continue; // exactly where zwm put it: not moved
        const cx = f.x + @divFloor(f.w, 2);
        const cy = f.y + @divFloor(f.h, 2);
        if (mons[cl.mon].screen.contains(cx, cy)) continue;
        for (mons[0..nmons], 0..) |m, i| {
            if (i != cl.mon and m.screen.contains(cx, cy)) {
                cl.rect = f;
                moves[n] = .{ .cl = cl, .to = i };
                n += 1;
                break;
            }
        }
    }
    for (moves[0..n]) |mv| sendmon(mv.cl, mv.to, false);
}

// ------------------------------------------------------ sleep / displays

var reconcile_pending = false;
var geometry_pending = false;
var followup_pending = false;
var full_requested = false;
var dirty_pids: std.ArrayList(i32) = .empty;

fn doReconcile(_: usize) void {
    reconcile_pending = false;
    if (paused) return;
    if (full_requested) {
        full_requested = false;
        dirty_pids.clearRetainingCapacity();
        reconcile();
        return;
    }
    const pids = dirty_pids.toOwnedSlice(gpa) catch {
        reconcile();
        return;
    };
    defer gpa.free(pids);
    for (pids) |pid| reconcileApp(pid);
}

/// macOS reports a focus change slightly BEFORE it is visible through the
/// Accessibility API, so a first read can see the old focus. A second, later
/// look (just the focus: cheap) catches up.
fn doFollowup(_: usize) void {
    followup_pending = false;
    if (!paused) refreshFocus();
}

fn doFocusSync(_: usize) void {
    if (!paused) refreshFocus();
}

fn doGeometry(_: usize) void {
    geometry_pending = false;
    if (paused) return;
    updateGeometry();
    reconcile();
}

fn scheduleFollowup() void {
    if (followup_pending) return;
    followup_pending = true;
    runloop.after(0.3, doFollowup, 0);
}

fn schedule() void {
    scheduleFollowup();
    if (reconcile_pending) return;
    reconcile_pending = true;
    runloop.after(config.debounce, doReconcile, 0);
}

/// The left mouse button went up: a drag may just have ended (and a click on a
/// window's close button may have closed one). Look at everything shortly.
pub fn mouseReleased() void {
    mouse_last_down = runloop.now();
    requestReconcile();
    runloop.after(0.15, doClickMonitor, 0);
}

/// Clicking on an empty part of another monitor (its wallpaper) makes that
/// monitor the selected one. Clicking a window already does, through the focus
/// change: so wait a moment, let that settle, and only act if it did not. The
/// menu bar and Dock are outside a monitor's `area`, so clicks there do nothing.
fn doClickMonitor(_: usize) void {
    if (paused or nmons < 2) return;
    syncFocus();
    const event = c.CGEventCreate(null) orelse return;
    defer c.CFRelease(event);
    const p = c.CGEventGetLocation(event);
    const px: i32 = @intFromFloat(@floor(p.x));
    const py: i32 = @intFromFloat(@floor(p.y));
    for (mons[0..nmons], 0..) |m, i| {
        if (i == selmon or !m.area.contains(px, py)) continue;
        log.debug("clicked on monitor {d}: selecting it", .{i});
        selmon = i;
        focus(selected(i));
        return;
    }
}

/// Something may have changed anywhere (app launched/quit, Space changed).

/// Something may have changed anywhere (app launched/quit, Space changed).
/// Batches bursts into one full pass.
pub fn requestReconcile() void {
    if (paused or nmons == 0) return;
    full_requested = true;
    schedule();
}

/// An app reported a window event: only that app needs a look.
pub fn requestApp(pid: i32) void {
    if (paused or nmons == 0) return;
    if (std.mem.indexOfScalar(i32, dirty_pids.items, pid) == null) dirty_pids.append(gpa, pid) catch {
        full_requested = true;
    };
    schedule();
}

/// An app was activated: only the focus can have changed.
pub fn requestFocusSync() void {
    if (paused or nmons == 0) return;
    runloop.after(config.debounce, doFocusSync, 0);
    scheduleFollowup();
}

/// Displays changed. Wait a moment: macOS reports several changes in a row.
pub fn requestGeometry() void {
    if (geometry_pending or paused) return;
    geometry_pending = true;
    runloop.after(0.4, doGeometry, 0);
}

/// Going to sleep / screen locked: stop touching windows.
pub fn pause() void {
    log.debug("pause", .{});
    paused = true;
    hotkeys.suspended = true;
}

/// Back from sleep / unlocked: re-arm everything. Displays can take a second
/// to come back, so the geometry pass runs shortly after.
pub fn wake() void {
    log.debug("wake", .{});
    paused = false;
    hotkeys.suspended = false;
    hotkeys.ensureEnabled();
    last_beat = runloop.now();
    geometry_pending = true;
    runloop.after(1.0, doGeometry, 0);
}

/// Every few seconds: keep the key tap alive, notice that we slept (a long gap
/// between beats means the machine was suspended even if no notification
/// reached us), and reconcile in case a notification was lost.
pub fn heartbeat() void {
    const now = runloop.now();
    if (last_beat == 0) last_beat = now;
    const gap = now - last_beat;
    last_beat = now;
    if (paused) return;
    hotkeys.ensureEnabled();
    if (gap > config.heartbeat * 3 + 5) {
        wake();
        return;
    }
    reconcile();
}

/// Put every parked window back on screen. Runs on quit so no window is lost.
fn shutdown() void {
    for (clients.items) |cl| {
        if (parked(cl)) ax.setFrame(cl.app, cl.window, cl.rect);
    }
}

var restoring = false;

/// Called when zwm is crashing (a Zig panic): put parked windows back on
/// screen before dying, so a bug can't leave your windows off-screen. Careful
/// not to make things worse: runs at most once, and does nothing fancy.
pub fn emergencyRestore() void {
    if (restoring) return;
    restoring = true;
    shutdown();
}

/// Free everything we allocated, so the leak report at exit means something.
fn cleanup() void {
    while (clients.items.len > 0) _ = unmanage(clients.items[0]);
    clients.deinit(gpa);
    dirty_pids.deinit(gpa);
    apps.deinit();
}

pub fn quit() void {
    shutdown(); // put parked windows back first: that matters most
    cleanup();
    mem.reportLeaks();
    std.process.exit(0);
}

// --------------------------------------------------------------- actions

/// Do what a key binding says. The `switch` has no `else`: add a new action to
/// `types.Action` and the compiler makes you handle it here.
pub fn run(action: Action) void {
    log.debug("action: {s}", .{@tagName(action)});
    switch (action) {
        .spawn => |cmd| spawn(cmd),
        .view => |mask| if (mons[selmon].viewTo(mask)) retag(),
        .view_previous => if (mons[selmon].viewPrevious()) retag(),
        .toggle_view => |mask| if (mons[selmon].toggleView(mask)) retag(),
        .tag => |mask| tagWindow(mask, false),
        .toggle_tag => |mask| tagWindow(mask, true),
        .focus_stack => |dir| focusStack(dir),
        .focus_monitor => |dir| focusMonitor(dir),
        .tag_monitor => |dir| tagMonitor(dir),
        .inc_nmaster => |d| if (mons[selmon].incNmaster(d)) arrange(selmon),
        .inc_mfact => |d| if (mons[selmon].incMfact(d)) arrange(selmon),
        .set_layout => |name| {
            const idx = model.layoutIndex(name) orelse return;
            if (mons[selmon].setLayout(idx)) arrange(selmon);
        },
        .last_layout => if (mons[selmon].lastLayout()) arrange(selmon),
        .zoom => zoom(),
        .toggle_floating => {
            const s = selected(selmon) orelse return;
            s.floating = !s.floating;
            arrange(selmon);
        },
        .toggle_bar => bar.toggle(),
        .kill_client => {
            const s = selected(selmon) orelse return;
            ax.closeWindow(s.window);
        },
        .quit => quit(),
        .custom => |f| f(),
    }
}

/// The shown tags changed: lay out again, then pick what to focus.
fn retag() void {
    arrange(selmon);
    focus(null);
}

fn tagWindow(mask: u32, toggle: bool) void {
    const s = selected(selmon) orelse return;
    const bits = mask & tagmask;
    const new = if (toggle) s.tags ^ bits else bits;
    if (new == 0) return;
    s.tags = new;
    retag();
}

/// Visible, shown windows of the selected monitor, in tiling order.
fn focusCandidates(list: *std.ArrayList(*Client)) void {
    for (clients.items) |cl| {
        if (cl.mon == selmon and visible(cl) and !parked(cl) and !cl.away) list.append(gpa, cl) catch return;
    }
}

fn focusStack(dir: i32) void {
    const s = selected(selmon) orelse return;
    var cand: std.ArrayList(*Client) = .empty;
    defer cand.deinit(gpa);
    focusCandidates(&cand);
    const idx = std.mem.indexOfScalar(*Client, cand.items, s) orelse return;
    const next = if (dir > 0) (idx + 1) % cand.items.len else (idx + cand.items.len - 1) % cand.items.len;
    focus(cand.items[next]);
}

fn focusMonitor(dir: i32) void {
    if (nmons < 2) return;
    const next = monitorAfter(dir);
    if (next == selmon) return;
    selmon = next;
    focus(null);
}

fn monitorAfter(dir: i32) usize {
    const n: i32 = @intCast(nmons);
    return @intCast(@mod(@as(i32, @intCast(selmon)) + dir, n));
}

fn tagMonitor(dir: i32) void {
    const s = selected(selmon) orelse return;
    if (nmons < 2) return;
    sendmon(s, monitorAfter(dir), true);
}

/// Swap the focused window with the master (or, if it already is the master,
/// with the next window).
fn zoom() void {
    var s = selected(selmon) orelse return;
    if (!tiled(s)) return;
    var first: ?*Client = null;
    var second: ?*Client = null;
    for (clients.items) |cl| {
        if (cl.mon != selmon or !visible(cl) or !tiled(cl)) continue;
        if (first == null) first = cl else if (second == null) second = cl;
    }
    if (s == first) s = second orelse return;
    if (std.mem.indexOfScalar(*Client, clients.items, s)) |i| _ = clients.orderedRemove(i);
    clients.insert(gpa, 0, s) catch return;
    arrange(selmon);
    focus(s);
}

/// Move a window to another monitor. `rescale` keeps a floating window at the
/// same relative position; false keeps it exactly where it is.
fn sendmon(cl: *Client, to: usize, rescale: bool) void {
    if (cl.mon == to) return;
    const from = mons[cl.mon].area;
    const dest = mons[to];
    if (rescale) {
        cl.rect.x = dest.area.x + @divFloor((cl.rect.x - from.x) * dest.area.w, from.w);
        cl.rect.y = dest.area.y + @divFloor((cl.rect.y - from.y) * dest.area.h, from.h);
    }
    cl.mon = @intCast(to);
    cl.home = dest.display_id; // an explicit move: this is the new home
    cl.tags = dest.view;
    cl.placement = .unknown;
    arrangeAll();
    focus(null);
}

extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;
extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;

fn cString(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ?[*:0]u8 {
    const buf = a.allocSentinel(u8, std.fmt.count(fmt, args), 0) catch return null;
    _ = std.fmt.bufPrint(buf, fmt, args) catch return null;
    return buf.ptr;
}

/// The environment for programs we start: ours, plus
///  * a PATH that also finds programs installed next to zwm and in the usual
///    places (see model.searchPath), even when zwm was started by launchd with
///    its minimal PATH;
///  * ZWM_MONITOR: the number of the monitor you are working on (0 = leftmost),
///    which programs such as zmenu use to appear on the right screen.
fn childEnvironment(a: std.mem.Allocator) ?[*:null]?[*:0]u8 {
    var exe_buf: [1024]u8 = undefined;
    var size: u32 = exe_buf.len;
    var dir: []const u8 = "";
    if (_NSGetExecutablePath(&exe_buf, &size) == 0) {
        dir = std.fs.path.dirname(std.mem.sliceTo(&exe_buf, 0)) orelse "";
    }
    var list: std.ArrayList(?[*:0]u8) = .empty;
    var current_path: ?[]const u8 = null;
    const env = _NSGetEnviron().*;
    var i: usize = 0;
    while (env[i]) |entry| : (i += 1) {
        const s = std.mem.span(entry);
        if (std.mem.startsWith(u8, s, "ZWM_MONITOR=")) continue; // ours replaces it
        if (std.mem.startsWith(u8, s, "PATH=")) {
            current_path = s[5..]; // ours replaces it, built from this
        } else {
            list.append(a, entry) catch return null;
        }
    }
    const home = if (c.getenv("HOME")) |h| std.mem.span(h) else "";
    const path = model.searchPath(a, dir, current_path, home) catch return null;
    list.append(a, cString(a, "PATH={s}", .{path})) catch return null;
    list.append(a, cString(a, "ZWM_MONITOR={d}", .{selmon})) catch return null;
    list.append(a, null) catch return null;
    return @ptrCast(list.items.ptr);
}

/// Start a program (no shell involved unless you ask for one with `sh`).
fn spawn(cmd: []const []const u8) void {
    if (cmd.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = a.alloc(?[*:0]u8, cmd.len + 1) catch return;
    for (cmd, 0..) |s, i| {
        const z = a.allocSentinel(u8, s.len, 0) catch return;
        @memcpy(z, s);
        argv[i] = z.ptr;
    }
    argv[cmd.len] = null;
    var pid: c.pid_t = 0;
    const envp = childEnvironment(a) orelse _NSGetEnviron().*;
    const rc = c.posix_spawnp(&pid, argv[0].?, null, null, @ptrCast(argv.ptr), @ptrCast(envp));
    if (rc != 0) std.debug.print("zwm: could not start {s} (error {d})\n", .{ cmd[0], rc });
}

/// Print everything zwm knows (send SIGUSR1 to trigger it). `*` marks the
/// selected window of each monitor.
pub fn dump() void {
    const p = std.debug.print;
    p("---- zwm state: {d} monitor(s), selmon={d}, paused={}, {d} window(s)\n", .{ nmons, selmon, paused, clients.items.len });
    for (mons[0..nmons], 0..) |m, i| {
        p("monitor {d}{s}: display={d} area=({d},{d} {d}x{d}) view={b} previous={b}\n", .{ i, if (i == selmon) " (selected)" else "", m.display_id, m.area.x, m.area.y, m.area.w, m.area.h, m.view, m.prev_view });
        for (config.tags, m.tag) |t, s| {
            p("    tag {s}: layout={s} previous={s} mfact={d} nmaster={d}\n", .{ t.name, config.layouts[s.layout].name, config.layouts[s.prev_layout].name, s.mfact, s.nmaster });
        }
    }
    for (ghosts[0..nghosts]) |g| {
        p("remembered, display not connected: display={d} ({d}x{d}) view={b}\n", .{ g.display_id, g.screen.w, g.screen.h, g.view });
    }
    for (clients.items) |cl| {
        const mark: u8 = if (selected(cl.mon) == cl) '*' else ' ';
        p("{c} id={d} {s} mon={d} home={d} tags={b} {s} rect=({d},{d} {d}x{d}) min={d}x{d} tick={d} ", .{ mark, cl.id, appName(cl.pid), cl.mon, cl.home, cl.tags, if (cl.floating) "floating" else "tiled", cl.rect.x, cl.rect.y, cl.rect.w, cl.rect.h, cl.min_w, cl.min_h, cl.focus_tick });
        switch (cl.placement) {
            .unknown => p("unknown\n", .{}),
            .parked => p("parked\n", .{}),
            .shown => |r| p("shown({d},{d} {d}x{d})\n", .{ r.x, r.y, r.w, r.h }),
        }
    }
    p("----\n", .{});
}
