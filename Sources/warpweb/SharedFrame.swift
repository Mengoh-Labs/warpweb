import Foundation
import Darwin
import CWarpWeb

/// Kitty's local shared-memory transport. One object lives until the terminal
/// acknowledges reading it; both peers may unlink it safely during cleanup.
final class SharedFrame: @unchecked Sendable {
    let name: String
    init(_ data: Data) throws {
        name = "/ww-" + UUID().uuidString.replacingOccurrences(of:"-",with:"").prefix(24)
        guard warpweb_watchdog_register(name) == 0 else { throw CLIError("Session cleanup watchdog disconnected") }
        let fd = warpweb_create_shared_memory(name)
        guard fd >= 0 else {
            warpweb_watchdog_unregister(name)
            throw CLIError("Cannot allocate shared frame")
        }
        var created = false
        defer { if !created { shm_unlink(name); warpweb_watchdog_unregister(name) } }
        defer { close(fd) }
        guard ftruncate(fd,off_t(data.count)) == 0 else { shm_unlink(name); throw CLIError("Cannot size shared frame") }
        let pointer = mmap(nil,data.count,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0)
        guard pointer != MAP_FAILED, let pointer else { shm_unlink(name); throw CLIError("Cannot map shared frame") }
        data.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress { pointer.copyMemory(from:source,byteCount:data.count) }
        }
        munmap(pointer,data.count)
        created = true
    }
    private var unlinked = false
    func unlink() {
        guard !unlinked else { return }; unlinked = true
        shm_unlink(name); warpweb_watchdog_unregister(name)
    }
    deinit { unlink() }
    func packet(id: Int, width: Int, height: Int, columns: Int, rows: Int, query: Bool = false) -> Data {
        let payload = Data(name.utf8).base64EncodedString()
        let position = query ? "" : "\u{1b}[1;1H"
        return Data("\(position)\u{1b}_Ga=\(query ? "q" : "T"),t=s,f=32,i=\(id),s=\(width),v=\(height),c=\(columns),r=\(rows),z=-1,C=1,q=0;\(payload)\u{1b}\\".utf8)
    }
}
