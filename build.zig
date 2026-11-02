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

//! Build script for zwm.
//!
//! The important trick (borrowed from dwm's Makefile): the config is a Zig
//! source file that is compiled INTO the program. If `config.zig` does not
//! exist yet we copy `config.def.zig` to it. Edit `config.zig`, run
//! `zig build`, restart zwm. `config.def.zig` is never touched.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // dwm: `config.h: cp config.def.h $@`.  Never overwrites an existing config.zig.
    const make_config = b.addSystemCommand(&.{ "/bin/sh", "-c", "[ -f config.zig ] || cp config.def.zig config.zig" });

    // The macOS C headers (Accessibility, CoreGraphics, CoreFoundation, the
    // Objective-C runtime) are turned into a Zig module by translate-c.
    const c_mod = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();

    // Objective-C: the `zig-objc` package (also used by Ghostty) does the
    // message sending; `src/cocoa.zig` adds a few helpers on top of it.
    const zig_objc = b.dependency("zig_objc", .{ .target = target, .optimize = optimize });
    const objc_mod = zig_objc.module("objc");

    // Two modules that import each other: `zwm` (the window manager) reads
    // `config`, and `config` uses types and actions from `zwm`.
    const zwm_mod = b.createModule(.{
        .root_source_file = b.path("src/zwm.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "c", .module = c_mod }, .{ .name = "objc", .module = objc_mod } },
    });
    const config_mod = b.createModule(.{
        .root_source_file = b.path("config.zig"),
        .target = target,
        .optimize = optimize,
    });
    zwm_mod.addImport("config", config_mod);
    config_mod.addImport("zwm", zwm_mod);

    for ([_][]const u8{ "AppKit", "ApplicationServices", "CoreFoundation", "CoreGraphics" }) |fw|
        zwm_mod.linkFramework(fw, .{});

    const exe = b.addExecutable(.{
        .name = "zwm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zwm", .module = zwm_mod }},
        }),
    });
    exe.step.dependOn(&make_config.step);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Build and run zwm").dependOn(&run.step);

    // `zig build bundle` makes zig-out/zwm.app: the same program inside an app
    // bundle. Run that way (or from a login item), macOS gives the Accessibility
    // permission to "zwm" itself instead of to the terminal you started it from.
    // The permission is tied to the app's code signature: the default ad-hoc
    // signature changes with every build, so after rebuilding you have to
    // enable zwm in System Settings again. A stable identity avoids that:
    //     zig build bundle -Dsign-identity="My Certificate"
    const sign_identity = b.option([]const u8, "sign-identity", "codesign identity for `bundle` (default: ad-hoc)") orelse "-";
    const install_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "zwm.app/Contents/MacOS" } },
    });
    const install_plist = b.addInstallFile(b.path("resources/Info.plist"), "zwm.app/Contents/Info.plist");
    const sign = b.addSystemCommand(&.{ "codesign", "--force", "--deep", "--sign", sign_identity, "zig-out/zwm.app" });
    sign.step.dependOn(&install_exe.step);
    sign.step.dependOn(&install_plist.step);
    b.step("bundle", "Build zig-out/zwm.app (see build.zig for the Accessibility note)").dependOn(&sign.step);

    // `zig build test` runs the unit tests (layout maths, key matching).
    const tests = b.addTest(.{ .root_module = zwm_mod });
    tests.step.dependOn(&make_config.step);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
