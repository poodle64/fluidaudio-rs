#[cfg(target_os = "macos")]
pub mod bridge;

#[cfg(target_os = "macos")]
pub use bridge::{AsrResult, FluidAudioBridge, SystemInfo};

// Stub types for non-macOS platforms so dependents compile
#[cfg(not(target_os = "macos"))]
mod stubs {
    #[derive(Debug, Clone)]
    pub struct AsrResult {
        pub text: String,
        pub confidence: f32,
        pub duration: f64,
        pub processing_time: f64,
        pub rtfx: f32,
    }

    #[derive(Debug, Clone)]
    pub struct SystemInfo {
        pub platform: String,
        pub chip_name: String,
        pub memory_gb: f64,
        pub is_apple_silicon: bool,
    }

    pub struct FluidAudioBridge;

    impl FluidAudioBridge {
        pub fn new() -> Option<Self> {
            None
        }

        pub fn initialize_asr(&self) -> Result<(), String> {
            Err("FluidAudio is only available on macOS".to_string())
        }

        pub fn transcribe_file(&self, _path: &str) -> Result<AsrResult, String> {
            Err("FluidAudio is only available on macOS".to_string())
        }

        pub fn is_asr_available(&self) -> bool {
            false
        }

        pub fn initialize_vad(&self, _threshold: f32) -> Result<(), String> {
            Err("FluidAudio is only available on macOS".to_string())
        }

        pub fn is_vad_available(&self) -> bool {
            false
        }

        pub fn system_info(&self) -> SystemInfo {
            SystemInfo {
                platform: "unsupported".to_string(),
                chip_name: "unsupported".to_string(),
                memory_gb: 0.0,
                is_apple_silicon: false,
            }
        }

        pub fn is_apple_silicon(&self) -> bool {
            false
        }

        pub fn cleanup(&self) {}
    }
}

#[cfg(not(target_os = "macos"))]
pub use stubs::{AsrResult, FluidAudioBridge, SystemInfo};
