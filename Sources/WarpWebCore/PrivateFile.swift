import Foundation
import Darwin

/// Publishes a complete owner-only file. A destination symlink is replaced,
/// never followed. The caller must choose a trusted parent directory.
public enum PrivateFile {
    public static func write(_ data: Data, to url: URL) throws {
        let destination = url.lastPathComponent
        guard url.isFileURL, !destination.isEmpty, destination != ".", destination != ".." else {
            throw POSIXError(.EINVAL)
        }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw failure() }
        defer { close(directory) }
        let temporary = ".warpweb-\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure() }
        defer { close(descriptor); unlinkat(directory, temporary, 0) }
        // A restrictive caller umask may remove owner access; set the exact mode
        // on our exclusive descriptor before any sensitive bytes are written.
        guard fchmod(descriptor, 0o600) == 0 else { throw failure() }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw failure()
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        guard renameat(directory, temporary, directory, destination) == 0 else { throw failure() }
    }

    private static func failure() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
