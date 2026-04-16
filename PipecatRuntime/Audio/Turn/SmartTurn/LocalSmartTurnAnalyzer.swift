import Foundation
import Accelerate

// Mirrors Pipecat `local_smart_turn_v3.py` (LocalSmartTurnAnalyzerV3).
// 推理后端: ONNX Runtime C API — 与 Python 版本保持同一模型资产，源码同构。
// xcframework `Frameworks/onnxruntime.xcframework` 已链接到 app target，提供 C API。
//
// 参数（与 Python 版一一对应）：
//   - 模型:     smart-turn-v3.2-cpu.onnx  (从 app bundle 加载)
//   - 采样率:   16 000 Hz
//   - 窗口:     最后 8 s = 128 000 samples，不足头部补零
//   - 特征:     Whisper mel, 80 bins × 800 frames  (8 s @ 10 ms/frame)
//               ONNX 模型输入 shape: [batch, 80, 800]  (经 graph 核查)
//   - 推理:     input_features → logits [1,1] (sigmoid probability)
//   - 阈值:     probability > 0.5 → complete
//
// 资源 (需在 Xcode Copy Bundle Resources 中添加):
//   smart-turn-v3.2-cpu.onnx  (pipecat/src/pipecat/audio/turn/smart_turn/data/)

// ORT C API 通过 bridging header 引入 onnxruntime_c_api.h
// 项目已配置 HEADER_SEARCH_PATHS 包含 Frameworks/onnxruntime.xcframework/Headers

// MARK: - Model constants (mirrors local_smart_turn_v3.py)

private let kModelSampleRate: Int = 16_000
private let kWindowSamples:   Int = 8 * kModelSampleRate   // 128 000 samples = 8 s

// Whisper mel — 与 Python WhisperFeatureExtractor(chunk_length=8) 对齐
private let kMelBins:   Int = 80
private let kMelFrames: Int = 800    // 8 s × 100 frames/s (10 ms hop)
                                     // 实测 ONNX graph: input_features [batch, 80, 800]
private let kFFTSize:   Int = 400    // 25 ms frame @ 16 kHz
private let kHopLength: Int = 160    // 10 ms hop  @ 16 kHz

// MARK: - LocalSmartTurnAnalyzer

/// Swift 版 `LocalSmartTurnAnalyzerV3`。
/// 参考: `local_smart_turn_v3.py:28`
/// 推理后端: ORT C API (onnxruntime.xcframework 已链接) — 不做 CoreML 转换，与 Python 共享同一模型。
final class LocalSmartTurnAnalyzer: BaseSmartTurn {

    // MARK: - ORT C API 句柄（opaque pointers）

    private var ortEnv: OpaquePointer?       // OrtEnv*
    private var ortSession: OpaquePointer?   // OrtSession*
    private var ortOptions: OpaquePointer?   // OrtSessionOptions*
    private var ortApi: UnsafePointer<OrtApi>?

    /// Whisper mel filterbank [kMelBins][kFFTSize/2+1] — init 时计算一次。
    private let melFilterbank: [[Float]]

    // MARK: - Init

    /// 从 app bundle 加载 `smart-turn-v3.2-cpu.onnx` 并创建 OrtSession。
    /// 对应 Python `__init__` 中加载 bundled ONNX 模型。
    override init(params: BaseSmartTurn.Params = .init()) {
        melFilterbank = LocalSmartTurnAnalyzer.buildMelFilterbank()
        super.init(params: params)

        // 获取 ORT API 表 (ORT_API_VERSION = 当前版本)
        guard let apiBase = OrtGetApiBase() else {
            fatalError("[LocalSmartTurnAnalyzer] OrtGetApiBase() returned nil")
        }
        guard let api = apiBase.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
            fatalError("[LocalSmartTurnAnalyzer] Failed to get OrtApi v\(ORT_API_VERSION)")
        }
        ortApi = api

        // CreateEnv
        var envPtr: OpaquePointer?
        let envStatus = api.pointee.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "SmartTurn", &envPtr)
        if let s = envStatus {
            print("[LocalSmartTurnAnalyzer] ⚠️ CreateEnv failed: \(ortErrorMessage(api, s))")
            api.pointee.ReleaseStatus(s)
        }
        ortEnv = envPtr

        // SessionOptions
        var optionsPtr: OpaquePointer?
        let optStatus = api.pointee.CreateSessionOptions(&optionsPtr)
        if let s = optStatus {
            print("[LocalSmartTurnAnalyzer] ⚠️ CreateSessionOptions failed: \(ortErrorMessage(api, s))")
            api.pointee.ReleaseStatus(s)
        }
        ortOptions = optionsPtr

        // 加载模型
        guard let modelURL = Bundle.main.url(forResource: "smart-turn-v3.2-cpu", withExtension: "onnx") else {
            fatalError(
                "[LocalSmartTurnAnalyzer] smart-turn-v3.2-cpu.onnx not found in bundle. " +
                "将文件拖入 Xcode 项目 → Copy Bundle Resources。"
            )
        }
        var sessionPtr: OpaquePointer?
        let sessionStatus = api.pointee.CreateSession(envPtr, modelURL.path, optionsPtr, &sessionPtr)
        if let s = sessionStatus {
            print("[LocalSmartTurnAnalyzer] ❌ CreateSession failed: \(ortErrorMessage(api, s))")
            print("[LocalSmartTurnAnalyzer]    modelPath: \(modelURL.path)")
            api.pointee.ReleaseStatus(s)
        }
        ortSession = sessionPtr

        if ortSession == nil {
            print("[LocalSmartTurnAnalyzer] ❌ ortSession is nil after init — all predictions will return 0")
        } else {
            print("[LocalSmartTurnAnalyzer] ✓ ORT session created successfully")
        }
    }

    deinit {
        guard let api = ortApi else { return }
        if let s = ortSession { api.pointee.ReleaseSession(s) }
        if let o = ortOptions { api.pointee.ReleaseSessionOptions(o) }
        if let e = ortEnv     { api.pointee.ReleaseEnv(e) }
    }

    // MARK: - predictEndpoint

    /// 对应 `_predict_endpoint(audio_array)` — `local_smart_turn_v3.py:141`。
    /// 步骤与 Python 完全一致:
    ///   1. 重采样到 16 kHz
    ///   2. 截断/补零至 8 s (128 000 samples)
    ///   3. Whisper mel 特征 [1, 80, 800]
    ///   4. ORT C API 推理
    ///   5. probability > 0.5 → prediction = 1 (complete)
    override func predictEndpoint(_ audioSegment: [Float]) -> (prediction: Int, probability: Float) {
        let resampled = resampleIfNeeded(audioSegment, fromRate: sampleRate, toRate: kModelSampleRate)
        let windowed  = truncateOrPad(resampled, targetLength: kWindowSamples)

        guard let melFlat = buildMelFlat(windowed) else {
            print("[LocalSmartTurnAnalyzer] predictEndpoint: buildMelFlat returned nil (samples=\(windowed.count))")
            return (prediction: 0, probability: 0)
        }

        guard let probability = runORT(melFlat: melFlat) else {
            print("[LocalSmartTurnAnalyzer] predictEndpoint: runORT returned nil (melFlat.count=\(melFlat.count))")
            return (prediction: 0, probability: 0)
        }

        let prediction = probability > 0.5 ? 1 : 0
        print("[LocalSmartTurnAnalyzer] predictEndpoint: probability=\(probability), prediction=\(prediction)")
        return (prediction: prediction, probability: probability)
    }

    // MARK: - ORT C API 推理

    private func runORT(melFlat: [Float]) -> Float? {
        guard let api = ortApi, let session = ortSession else {
            print("[LocalSmartTurnAnalyzer] runORT: api or session is nil")
            return nil
        }

        // 创建 CPU MemoryInfo（CreateTensorWithDataAsOrtValue 需要 OrtMemoryInfo*，不是 OrtAllocator*）
        var memInfo: OpaquePointer?  // OrtMemoryInfo*
        let memStatus = api.pointee.CreateCpuMemoryInfo(
            OrtArenaAllocator, OrtMemTypeDefault, &memInfo
        )
        if let s = memStatus {
            print("[LocalSmartTurnAnalyzer] runORT: CreateCpuMemoryInfo failed: \(ortErrorMessage(api, s))")
            api.pointee.ReleaseStatus(s); return nil
        }
        guard let info = memInfo else { return nil }
        defer { api.pointee.ReleaseMemoryInfo(info) }

        // 构造输入 OrtValue [1, 80, 800] float32
        var inputValue: OpaquePointer?
        var shape: [Int64] = [1, Int64(kMelBins), Int64(kMelFrames)]
        let byteCount = melFlat.count * MemoryLayout<Float>.size
        var inputStatus: OpaquePointer? = nil
        melFlat.withUnsafeBytes { rawPtr in
            let mutablePtr = UnsafeMutableRawPointer(mutating: rawPtr.baseAddress!)
            inputStatus = api.pointee.CreateTensorWithDataAsOrtValue(
                info,
                mutablePtr,
                byteCount,
                &shape, shape.count,
                ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
                &inputValue
            )
        }
        if let s = inputStatus {
            print("[LocalSmartTurnAnalyzer] runORT: CreateTensor failed: \(ortErrorMessage(api, s))")
            api.pointee.ReleaseStatus(s)
        }
        guard let inVal = inputValue else {
            print("[LocalSmartTurnAnalyzer] runORT: inputValue is nil after CreateTensor")
            return nil
        }
        defer { api.pointee.ReleaseValue(inVal) }

        // 输出 OrtValue（让 ORT 自动分配）
        var outputValue: OpaquePointer?

        // 输入/输出名称（与 ONNX 模型 graph 对应）
        let inputName  = "input_features"
        let outputName = "logits"

        var runStatus: OpaquePointer? = nil
        inputName.withCString { inCStr in
            outputName.withCString { outCStr in
                var inNamePtr: UnsafePointer<CChar>? = inCStr
                var outNamePtr: UnsafePointer<CChar>? = outCStr
                var inValPtr: OpaquePointer? = inVal

                runStatus = api.pointee.Run(
                    session, nil,
                    &inNamePtr, &inValPtr, 1,
                    &outNamePtr, 1,
                    &outputValue
                )
            }
        }
        if let s = runStatus {
            print("[LocalSmartTurnAnalyzer] runORT: Run failed: \(ortErrorMessage(api, s))")
            api.pointee.ReleaseStatus(s); return nil
        }
        guard let outVal = outputValue else {
            print("[LocalSmartTurnAnalyzer] runORT: outputValue is nil after Run")
            return nil
        }
        defer { api.pointee.ReleaseValue(outVal) }

        // 读取输出 float32
        var dataPtr: UnsafeMutableRawPointer?
        let dataStatus = api.pointee.GetTensorMutableData(outVal, &dataPtr)
        if let s = dataStatus {
            print("[LocalSmartTurnAnalyzer] runORT: GetTensorMutableData failed: \(ortErrorMessage(api, s))")
            api.pointee.ReleaseStatus(s); return nil
        }
        guard let ptr = dataPtr else { return nil }

        let rawValue = ptr.load(as: Float.self)
        // 模型输出 sigmoid probability；如为 raw logit 则手动应用
        if rawValue > 10 || rawValue < -10 {
            return 1.0 / (1.0 + exp(-rawValue))
        }
        return rawValue
    }

    /// Extract error message from OrtStatus for diagnostics.
    private func ortErrorMessage(_ api: UnsafePointer<OrtApi>, _ status: OpaquePointer) -> String {
        if let msg = api.pointee.GetErrorMessage(status) {
            return String(cString: msg)
        }
        return "(unknown ORT error)"
    }

    // MARK: - Resample

    /// 线性插值重采样（对应 soxr.resample 的简化版本）。
    /// vDSP_vgenp 签名: (A, IA, B, IB, C, IC, N, M)
    ///   A = input, IA = input stride, B = positions, IB = position stride,
    ///   C = output, IC = output stride, N = output count, M = input count
    private func resampleIfNeeded(_ samples: [Float], fromRate: Int, toRate: Int) -> [Float] {
        guard fromRate != toRate, fromRate > 0 else { return samples }
        let ratio = Double(toRate) / Double(fromRate)
        let outputCount = Int(Double(samples.count) * ratio)
        guard outputCount > 0 else { return samples }
        var output = [Float](repeating: 0, count: outputCount)
        var positions = (0..<outputCount).map { Float($0) / Float(ratio) }
        vDSP_vgenp(samples, 1, &positions, 1, &output, 1,
                   vDSP_Length(outputCount), vDSP_Length(samples.count))
        return output
    }

    // MARK: - Truncate / Pad

    /// 对应 `truncate_audio_to_last_n_seconds` — py:144。
    private func truncateOrPad(_ samples: [Float], targetLength: Int) -> [Float] {
        if samples.count > targetLength { return Array(samples.suffix(targetLength)) }
        if samples.count < targetLength { return [Float](repeating: 0, count: targetLength - samples.count) + samples }
        return samples
    }

    // MARK: - Whisper Mel Spectrogram

    /// 构造 [kMelBins × kMelFrames] float32 flat array。
    /// 对应 `WhisperFeatureExtractor(chunk_length=8)`:
    ///   80 mel bins, 400-pt FFT, 160-pt hop, Whisper 归一化。
    private func buildMelFlat(_ samples: [Float]) -> [Float]? {
        let frameCount = (samples.count - kFFTSize) / kHopLength + 1
        guard frameCount > 0 else { return nil }

        let log2n = vDSP_Length(log2(Float(kFFTSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var window = [Float](repeating: 0, count: kFFTSize)
        vDSP_hann_window(&window, vDSP_Length(kFFTSize), Int32(vDSP_HANN_NORM))

        var magnitudes = [[Float]](repeating: [Float](repeating: 0, count: kFFTSize / 2 + 1), count: frameCount)
        for f in 0..<frameCount {
            let start = f * kHopLength
            var frame = [Float](repeating: 0, count: kFFTSize)
            let copyLen = min(kFFTSize, samples.count - start)
            frame[0..<copyLen] = samples[start..<(start + copyLen)]
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(kFFTSize))

            var real = frame
            var imag = [Float](repeating: 0, count: kFFTSize)
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            var mag = [Float](repeating: 0, count: kFFTSize / 2 + 1)
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_zvmags(&split, 1, &mag, 1, vDSP_Length(kFFTSize / 2 + 1))
                }
            }
            magnitudes[f] = mag
        }

        var melSpec = [[Float]](repeating: [Float](repeating: 0, count: frameCount), count: kMelBins)
        for b in 0..<kMelBins {
            for f in 0..<frameCount {
                var val: Float = 0
                vDSP_dotpr(melFilterbank[b], 1, magnitudes[f], 1, &val, vDSP_Length(kFFTSize / 2 + 1))
                melSpec[b][f] = val
            }
        }

        // Whisper 归一化
        var flat = [Float](repeating: 0, count: kMelBins * frameCount)
        for b in 0..<kMelBins {
            for f in 0..<frameCount { flat[b * frameCount + f] = log10(max(melSpec[b][f], 1e-10)) }
        }
        let maxVal = flat.max() ?? 0
        let threshold = maxVal - 8.0
        for i in flat.indices { flat[i] = (max(flat[i], threshold) + 4.0) / 4.0 }

        var output = [Float](repeating: 0, count: kMelBins * kMelFrames)
        let usableFrames = min(frameCount, kMelFrames)
        for b in 0..<kMelBins {
            output[(b * kMelFrames)..<(b * kMelFrames + usableFrames)] =
                flat[(b * frameCount)..<(b * frameCount + usableFrames)]
        }
        return output
    }

    // MARK: - Mel Filterbank

    private static func buildMelFilterbank() -> [[Float]] {
        let sr: Float = Float(kModelSampleRate)
        let fftFreqs = (0...(kFFTSize / 2)).map { Float($0) * sr / Float(kFFTSize) }
        let melMin: Float = 0
        let melMax = hzToMel(sr / 2)
        let melPoints = (0...(kMelBins + 1)).map { i -> Float in
            melToHz(melMin + Float(i) * (melMax - melMin) / Float(kMelBins + 1))
        }
        var filterbank = [[Float]](repeating: [Float](repeating: 0, count: kFFTSize / 2 + 1), count: kMelBins)
        for b in 0..<kMelBins {
            let lower = melPoints[b], center = melPoints[b + 1], upper = melPoints[b + 2]
            for (i, freq) in fftFreqs.enumerated() {
                if freq >= lower && freq <= center { filterbank[b][i] = (freq - lower) / (center - lower) }
                else if freq > center && freq <= upper { filterbank[b][i] = (upper - freq) / (upper - center) }
            }
        }
        return filterbank
    }

    private static func hzToMel(_ hz: Float) -> Float { 2595 * log10(1 + hz / 700) }
    private static func melToHz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }
}
