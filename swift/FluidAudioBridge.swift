import Foundation
import AVFoundation
import FluidAudio
import Darwin

// MARK: - Sync/async bridge

/// Runs an async, possibly actor-isolated operation to completion synchronously
/// and returns its result. For use ONLY at the synchronous C FFI boundary
/// (`@_cdecl` functions) which cannot be made async. The result crosses back
/// through a `Sendable` box, so the `Task` closure captures only `Sendable`
/// values and stays race-free under Swift 6 strict concurrency.
///
/// Must NOT be called from within another Swift `async` context: `wait()`
/// blocks the calling thread, and blocking a cooperative-pool thread can
/// deadlock the executor. At a sync FFI edge (a dedicated caller thread) this
/// is the accepted pattern.
func runBlocking<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
) throws -> T {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let outcome: Result<T, Error>
        do {
            outcome = .success(try await operation())
        } catch {
            outcome = .failure(error)
        }
        box.set(outcome)
        semaphore.signal()
    }
    semaphore.wait()
    return try box.take()
}

/// Sendable hand-off container. The lock makes `@unchecked Sendable` sound:
/// the write happens-before `signal()` and the read happens-after `wait()`.
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?

    func set(_ result: Result<T, Error>) {
        lock.lock(); defer { lock.unlock() }
        value = result
    }

    func take() throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard let value else { throw BridgeError.noResult }
        return try value.get()
    }
}

// MARK: - Bridge Class

/// Internal bridge class that wraps FluidAudio.
///
/// `@unchecked Sendable`: instances are owned by the C FFI layer, which holds a
/// single global bridge and serialises every call (one transcription at a
/// time), so the stored model/manager fields are never touched concurrently.
final class FluidAudioBridgeInternal: @unchecked Sendable {
    private var asrManager: AsrManager?
    private var asrModels: AsrModels?
    private var vadManager: VadManager?

    init() {}

    func initializeAsr() throws {
        // FluidAudio 0.15: AsrManager is an actor constructed with its models
        // injected; the separate initialize(models:) step was removed. The
        // model load and manager construction run async; the assignment to
        // self happens back on this (sync) thread after runBlocking returns.
        let (models, manager) = try runBlocking { () -> (AsrModels, AsrManager) in
            let models = try await AsrModels.downloadAndLoad()
            // melChunkContext: false selects FluidAudio's silence-aligned +
            // acoustic-warmup chunking for the v3 long-form batch path instead
            // of the default 80ms mel-context prepend with fixed-stride,
            // parallel, SOS-cold-started chunks. The default path drops the tail
            // of recordings whose final chunk opens mid-utterance: that chunk
            // cold-starts the TDT decoder from SOS, the joint predicts blank for
            // every frame, the chunk yields zero tokens, and the last words are
            // lost (e.g. "...waiting for port colours[ to finish being built]").
            // The silence-aligned path warms each chunk from real audio context,
            // which decodes those tails correctly. Verified across recordings of
            // 19s–52s; no English-accuracy regression observed.
            let config = ASRConfig(melChunkContext: false)
            return (models, AsrManager(config: config, models: models))
        }
        self.asrModels = models
        self.asrManager = manager
    }

    func transcribeFile(_ path: String) throws -> (String, Float, Double, Double, Float) {
        guard let manager = asrManager else {
            throw BridgeError.notInitialized
        }

        let r = try runBlocking { () -> ASRResult in
            let url = URL(fileURLWithPath: path)
            // FluidAudio 0.15: transcribe requires an inout decoder state. The
            // var is local to this closure, so &decoderState is legal here; a
            // fresh state per call keeps decoder context from leaking between
            // recordings.
            var decoderState = TdtDecoderState.make()
            return try await manager.transcribe(url, decoderState: &decoderState)
        }

        return (r.text, r.confidence, r.duration, r.processingTime, r.rtfx)
    }

    func isAsrAvailable() -> Bool {
        return asrManager != nil
    }

    func initializeVad(_ threshold: Float) throws {
        let manager = try runBlocking { () -> VadManager in
            let config = VadConfig(defaultThreshold: threshold)
            return try await VadManager(config: config)
        }
        self.vadManager = manager
    }

    func isVadAvailable() -> Bool {
        return vadManager != nil
    }

    func cleanup() {
        asrManager = nil
        asrModels = nil
        vadManager = nil
    }
}

enum BridgeError: Error {
    case notInitialized
    case noResult
}

// MARK: - C FFI Functions

/// Storage for bridge instances (simple approach - use a single global for now).
/// Access is serialised by the Rust FFI layer (one global bridge, one
/// transcription at a time), so nonisolated(unsafe) is sound under Swift 6's
/// strict concurrency checking.
nonisolated(unsafe) private var globalBridge: FluidAudioBridgeInternal?

@_cdecl("fluidaudio_bridge_create")
public func fluidaudio_bridge_create() -> UnsafeMutableRawPointer? {
    let bridge = FluidAudioBridgeInternal()
    globalBridge = bridge
    return Unmanaged.passRetained(bridge).toOpaque()
}

@_cdecl("fluidaudio_bridge_destroy")
public func fluidaudio_bridge_destroy(_ ptr: UnsafeMutableRawPointer?) {
    guard let ptr = ptr else { return }
    let bridge = Unmanaged<FluidAudioBridgeInternal>.fromOpaque(ptr).takeRetainedValue()
    bridge.cleanup()
    if globalBridge === bridge {
        globalBridge = nil
    }
}

@_cdecl("fluidaudio_initialize_asr")
public func fluidaudio_initialize_asr(_ ptr: UnsafeMutableRawPointer?) -> Int32 {
    guard let ptr = ptr else { return -1 }
    let bridge = Unmanaged<FluidAudioBridgeInternal>.fromOpaque(ptr).takeUnretainedValue()
    do {
        try bridge.initializeAsr()
        return 0
    } catch {
        print("ASR init error: \(error)")
        return -1
    }
}

@_cdecl("fluidaudio_transcribe_file")
public func fluidaudio_transcribe_file(
    _ ptr: UnsafeMutableRawPointer?,
    _ path: UnsafePointer<CChar>?,
    _ outText: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ outConfidence: UnsafeMutablePointer<Float>?,
    _ outDuration: UnsafeMutablePointer<Double>?,
    _ outProcessingTime: UnsafeMutablePointer<Double>?,
    _ outRtfx: UnsafeMutablePointer<Float>?
) -> Int32 {
    guard let ptr = ptr, let path = path else { return -1 }
    let bridge = Unmanaged<FluidAudioBridgeInternal>.fromOpaque(ptr).takeUnretainedValue()

    let pathString = String(cString: path)

    do {
        let (text, confidence, duration, processingTime, rtfx) = try bridge.transcribeFile(pathString)

        // Allocate and copy text
        if let outText = outText {
            let cString = strdup(text)
            outText.pointee = cString
        }

        outConfidence?.pointee = confidence
        outDuration?.pointee = duration
        outProcessingTime?.pointee = processingTime
        outRtfx?.pointee = rtfx

        return 0
    } catch {
        print("Transcribe error: \(error)")
        return -1
    }
}

@_cdecl("fluidaudio_is_asr_available")
public func fluidaudio_is_asr_available(_ ptr: UnsafeMutableRawPointer?) -> Int32 {
    guard let ptr = ptr else { return 0 }
    let bridge = Unmanaged<FluidAudioBridgeInternal>.fromOpaque(ptr).takeUnretainedValue()
    return bridge.isAsrAvailable() ? 1 : 0
}

@_cdecl("fluidaudio_initialize_vad")
public func fluidaudio_initialize_vad(_ ptr: UnsafeMutableRawPointer?, _ threshold: Float) -> Int32 {
    guard let ptr = ptr else { return -1 }
    let bridge = Unmanaged<FluidAudioBridgeInternal>.fromOpaque(ptr).takeUnretainedValue()
    do {
        try bridge.initializeVad(threshold)
        return 0
    } catch {
        print("VAD init error: \(error)")
        return -1
    }
}

@_cdecl("fluidaudio_is_vad_available")
public func fluidaudio_is_vad_available(_ ptr: UnsafeMutableRawPointer?) -> Int32 {
    guard let ptr = ptr else { return 0 }
    let bridge = Unmanaged<FluidAudioBridgeInternal>.fromOpaque(ptr).takeUnretainedValue()
    return bridge.isVadAvailable() ? 1 : 0
}

@_cdecl("fluidaudio_get_platform")
public func fluidaudio_get_platform(_ out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) {
    #if os(macOS)
    let platform = "macOS"
    #elseif os(iOS)
    let platform = "iOS"
    #else
    let platform = "unknown"
    #endif

    out?.pointee = strdup(platform)
}

@_cdecl("fluidaudio_get_chip_name")
public func fluidaudio_get_chip_name(_ out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) {
    var size: size_t = 0
    var chipName = "Unknown"

    if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 {
        var buffer = [CChar](repeating: 0, count: Int(size))
        if sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 {
            chipName = String(cString: buffer)
        }
    }

    out?.pointee = strdup(chipName)
}

@_cdecl("fluidaudio_get_memory_gb")
public func fluidaudio_get_memory_gb() -> Double {
    return Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
}

@_cdecl("fluidaudio_is_apple_silicon")
public func fluidaudio_is_apple_silicon() -> Int32 {
    return SystemInfo.isAppleSilicon ? 1 : 0
}

@_cdecl("fluidaudio_cleanup")
public func fluidaudio_cleanup(_ ptr: UnsafeMutableRawPointer?) {
    guard let ptr = ptr else { return }
    let bridge = Unmanaged<FluidAudioBridgeInternal>.fromOpaque(ptr).takeUnretainedValue()
    bridge.cleanup()
}

@_cdecl("fluidaudio_free_string")
public func fluidaudio_free_string(_ s: UnsafeMutablePointer<CChar>?) {
    free(s)
}
