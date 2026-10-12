import Foundation
import Darwin

/// Keep concurrent invocations using the same command from overwriting each
/// other's diagnostics. Lock files stay in place to avoid unlink/lock races.
final class SessionDiagnostics {
    let path: String
    private let descriptor: Int32
    init(path requested: String) throws {
        var candidate = requested
        var attempt = 0
        while true {
            let fd = open(candidate + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw CLIError("Cannot open diagnostics lock: \(candidate)") }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                path = candidate; descriptor = fd
                if candidate != requested { fputs("warpweb: Session diagnostics: \(candidate)\n", stderr) }
                return
            }
            let failure = errno; close(fd)
            guard failure == EWOULDBLOCK else { throw CLIError("Cannot lock diagnostics: \(candidate)") }
            attempt += 1
            let url = URL(fileURLWithPath: requested)
            let suffix = attempt == 1 ? "\(getpid())" : "\(getpid()).\(attempt)"
            candidate = url.deletingPathExtension().path + "." + suffix + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension)
        }
    }
    deinit { close(descriptor) }
}
