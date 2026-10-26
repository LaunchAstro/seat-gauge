import Foundation
import Testing

@testable import SeatGaugeCore

/// `PrivateFile` itself: no draft left behind, a missing folder made only
/// when asked, and a folder that is not the user's never touched.
@Suite struct PrivateFileTests {
    @Test("a write never leaves a draft behind, and never touches a folder that is not the user's")
    func noDraftAndNoForeignFolder() throws {
        let root = try OwnerOnlyFilesTests.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state.json")
        try PrivateFile.write(Data("one".utf8), to: file)
        try PrivateFile.write(Data("two".utf8), to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "two")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["state.json"])
        // A missing folder is made only when the caller asks.
        let missing = root.appendingPathComponent("missing/state.json")
        #expect(throws: (any Error).self) { try PrivateFile.write(Data(), to: missing) }
        // The shared temporary folder is root's, and stays as it is.
        let before = OwnerOnlyFilesTests.mode(URL(fileURLWithPath: "/private/tmp"))
        PrivateFile.narrow(URL(fileURLWithPath: "/private/tmp"))
        #expect(OwnerOnlyFilesTests.mode(URL(fileURLWithPath: "/private/tmp")) == before)
    }
}
