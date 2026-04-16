import Foundation

protocol TTSServicing: AnyObject {
    var isAvailable: Bool { get }
    func initialize() async
    func synthesizeChunk(_ text: String) -> AudioChunk?
    func canonicalizeRuntimeSettings(_ delta: TTSSettings) -> TTSSettings
    func applyRuntimeSettings(_ settings: TTSSettings, changed: [String: Any]) async
}

extension TTSServicing {
    func canonicalizeRuntimeSettings(_ delta: TTSSettings) -> TTSSettings {
        delta
    }

    func applyRuntimeSettings(_ settings: TTSSettings, changed: [String: Any]) async {}
}

extension TTSService: TTSServicing {}

private struct SpeakableSegmenter {
    func split(_ buffer: String) -> (segments: [String], remainder: String) {
        var segments: [String] = []
        var lastSplit = buffer.startIndex

        let hardChinesePunctuation: Set<Character> = ["。", "！", "？", "；"]
        let softChinesePunctuation: Set<Character> = ["，", "、", "："]
        let hardEnglishPunctuation: Set<Character> = [".", "!", "?", ";"]
        let softEnglishPunctuation: Set<Character> = [",", ":"]
        let minSoftClauseLength = 8

        var index = buffer.startIndex
        while index < buffer.endIndex {
            let character = buffer[index]
            let nextIndex = buffer.index(after: index)

            var shouldSplit = false

            if hardChinesePunctuation.contains(character) || character == "\n" {
                shouldSplit = true
            } else if softChinesePunctuation.contains(character) || softEnglishPunctuation.contains(character) {
                let clause = String(buffer[lastSplit..<nextIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                shouldSplit = clause.count >= minSoftClauseLength
            } else if hardEnglishPunctuation.contains(character) && nextIndex < buffer.endIndex {
                let nextCharacter = buffer[nextIndex]
                if nextCharacter == " " || nextCharacter == "\n" {
                    let clause = String(buffer[lastSplit..<nextIndex])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    shouldSplit = clause.count >= minSoftClauseLength
                }
            } else if hardEnglishPunctuation.contains(character) && nextIndex == buffer.endIndex {
                shouldSplit = true
            }

            if shouldSplit {
                let segment = String(buffer[lastSplit..<nextIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !segment.isEmpty {
                    segments.append(segment)
                    lastSplit = nextIndex
                }
            }

            index = nextIndex
        }

        return (segments, String(buffer[lastSplit...]))
    }
}

private actor TTSSynthesisQueue {
    private struct QueuedSynthesis {
        let generation: UInt64
        let text: String
        let appendToContext: Bool
        let emit: @Sendable (Frame) async -> Void
    }

    private let service: TTSServicing
    private var pending: [QueuedSynthesis] = []
    private var isDraining = false
    private var generation: UInt64 = 0

    init(service: TTSServicing) {
        self.service = service
    }

    func enqueue(
        _ text: String,
        appendToContext: Bool,
        emit: @escaping @Sendable (Frame) async -> Void
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        print("[TTSSynthQueue] enqueue: \"\(trimmed.prefix(40))\"")

        pending.append(
            QueuedSynthesis(
                generation: generation,
                text: trimmed,
                appendToContext: appendToContext,
                emit: emit
            )
        )

        guard !isDraining else { return }
        isDraining = true
        await drain()
    }

    func interrupt() {
        generation += 1
        pending.removeAll(keepingCapacity: false)
    }

    private func drain() async {
        while let item = pending.first {
            pending.removeFirst()

            guard item.generation == generation else { continue }
            let contextID = UUID().uuidString
            await item.emit(TTSStartedFrame(contextID: contextID))
            let chunk = service.synthesizeChunk(item.text)
            guard item.generation == generation else { continue }

            if let chunk {
                print("[TTSSynthQueue] drain: synthesized \(chunk.buffer.frameLength) frames for \"\(item.text.prefix(30))\"")
                await item.emit(TTSAudioRawFrame(chunk: chunk, contextID: contextID))
                await item.emit(
                    TTSTextFrame(
                        text: item.text,
                        contextID: contextID,
                        appendToContext: item.appendToContext
                    )
                )
            } else {
                print("[TTSSynthQueue] drain: synthesizeChunk returned nil for \"\(item.text.prefix(30))\"")
            }
            await item.emit(TTSStoppedFrame(contextID: contextID))
        }

        isDraining = false
        if !pending.isEmpty {
            isDraining = true
            await drain()
        }
    }
}

final class SherpaTTSServiceAdapter: FrameProcessor, @unchecked Sendable {
    private let service: TTSServicing
    private let segmenter = SpeakableSegmenter()
    private let synthesisQueue: TTSSynthesisQueue
    private let transportDestination: String?
    private let settings = TTSSettings.defaultStore()
    private var sentenceBuffer = ""
    private var sentenceBufferAppendToContext = true
    /// Mirrors pipecat `TTSService.text_filters` (tts_service.py:181, 296).
    /// Applied per segment before enqueueing for synthesis; segments that
    /// filter to empty are dropped (py:940-943).
    private let textFilters: [BaseTextFilter]

    init(
        service: TTSServicing = TTSService(),
        transportDestination: String? = nil,
        textFilters: [BaseTextFilter] = []
    ) {
        self.service = service
        self.transportDestination = transportDestination
        self.textFilters = textFilters
        self.synthesisQueue = TTSSynthesisQueue(service: service)
        super.init(name: "SherpaTTSServiceAdapter")
    }

    override func didReceiveStart(
        _ frame: StartFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        if !service.isAvailable {
            await service.initialize()
        }
        sentenceBuffer = ""
        sentenceBufferAppendToContext = true
    }

    override func didReceiveStop(
        _ frame: StopFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        sentenceBuffer = ""
        sentenceBufferAppendToContext = true
        await synthesisQueue.interrupt()
    }

    override func didReceiveCancel(
        _ frame: CancelFrame,
        direction: FrameDirection,
        context: FrameProcessorContext
    ) async {
        sentenceBuffer = ""
        sentenceBufferAppendToContext = true
        await synthesisQueue.interrupt()
    }

    override func process(_ frame: Frame, direction: FrameDirection, context: FrameProcessorContext) async {
        let emit: @Sendable (Frame) async -> Void = { frame in
            self.stampTransportDestination(frame)
            await context.push(frame, direction: .downstream)
        }

        switch frame {
        case is InterruptionFrame:
            print("[SherpaTTS] received InterruptionFrame — clearing synthesis queue")
            sentenceBuffer = ""
            sentenceBufferAppendToContext = true
            await synthesisQueue.interrupt()
            await context.push(frame, direction: direction)

        case is LLMFullResponseStartFrame:
            sentenceBuffer = ""
            sentenceBufferAppendToContext = true
            await context.push(frame, direction: direction)

        case let frame as LLMTextFrame:
            if frame.skipTTS == true {
                await context.push(frame, direction: direction)
                return
            }

            if sentenceBuffer.isEmpty {
                sentenceBufferAppendToContext = frame.appendToContext
            }
            sentenceBuffer += frame.text
            let split = segmenter.split(sentenceBuffer)
            sentenceBuffer = split.remainder

            if service.isAvailable {
                for segment in split.segments {
                    await enqueueFiltered(
                        segment,
                        appendToContext: sentenceBufferAppendToContext,
                        emit: emit
                    )
                }
            } else if !split.segments.isEmpty {
                await context.push(
                    ErrorFrame(message: "SherpaTTSServiceAdapter is not ready for synthesis"),
                    direction: .downstream
                )
            }

        case is LLMFullResponseEndFrame:
            let trailing = sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            sentenceBuffer = ""

            if service.isAvailable, !trailing.isEmpty {
                await enqueueFiltered(
                    trailing,
                    appendToContext: sentenceBufferAppendToContext,
                    emit: emit
                )
            }
            sentenceBufferAppendToContext = true

            await context.push(frame, direction: direction)

        case let frame as TTSUpdateSettingsFrame:
            if let target = frame.service, target !== self {
                await context.push(frame, direction: direction)
            } else if let delta = frame.ttsDelta {
                await applySettings(delta)
            } else if !frame.settings.isEmpty {
                await applySettings(TTSSettings.fromMapping(frame.settings))
            }

        default:
            await super.process(frame, direction: direction, context: context)
        }
    }

    /// Mirrors pipecat `TTSService._push_tts_frames` text-filter loop
    /// (tts_service.py:935-943): apply each filter in sequence, drop the
    /// segment if it filters to empty.
    private func enqueueFiltered(
        _ segment: String,
        appendToContext: Bool,
        emit: @escaping @Sendable (Frame) async -> Void
    ) async {
        var text = segment
        for filter in textFilters {
            await filter.resetInterruption()
            text = await filter.filter(text)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await synthesisQueue.enqueue(
            trimmed,
            appendToContext: appendToContext,
            emit: emit
        )
    }

    private func applySettings(_ delta: TTSSettings) async {
        let normalized = service.canonicalizeRuntimeSettings(delta.copy())
        let changed = settings.applyUpdate(normalized)
        await service.applyRuntimeSettings(settings.copy(), changed: changed)
    }

    private func stampTransportDestination(_ frame: Frame) {
        switch frame {
        case is TTSStartedFrame, is TTSStoppedFrame, is TTSAudioRawFrame, is TTSTextFrame:
            frame.transportDestination = transportDestination
        default:
            break
        }
    }
}
