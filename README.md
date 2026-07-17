# fluidaudio-rs

> **This is a household fork, and it exists to be retired.** Read
> [Why this fork exists](#why-this-fork-exists-and-what-would-end-it) before
> building on it. Its one genuine remaining delta over
> [upstream](https://github.com/FluidInference/fluidaudio-rs) is a platform
> compile-guard; on features it is now *behind* upstream, not ahead.

Rust bindings for [FluidAudio](https://github.com/FluidInference/FluidAudio) - a Swift library for ASR, VAD, Speaker Diarization, and TTS on Apple platforms.

## Features

- **ASR (Automatic Speech Recognition)** - High-quality speech-to-text using Parakeet TDT models
- **VAD (Voice Activity Detection)** - Detect speech segments in audio

## Requirements

- macOS 14+ or iOS 17+
- Apple Silicon (M1/M2/M3) recommended
- Rust 1.70+
- Swift 5.10+

## Installation

Add to your `Cargo.toml`:

```toml
[dependencies]
fluidaudio-rs = "0.1"
```

## Usage

### Speech-to-Text (ASR)

```rust
use fluidaudio_rs::FluidAudio;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let audio = FluidAudio::new()?;

    // Check system info
    let info = audio.system_info();
    println!("Running on: {} ({})", info.chip_name, info.platform);
    println!("Apple Silicon: {}", audio.is_apple_silicon());

    // Initialize ASR (downloads models on first run)
    audio.init_asr()?;

    // Transcribe an audio file
    let result = audio.transcribe_file("audio.wav")?;
    println!("Text: {}", result.text);
    println!("Confidence: {:.2}%", result.confidence * 100.0);
    println!("Processing speed: {:.1}x realtime", result.rtfx);

    Ok(())
}
```

### Voice Activity Detection (VAD)

```rust
use fluidaudio_rs::FluidAudio;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let audio = FluidAudio::new()?;

    // Initialize VAD with threshold (0.0-1.0)
    audio.init_vad(0.85)?;

    println!("VAD available: {}", audio.is_vad_available());

    Ok(())
}
```

## Model Loading

First initialization downloads and compiles ML models (~500MB total). This can take 20-30 seconds as Apple's Neural Engine compiles the models. Subsequent loads use cached compilations (~1 second).

## Platform Support

| Platform | Status |
|----------|--------|
| macOS (Apple Silicon) | Full support |
| macOS (Intel) | Limited (no ASR) |
| iOS | Full support |
| Linux/Windows | Not supported |

## How it Works

This crate uses a C FFI bridge to communicate between Rust and Swift:

1. The Swift layer (`FluidAudioBridge`) wraps the FluidAudio library
2. C-compatible functions are exported using `@_cdecl`
3. Rust calls these functions through `extern "C"` declarations
4. The build.rs script compiles the Swift package and links it

## License

MIT

## Why this fork exists, and what would end it

Assessed against upstream `FluidInference/fluidaudio-rs` on 2026-07-17 (upstream
tip `2d10833`, latest tag v0.14.1). Three reasons were originally recorded for
forking. **Two no longer hold.**

| Original reason | Status today | Evidence |
| --- | --- | --- |
| Upstream lacks platform compile-guards, so it fails to build on Linux/Windows | **Still true — the only real delta.** Upstream's `build.rs` still invokes `swift build` unconditionally and its `src/ffi/mod.rs` carries no `cfg` gating. | fork commits `547b1b4`, `97aaf88` |
| Fork is ahead on the FluidAudio Swift dep (0.15.0 vs upstream 0.14.1) | **No longer load-bearing.** The correctness-critical part of that bump — a fresh `TdtDecoderState` per one-shot call — reached upstream independently, applied against 0.14.1 by upstream PR #15 (`355370e`, merged in `2d10833`). This is the same conclusion thoth#79 reached when it closed as "nothing to cherry-pick". | upstream `355370e` |
| `melChunkContext=false` (silence-aligned chunking) | **Never load-bearing.** The consuming app's own segmentation (thoth's `plan_segments`) keeps every padded unit under FluidAudio's 15 s single-shot limit, so the chunked decoder never fires on either variant. The fork's own `Cargo.toml` comment already concedes this is "redundant belt-and-braces". | fork commit `0061017`; thoth `src-tauri/Cargo.toml` |

**The fork is now behind upstream, not ahead.** `git diff upstream/main main`
is ~305 insertions against ~4136 deletions: upstream has since added
diarization, VAD, Qwen3-ASR, streaming and ITN surfaces this fork does not
carry. The Rust API its only consumer uses — `FluidAudio::new()`,
`is_apple_silicon()`, `init_asr()`, `transcribe_file()` — is present verbatim
in current upstream, which is a strict superset. Switching back is a drop-in
match at the API level.

### The retirement condition

This fork should be deleted, and its consumer repointed at upstream, once
**both** hold:

1. The platform compile-guard is upstream and in a cut release; and
2. that release is verified against the live consuming app — the cargo test
   suite **and** a real end-to-end transcription on a real recording, not a
   compile check.

Nothing else here needs preserving.

### The one contribution that would unblock it

A PR to upstream carrying the platform guard. Note the scope honestly: it is
**not** a straight cherry-pick of `547b1b4`. That commit guards this fork's
much smaller FFI surface; upstream's `src/ffi/bridge.rs` is ~755 lines with
more exported types (`AsrResult`, `DiarizationSegment`, `FluidAudioBridge`,
`SystemInfo`, `VadFrame`), so the `cfg` gating must be re-done against
upstream's surface, and the result genuinely compile-checked on Linux — a
`build.rs` early-return alone leaves the extern declarations to fail at link
time instead of build time.

### Open sync PRs (#1, #2)

Both are bot-generated by this fork's daily `sync-version.yaml` cron and are
2-line version-string bumps (FluidAudio 0.15.4 and 0.15.5). Treat with care:
**no CI runs on PRs in this fork at all** (`statusCheckRollup` is empty; the
only workflows are tag-push release and the cron itself), so they are
unverified diffs, not evidence the crate still builds. #2 supersedes #1. Given
the retirement plan above, merging them buys the consumer nothing — it pins
this fork **by tag** (`v0.15.0-thoth.1`), so fork `main` moving does not reach
it.

