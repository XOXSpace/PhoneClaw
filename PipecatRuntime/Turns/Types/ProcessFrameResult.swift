import Foundation

// Mirrors Pipecat turns/types.py
enum ProcessFrameResult {
    /// Continue letting subsequent strategies process this frame.
    case `continue`
    /// Short-circuit: no further strategies in this pass will be called.
    case stop
}
