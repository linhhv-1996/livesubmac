import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreML
import WhisperKit

struct SubtitleSnapshot: Sendable {
    let stableLines: [String]
    let pendingText: String

    var displayText: String {
        let parts = stableLines + [pendingText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: "\n")
    }
}

final class AudioStreamManager: NSObject, SCStreamOutput, SCStreamDelegate {
    private let sampleRate = 16_000
    private let captureQueue = DispatchQueue(label: "com.livesub.capture.queue", qos: .userInitiated)
    private let defaults = UserDefaults.standard

    private var whisper: WhisperKit?
    private var stream: SCStream?
    private var audioBuffer: [Float] = []
    private var isTranscribing = false
    private var isCapturing = false
    private var lastDeliveredDisplayText = ""
    private var stableTranscript = ""
    private var currentBufferTranscript = ""
    private var lastProcessTime = Date()
    private var lastTranscriptionChangeTime = Date()

    var onSubtitleSnapshot: ((SubtitleSnapshot) -> Void)?
    var onModelReady: (() -> Void)?
    var onStatusChanged: ((String) -> Void)?

    override init() {
        super.init()
        setupWhisper()
    }

    private func setupWhisper() {
        Task {
            do {
                let config = WhisperKitConfig()
                config.model = "whisper-large-v3-v20240930-turbo-632MB"
                
                // Xcode flattens folder contents into Resources/, so model files sit directly
                // in Bundle.main.resourceURL (not inside a named subfolder).
                // We verify by checking if AudioEncoder.mlmodelc exists there.
                if let resourcesURL = Bundle.main.resourceURL,
                   FileManager.default.fileExists(atPath: resourcesURL.appendingPathComponent("AudioEncoder.mlmodelc").path) {
                    await MainActor.run {
                        self.onStatusChanged?("Loading bundled large-v3 offline model...")
                    }
                    config.modelFolder = resourcesURL.path
                    config.download = false  // truly offline, no Hugging Face check
                    config.verbose = true    // log per-stage timing to confirm offline + diagnose speed
                    config.computeOptions = ModelComputeOptions(
                        audioEncoderCompute: .cpuAndNeuralEngine,
                        textDecoderCompute: .cpuAndNeuralEngine
                    )
                    whisper = try await WhisperKit(config)
                } else {
                    await MainActor.run {
                        self.onStatusChanged?("Downloading large-v3 speech model...")
                    }
                    let modelURL = try await WhisperKit.download(variant: "large-v3")
                    config.modelFolder = modelURL.path
                    whisper = try await WhisperKit(config)
                }
                
                await MainActor.run {
                    self.onModelReady?()
                }
            } catch {
                await MainActor.run {
                    self.onStatusChanged?("Model setup failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func startCapture() async -> Bool {
        guard whisper != nil else {
            await MainActor.run {
                self.onStatusChanged?("Speech model is still loading.")
            }
            return false
        }

        guard !isCapturing else { return true }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                await MainActor.run {
                    self.onStatusChanged?("No display available for capture.")
                }
                return false
            }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = sampleRate
            config.channelCount = 1
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
            config.queueDepth = 3

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()

            self.stream = stream
            self.audioBuffer.removeAll(keepingCapacity: true)
            self.isCapturing = true
            self.lastDeliveredDisplayText = ""
            self.stableTranscript = ""
            self.currentBufferTranscript = ""
            self.lastProcessTime = Date()
            self.lastTranscriptionChangeTime = Date()

            await MainActor.run {
                self.onStatusChanged?("Capturing system audio.")
            }
            return true
        } catch {
            await MainActor.run {
                self.onStatusChanged?("Start capture failed: \(error.localizedDescription)")
            }
            return false
        }
    }

    func stopCapture() {
        let stream = self.stream
        self.stream = nil
        self.isCapturing = false
        self.audioBuffer.removeAll(keepingCapacity: false)
        self.isTranscribing = false
        self.lastDeliveredDisplayText = ""
        self.stableTranscript = ""
        self.currentBufferTranscript = ""

        Task {
            try? await stream?.stopCapture()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task {
            await MainActor.run {
                self.onStatusChanged?("Capture stopped: \(error.localizedDescription)")
            }
        }
        stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard isCapturing, let samples = extractFloatSamples(from: sampleBuffer), !samples.isEmpty else { return }

        audioBuffer.append(contentsOf: samples)

        let now = Date()
        if now.timeIntervalSince(lastProcessTime) >= 0.35, !isTranscribing {
            lastProcessTime = now
            let samplesToProcess = audioBuffer
            processAudio(samplesToProcess)
        }
    }

    private func processAudio(_ samples: [Float]) {
        guard let whisper, !isTranscribing else { return }
        isTranscribing = true

        Task {
            do {
                var options = DecodingOptions()
                options.temperature = 0
                options.skipSpecialTokens = true
                options.language = preferredLanguageCode()
                options.detectLanguage = options.language == nil

                let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
                if let result = results.first {
                    await MainActor.run {
                        let reliableSegments = result.segments.filter { segment in
                            let textLower = segment.text.lowercased()
                            let isGarbage = textLower.contains("thank you") || textLower.contains("subscribe") || textLower.contains("amara.org") || textLower.contains("bye") || textLower.contains("cảm ơn các bạn") || textLower.contains("chào các bạn") || textLower.contains("blank audio") || textLower.contains("silence") || textLower.isEmpty
                            return !isGarbage && segment.noSpeechProb < 0.8
                        }
                        
                        let rawText = reliableSegments.map { $0.text }.joined(separator: " ")
                        let newText = self.normalizeSubtitleText(rawText)
                        
                        var changed = false
                        if newText != self.currentBufferTranscript {
                            self.currentBufferTranscript = newText
                            self.lastTranscriptionChangeTime = Date()
                            changed = true
                        }
                        
                        let audioDuration = Double(samples.count) / Double(self.sampleRate)
                        let lastSegmentEnd = reliableSegments.last?.end ?? 0.0
                        let silenceDuration = audioDuration - Double(lastSegmentEnd)
                        let endsWithSilence = silenceDuration > 0.4
                        
                        if changed {
                            self.pushSubtitleSnapshot()
                            self.onStatusChanged?("Capturing system audio.")
                        } else if Date().timeIntervalSince(self.lastTranscriptionChangeTime) > 15.0 && (!self.stableTranscript.isEmpty || !self.currentBufferTranscript.isEmpty) {
                            self.stableTranscript = ""
                            self.currentBufferTranscript = ""
                            self.pushSubtitleSnapshot()
                            self.audioBuffer.removeAll(keepingCapacity: true)
                        }
                        
                        if (audioDuration > 1.5 && endsWithSilence) || audioDuration > 6.0 {
                            if !self.currentBufferTranscript.isEmpty {
                                let separator = self.stableTranscript.isEmpty ? "" : " "
                                let combined = self.stableTranscript + separator + self.currentBufferTranscript
                                
                                // Pack into temp lines to trim cleanly exactly at line boundaries
                                let words = combined.split(separator: " ").map { String($0) }
                                var tempLines: [String] = []
                                var tLine = ""
                                for w in words {
                                    if tLine.isEmpty { tLine = w }
                                    else if tLine.count + 1 + w.count <= 38 { tLine += " " + w }
                                    else { tempLines.append(tLine); tLine = w }
                                }
                                if !tLine.isEmpty { tempLines.append(tLine) }
                                
                                // Only keep the last 6 lines to prevent memory leaks while guaranteeing no word reflow
                                if tempLines.count > 6 {
                                    self.stableTranscript = tempLines.suffix(6).joined(separator: " ")
                                } else {
                                    self.stableTranscript = combined
                                }
                                
                                self.currentBufferTranscript = ""
                                let keepCount = Int(0.4 * Double(self.sampleRate))
                                if self.audioBuffer.count > keepCount {
                                    self.audioBuffer = Array(self.audioBuffer.suffix(keepCount))
                                } else {
                                    self.audioBuffer.removeAll(keepingCapacity: true)
                                }
                            } else {
                                let keepCount = Int(0.4 * Double(self.sampleRate))
                                if self.audioBuffer.count > keepCount {
                                    self.audioBuffer = Array(self.audioBuffer.suffix(keepCount))
                                }
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.onStatusChanged?("Transcription failed: \(error.localizedDescription)")
                }
            }

            self.isTranscribing = false
        }
    }

    @MainActor
    private func pushSubtitleSnapshot() {
        var rawText = stableTranscript
        if !currentBufferTranscript.isEmpty {
            let separator = stableTranscript.isEmpty ? "" : " "
            rawText += separator + currentBufferTranscript
        }
        
        let formatted = rawText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            
        let words = formatted.split(separator: " ").map { String($0) }
        var lines: [String] = []
        var currentLine = ""
        let maxLineLength = 38 // Very conservative length to guarantee SwiftUI never organically wraps
        
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
        
        let displayText = snapshot.displayText
        guard displayText != lastDeliveredDisplayText else { return }
        
        lastDeliveredDisplayText = displayText
        onSubtitleSnapshot?(snapshot)
    }

    private func normalizeSubtitleText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"<\|[^>]+\|>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[.*?\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func preferredLanguageCode() -> String? {
        guard let selectedIdentifier = defaults.string(forKey: "selectedLanguage"),
              !selectedIdentifier.isEmpty else {
            return nil
        }

        let locale = Locale(identifier: selectedIdentifier)
        if #available(macOS 13.0, *) {
            return locale.language.languageCode?.identifier
        } else {
            return locale.languageCode
        }
    }

    private func extractFloatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let asbd = asbdPointer.pointee
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0

        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        )
        var blockBuffer: CMBlockBuffer?

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        var extracted: [Float] = []
        extracted.reserveCapacity(Int(audioBufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size)

        for buffer in buffers {
            guard let mData = buffer.mData else { continue }

            if isFloat {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let pointer = mData.bindMemory(to: Float.self, capacity: count)
                extracted.append(contentsOf: UnsafeBufferPointer(start: pointer, count: count))
            } else if isSignedInteger {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                let pointer = mData.bindMemory(to: Int16.self, capacity: count)
                extracted.append(contentsOf: UnsafeBufferPointer(start: pointer, count: count).map {
                    Float($0) / Float(Int16.max)
                })
            }
        }

        return extracted
    }
}
