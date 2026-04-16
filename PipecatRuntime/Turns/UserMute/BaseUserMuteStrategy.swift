import Foundation

class BaseUserMuteStrategy: @unchecked Sendable {
    func setup() async {}

    func cleanup() async {}

    func reset() async {}

    func processFrame(_ frame: Frame) async -> Bool {
        false
    }
}
