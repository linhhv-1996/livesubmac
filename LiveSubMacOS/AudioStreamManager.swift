import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreML
import Translation
import NaturalLanguage
import WhisperKit

// MARK: - Data Model
struct SubtitleSnapshot: Sendable {
    let stableLines: [String]
    let pendingText: String
    
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
    private let processingWindowSize: Int = 128_000  // 8.0 giây
    private let overlapSize: Int          = 8_000    // 0.5 giây
    private let minProcessInterval: TimeInterval = 0.25
    private let vadWindowSize: Int        = 8_000    // 0.5 giây
    
    private var translationSession: TranslationSession?

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
    }

    // MARK: - Setup & Model Management
    
    // Hàm để UIState đẩy session xuống
    func setTranslationSession(_ session: TranslationSession) {
        self.translationSession = session
    }

    private let modelLinks: [String: String] = [
        "tiny": "https://huggingface.co/buckets/hvlinhtptn/livesub/resolve/openai_whisper-tiny.zip?download=true",
        "small": "https://huggingface.co/buckets/hvlinhtptn/livesub/resolve/openai_whisper-small.zip?download=true",
        "medium": "https://huggingface.co/buckets/hvlinhtptn/livesub/resolve/openai_whisper-medium.zip?download=true",
        "turbo": "https://huggingface.co/buckets/hvlinhtptn/livesub/resolve/openai_whisper-large-v3-v20240930_626MB.zip?download=true"
    ]

    func prepareModel() async {
        if isCapturing { stopCapture() }
        whisper = nil
        
        let targetModel = defaults.string(forKey: "selectedModel") ?? "small"
        if defaults.string(forKey: "selectedModel") == nil {
            defaults.set("small", forKey: "selectedModel")
        }
        
        await setupWhisper(modelType: targetModel)
    }
    
    private func setupWhisper(modelType: String) async {
        print("🛠️ DEBUG [1]: Bắt đầu setupWhisper với model: \(modelType)")
        do {
            let config = WhisperKitConfig()
            let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let modelsDirectory = appSupportURL.appendingPathComponent("LiveSubModels", isDirectory: true)
            
            print("🛠️ DEBUG [2]: Thư mục chứa model: \(modelsDirectory.path)")
            
            if !FileManager.default.fileExists(atPath: modelsDirectory.path) {
                try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
                print("🛠️ DEBUG [3]: Đã tạo thư mục LiveSubModels")
            }
            
            let folderName = (modelType == "turbo") ? "openai_whisper-large-v3-v20240930_626MB" : "openai_whisper-\(modelType)"
            let finalModelPath = modelsDirectory.appendingPathComponent(folderName)
            let encoderPath = finalModelPath.appendingPathComponent("AudioEncoder.mlmodelc").path
            
            if !FileManager.default.fileExists(atPath: encoderPath) {
                print("🛠️ DEBUG [4]: Chưa có model, chuẩn bị tải...")
                await sendStatus("Downloading \(modelType.capitalized) model...")
                
                guard let urlString = modelLinks[modelType], let zipURL = URL(string: urlString) else {
                    print("🔥 DEBUG ERROR: URL không hợp lệ")
                    await sendStatus("Error: Invalid model URL.")
                    return
                }
                
                print("🛠️ DEBUG [5]: Bắt đầu tải từ \(zipURL)... (Bước này có thể kẹt do mạng)")
                let (tempZipURL, response) = try await URLSession.shared.download(from: zipURL)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    print("🔥 DEBUG ERROR: Lỗi mạng HTTP Code khác 200")
                    await sendStatus("Error: Failed to download model.")
                    return
                }
                
                print("🛠️ DEBUG [6]: Tải xong! Bắt đầu giải nén file zip bằng Process...")
                await sendStatus("Extracting model...")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-o", tempZipURL.path, "-d", modelsDirectory.path]
                
                try process.run()
                process.waitUntilExit()
                print("🛠️ DEBUG [7]: Giải nén xong (Exit code: \(process.terminationStatus))")
                
                try? FileManager.default.removeItem(at: tempZipURL)
                
                if !FileManager.default.fileExists(atPath: encoderPath) {
                    print("🔥 DEBUG ERROR: Giải nén xong nhưng KHÔNG THẤY file AudioEncoder.mlmodelc")
                    await sendStatus("Error: Not found AudioEncoder.mlmodelc.")
                    return
                }
            } else {
                print("🛠️ DEBUG [4b]: Đã tìm thấy model có sẵn trên máy, bỏ qua bước tải.")
            }
            
            print("🛠️ DEBUG [8]: Bắt đầu load WhisperKit vào bộ nhớ (BƯỚC NÀY HAY TREO NHẤT)...")
            await sendStatus("Loading \(modelType.capitalized) model into memory...")
            config.modelFolder = finalModelPath.path
            config.download = false
            config.verbose = true
            
            config.computeOptions = ModelComputeOptions(audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndGPU)

            whisper = try await WhisperKit(config)
            print("✅ DEBUG [9]: KHỞI TẠO WHISPERKIT THÀNH CÔNG!")
            
            let cb = onModelReady
            await MainActor.run { cb?() }

        } catch {
            print("🔥 DEBUG CATCH ERROR: Bị văng lỗi: \(error)")
            await sendStatus("Error: Model setup failed: \(error.localizedDescription)")
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

            let bridge = StreamBridge(manager: self)
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

        if audioBuffer.count > processingWindowSize {
            audioBuffer = Array(audioBuffer.suffix(processingWindowSize))
        }

        let now = Date()
        guard now.timeIntervalSince(lastProcessTime) >= minProcessInterval,
              !isTranscribing,
              audioBuffer.count >= sampleRate / 5
        else { return }

        let window = audioBuffer
        
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
            let sourceId = defaults.string(forKey: "sourceLanguage") ?? "en"
            
            var opts = DecodingOptions()
            opts.temperature = 0
            opts.temperatureFallbackCount = 0
            opts.withoutTimestamps = true
            opts.skipSpecialTokens = true
            opts.language = sourceId // ÉP CỨNG NGÔN NGỮ NÓI
            opts.detectLanguage = false     // TẮT TỰ ĐỘNG NHẬN DIỆN

            let results = try await whisper.transcribe(audioArray: window, decodeOptions: opts)
            guard let result = results.first else { return }

            let cleanSegments = result.segments.filter { isCleanSegment($0) }
            let rawText = cleanSegments.map { $0.text }.joined(separator: " ")
            
            let cleanRawText = normalizeText(rawText)
            if cleanRawText.isEmpty { return }
            await handleTranslationAndUI(cleanRawText, tailSilent: isTailSilent(window))

        } catch {
            await sendStatus("Transcription error: \(error.localizedDescription)")
        }
    }
    
    // Hàm xử lý chính: Nhận text thô -> Check tiếng -> Dịch -> Đẩy UI
    private func handleTranslationAndUI(_ text: String, tailSilent: Bool) async {
        guard !text.isEmpty else { return }
        await processTranscriptionResult(text, tailSilent: tailSilent, windowSize: 128_000)
    }


    // MARK: - Result Processing

    private func processTranscriptionResult(_ newLiveText: String, tailSilent: Bool, windowSize: Int) async {
        let changed = newLiveText != liveText
        if changed {
            liveText = newLiveText
            lastTranscriptionChangeTime = Date()
        }

        let windowDuration = Double(windowSize) / Double(sampleRate)

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

        let shouldCommit = (tailSilent && windowDuration > 0.8) || windowDuration >= 7.5

        if shouldCommit, !liveText.isEmpty {
            let separator = committedText.isEmpty ? "" : " "
            let combined = committedText + separator + liveText
            
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
//    private func pushSnapshot() {
//        // 1. Lấy text gốc (Tiếng Anh) hiện tại
//        let rawCommitted = committedText
//        let rawLive = liveText
//        
//        // Bọc vào Task để gọi TranslationSession (bất đồng bộ)
//        Task {
//            var finalDisplayText = ""
//            let fullRawText = [rawCommitted, rawLive]
//                .filter { !$0.isEmpty }
//                .joined(separator: " ")
//            
//            // 2. ĐEM TOÀN BỘ CÂU ĐI DỊCH
//            let sourceId = defaults.string(forKey: "sourceLanguage") ?? "en-US"
//            let targetId = defaults.string(forKey: "targetLanguage") ?? "vi-VN"
//            
//            if sourceId != targetId, !fullRawText.isEmpty, let session = await self.translationSession {
//                do {
//                    // Nhờ đưa cả câu dài, máy sẽ hiểu: "book" trong "book a room" là "đặt" chứ không phải "sách"
//                    let response = try await session.translations(from: [TranslationSession.Request(sourceText: fullRawText)])
//                    finalDisplayText = response.first?.targetText ?? fullRawText
//                } catch {
//                    print("Translation error: \(error)")
//                    finalDisplayText = fullRawText // Lỗi thì hiện tạm text gốc
//                }
//            } else {
//                finalDisplayText = fullRawText
//            }
//            
//            // 3. XỬ LÝ CHIA DÒNG TEXT SAU KHI ĐÃ DỊCH XONG
//            let formatted = finalDisplayText
//                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
//                .trimmingCharacters(in: .whitespacesAndNewlines)
//                
//            let words = formatted.split(separator: " ").map { String($0) }
//            var lines: [String] = []
//            var currentLine = ""
//            let maxLineLength = 50 // Tăng lên 50 vì tiếng Việt sau khi dịch thường dài hơn tiếng Anh
//            
//            for word in words {
//                if currentLine.isEmpty {
//                    currentLine = word
//                } else if currentLine.count + 1 + word.count <= maxLineLength {
//                    currentLine += " " + word
//                } else {
//                    lines.append(currentLine)
//                    currentLine = word
//                }
//            }
//            if !currentLine.isEmpty { lines.append(currentLine) }
//            
//            // Luôn chỉ lấy 2 dòng cuối cùng để nhét vừa Dynamic Island
//            let displayLines = Array(lines.suffix(2))
//            let snapshot = SubtitleSnapshot(stableLines: displayLines, pendingText: "")
//            
//            let comparableString = snapshot.displayText
//            guard comparableString != lastDeliveredSnapshotText else { return }
//            lastDeliveredSnapshotText = comparableString
//            
//            // 4. ĐẨY LÊN GIAO DIỆN
//            let cb = onSubtitleSnapshot
//            await MainActor.run { cb?(snapshot) }
//        }
//    }
//
    private func pushSnapshot() {
        let rawCommitted = committedText
        let rawLive = liveText
        
        Task {
            let fullRawText = [rawCommitted, rawLive]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            
            if fullRawText.isEmpty { return }
            
            let sourceId = defaults.string(forKey: "sourceLanguage") ?? "en"
            let targetId = defaults.string(forKey: "targetLanguage") ?? "none"
            
            var translatedText = fullRawText
            
            // CHỈ DỊCH KHI USER CHỌN TARGET VÀ TARGET KHÁC SOURCE
            if targetId != "none", sourceId != targetId, let session = await self.translationSession {
                do {
                    // Dịch cả câu dài để lấy ngữ cảnh đúng
                    let response = try await session.translations(from: [TranslationSession.Request(sourceText: fullRawText)])
                    translatedText = response.first?.targetText ?? fullRawText
                } catch {
                    print("Translation error: \(error)")
                }
            }
            
            // Sau khi có text (đã dịch hoặc gốc), mới format chia dòng
            let words = translatedText.split(separator: " ").map { String($0) }
            var lines: [String] = []
            var currentLine = ""
            
            for word in words {
                if currentLine.isEmpty { currentLine = word }
                else if currentLine.count + 1 + word.count <= 45 { currentLine += " " + word }
                else { lines.append(currentLine); currentLine = word }
            }
            if !currentLine.isEmpty { lines.append(currentLine) }
            
            let displayLines = Array(lines.suffix(2))
            let snapshot = SubtitleSnapshot(stableLines: displayLines, pendingText: "")
            
            // Cập nhật UI
            let cb = onSubtitleSnapshot
            await MainActor.run { cb?(snapshot) }
        }
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

