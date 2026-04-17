import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreML
import WhisperKit

// MARK: - Data Model

struct SubtitleSnapshot: Sendable {
    /// Các câu giao diện cần hiển thị (đã được bọc theo chuẩn 2 dòng, ko bị giật layout)
    let stableLines: [String]
    let pendingText: String // Luôn rỗng vì logic bọc chữ nội bộ đã lo phần liveText
    
    var displayText: String {
        let parts = (stableLines + [pendingText])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Audio Stream Manager

actor AudioStreamManager: NSObject {
    // MARK: Constants
    private let sampleRate = 16_000
    /// AI có thể nhìn tối đa 8 giây để lấy ngữ cảnh.
    private let processingWindowSize: Int = 128_000  // 8.0 giây
    /// Đoạn âm thanh nhỏ gối đầu khi ngắt câu để không bị mất chữ đứng giữa ranh giới
    private let overlapSize: Int          = 8_000    // 0.5 giây
    /// Trái tim của Ultra-low latency: Cứ 0.25s là bơm âm thanh cho AI dịch!
    private let minProcessInterval: TimeInterval = 0.25
    /// Cửa sổ kiểm tra giọng đọc
    private let vadWindowSize: Int        = 8_000    // 0.5 giây

    // MARK: State
    private var whisper: WhisperKit?
    private var stream: SCStream?
    private var streamBridge: StreamBridge?
    private var audioBuffer: [Float] = []
    private var isTranscribing = false
    private var isCapturing = false
    private var lastProcessTime: Date = .distantPast
    private var lastTranscriptionChangeTime: Date = .distantPast

    private var committedText: String = ""
    private var liveText: String = ""
    private var lastDeliveredSnapshotText: String = ""

    // MARK: Callbacks (MainActor)
    var onSubtitleSnapshot: (@MainActor @Sendable (SubtitleSnapshot) -> Void)?
    var onModelReady: (@MainActor @Sendable () -> Void)?
    var onStatusChanged: (@MainActor @Sendable (String) -> Void)?

    func setCallbacks(
        onModelReady: (@MainActor @Sendable () -> Void)?,
        onStatusChanged: (@MainActor @Sendable (String) -> Void)?,
        onSubtitleSnapshot: (@MainActor @Sendable (SubtitleSnapshot) -> Void)?
    ) {
        self.onModelReady = onModelReady
        self.onStatusChanged = onStatusChanged
        self.onSubtitleSnapshot = onSubtitleSnapshot
    }

    private nonisolated let defaults = UserDefaults.standard

    override init() {
        super.init()
        Task { await self.setupWhisper() }
    }

    // MARK: - Setup

    private func setupWhisper() async {
        do {
            let config = WhisperKitConfig()

            let testModelPath = "/Users/linhhv/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-small"
            let externalModelURL = URL(fileURLWithPath: testModelPath)
            let modelName = externalModelURL.lastPathComponent

            if FileManager.default.fileExists(atPath: externalModelURL.appendingPathComponent("AudioEncoder.mlmodelc").path) {
                await sendStatus("Loading test model: \(modelName)...")
                config.modelFolder = testModelPath
                config.download = false
                config.verbose = false
                config.computeOptions = ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)
            } else if let resourcesURL = Bundle.main.resourceURL,
                      FileManager.default.fileExists(atPath: resourcesURL.appendingPathComponent("AudioEncoder.mlmodelc").path) {
                await sendStatus("Loading bundled model (offline)...")
                config.model = "whisper-large-v3-v20240930-turbo-632MB"
                config.modelFolder = resourcesURL.path
                config.download = false
                config.verbose = false
                config.computeOptions = ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)
            } else {
                await sendStatus("Downloading speech model...")
                let modelURL = try await WhisperKit.download(variant: "large-v3")
                config.modelFolder = modelURL.path
            }

            whisper = try await WhisperKit(config)
            let cb = onModelReady
            await MainActor.run { cb?() }

        } catch {
            await sendStatus("Model setup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Capture Control

    func startCapture() async -> Bool {
        guard whisper != nil else {
            await sendStatus("Speech model is still loading.")
            return false
        }
        guard !isCapturing else { return true }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return false }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let streamConfig = SCStreamConfiguration()
            streamConfig.capturesAudio = true
            streamConfig.excludesCurrentProcessAudio = true
            streamConfig.sampleRate = sampleRate
            streamConfig.channelCount = 1
            streamConfig.width = 2
            streamConfig.height = 2
            streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 2)
            streamConfig.queueDepth = 5

            let bridge = await StreamBridge(manager: self)
            self.streamBridge = bridge
            let newStream = SCStream(filter: filter, configuration: streamConfig, delegate: bridge)
            try newStream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
            try newStream.addStreamOutput(bridge, type: .screen, sampleHandlerQueue: .global(qos: .background))
            try await newStream.startCapture()

            stream = newStream
            resetState()
            isCapturing = true
            await sendStatus("Capturing system audio.")
            return true
        } catch {
            await sendStatus("Start capture failed: \(error.localizedDescription)")
            return false
        }
    }

    func stopCapture() {
        let s = stream
        stream = nil
        streamBridge = nil
        isCapturing = false
        isTranscribing = false
        resetState()
        Task.detached { try? await s?.stopCapture() }
    }

    private func resetState() {
        audioBuffer.removeAll(keepingCapacity: true)
        committedText = ""
        liveText = ""
        lastDeliveredSnapshotText = ""
        lastProcessTime = .distantPast
        lastTranscriptionChangeTime = .distantPast
    }

    // MARK: - Audio Ingestion

    func ingestSamples(_ samples: [Float]) {
        guard isCapturing else { return }

        audioBuffer.append(contentsOf: samples)

        // Không bao giờ để mảng lớn hơn processingWindowSize (8s) để tranh OOM. 
        if audioBuffer.count > processingWindowSize {
            audioBuffer = Array(audioBuffer.suffix(processingWindowSize))
        }

        let now = Date()
        guard now.timeIntervalSince(lastProcessTime) >= minProcessInterval,
              !isTranscribing,
              audioBuffer.count >= sampleRate / 5 // Tích được cỡ 0.2s âm thanh là dịch ngay!
        else { return }

        let window = audioBuffer
        
        // Block VAD tĩnh: Nếu chỉ là nhiễu nền rác rưởi, không gọi AI cho đỡ tốn pin.
        guard isActive(window) else {
            if audioBuffer.count > sampleRate * 3 {
                audioBuffer.removeAll(keepingCapacity: true)
            }
            return
        }

        lastProcessTime = now
        isTranscribing = true

        Task { await transcribe(window: window) }
    }

    // MARK: - Transcription

    private func transcribe(window: [Float]) async {
        defer { isTranscribing = false }
        guard let whisper else { return }

        do {
            var opts = DecodingOptions()
            opts.temperature = 0
            opts.temperatureFallbackCount = 0
            opts.withoutTimestamps = true
            opts.skipSpecialTokens = true
            opts.language = preferredLanguageCode()
            opts.detectLanguage = opts.language == nil

            let results = try await whisper.transcribe(audioArray: window, decodeOptions: opts)
            guard let result = results.first else { return }

            let cleanSegments = result.segments.filter { isCleanSegment($0) }
            let rawText = cleanSegments.map { $0.text }.joined(separator: " ")
            let newLiveText = normalizeText(rawText)

            let tailSilent = isTailSilent(window)

            await processTranscriptionResult(newLiveText, tailSilent: tailSilent, windowSize: window.count)

        } catch {
            await sendStatus("Transcription error: \(error.localizedDescription)")
        }
    }

    // MARK: - Result Processing & Logic chốt chữ

    private func processTranscriptionResult(_ newLiveText: String, tailSilent: Bool, windowSize: Int) async {
        let changed = newLiveText != liveText
        if changed {
            liveText = newLiveText
            lastTranscriptionChangeTime = Date()
        }

        let windowDuration = Double(windowSize) / Double(sampleRate)

        // Nếu ngâm quá lâu không có biến (sau 8s tĩnh), dọn dẹp sạch sẽ
        if !changed, Date().timeIntervalSince(lastTranscriptionChangeTime) > 8.0, (!committedText.isEmpty || !liveText.isEmpty) {
            committedText = ""
            liveText = ""
            audioBuffer.removeAll(keepingCapacity: true)
            pushSnapshot()
            return
        }

        if changed {
            pushSnapshot()
        }

        // TỐI ƯU CỐT LÕI: Chỉ chặn dòng chốt câu khi ĐƯỢC PHÉP CHỐT: 
        // Lệnh ngắt câu rơi vào khi Đuôi câu yên tĩnh (>0.8s) HOẶC bộ đệm đã cứng tới 7.5s (tránh nhai đi nhai lại cục quá to).
        let shouldCommit = (tailSilent && windowDuration > 0.8) || windowDuration >= 7.5

        if shouldCommit, !liveText.isEmpty {
            let separator = committedText.isEmpty ? "" : " "
            let combined = committedText + separator + liveText
            
            // Xoá cuộn - gói văn bản để không làm tràn biến nhớ
            let words = combined.split(separator: " ").map { String($0) }
            var tempLines: [String] = []
            var tLine = ""
            for w in words {
                if tLine.isEmpty { tLine = w }
                else if tLine.count + 1 + w.count <= 40 { tLine += " " + w }
                else { tempLines.append(tLine); tLine = w }
            }
            if !tLine.isEmpty { tempLines.append(tLine) }
            
            if tempLines.count > 4 {
                committedText = tempLines.suffix(4).joined(separator: " ")
            } else {
                committedText = combined
            }

            liveText = ""
            if audioBuffer.count > overlapSize {
                audioBuffer = Array(audioBuffer.suffix(overlapSize))
            } else {
                audioBuffer.removeAll(keepingCapacity: true)
            }
            pushSnapshot()
        }
    }

    // MARK: - Format & Snapshot Push

    private func pushSnapshot() {
        var rawText = committedText
        if !liveText.isEmpty {
            let separator = committedText.isEmpty ? "" : " "
            rawText += separator + liveText
        }
        
        let formatted = rawText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            
        let words = formatted.split(separator: " ").map { String($0) }
        var lines: [String] = []
        var currentLine = ""
        let maxLineLength = 40 // Thuật toán bọc cứng khung nhìn chống phình/ngóp bong bóng UI nhảy loạn
        
        for word in words {
            if currentLine.isEmpty {
                currentLine = word
            } else if currentLine.count + 1 + word.count <= maxLineLength {
                currentLine += " " + word
            } else {
                lines.append(currentLine)
                currentLine = word
            }
        }
        if !currentLine.isEmpty {
            lines.append(currentLine)
        }
        
        let displayLines = Array(lines.suffix(2))
        let snapshot = SubtitleSnapshot(stableLines: displayLines, pendingText: "")
        
        // Tránh flood UI nếu kết xuất bề mặt giống y hệt nhau
        let comparableString = snapshot.displayText
        guard comparableString != lastDeliveredSnapshotText else { return }
        lastDeliveredSnapshotText = comparableString
        
        let cb = onSubtitleSnapshot
        Task { @MainActor in cb?(snapshot) }
    }

    // MARK: - VAD Helpers

    private func isActive(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        let rms = sqrt(sumSq / Float(samples.count))
        return rms >= 0.005
    }

    private func isTailSilent(_ samples: [Float]) -> Bool {
        guard samples.count >= vadWindowSize else { return false }
        let tail = samples.suffix(vadWindowSize)
        var sumSq: Float = 0
        for s in tail { sumSq += s * s }
        let rms = sqrt(sumSq / Float(vadWindowSize))
        return rms < 0.015 
    }

    // MARK: - Text Processing

    private func isCleanSegment(_ segment: TranscriptionSegment) -> Bool {
        let t = segment.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, segment.noSpeechProb < 0.6 else { return false }

        let blacklist = ["thank you", "subscribe", "amara.org", "cảm ơn các bạn",
                         "chào các bạn", "blank audio", "silence", "you", "yeah", "ừ", "bye", "bạn"]
        if blacklist.contains(t) { return false }
        if t.contains("amara.org") || t.contains("subscribe") { return false }

        let words = t.split(separator: " ").map(String.init)
        if words.count >= 3 {
            let uniqueWords = Set(words)
            if uniqueWords.count == 1 { return false }
            if words.allSatisfy({ $0.count <= 3 }) && uniqueWords.count <= 2 { return false }
        }
        return true
    }

    private func normalizeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"<\|[^>]+\|>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#,     with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[.*?\]"#,     with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\([^)]*\)"#,   with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated func preferredLanguageCode() -> String? {
        guard let id = defaults.string(forKey: "selectedLanguage"), !id.isEmpty else { return nil }
        let locale = Locale(identifier: id)
        return locale.language.languageCode?.identifier
    }

    private func sendStatus(_ msg: String) async {
        let cb = onStatusChanged
        await MainActor.run { cb?(msg) }
    }
}

// MARK: - StreamBridge
private final class StreamBridge: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private weak var manager: AudioStreamManager?

    init(manager: AudioStreamManager) {
        self.manager = manager
        super.init()
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let samples = extractFloatSamples(from: sampleBuffer),
              !samples.isEmpty,
              let mgr = manager else { return }

        Task { await mgr.ingestSamples(samples) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let mgr = manager else { return }
        Task {
            await mgr.stopCapture()
            let cb = await mgr.onStatusChanged
            await MainActor.run { cb?("Capture stopped: \(error.localizedDescription)") }
        }
    }

    private nonisolated func extractFloatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return nil }

        let asbd = asbdPtr.pointee
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isInt   = asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0

        var abl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        )
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        var result: [Float] = []
        result.reserveCapacity(Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size)

        for buf in UnsafeMutableAudioBufferListPointer(&abl) {
            guard let data = buf.mData else { continue }
            if isFloat {
                let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                result.append(contentsOf: UnsafeBufferPointer(start: data.bindMemory(to: Float.self, capacity: count), count: count))
            } else if isInt {
                let count = Int(buf.mDataByteSize) / MemoryLayout<Int16>.size
                let ptr = data.bindMemory(to: Int16.self, capacity: count)
                result.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count).map { Float($0) / Float(Int16.max) })
            }
        }
        return result
    }
}

//private final class StreamBridge: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
//    private weak var manager: AudioStreamManager?
//
//    init(manager: AudioStreamManager) {
//        self.manager = manager
//    }
//
//    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
//        guard type == .audio,
//              let samples = extractFloatSamples(from: sampleBuffer),
//              !samples.isEmpty,
//              let mgr = manager else { return }
//
//        Task { await mgr.ingestSamples(samples) }
//    }
//
//    func stream(_ stream: SCStream, didStopWithError error: Error) {
//        guard let mgr = manager else { return }
//        Task {
//            await mgr.stopCapture()
//            let cb = await mgr.onStatusChanged
//            await MainActor.run { cb?("Capture stopped: \(error.localizedDescription)") }
//        }
//    }
//
//    private func extractFloatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
//        guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
//              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return nil }
//
//        let asbd = asbdPtr.pointee
//        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
//        let isInt   = asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
//
//        var abl = AudioBufferList(
//            mNumberBuffers: 1,
//            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
//        )
//        var blockBuffer: CMBlockBuffer?
//        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
//            sampleBuffer, bufferListSizeNeededOut: nil,
//            bufferListOut: &abl,
//            bufferListSize: MemoryLayout<AudioBufferList>.size,
//            blockBufferAllocator: kCFAllocatorDefault,
//            blockBufferMemoryAllocator: kCFAllocatorDefault,
//            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
//            blockBufferOut: &blockBuffer
//        )
//        guard status == noErr else { return nil }
//
//        var result: [Float] = []
//        result.reserveCapacity(Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size)
//
//        for buf in UnsafeMutableAudioBufferListPointer(&abl) {
//            guard let data = buf.mData else { continue }
//            if isFloat {
//                let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
//                result.append(contentsOf: UnsafeBufferPointer(start: data.bindMemory(to: Float.self, capacity: count), count: count))
//            } else if isInt {
//                let count = Int(buf.mDataByteSize) / MemoryLayout<Int16>.size
//                let ptr = data.bindMemory(to: Int16.self, capacity: count)
//                result.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count).map { Float($0) / Float(Int16.max) })
//            }
//        }
//        return result
//    }
//}
