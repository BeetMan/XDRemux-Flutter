//! Build script: compiles x265_helper.c and links a static libx265.
//!
//! Encoder selection:
//! - Android: always x265 static (SELinux blocks subprocess execution).
//! - Windows/macOS/Linux: x265 static by default; set `XDREMUX_USE_FFMPEG=1`
//!   to skip linking and use the ffmpeg subprocess fallback instead.
//!
//! Expected layout:
//! - Headers: vendor/x265/include/{x265.h,x265_config.h} (x265_config.h copied
//!   from any configure pass; it only holds X265_BUILD/feature macros).
//! - Libraries:
//!   - Android: vendor/x265/build_android/libx265.a
//!   - Windows (MSVC): vendor/x265/build_windows/Release/x265-static.lib
//!   - macOS/Linux: vendor/x265/build_desktop/libx265.a

fn main() {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    // OHOS Rust targets report os=linux + env=ohos (like Android's os=linux
    // + env=... distinction); detect via env so the x265 path picks build_ohos.
    let target_env = std::env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();
    let is_ohos = target_env == "ohos";
    build_libheif_decoder(&target_os);

    let use_x265 = target_os == "android" || std::env::var_os("XDREMUX_USE_FFMPEG").is_none();
    // Declared unconditionally so cfg-off builds do not warn (the cfg is only
    // set below when a 10-bit archive is present).
    println!("cargo:rustc-check-cfg=cfg(xdremux_main10)");
    if !use_x265 {
        println!("cargo:rustc-cfg=xdremux_ffmpeg_fallback");
        println!("cargo:rerun-if-env-changed=XDREMUX_USE_FFMPEG");
        return;
    }

    let manifest = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let x265_root = format!("{manifest}/vendor/x265");
    let x265_include = format!("{x265_root}/include");

    // Compile the C++ helper that sets x265_picture/x265_param struct fields.
    // Compiled as C++ everywhere: x265.h uses `bool`, which MSVC's C mode lacks.
    let mut build = cc::Build::new();
    build
        .file("src/x265_helper.c")
        .include(&x265_include)
        .opt_level(2);
    if target_os != "windows" {
        build.flag("-fvisibility=default");
    }
    build.compile("x265_helper");

    // Static libx265 location per platform.
    let (link_search, lib_name) = match target_os.as_str() {
        "android" => (format!("{x265_root}/build_android"), "x265".to_string()),
        // The iOS simulator reports os=ios + env=sim and needs a library built
        // against the iphonesimulator SDK; linking the device archive fails with
        // "building for 'iOS-simulator', but linking in object file ... built
        // for 'iOS'".
        "ios" if target_env == "sim" => {
            (format!("{x265_root}/build_ios_sim"), "x265".to_string())
        }
        "ios" => (format!("{x265_root}/build_ios"), "x265".to_string()),
        "windows" => (
            format!("{x265_root}/build_windows/Release"),
            "x265-static".to_string(),
        ),
        _ if is_ohos => (format!("{x265_root}/build_ohos"), "x265".to_string()),
        _ => (format!("{x265_root}/build_desktop"), "x265".to_string()),
    };

    let lib_file = if target_os == "windows" {
        format!("{link_search}/{lib_name}.lib")
    } else {
        format!("{link_search}/lib{lib_name}.a")
    };
    if !std::path::Path::new(&lib_file).exists() {
        panic!(
            "static libx265 not found at {lib_file}.\n\
             Build it first (see docs/next-phase-plan.md):\n\
             - Windows: cmake -S vendor/x265/source -B vendor/x265/build_windows \\\n\
                 -G \"Visual Studio 17 2022\" -A x64 -DENABLE_SHARED=OFF -DENABLE_CLI=OFF \\\n\
                 -DXDREMUX_SKIP_RC=ON && \\\n\
               cmake --build vendor/x265/build_windows --config Release --target x265-static\n\
             - macOS/Linux: cmake -S vendor/x265/source -B vendor/x265/build_desktop \\\n\
                 -DENABLE_SHARED=OFF -DENABLE_CLI=OFF && \\\n\
               cmake --build vendor/x265/build_desktop --target x265-static -j\n\
             Or set XDREMUX_USE_FFMPEG=1 to use the ffmpeg subprocess fallback."
        );
    }

    // Optional 10-bit (Main10) encoder for the Styles Linear Thumbnail.
    // Built with HIGH_BIT_DEPTH=ON + EXPORT_C_API=OFF so its objects live in
    // `namespace x265_10bit` and coexist with the 8-bit archive; see
    // docs/research/x265-main10-feasibility-20261025.md. When the archive is
    // absent the bridge is not compiled and the 8-bit Apple Log path stays in
    // use, so each platform can adopt 10-bit independently.
    let main10_file_and_dir: Option<(String, String)> = {
        let candidates: Vec<String> = match target_os.as_str() {
            "android" => vec![format!("{x265_root}/build_android_10bit")],
            "ios" if target_env == "sim" => vec![format!("{x265_root}/build_ios_sim_10bit")],
            "ios" => vec![format!("{x265_root}/build_ios_10bit")],
            "windows" => vec![
                format!("{x265_root}/build_windows_10bit/Release"),
                format!("{x265_root}/build_windows_10bit"),
            ],
            _ if is_ohos => vec![format!("{x265_root}/build_ohos_10bit")],
            _ => vec![format!("{x265_root}/build_desktop_10bit")],
        };
        let mut found = None;
        for dir in candidates {
            // Watch the location even while absent so adding the archive later
            // reruns this script instead of silently staying 8-bit only.
            println!("cargo:rerun-if-changed={dir}");
            let lib_name = if target_os == "windows" { "x265-static" } else { "x265" };
            let file = if target_os == "windows" {
                format!("{dir}/{lib_name}.lib")
            } else {
                format!("{dir}/lib{lib_name}.a")
            };
            if std::path::Path::new(&file).exists() {
                found = Some((file, dir));
                break;
            }
        }
        found
    };

    if let Some((main10_file, _main10_dir)) = &main10_file_and_dir {
        let mut bridge = cc::Build::new();
        bridge
            .cpp(true)
            .file("src/x265_10bit_bridge.cpp")
            .include(&x265_include)
            .opt_level(2)
            .define("XDREMUX_MAIN10", None);
        if target_os != "windows" {
            bridge.flag("-fvisibility=default");
        }
        bridge.compile("x265_10bit_bridge");
        // Both x265 archives are usually called `x265-static` (Windows) or
        // `libx265.a`; cargo dedupes identical -l names and the linker would
        // then only ever pick one of them. Copy the 10-bit archive into
        // OUT_DIR under a unique name so both get linked, in dependency order
        // (10-bit objects reference the global C API provided by the 8-bit
        // archive, so the 10-bit one is emitted first).
        let out_dir = std::env::var("OUT_DIR").expect("OUT_DIR");
        let unique_name = if target_os == "windows" {
            "x265-main10.lib"
        } else {
            "libx265-main10.a"
        };
        let staged = std::path::Path::new(&out_dir).join(unique_name);
        let needs_copy = match (std::fs::metadata(main10_file), std::fs::metadata(&staged)) {
            (Ok(source), Ok(staged_meta)) => source.len() != staged_meta.len(),
            _ => true,
        };
        if needs_copy {
            std::fs::copy(main10_file, &staged).expect("stage the 10-bit x265 archive");
        }
        println!("cargo:rustc-link-search=native={out_dir}");
        // On iOS too: link args never reach the staticlib that Xcode links,
        // while a static -l is bundled into libxdremux_core.a next to the
        // bridge. The app force-loads that archive; the 10-bit objects only
        // overlap the 8-bit libx265.a on weak template symbols.
        println!("cargo:rustc-link-lib=static=x265-main10");
        println!("cargo:rustc-cfg=xdremux_main10");
        println!("cargo:rustc-check-cfg=cfg(xdremux_main10)");
        println!("cargo:rerun-if-changed=src/x265_10bit_bridge.cpp");
    }

    println!("cargo:rustc-link-search=native={link_search}");
    if target_os != "ios" {
        println!("cargo:rustc-link-lib=static={lib_name}");
    }

    match target_os.as_str() {
        "android" => {
            // Resolve C helper symbols locally (avoid PLT/dynamic lookup).
            println!("cargo:rustc-link-arg=-Wl,-Bsymbolic");
            println!("cargo:rustc-link-lib=c++_shared");
            println!("cargo:rustc-link-lib=m");
            println!("cargo:rustc-link-lib=log");
        }
        "windows" => {
            // x265 ThreadPool reads the registry for CPU group config.
            println!("cargo:rustc-link-lib=advapi32");
        }
        "macos" => {
            println!("cargo:rustc-link-lib=c++");
            println!("cargo:rustc-link-lib=m");
        }
        "ios" => {
            // iOS uses libc++ (not libstdc++); m/pthread are part of libSystem.
            // libx265.a has internal cross-references between the common and
            // encoder objects; force-load so no object is dropped by the
            // linker's dead-strip / ordering.
            println!("cargo:rustc-link-lib=c++");
            println!("cargo:rustc-link-arg=-Wl,-force_load,{link_search}/libx265.a");
        }
        _ if is_ohos => {
            // OHOS is musl-based with LLVM libc++; like Android, ship
            // libc++_shared.so next to the Rust cdylib. No numa/pthread:
            // musl folds them into libc and the NDK has no libnuma.
            println!("cargo:rustc-link-arg=-Wl,-Bsymbolic");
            println!("cargo:rustc-link-lib=c++_shared");
            println!("cargo:rustc-link-lib=m");
        }
        _ => {
            println!("cargo:rustc-link-lib=stdc++");
            println!("cargo:rustc-link-lib=m");
            println!("cargo:rustc-link-lib=pthread");
            if target_os == "linux" {
                // x265 detects libnuma during its static build, so the
                // dependency must be repeated when the archive is linked.
                println!("cargo:rustc-link-lib=numa");
            }
        }
    }

    println!("cargo:rerun-if-env-changed=XDREMUX_USE_FFMPEG");
    println!("cargo:rerun-if-changed=src/x265_helper.c");
    println!("cargo:rerun-if-changed={lib_file}");
}

fn build_libheif_decoder(target_os: &str) {
    println!("cargo:rerun-if-env-changed=XDREMUX_LIBHEIF_PREFIX");
    println!("cargo:rerun-if-changed=src/libheif_helper.cpp");
    if std::env::var_os("CARGO_FEATURE_LIBHEIF_DECODER").is_none() {
        return;
    }
    let prefix = std::env::var_os("XDREMUX_LIBHEIF_PREFIX")
        .map(std::path::PathBuf::from)
        .expect("libheif-decoder requires XDREMUX_LIBHEIF_PREFIX (target-built libheif >= 1.23.4; see tools/native/README.md)");
    let include = prefix.join("include");
    let lib = prefix.join("lib");
    assert!(
        include.join("libheif/heif.h").is_file(),
        "libheif header missing in {}",
        include.display()
    );
    let library = if target_os == "windows" {
        "heif.lib"
    } else if target_os == "macos" || target_os == "ios" {
        "libheif.dylib"
    } else {
        "libheif.so"
    };
    assert!(
        lib.join(library).is_file(),
        "libheif shared/import library missing in {}",
        lib.display()
    );
    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .file("src/libheif_helper.cpp")
        .include(include)
        .compile("xdremux_heif_decode");
    println!("cargo:rustc-link-search=native={}", lib.display());
    println!("cargo:rustc-link-lib=dylib=heif");
    if target_os == "android" || std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("ohos") {
        println!("cargo:rustc-link-lib=c++_shared");
    } else if target_os == "linux" {
        println!("cargo:rustc-link-lib=stdc++");
    } else if target_os == "macos" || target_os == "ios" {
        println!("cargo:rustc-link-lib=c++");
    }
    println!("cargo:rerun-if-changed={}", lib.join(library).display());
}
