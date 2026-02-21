use std::path::PathBuf;
use std::process::Command;

fn main() {
    // FluidAudio is macOS/iOS only (requires Swift, CoreML, Apple frameworks).
    // On other platforms, skip the Swift build entirely so dependents can
    // compile with this crate as an optional dependency.
    if std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default() != "macos" {
        return;
    }

    // Tell Cargo to rerun if Swift files change
    println!("cargo:rerun-if-changed=swift/");
    println!("cargo:rerun-if-changed=Package.swift");

    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());

    // Build the Swift package first to get FluidAudio dependency
    println!("cargo:warning=Building Swift package...");

    let swift_build_dir = out_dir.join("swift-build");
    std::fs::create_dir_all(&swift_build_dir).expect("Failed to create swift-build directory");

    // Build Swift package in release mode
    let status = Command::new("swift")
        .args(&[
            "build",
            "-c",
            "release",
            "--build-path",
            swift_build_dir.to_str().unwrap(),
        ])
        .current_dir(&manifest_dir)
        .status()
        .expect("Failed to run swift build");

    if !status.success() {
        panic!("Swift package build failed");
    }

    // Find the built library
    let lib_path = swift_build_dir.join("release");

    // Link the Swift library
    println!("cargo:rustc-link-search=native={}", lib_path.display());
    println!("cargo:rustc-link-lib=static=FluidAudioBridge");

    // Link Apple frameworks
    println!("cargo:rustc-link-lib=framework=Foundation");
    println!("cargo:rustc-link-lib=framework=AVFoundation");
    println!("cargo:rustc-link-lib=framework=CoreML");
    println!("cargo:rustc-link-lib=framework=Accelerate");
    println!("cargo:rustc-link-lib=framework=Metal");
    println!("cargo:rustc-link-lib=framework=MetalPerformanceShaders");

    // Link Swift runtime
    println!("cargo:rustc-link-lib=dylib=swiftCore");

    // Link C++ standard library (needed for FastClusterWrapper.cpp in FluidAudio)
    println!("cargo:rustc-link-lib=c++");

    // Add Swift runtime library rpaths so dyld can find libswift_Concurrency.dylib
    // and other Swift runtime libraries at runtime.
    //
    // On deployment targets < macOS 15.0, Swift Concurrency resolves via @rpath
    // (the tbd has $ld$previous$@rpath/libswift_Concurrency.dylib$$6$13.1$15.0$$).
    // We need rpaths pointing to the Swift runtime library directories.
    //
    // Use `swift -print-target-info` to find the correct paths dynamically.
    if let Ok(output) = Command::new("swift").args(&["-print-target-info"]).output() {
        if output.status.success() {
            if let Ok(json_str) = String::from_utf8(output.stdout) {
                // Parse the JSON to extract runtimeLibraryPaths
                // Format: { "paths": { "runtimeLibraryPaths": ["/path1", "/path2"] } }
                if let Some(paths_start) = json_str.find("\"runtimeLibraryPaths\"") {
                    if let Some(arr_start) = json_str[paths_start..].find('[') {
                        let arr_offset = paths_start + arr_start;
                        if let Some(arr_end) = json_str[arr_offset..].find(']') {
                            let arr_str = &json_str[arr_offset + 1..arr_offset + arr_end];
                            for item in arr_str.split(',') {
                                let path = item.trim().trim_matches('"').trim();
                                if !path.is_empty() {
                                    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", path);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Fallback: always add /usr/lib/swift in case the dynamic detection missed it
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
}
