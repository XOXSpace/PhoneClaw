import Foundation

final class Pipeline {
    let processors: [FrameProcessor]

    init(_ processors: [FrameProcessor]) {
        self.processors = processors
    }
}
