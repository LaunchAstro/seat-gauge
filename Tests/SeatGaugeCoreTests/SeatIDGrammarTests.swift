import Foundation
import Testing

import SeatGaugeCore

/// A seat id names files and fills a column of `spend.csv`, so `seats.json`
/// holds it to the plain id first launch already uses: a lowercase letter or
/// digit, then lowercase letters, digits, `-` or `_`.
@Suite struct SeatIDGrammarTests {
    static func seats(_ id: String, kind: String) throws -> Data {
        var seat: [String: Any] = ["id": id, "label": "Seat", "kind": kind]
        if kind == "claude" { seat["profile"] = "/tmp/seat-gauge-grammar/profile"; seat["login"] = "own" }
        return try JSONSerialization.data(withJSONObject: ["seats": [seat]])
    }

    static let refused = ["work,team", "../../escaped", "a/b", "-work", "--email", "_work", "work team",
                          "wörk", "Work", "", "work\nteam", ".hidden", "work.team", "wo\"rk"]

    @Test("an id that is not a plain id is refused at load, in one sentence that names it, for either kind")
    func refusesWhatIsNotAPlainID() throws {
        for kind in ["claude", "codex"] {
            for id in Self.refused {
                do {
                    _ = try ConfigLoader.decode(try Self.seats(id, kind: kind))
                    Issue.record("\(kind) seat \(id.debugDescription) was accepted")
                } catch let problem as ConfigProblem {
                    #expect(problem.reason.hasPrefix("seats.json: the id \"\(id)\" is not a plain id"),
                            "\(id.debugDescription): \(problem.reason)")
                    let rest = problem.reason.replacingOccurrences(of: "seats.json", with: "")
                        .replacingOccurrences(of: "\"\(id)\"", with: "")
                    #expect(rest.hasSuffix(".") && rest.filter { $0 == "." }.count == 1 && !rest.contains("\n"),
                            "\(id.debugDescription): one sentence")
                }
            }
        }
    }

    @Test("plain ids are still read")
    func acceptsPlainIDs() throws {
        for id in ["work", "w0-r_k", "9lives", "a"] {
            #expect(try ConfigLoader.decode(try Self.seats(id, kind: "claude")).seats.map(\.id.rawValue) == [id])
        }
        #expect(try ConfigLoader.decode(try Self.seats("codex-2", kind: "codex")).seats.map(\.id.rawValue)
                == ["codex-2"])
    }

    @Test("a seat with neither login nor token never reads a token file it did not name")
    func noImplicitTokenFile() throws {
        // Only ever under the scratch home `scripts/scratch-home.sh` makes.
        let home = NSHomeDirectory()
        try #require(URL(fileURLWithPath: home).lastPathComponent.hasPrefix("seat-gauge-home."))
        let folder = URL(fileURLWithPath: home).appendingPathComponent(".config/claude-seats", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("not-a-real-token".utf8).write(to: folder.appendingPathComponent("personal.token"))

        let text = #"{ "seats": [ { "id": "personal", "label": "Personal", "kind": "claude", "profile": "/tmp/seat-gauge-grammar/personal" } ] }"#
        let seat = try #require(ConfigLoader.decode(Data(text.utf8)).seats.first)
        #expect(seat.tokenFile == nil)
    }
}
