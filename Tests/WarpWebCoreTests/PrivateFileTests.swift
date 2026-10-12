import Foundation
import Darwin
import Testing
import WarpWebCore

@Suite struct PrivateFileTests {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build").appendingPathComponent("warpweb-private-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        guard chmod(url.path, 0o700) == 0 else { throw POSIXError(.EACCES) }
        return url
    }
    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }
    @Test func creationAndReplacementArePrivate() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("diagnostics.json")
        let bytes = Data(repeating: 42, count: 131_073)
        try PrivateFile.write(bytes, to: file)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try mode(file) == 0o600)
        #expect(chmod(file.path, 0o644) == 0)
        try PrivateFile.write(Data("replacement".utf8), to: file)
        #expect(try Data(contentsOf: file) == Data("replacement".utf8))
        #expect(try mode(file) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["diagnostics.json"])
    }
    @Test func destinationSymlinkIsReplacedWithoutTouchingTarget() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("public.txt")
        let destination = folder.appendingPathComponent("session")
        try PrivateFile.write(Data("untouched".utf8), to: target)
        #expect(chmod(target.path, 0o644) == 0)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        try PrivateFile.write(Data("private capability".utf8), to: destination)
        #expect(try Data(contentsOf: target) == Data("untouched".utf8))
        #expect(try mode(target) == 0o644)
        #expect(try mode(destination) == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType == .typeRegular)
    }
    @Test func failedReplacementRemovesTemporaryFile() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        #expect(chmod(destination.path, 0o700) == 0)
        #expect(throws: POSIXError.self) { try PrivateFile.write(Data("private".utf8), to: destination) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["directory"])
    }
}
