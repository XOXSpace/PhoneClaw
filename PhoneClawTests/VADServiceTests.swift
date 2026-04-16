import XCTest
import FluidAudio
@testable import PhoneClaw

final class VADServiceTests: XCTestCase {

    func testCallbackOrderingEmitsProbabilityBeforeSpeechStart() async {
        let service = VADService()
        let chunk = [Float](repeating: 0.25, count: VadManager.chunkSize)
        let result = VadStreamResult(
            state: VadStreamState(triggered: true, processedSamples: chunk.count),
            event: VadStreamEvent(kind: .speechStart, sampleIndex: 0),
            probability: 0.92
        )

        var callbacks: [String] = []
        service.onProbabilityUpdate = { _ in callbacks.append("prob") }
        service.onSpeechStart = { callbacks.append("speechStart") }

        service.handleStreamingResult(result, chunk: chunk)

        XCTAssertEqual(callbacks, ["prob", "speechStart"])
        XCTAssertEqual(service.state, .speaking)
    }

    func testSpeechStartChunkIsDeliveredAfterSpeechStart() async {
        let service = VADService()
        let chunk = [Float](repeating: 0.25, count: VadManager.chunkSize)
        let result = VadStreamResult(
            state: VadStreamState(triggered: true, processedSamples: chunk.count),
            event: VadStreamEvent(kind: .speechStart, sampleIndex: 0),
            probability: 0.92
        )

        var callbacks: [String] = []
        var deliveredChunk: [Float] = []
        service.onProbabilityUpdate = { _ in callbacks.append("prob") }
        service.onSpeechStart = { callbacks.append("speechStart") }
        service.onSpeechChunk = { samples in
            callbacks.append("chunk")
            deliveredChunk = samples
        }

        service.handleStreamingResult(result, chunk: chunk)

        XCTAssertEqual(callbacks, ["prob", "speechStart", "chunk"])
        XCTAssertEqual(deliveredChunk, chunk)
    }

    func testSpeechEndDeliversAccumulatedSamplesAndResetsToListening() async {
        let service = VADService()
        let firstChunk = [Float](repeating: 0.1, count: 8)
        let middleChunk = [Float](repeating: 0.2, count: 8)
        let endChunk = [Float](repeating: 0.3, count: 8)

        let startResult = VadStreamResult(
            state: VadStreamState(triggered: true, processedSamples: firstChunk.count),
            event: VadStreamEvent(kind: .speechStart, sampleIndex: 0),
            probability: 0.95
        )
        let middleResult = VadStreamResult(
            state: VadStreamState(triggered: true, processedSamples: firstChunk.count + middleChunk.count),
            event: nil,
            probability: 0.88
        )
        let endResult = VadStreamResult(
            state: VadStreamState(triggered: false, processedSamples: firstChunk.count + middleChunk.count + endChunk.count),
            event: VadStreamEvent(kind: .speechEnd, sampleIndex: firstChunk.count + middleChunk.count),
            probability: 0.05
        )

        var delivered: [Float] = []
        service.onSpeechEnd = { samples in
            delivered = samples
        }

        service.handleStreamingResult(startResult, chunk: firstChunk)
        service.handleStreamingResult(middleResult, chunk: middleChunk)
        service.handleStreamingResult(endResult, chunk: endChunk)

        XCTAssertEqual(service.state, .listening)
        XCTAssertEqual(delivered, firstChunk + middleChunk)
    }

    func testOnSpeechChunkStreamsTriggerAndMiddleChunksOnly() async {
        let service = VADService()
        let firstChunk = [Float](repeating: 0.1, count: 8)
        let middleChunk = [Float](repeating: 0.2, count: 8)
        let endChunk = [Float](repeating: 0.3, count: 8)

        let startResult = VadStreamResult(
            state: VadStreamState(triggered: true, processedSamples: firstChunk.count),
            event: VadStreamEvent(kind: .speechStart, sampleIndex: 0),
            probability: 0.95
        )
        let middleResult = VadStreamResult(
            state: VadStreamState(triggered: true, processedSamples: firstChunk.count + middleChunk.count),
            event: nil,
            probability: 0.88
        )
        let endResult = VadStreamResult(
            state: VadStreamState(triggered: false, processedSamples: firstChunk.count + middleChunk.count + endChunk.count),
            event: VadStreamEvent(kind: .speechEnd, sampleIndex: firstChunk.count + middleChunk.count),
            probability: 0.05
        )

        var streamedChunks: [[Float]] = []
        service.onSpeechChunk = { streamedChunks.append($0) }

        service.handleStreamingResult(startResult, chunk: firstChunk)
        service.handleStreamingResult(middleResult, chunk: middleChunk)
        service.handleStreamingResult(endResult, chunk: endChunk)

        XCTAssertEqual(streamedChunks, [firstChunk, middleChunk])
    }
}

final class LiveTurnCompletionParserTests: XCTestCase {

    func testCompleteMarkerPassesOnlySpokenText() {
        var parser = LiveTurnCompletionParser()

        let first = parser.consume("✓ 你好，")
        let second = parser.consume("我是手机龙虾。")

        XCTAssertEqual(first.speakableText, "你好，")
        XCTAssertNil(first.incompleteType)
        XCTAssertEqual(second.speakableText, "我是手机龙虾。")
    }

    func testIncompleteShortMarkerSuppressesAllFollowingText() {
        var parser = LiveTurnCompletionParser()

        let first = parser.consume("○")
        let second = parser.consume("你还在吗")

        XCTAssertEqual(first.incompleteType, .short)
        XCTAssertEqual(first.speakableText, "")
        XCTAssertEqual(second.speakableText, "")
    }

    func testFinalizeFallsBackWhenMarkerMissing() {
        var parser = LiveTurnCompletionParser()

        let first = parser.consume("你好")
        let second = parser.consume("，我是手机龙虾。")
        let fallback = parser.finalizeWithoutMarker()

        XCTAssertEqual(first.speakableText, "")
        XCTAssertEqual(second.speakableText, "")
        XCTAssertEqual(fallback, "你好，我是手机龙虾。")
    }
}
