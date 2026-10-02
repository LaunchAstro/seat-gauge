import Foundation
import Testing

import SeatGaugeCore

/// The profile path reaches the CLI as written (`CLAUDE_CONFIG_DIR` is
/// `profileDir.path`), and the CLI joins file names onto it, which undoes
/// `..` by name. On main 56c9a49 `ConfigLoader.decode` undid `..` by name too
/// (`standardizedFileURL`) and refused these; at a054889 `spot` lets the file
/// system walk `link/..`, which lands beside the link's target instead.
@Suite struct SolProofPR6Tests {

    @Test("Sol proof, criterion 2: a dot-dot past a linked folder that names the default login or another seat's profile is still refused")
    func dotDotPastALinkIsStillRefused() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-sol-\(UUID().uuidString)", isDirectory: true)
        let elsewhere = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-sol-elsewhere-\(UUID().uuidString)/deep", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: elsewhere.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        // `~/sub` is a link to a folder somewhere else.
        try FileManager.default.createSymbolicLink(atPath: home.path + "/sub", withDestinationPath: elsewhere.path)

        func problem(_ seats: [String]) -> String? {
            let text = "{ \"seats\": [\(seats.joined(separator: ", "))] }"
            do {
                _ = try ConfigLoader.decode(Data(text.utf8), tokenDirectory: home.appendingPathComponent("tokens"), home: home)
                return nil
            } catch { return (error as? ConfigProblem)?.reason ?? "\(error)" }
        }
        func claude(_ id: String, _ profile: String) -> String {
            #"{ "id": "\#(id)", "label": "\#(id)", "kind": "claude", "profile": "\#(profile)", "login": "own" }"#
        }

        // `~/sub/../.claude`: the CLI reads `~/.claude/...`, the default login.
        let main = problem([claude("work", home.path + "/sub/../.claude")])
        #expect(main?.contains("default login") == true, "\(main ?? "accepted")")

        // Two seats whose paths the CLI reads as one folder.
        let shared = problem([claude("work", home.path + "/profiles/work"),
                              claude("personal", home.path + "/sub/../profiles/work")])
        #expect(shared?.contains("same profile as \"work\"") == true, "\(shared ?? "accepted")")
    }
}
