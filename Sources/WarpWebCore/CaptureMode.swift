public enum CaptureMode: String, Sendable {
    case automatic = "auto"
    case snapshot
    case stream

    /// The caller supplies a non-prompting permission preflight. Actual stream
    /// startup still rechecks access and retains its snapshot fallback.
    public func usesStream(isServing: Bool, captureAccess: () -> Bool) -> Bool {
        guard !isServing else { return false }
        switch self {
        case .automatic: return captureAccess()
        case .snapshot: return false
        case .stream: return true
        }
    }
}
