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

    let use_x265 = target_os == "android" || std::env::var_os("XDREMUX_USE_FFMPEG").is_none();
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
        "ios" => (format!("{x265_root}/build_ios"), "x265".to_string()),
        "windows" => (format!("{x265_root}/build_windows/Release"), "x265-static".to_string()),
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
