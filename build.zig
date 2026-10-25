const std = @import("std");
const Translator = @import("translate_c").Translator;

const feature_names = [_][]const u8{
    "cooling_performance",
    "device",
    "display",
    "input_performance",
    "lighting",
    "power",
    "system_performance",
};

const FeatureModules = struct {
    name: []const u8,
    capability: *std.Build.Module,
    engine: *std.Build.Module,
};

const DescriptorModule = struct {
    name: []const u8,
    module: *std.Build.Module,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // A preferred mode prevents standardOptimizeOption from registering -Doptimize.
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.dependency("translate_c", .{});
    const transport = module(b, b.path("src/device/transport.zig"), target, optimize);
    const device_lock = module(b, b.path("src/platform/device_lock.zig"), target, optimize);

    transport.addImport("hidapi_c", hidapiC(b, translate_c, target, optimize));
    transport.addImport("device_lock", device_lock);
    const ui = module(b, b.path("src/interface/ui.zig"), target, optimize);
    const probe_result = module(b, b.path("src/device/probe_result.zig"), target, optimize);

    probe_result.addImport("ui", ui);
    probe_result.addImport("transport", transport);
    const battery = module(b, b.path("src/platform/battery.zig"), target, optimize);

    const power_mode = module(b, b.path("src/features/power_mode.zig"), target, optimize);

    power_mode.addImport("transport", transport);
    const saved = module(b, b.path("src/settings/saved.zig"), target, optimize);

    saved.addImport("ui", ui);
    const device_base_types = module(b, b.path("src/device/base_types.zig"), target, optimize);

    var features: std.ArrayList(FeatureModules) = .empty;

    for (feature_names) |name| {
        const capability_path = b.fmt("src/features/{s}_types.zig", .{name});
        const capability = module(b, b.path(capability_path), target, optimize);

        if (std.mem.eql(u8, name, "system_performance"))
            capability.addImport("device_base_types", device_base_types);

        const engine = module(b, b.path(b.fmt("src/features/{s}.zig", .{name})), target, optimize);

        engine.addImport("transport", transport);
        engine.addImport("ui", ui);
        engine.addImport("probe_result", probe_result);

        if (std.mem.eql(u8, name, "power"))
            engine.addImport("battery", battery);

        if (std.mem.eql(u8, name, "power") or std.mem.eql(u8, name, "system_performance") or std.mem.eql(u8, name, "display"))
            engine.addImport("power_mode", power_mode);

        features.append(b.allocator, .{ .name = name, .capability = capability, .engine = engine }) catch @panic("OOM");
    }

    const capabilities_source = capabilitiesSource(b, features.items);
    const capabilities = module(b, b.addWriteFiles().add("capabilities.zig", capabilities_source), target, optimize);

    for (features.items) |feature|
        capabilities.addImport(b.fmt("features/{s}_types", .{feature.name}), feature.capability);

    const device_types = module(b, b.path("src/device/types.zig"), target, optimize);

    device_types.addImport("capabilities", capabilities);
    device_types.addImport("device_base_types", device_base_types);

    const setting_types = module(b, b.path("src/settings/types.zig"), target, optimize);

    setting_types.addImport("device_types", device_types);
    setting_types.addImport("transport", transport);
    setting_types.addImport("ui", ui);

    for (features.items) |feature| {
        feature.engine.addImport("device_types", device_types);
        feature.engine.addImport("setting_types", setting_types);
        feature.engine.addImport(b.fmt("features/{s}_types", .{feature.name}), feature.capability);
    }

    var descriptor_modules: std.ArrayList(DescriptorModule) = .empty;

    for (scanDevices(b)) |path| {
        const name = path[0 .. path.len - ".zig".len];
        const descriptor = module(b, b.path(b.pathJoin(&.{ "src", path })), target, optimize);

        descriptor.addImport("device_types", device_types);

        for (features.items) |feature| {
            if (std.mem.eql(u8, feature.name, "lighting"))
                descriptor.addImport("features/lighting_types", feature.capability);
        }

        descriptor_modules.append(b.allocator, .{ .name = name, .module = descriptor }) catch @panic("OOM");
    }

    const registry_source = registrySource(b, features.items, descriptor_modules.items);
    const registry = module(b, b.addWriteFiles().add("registry.zig", registry_source), target, optimize);

    registry.addImport("device_types", device_types);

    for (features.items) |feature|
        registry.addImport(b.fmt("features/{s}", .{feature.name}), feature.engine);

    for (descriptor_modules.items) |descriptor|
        registry.addImport(descriptor.name, descriptor.module);

    const device = module(b, b.path("src/device/catalog.zig"), target, optimize);

    device.addImport("device_types", device_types);
    device.addImport("registry", registry);

    const settings = module(b, b.path("src/settings/engine.zig"), target, optimize);

    settings.addImport("device_types", device_types);
    settings.addImport("setting_types", setting_types);
    settings.addImport("transport", transport);
    settings.addImport("ui", ui);
    settings.addImport("saved", saved);
    settings.addImport("registry", registry);

    const frame_session = module(b, b.path("src/playback/frame_session.zig"), target, optimize);
    const stream_input = module(b, b.path("src/platform/stream_input.zig"), target, optimize);
    stream_input.link_libc = true;

    frame_session.addImport("stream_input", stream_input);
    frame_session.addImport("settings", settings);
    frame_session.addImport("transport", transport);
    frame_session.addImport("device_types", device_types);
    const polychromatic = module(b, b.path("src/polychromatic.zig"), target, optimize);
    const chroma = module(b, b.path("src/chroma.zig"), target, optimize);
    const keyboard_input = module(b, b.path("src/platform/keyboard.zig"), target, optimize);
    keyboard_input.link_libc = true;
    keyboard_input.addImport("chroma", chroma);
    keyboard_input.addImport("transport", transport);
    for (features.items) |feature|
        if (std.mem.eql(u8, feature.name, "lighting"))
            keyboard_input.addImport("lighting_types", feature.capability);

    // C imports for each OS backend. Other targets fail in the modules' @compileError.
    switch (target.result.os.tag) {
        .linux => {
            device_lock.addImport("device_lock_linux_c", translateC(b, translate_c, "src/c/device_lock_linux.h", target, optimize, &.{}));
            keyboard_input.addImport("keyboard_input_c", translateC(b, translate_c, "src/c/keyboard_input.h", target, optimize, &.{}));
        },
        .windows => {
            device_lock.addImport("device_lock_windows_c", translateC(b, translate_c, "src/c/device_lock_windows.h", target, optimize, &.{}));
            battery.addImport("battery_windows_c", translateC(b, translate_c, "src/c/battery_windows.h", target, optimize, &.{.{ .name = "setupapi" }}));
            stream_input.addImport("stream_input_windows_c", translateC(b, translate_c, "src/c/stream_input_windows.h", target, optimize, &.{}));
        },
        else => {},
    }

    const app = module(b, b.path("src/main.zig"), target, optimize);

    app.link_libc = true;
    app.addImport("device", device);
    app.addImport("device_types", device_types);
    app.addImport("settings", settings);
    app.addImport("setting_types", setting_types);
    app.addImport("transport", transport);
    app.addImport("ui", ui);
    app.addImport("probe_result", probe_result);
    app.addImport("frame_session", frame_session);
    app.addImport("polychromatic", polychromatic);
    app.addImport("chroma", chroma);
    app.addImport("keyboard_input", keyboard_input);

    const test_step = b.step("test", "Run unit tests");

    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = app })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = device })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = settings })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = device_types })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = setting_types })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = transport })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = frame_session })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = polychromatic })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = chroma })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = keyboard_input })).step);

    const collection = module(b, b.path("examples/test_collection.zig"), target, optimize);
    collection.addImport("chroma", chroma);
    collection.addImport("polychromatic", polychromatic);
    collection.addImport("device", device);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = collection })).step);

    for ([_]*std.Build.Module{ ui, probe_result, saved, battery, device_base_types, stream_input, device_lock }) |shared|
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = shared })).step);

    for (features.items) |feature|
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = feature.engine })).step);

    for (features.items) |feature|
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = feature.capability })).step);

    const exe = b.addExecutable(.{ .name = "razerctl", .root_module = app });

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);

    run.addPassthruArgs();

    b.step("run", "Run razerctl").dependOn(&run.step);
}

fn translateC(b: *std.Build, dep: *std.Build.Dependency, header: []const u8, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, libs: []const Translator.LinkSystemLib) *std.Build.Module {
    const translator: Translator = .init(dep, .{
        .c_source_file = b.path(header),
        .target = target,
        .optimize = optimize,
        .link_system_libs = libs,
    });

    return translator.mod;
}

/// Linux uses the system hidraw backend; Windows builds the vendored hidapi statically.
fn hidapiC(b: *std.Build, dep: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    if (target.result.os.tag != .windows)
        return translateC(b, dep, "src/c/hidapi.h", target, optimize, &.{.{ .name = "hidapi-hidraw" }});

    const source = b.dependency("hidapi", .{});
    const lib = b.addLibrary(.{
        .name = "hidapi",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });

    lib.root_module.addCSourceFile(.{ .file = source.path("windows/hid.c") });
    lib.root_module.addIncludePath(source.path("hidapi"));
    lib.root_module.linkSystemLibrary("setupapi", .{});
    lib.root_module.linkSystemLibrary("hid", .{});
    lib.installHeadersDirectory(source.path("hidapi"), "hidapi", .{});

    const translator: Translator = .init(dep, .{
        .c_source_file = b.path("src/c/hidapi.h"),
        .target = target,
        .optimize = optimize,
    });

    translator.linkLibrary(lib);
    return translator.mod;
}

fn module(b: *std.Build, root: std.Build.LazyPath, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = root,
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
        // Windows x64 needs unwind tables for SEH, including in Zig's bundled mingw CRT.
        .unwind_tables = if (target.result.os.tag == .windows) null else .none,
    });
}

fn capabilitiesSource(b: *std.Build, features: []const FeatureModules) []const u8 {
    var fields: std.ArrayList(u8) = .empty;

    for (features) |feature|
        fields.appendSlice(b.allocator, b.fmt("    {s}: @import(\"features/{s}_types\").Config = .{{}},\n", .{ feature.name, feature.name })) catch @panic("OOM");

    return b.fmt(
        \\//! Generated from the explicit device capability contracts in build.zig.
        \\pub const Features = struct {{
        \\{s}}};
        \\
    , .{fields.items});
}

fn registrySource(b: *std.Build, features: []const FeatureModules, descriptors: []const DescriptorModule) []const u8 {
    var feature_fields: std.ArrayList(u8) = .empty;

    for (features) |feature|
        feature_fields.appendSlice(b.allocator, b.fmt("    pub const {s} = @import(\"features/{s}\");\n", .{ feature.name, feature.name })) catch @panic("OOM");

    var device_items: std.ArrayList(u8) = .empty;

    for (descriptors) |descriptor|
        device_items.appendSlice(b.allocator, b.fmt("    @import(\"{s}\").descriptor,\n", .{descriptor.name})) catch @panic("OOM");

    return b.fmt(
        \\//! Generated by build.zig: features are explicit; device descriptors are discovered.
        \\pub const features = struct {{
        \\{s}}};
        \\
        \\pub const devices = [_]@import("device_types").Descriptor{{
        \\{s}}};
        \\
    , .{ feature_fields.items, device_items.items });
}

/// Discover descriptors by category, sorted for stable tables and completion.
fn scanDevices(b: *std.Build) []const []const u8 {
    const io = b.graph.io;
    const src = b.pathJoin(&.{ "src", "device", "descriptors" });

    // Rescan when a device file is added or removed.
    b.dependOnDirectoryContents(b.path(src));
    const dir_path = b.root.joinString(b.allocator, src) catch @panic("OOM");
    var dir = b.root.root_dir.handle.openDir(io, dir_path, .{ .iterate = true }) catch |err|
        std.debug.panic("cannot open {s}: {t}", .{ src, err });
    defer dir.close(io);

    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;

    while (walker.next(io) catch |err| std.debug.panic("cannot read {s}: {t}", .{ src, err })) |entry| {
        // The walker uses native separators, but generated @import names need '/'.
        const entry_path = b.allocator.dupe(u8, entry.path) catch @panic("OOM");
        std.mem.replaceScalar(u8, entry_path, '\\', '/');

        // Directory dependencies only track direct entries, so add each family folder too.
        if (entry.kind == .directory and std.mem.indexOfScalar(u8, entry_path, '/') == null)
            b.dependOnDirectoryContents(b.path(b.pathJoin(&.{ src, entry_path })));

        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig"))
            continue;

        if (std.mem.indexOfScalar(u8, entry_path, '/') == null)
            continue;

        paths.append(b.allocator, b.fmt("device/descriptors/{s}", .{entry_path})) catch @panic("OOM");
    }

    std.mem.sort([]const u8, paths.items, {}, lessThan);
    return paths.items;
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
