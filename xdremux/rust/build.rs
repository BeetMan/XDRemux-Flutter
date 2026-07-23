//! Build script: compiles x265_helper.c and links libx265.a on Android.

fn main() {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();

    if target_os == "android" {
        let manifest = std::env::var("CARGO_MANIFEST_DIR").unwrap();
        let x265_src = format!("{manifest}/vendor/x265/source");
        let x265_build = format!("{manifest}/vendor/x265/build_android");

        // Compile our C helper that accesses x265_picture struct fields.
        cc::Build::new()
            .file("src/x265_helper.c")
            .include(&x265_src)
            .include(&x265_build) // for x265_config.h
            .flag("-fvisibility=default")
            .opt_level(2)
            .compile("x265_helper");

        // Resolve C helper symbols locally (avoid PLT/dynamic lookup).
        println!("cargo:rustc-link-arg=-Wl,-Bsymbolic");

        // Link the pre-built x265 static library.
        println!("cargo:rustc-link-search=native={x265_build}");
        println!("cargo:rustc-link-lib=static=x265");

        // x265 is C++ — link the C++ runtime.
        println!("cargo:rustc-link-lib=c++_shared");

        // System libraries x265 depends on.
        println!("cargo:rustc-link-lib=m");
        println!("cargo:rustc-link-lib=log");
    }
}
