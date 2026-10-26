import Foundation
import Testing

/// `scripts/check.sh`'s own parts, run in bash straight from the script, so
/// a change to the gate is checked without running the whole gate.
@Suite struct CheckScriptTests {

    static let script = ScratchHomeTests.root.appendingPathComponent("scripts/check.sh").path

    /// Runs `body` in bash after the lines of check.sh from `start` to `end`.
    static func bash(from start: String, to end: String, _ body: String, _ arguments: [String] = []) throws -> ScratchHomeTests.Ran {
        let part = #"eval "$(sed -n '/^\#(start)/,/^\#(end)/p' "$0")""#
        return try ScratchHomeTests.run("/bin/bash", ["-c", part + "\n" + body, script] + arguments,
                                        env: ["PATH": "/usr/bin:/bin"])
    }

    @Test("Sol proof, criterion 3: protected suites select the alone pass")
    func protectedSuitesSelectTheAlonePass() throws {
        let alone = ["SeatGaugeCoreTests.AttributionSeedTests/theSeedTakesTheWritersLock()",
                     "SeatGaugeCoreTests.SolProofTests/x()", "SeatGaugeCoreTests.StateWriterTests/x()",
                     "SeatGaugeCoreTests.SolProofPR3Tests/x()", "SeatGaugeCoreTests.StrictMCPConfigTests/x()",
                     "SeatGaugeCoreTests.ClearableFoldersTests/x()", "SeatGaugeCoreTests.SignInScriptTests/x()",
                     "SeatGaugeCoreTests.SolPR73ProofTests/x()", "SeatGaugeTests.InstallTests/x()",
                     "SeatGaugeCoreTests.SeatOpenTests/x()"]
        // A name that only ends like a listed one stays side by side.
        let side = ["SeatGaugeCoreTests.PlanTests/x()", "SeatGaugeTests.SpendAccountsTests/x()",
                    "SeatGaugeCoreTests.MySeatOpenTests/x()"]
        let ran = try Self.bash(from: "ALONE=(", to: "alone=",
                                #"for id; do [[ $id =~ $alone ]] && echo "alone $id" || echo "side $id"; done"#,
                                alone + side)
        #expect(ran.status == 0, "\(ran.out)")
        #expect(ran.lines == alone.map { "alone " + $0 } + side.map { "side " + $0 })
    }

    @Test("Sol proof, criterion 4: every failed case survives failure rendering")
    func everyFailedCaseSurvivesFailureRendering() throws {
        let ran = try Self.bash(from: "step() {", to: "}", """
            failed=0
            step demo bash -c 'for i in $(seq 1 61); do echo "✘ Test case$i() failed after 0.001 seconds with 1 issue."; done
              for i in $(seq 1 25); do echo "end$i"; done; exit 1'
            echo "failed=$failed"
            """)
        #expect(ran.lines.first == "check: demo FAIL")
        for n in 1 ... 61 { #expect(ran.out.contains("case\(n)() failed"), "case\(n) was left out") }
        #expect(ran.lines.suffix(2) == ["end25", "failed=1"])
    }
}
