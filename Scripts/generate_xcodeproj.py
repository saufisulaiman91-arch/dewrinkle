#!/usr/bin/env python3
"""Write Dewrinkle.xcodeproj and the app icon. Run from anywhere."""

import hashlib
import os
import re
import struct
import zlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def uid(name: str) -> str:
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()


def chunk(tag: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def write_png(path: str, width: int, height: int, pixels: bytes) -> None:
    raw = bytearray()
    stride = width * 3
    for y in range(height):
        raw.append(0)
        raw.extend(pixels[y * stride : (y + 1) * stride])
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)


def icon_pixels(size: int) -> bytes:
    pixels = bytearray(size * size * 3)

    def set_px(x: int, y: int, r: int, g: int, b: int) -> None:
        if x < 0 or y < 0 or x >= size or y >= size:
            return
        i = (y * size + x) * 3
        pixels[i : i + 3] = bytes((r, g, b))

    for y in range(size):
        for x in range(size):
            nx = x / (size - 1)
            ny = y / (size - 1)
            vignette = 1 - 0.22 * ((nx - 0.5) ** 2 + (ny - 0.5) ** 2) * 4
            base = int(28 * vignette)
            set_px(x, y, base + 4, base + 2, base)
            # A soft fold, lighter than the ground, running down the cloth.
            fold = abs((nx - 0.38) - 0.08 * (ny - 0.5))
            if 0.18 < ny < 0.82 and fold < 0.09:
                lift = int(36 * (1 - fold / 0.09) * (1 - abs(ny - 0.5)))
                set_px(x, y, base + 18 + lift, base + 14 + lift, base + 10 + lift)
            # Weave ticks that the high-frequency layer is meant to keep.
            if 0.22 < ny < 0.78 and (x // max(size // 48, 1) + y // max(size // 48, 1)) % 2 == 0:
                if fold > 0.11:
                    set_px(x, y, base + 10, base + 9, base + 7)
    # Copper topstitch. This is the structure the mask protects.
    stitch_y = int(size * 0.62)
    thickness = max(size // 90, 1)
    dash = max(size // 28, 2)
    gap = max(size // 40, 1)
    for x in range(int(size * 0.18), int(size * 0.82)):
        if (x // (dash + gap)) % 2 == 0:
            for t in range(-thickness, thickness + 1):
                set_px(x, stitch_y + t, 214, 154, 92)
    return bytes(pixels)


def downsample(src: bytes, src_size: int, dst_size: int) -> bytes:
    if dst_size == src_size:
        return src
    out = bytearray(dst_size * dst_size * 3)
    scale = src_size / dst_size
    for y in range(dst_size):
        for x in range(dst_size):
            x0 = int(x * scale)
            x1 = min(src_size, int((x + 1) * scale))
            y0 = int(y * scale)
            y1 = min(src_size, int((y + 1) * scale))
            acc = [0, 0, 0]
            count = 0
            for yy in range(y0, max(y1, y0 + 1)):
                for xx in range(x0, max(x1, x0 + 1)):
                    i = (yy * src_size + xx) * 3
                    acc[0] += src[i]
                    acc[1] += src[i + 1]
                    acc[2] += src[i + 2]
                    count += 1
            o = (y * dst_size + x) * 3
            out[o : o + 3] = bytes(channel // count for channel in acc)
    return bytes(out)


def write_icons() -> None:
    folder = os.path.join(ROOT, "App", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(folder, exist_ok=True)
    master = icon_pixels(1024)
    sizes = {
        "icon_16.png": 16,
        "icon_32.png": 32,
        "icon_64.png": 64,
        "icon_128.png": 128,
        "icon_256.png": 256,
        "icon_512.png": 512,
        "icon_1024.png": 1024,
    }
    for name, size in sizes.items():
        write_png(os.path.join(folder, name), size, size, downsample(master, 1024, size))
    contents = """{
  "images" : [
    { "filename" : "icon_16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_32.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_64.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_256.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_512.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
    with open(os.path.join(folder, "Contents.json"), "w") as handle:
        handle.write(contents)
    catalog = os.path.join(ROOT, "App", "Assets.xcassets", "Contents.json")
    with open(catalog, "w") as handle:
        handle.write('{ "info" : { "author" : "xcode", "version" : 1 } }\n')


def q(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def format_setting(value: str) -> str:
    # Xcode's project parser accepts unquoted identifiers, YES/NO, and integers.
    # @rpath, $(SETTING)/path, versions, and "-" must be quoted or the project
    # is reported as damaged.
    if value in {"YES", "NO"}:
        return value
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", value):
        return value
    if re.fullmatch(r"-?[0-9]+", value):
        return value
    return q(value)


def write_project() -> None:
    core_sources = [
        "Brush.swift",
        "ExportSettings.swift",
        "FrequencySeparation.swift",
        "GaussianBlur.swift",
        "GuidedMask.swift",
        "HijabRegion.swift",
        "MaskBuffer.swift",
        "NoiseReduction.swift",
        "Pipeline.swift",
        "Pixels.swift",
        "HistoryStack.swift",
        "PictureTurn.swift",
        "RegionGrow.swift",
        "StructureMask.swift",
        "SubjectMasking.swift",
        "WrinkleDetector.swift",
    ]
    app_sources = [
        ("App/DewrinkleApp.swift", "DewrinkleApp.swift"),
        ("App/Engine/CIPipeline.swift", "CIPipeline.swift"),
        ("App/Engine/KernelSources.swift", "KernelSources.swift"),
        ("App/IO/CGBridge.swift", "CGBridge.swift"),
        ("App/IO/ImageFile.swift", "ImageFile.swift"),
        ("App/Masking/VisionSegmenter.swift", "VisionSegmenter.swift"),
        ("App/UI/CanvasView.swift", "CanvasView.swift"),
        ("App/UI/EditLayer.swift", "EditLayer.swift"),
        ("App/UI/SidebarView.swift", "SidebarView.swift"),
        ("App/UI/ContentView.swift", "ContentView.swift"),
        ("App/UI/EditorModel.swift", "EditorModel.swift"),
        ("App/UI/InspectorView.swift", "InspectorView.swift"),
        ("App/UI/Theme.swift", "Theme.swift"),
    ]
    objects = []

    def add(object_id: str, isa: str, body: str) -> None:
        objects.append(f"\t\t{object_id} /* {isa} */ = {{\n\t\t\tisa = {isa};\n{body}\t\t}};")

    file_refs = {}

    def file_ref(path: str, name: str, kind: str) -> str:
        object_id = uid("fileref:" + path)
        file_refs[path] = object_id
        add(object_id, "PBXFileReference", f"\t\t\tlastKnownFileType = {kind};\n\t\t\tpath = {q(name)};\n\t\t\tsourceTree = \"<group>\";\n")
        return object_id

    for name in core_sources:
        file_ref(f"Sources/DewrinkleCore/{name}", name, "sourcecode.swift")
    for path, name in app_sources:
        file_ref(path, name, "sourcecode.swift")
    file_ref("Tests/DewrinkleCoreTests/EngineTests.swift", "EngineTests.swift", "sourcecode.swift")
    file_ref("App/Info.plist", "Info.plist", "text.plist.xml")
    file_ref("App/Dewrinkle.entitlements", "Dewrinkle.entitlements", "text.plist.entitlements")
    file_ref("App/Shaders/Dewrinkle.metal", "Dewrinkle.metal", "sourcecode.metal")
    file_ref("App/Assets.xcassets", "Assets.xcassets", "folder.assetcatalog")

    app_product = uid("product:app")
    core_product = uid("product:core")
    test_product = uid("product:test")
    add(app_product, "PBXFileReference", '\t\t\texplicitFileType = wrapper.application;\n\t\t\tincludeInIndex = 0;\n\t\t\tpath = Dewrinkle.app;\n\t\t\tsourceTree = BUILT_PRODUCTS_DIR;\n')
    add(core_product, "PBXFileReference", '\t\t\texplicitFileType = archive.ar;\n\t\t\tincludeInIndex = 0;\n\t\t\tpath = libDewrinkleCore.a;\n\t\t\tsourceTree = BUILT_PRODUCTS_DIR;\n')
    add(test_product, "PBXFileReference", '\t\t\texplicitFileType = wrapper.cfbundle;\n\t\t\tincludeInIndex = 0;\n\t\t\tpath = DewrinkleCoreTests.xctest;\n\t\t\tsourceTree = BUILT_PRODUCTS_DIR;\n')

    def build_file(path: str, extra: str = "") -> str:
        object_id = uid("build:" + path + extra)
        settings = f"\t\t\tsettings = {extra};\n" if extra else ""
        add(object_id, "PBXBuildFile", f"\t\t\tfileRef = {file_refs[path]};\n{settings}")
        return object_id

    core_build = [build_file(f"Sources/DewrinkleCore/{name}") for name in core_sources]
    app_build = [build_file(path) for path, _ in app_sources]
    test_build = [build_file("Tests/DewrinkleCoreTests/EngineTests.swift")]

    def product_build(key: str, product: str, settings: str = "") -> str:
        object_id = uid("buildprod:" + key)
        setting_line = f"\t\t\tsettings = {settings};\n" if settings else ""
        add(object_id, "PBXBuildFile", f"\t\t\tfileRef = {product};\n{setting_line}")
        return object_id

    app_link = product_build("app-link-core", core_product)
    test_link = product_build("test-link-core", core_product)
    asset_build = build_file("App/Assets.xcassets")

    def phase(kind: str, key: str, files: list, extra: str = "") -> str:
        object_id = uid("phase:" + key)
        file_lines = "\n".join(f"\t\t\t\t{item}," for item in files)
        add(
            object_id,
            kind,
            f"\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{file_lines}\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n{extra}",
        )
        return object_id

    core_sources_phase = phase("PBXSourcesBuildPhase", "core-sources", core_build)
    core_frameworks_phase = phase("PBXFrameworksBuildPhase", "core-frameworks", [])
    app_sources_phase = phase("PBXSourcesBuildPhase", "app-sources", app_build)
    app_frameworks_phase = phase("PBXFrameworksBuildPhase", "app-frameworks", [app_link])
    app_resources_phase = phase("PBXResourcesBuildPhase", "app-resources", [asset_build])
    test_sources_phase = phase("PBXSourcesBuildPhase", "test-sources", test_build)
    test_frameworks_phase = phase("PBXFrameworksBuildPhase", "test-frameworks", [test_link])

    script_phase = uid("phase:kernel")
    # Trailing \n is part of the OpenStep string. Xcode's parser expects it.
    script = '"' + '\\"' + '${SRCROOT}/Scripts/compile-kernel.sh' + '\\"\\n"'
    add(
        script_phase,
        "PBXShellScriptBuildPhase",
        "\t\t\talwaysOutOfDate = 1;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n\t\t\t);\n"
        "\t\t\tinputPaths = (\n\t\t\t\t\"$(SRCROOT)/App/Shaders/Dewrinkle.metal\",\n\t\t\t);\n"
        "\t\t\tname = \"Compile Core Image kernel\";\n"
        "\t\t\toutputPaths = (\n\t\t\t\t\"$(BUILT_PRODUCTS_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/Dewrinkle.ci.metallib\",\n\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t\tshellPath = /bin/bash;\n"
        f"\t\t\tshellScript = {script};\n",
    )

    def group(key: str, name: str, children: list, path: str = None) -> str:
        object_id = uid("group:" + key)
        child_lines = "\n".join(f"\t\t\t\t{child}," for child in children)
        path_line = f"\t\t\tpath = {q(path)};\n" if path else ""
        add(
            object_id,
            "PBXGroup",
            f"\t\t\tchildren = (\n{child_lines}\n\t\t\t);\n{path_line}\t\t\tsourceTree = \"<group>\";\n" + (f"\t\t\tname = {q(name)};\n" if path != name else f"\t\t\tname = {q(name)};\n"),
        )
        return object_id

    core_group = group("core", "DewrinkleCore", [file_refs[f"Sources/DewrinkleCore/{name}"] for name in core_sources], "DewrinkleCore")
    sources_group = group("sources", "Sources", [core_group], "Sources")
    engine_group = group("engine", "Engine", [file_refs["App/Engine/CIPipeline.swift"], file_refs["App/Engine/KernelSources.swift"]], "Engine")
    io_group = group("io", "IO", [file_refs["App/IO/CGBridge.swift"], file_refs["App/IO/ImageFile.swift"]], "IO")
    mask_group = group("mask", "Masking", [file_refs["App/Masking/VisionSegmenter.swift"]], "Masking")
    ui_group = group(
        "ui",
        "UI",
        [
            file_refs["App/UI/CanvasView.swift"],
            file_refs["App/UI/EditLayer.swift"],
            file_refs["App/UI/SidebarView.swift"],
            file_refs["App/UI/ContentView.swift"],
            file_refs["App/UI/EditorModel.swift"],
            file_refs["App/UI/InspectorView.swift"],
            file_refs["App/UI/Theme.swift"],
        ],
        "UI",
    )
    shader_group = group("shaders", "Shaders", [file_refs["App/Shaders/Dewrinkle.metal"]], "Shaders")
    app_group = group(
        "app",
        "App",
        [
            file_refs["App/DewrinkleApp.swift"],
            engine_group,
            io_group,
            mask_group,
            shader_group,
            ui_group,
            file_refs["App/Assets.xcassets"],
            file_refs["App/Dewrinkle.entitlements"],
            file_refs["App/Info.plist"],
        ],
        "App",
    )
    tests_inner = group("tests-inner", "DewrinkleCoreTests", [file_refs["Tests/DewrinkleCoreTests/EngineTests.swift"]], "DewrinkleCoreTests")
    tests_group = group("tests", "Tests", [tests_inner], "Tests")
    products = group("products", "Products", [app_product, core_product, test_product])
    main_group = group("main", "Dewrinkle", [app_group, sources_group, tests_group, products])

    def proxy(key: str, target: str) -> str:
        object_id = uid("proxy:" + key)
        add(
            object_id,
            "PBXContainerItemProxy",
            f"\t\t\tcontainerPortal = {uid('project')};\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {target};\n\t\t\tremoteInfo = {q(key)};\n",
        )
        return object_id

    app_target = uid("target:app")
    core_target = uid("target:core")
    test_target = uid("target:test")
    app_proxy = proxy("app-on-DewrinkleCore", core_target)
    test_proxy = proxy("test-on-DewrinkleCore", core_target)

    def dependency(key: str, proxy_id: str, target: str) -> str:
        object_id = uid("dep:" + key)
        add(object_id, "PBXTargetDependency", f"\t\t\ttarget = {target};\n\t\t\ttargetProxy = {proxy_id};\n")
        return object_id

    app_dep = dependency("app", app_proxy, core_target)
    test_dep = dependency("test", test_proxy, core_target)

    def config_list(key: str, configs: list) -> str:
        object_id = uid("cfglist:" + key)
        lines = "\n".join(f"\t\t\t\t{item}," for item in configs)
        add(object_id, "XCConfigurationList", f"\t\t\tbuildConfigurations = (\n{lines}\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n")
        return object_id

    def config(key: str, name: str, settings: dict) -> str:
        object_id = uid("cfg:" + key + name)
        body = "\t\t\tbuildSettings = {\n"
        for setting, value in settings.items():
            body += f"\t\t\t\t{setting} = {format_setting(value)};\n"
        body += "\t\t\t};\n"
        body += f"\t\t\tname = {name};\n"
        add(object_id, "XCBuildConfiguration", body)
        return object_id

    project_debug = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "ARCHS": "arm64",
        "CLANG_ENABLE_MODULES": "YES",
        "COPY_PHASE_STRIP": "NO",
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_DYNAMIC_NO_PIC": "NO",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "MACOSX_DEPLOYMENT_TARGET": "14.0",
        "ONLY_ACTIVE_ARCH": "YES",
        "SDKROOT": "macosx",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
        "SWIFT_STRICT_CONCURRENCY": "minimal",
        "SWIFT_VERSION": "5.0",
    }
    project_release = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "ARCHS": "arm64",
        "CLANG_ENABLE_MODULES": "YES",
        "COPY_PHASE_STRIP": "NO",
        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
        "MACOSX_DEPLOYMENT_TARGET": "14.0",
        "SDKROOT": "macosx",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": "-O",
        "SWIFT_STRICT_CONCURRENCY": "minimal",
        "SWIFT_VERSION": "5.0",
    }
    project_debug_id = config("project", "Debug", project_debug)
    project_release_id = config("project", "Release", project_release)
    project_list = config_list("project", [project_debug_id, project_release_id])

    sign_local = {
        "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
        "CODE_SIGN_IDENTITY": "-",
        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
        "CODE_SIGN_STYLE": "Manual",
        "CODE_SIGNING_ALLOWED": "YES",
        "CODE_SIGNING_REQUIRED": "YES",
        "DEVELOPMENT_TEAM": "",
        "PROVISIONING_PROFILE_SPECIFIER": "",
    }
    # Static library: the core is linked into Dewrinkle.app, so dyld never
    # loads a second Mach-O with its own code signature.
    core_common = {
        "CODE_SIGNING_ALLOWED": "NO",
        "CODE_SIGNING_REQUIRED": "NO",
        "CURRENT_PROJECT_VERSION": "1",
        "DEFINES_MODULE": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "MACH_O_TYPE": "staticlib",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_NAME": "DewrinkleCore",
        "SKIP_INSTALL": "YES",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }
    core_debug = dict(core_common, ENABLE_TESTABILITY="YES")
    core_release = dict(core_common)
    core_debug_id = config("core", "Debug", core_debug)
    core_release_id = config("core", "Release", core_release)
    core_list = config_list("core", [core_debug_id, core_release_id])

    app_common = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "CODE_SIGN_ENTITLEMENTS": "App/Dewrinkle.entitlements",
        **sign_local,
        "CURRENT_PROJECT_VERSION": "1",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "App/Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks",
        "LIBRARY_SEARCH_PATHS": "$(inherited) $(BUILT_PRODUCTS_DIR)",
        "SWIFT_INCLUDE_PATHS": "$(inherited) $(BUILT_PRODUCTS_DIR)",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": "studio.dewinkle.Dewrinkle",
        "PRODUCT_NAME": "Dewrinkle",
    }
    app_debug_id = config("app", "Debug", app_common)
    app_release_id = config("app", "Release", app_common)
    app_list = config_list("app", [app_debug_id, app_release_id])

    test_common = {
        "BUNDLE_LOADER": "",
        **sign_local,
        "CURRENT_PROJECT_VERSION": "1",
        "GENERATE_INFOPLIST_FILE": "YES",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": "studio.dewinkle.DewrinkleCoreTests",
        "PRODUCT_NAME": "DewrinkleCoreTests",
        "TEST_HOST": "",
    }
    test_debug_id = config("test", "Debug", test_common)
    test_release_id = config("test", "Release", test_common)
    test_list = config_list("test", [test_debug_id, test_release_id])

    def target(object_id: str, name: str, product_name: str, product_type: str, product_ref: str, phases: list, deps: list, cfg: str) -> None:
        phase_lines = "\n".join(f"\t\t\t\t{item}," for item in phases)
        dep_lines = "\n".join(f"\t\t\t\t{item}," for item in deps)
        add(
            object_id,
            "PBXNativeTarget",
            f"\t\t\tbuildConfigurationList = {cfg};\n"
            f"\t\t\tbuildPhases = (\n{phase_lines}\n\t\t\t);\n"
            f"\t\t\tbuildRules = (\n\t\t\t);\n"
            f"\t\t\tdependencies = (\n{dep_lines}\n\t\t\t);\n"
            f"\t\t\tname = {q(name)};\n"
            f"\t\t\tproductName = {q(product_name)};\n"
            f"\t\t\tproductReference = {product_ref};\n"
            f"\t\t\tproductType = {q(product_type)};\n",
        )

    target(
        core_target,
        "DewrinkleCore",
        "DewrinkleCore",
        "com.apple.product-type.library.static",
        core_product,
        [core_sources_phase, core_frameworks_phase],
        [],
        core_list,
    )
    target(
        app_target,
        "Dewrinkle",
        "Dewrinkle",
        "com.apple.product-type.application",
        app_product,
        [app_sources_phase, app_frameworks_phase, app_resources_phase, script_phase],
        [app_dep],
        app_list,
    )
    target(
        test_target,
        "DewrinkleCoreTests",
        "DewrinkleCoreTests",
        "com.apple.product-type.bundle.unit-test",
        test_product,
        [test_sources_phase, test_frameworks_phase],
        [test_dep],
        test_list,
    )

    project = uid("project")
    add(
        project,
        "PBXProject",
        f"\t\t\tattributes = {{\n"
        f"\t\t\t\tBuildIndependentTargetsInParallel = YES;\n"
        f"\t\t\t\tLastUpgradeCheck = 1500;\n"
        f"\t\t\t\tTargetAttributes = {{\n"
        f"\t\t\t\t\t{app_target} = {{ CreatedOnToolsVersion = 15.0; }};\n"
        f"\t\t\t\t\t{core_target} = {{ CreatedOnToolsVersion = 15.0; }};\n"
        f"\t\t\t\t\t{test_target} = {{ CreatedOnToolsVersion = 15.0; }};\n"
        f"\t\t\t\t}};\n"
        f"\t\t\t}};\n"
        f"\t\t\tbuildConfigurationList = {project_list};\n"
        f"\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n"
        f"\t\t\tdevelopmentRegion = en;\n"
        f"\t\t\thasScannedForEncodings = 0;\n"
        f"\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
        f"\t\t\tmainGroup = {main_group};\n"
        f"\t\t\tproductRefGroup = {products};\n"
        f"\t\t\tprojectDirPath = \"\";\n"
        f"\t\t\tprojectRoot = \"\";\n"
        f"\t\t\ttargets = (\n\t\t\t\t{app_target},\n\t\t\t\t{core_target},\n\t\t\t\t{test_target},\n\t\t\t);\n",
    )

    text = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n\n"
    text += "\n\n".join(objects)
    text += "\n\t};\n\trootObject = " + project + " /* Project object */;\n}\n"
    dest = os.path.join(ROOT, "Dewrinkle.xcodeproj")
    os.makedirs(dest, exist_ok=True)
    with open(os.path.join(dest, "project.pbxproj"), "w") as handle:
        handle.write(text)

    scheme_dir = os.path.join(dest, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)
    scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{app_target}"
               BuildableName = "Dewrinkle.app"
               BlueprintName = "Dewrinkle"
               ReferencedContainer = "container:Dewrinkle.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "NO"
            buildForArchiving = "NO"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{core_target}"
               BuildableName = "libDewrinkleCore.a"
               BlueprintName = "DewrinkleCore"
               ReferencedContainer = "container:Dewrinkle.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "NO"
            buildForProfiling = "NO"
            buildForArchiving = "NO"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{test_target}"
               BuildableName = "DewrinkleCoreTests.xctest"
               BlueprintName = "DewrinkleCoreTests"
               ReferencedContainer = "container:Dewrinkle.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{test_target}"
               BuildableName = "DewrinkleCoreTests.xctest"
               BlueprintName = "DewrinkleCoreTests"
               ReferencedContainer = "container:Dewrinkle.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "Dewrinkle.app"
            BlueprintName = "Dewrinkle"
            ReferencedContainer = "container:Dewrinkle.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "Dewrinkle.app"
            BlueprintName = "Dewrinkle"
            ReferencedContainer = "container:Dewrinkle.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
    with open(os.path.join(scheme_dir, "Dewrinkle.xcscheme"), "w") as handle:
        handle.write(scheme)


if __name__ == "__main__":
    write_icons()
    write_project()
    print("wrote xcodeproj and icons")
