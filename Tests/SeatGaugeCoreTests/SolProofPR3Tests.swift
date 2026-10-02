import Foundation
import Testing

import SeatGaugeCore

/// Sol's proofs for PR 3 at 8ea9f24, against the suite's own fake `claude`.
@Suite struct SolProofPR3Tests {

    /// True when this volume takes `A` and `a` for one name.
    static func ignoresCase(_ directory: URL) -> Bool {
        let probe = directory.appendingPathComponent("case-probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probe) }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("CASE-PROBE").path)
    }

    @Test("Sol proof, criterion 3: another seat's profile in another spelling is refused on a fresh machine") func anotherSeatsProfileInAnotherSpellingIsRefused() throws {
        let scratch = try SeatLoginTests.scratch(.accepts("c"))
        defer { scratch.remove() }
        guard Self.ignoresCase(scratch.home) else { return }
        // Neither profile exists yet, as on a fresh machine.
        let seats = [SeatLoginTests.seat("personal", profile: scratch.profile("personal")),
                     SeatLoginTests.seat("work", profile: scratch.home.appendingPathComponent("PROFILES/PERSONAL"))]
        let reason = SeatLoginTests.refusal {
            try SeatLoginTests.signIn("work", seats: seats, scratch: scratch, code: "c", said: SeatLoginTests.Said())
        }
        #expect(reason?.contains("same profile as personal") == true, "accepted: \(reason ?? "signed in")")
        #expect(!scratch.ran, "work's claude ran")
        // What work signed in is now personal's profile: personal's next child reads work's login.
        let crossed = FileManager.default.fileExists(atPath: scratch.profile("personal").appendingPathComponent(".signed-in").path)
        #expect(!crossed, "work's login landed in personal's profile")
    }

    @Test("Sol proof, criterion 3: ~/.claude in another spelling is refused when ~/.claude does not exist yet") func dotClaudeInAnotherSpellingIsRefusedBeforeItExists() throws {
        let scratch = try SeatLoginTests.scratch(.accepts("c"))
        defer { scratch.remove() }
        guard Self.ignoresCase(scratch.home) else { return }
        let shouted = scratch.home.appendingPathComponent(".CLAUDE", isDirectory: true)
        let reason = SeatLoginTests.refusal {
            try SeatLoginTests.signIn("work", seats: [SeatLoginTests.seat("work", profile: shouted)], scratch: scratch,
                                      code: "c", said: SeatLoginTests.Said())
        }
        #expect(reason?.contains("default login") == true, "accepted: \(reason ?? "signed in")")
        #expect(!scratch.ran, "claude ran with ~/.claude as its profile")
    }

    @Test("Sol proof, criterion 1: a claude auth status that never answers is stopped at its deadline") func aHungStatusIsStoppedAtItsDeadline() throws {
        let scratch = try SeatLoginTests.scratch(.accepts("c"))
        defer { scratch.remove() }
        // The status call hangs past SeatLogin.status's 60-second deadline.
        let fake = scratch.bin.appendingPathComponent("claude")
        let script = try String(contentsOf: fake, encoding: .utf8)
            .replacingOccurrences(of: "status)\n", with: "status)\n  sleep 85\n")
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let started = ContinuousClock.now
        _ = SeatLoginTests.refusal {
            try SeatLoginTests.signIn("work", seats: [SeatLoginTests.seat("work", profile: scratch.profile("work"))],
                                      scratch: scratch, code: "c", said: SeatLoginTests.Said())
        }
        let took = ContinuousClock.now - started
        #expect(took < .seconds(70), "the status deadline did not bound the wait: took \(took)")
    }
}
