import Foundation
import Testing
import SeatGaugeCore

@Suite struct SolPR73ProofTests {
    @Test("Sol proof, criterion 2: interrupting login waits for Return")
    func interruptingLoginWaitsForReturn() throws {
        let scratch = try SignInScriptTests.scratch(then: "exec sleep 30")
        defer { scratch.remove() }
        let written = try SignInScript.write(helper: scratch.helper, seat: "work", seatsFile: scratch.seats,
                                             in: scratch.parent)
        let (process, input) = try SignInScriptTests.run(written.script)
        defer {
            if process.isRunning {
                try? input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
                process.terminate()
            }
            process.waitUntilExit()
        }
        #expect(SignInScriptTests.appears(scratch.pid))
        let helper = try #require(Int32(SignInScriptTests.text(scratch.pid)))
        // A terminal's Ctrl-C reaches the foreground script and its helper.
        kill(helper, SIGINT)
        kill(process.processIdentifier, SIGINT)
        #expect(SignInScriptTests.appears(written.marker))
        usleep(100_000)
        #expect(SignInScriptTests.text(written.marker) == "130")
        #expect(process.isRunning, "Ctrl-C ended the script without waiting for Return")
    }
}

extension SolPR73ProofTests {
    @Test("Sol proof, criterion correctness: a configured leading-dash seat survives the CLI hand-off")
    func aConfiguredLeadingDashSeatSurvivesTheCLIHandOff() throws {
        let scratch = try SeatLoginTests.scratch(.accepts("fake-code"))
        defer { scratch.remove() }
        let id = "-work"
        let bytes = try JSONSerialization.data(withJSONObject: ["seats": [[
            "id": id, "label": "Work", "kind": "claude",
            "profile": scratch.profile("work").path, "login": "own"
        ]]])
        let seats = try ConfigLoader.decode(bytes, home: scratch.home).seats
        // The app's previous direct path accepts this configured seat and
        // completes its login against a fake Claude, without a real account.
        let signed = try SeatLoginTests.signIn(id, seats: seats, scratch: scratch,
                                               code: "fake-code", said: SeatLoginTests.Said())
        #expect(signed.plan == "pro")
        // The new script hands these exact arguments to the helper, whose
        // parser rejects the accepted seat as a flag before checking it.
        let request = try SeatLogin.Request(arguments: [id, scratch.home.appendingPathComponent("seats.json").path])
        #expect(request.seat == id)
    }
}
