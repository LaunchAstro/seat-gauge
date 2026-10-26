import Foundation
import Testing
@testable import SeatGaugeCore

/// Issue #153: lanes now run as named tabs inside one job workspace, so a
/// session goes by its tab's label when someone named the tab, and by its
/// workspace's label otherwise, exactly as before.
@Suite struct SessionTabLabelTests {
    @Test func aNamedTabInASharedWorkspaceLabelsItsSession() async throws {
        let rows = try await TabScene.run([.init()])
        #expect(rows[0]["shared"]?.workspace == "PROJECT-Refine-work")
        #expect(rows[0]["shared"]?.repo == "PROJECT" && rows[0]["shared"]?.section == "Refine" && rows[0]["shared"]?.seat == "work")
    }

    @Test func aTabHerdrNumberedItselfLeavesTheWorkspaceLabel() async throws {
        let rows = try await TabScene.run([.init()])
        #expect(rows[0]["solo"]?.workspace == "PROJECT-Log-work")
        #expect(rows[0]["solo"]?.section == "Log")
    }

    @Test func aBlankTabLabelLeavesTheWorkspaceLabel() async throws {
        let rows = try await TabScene.run([.init(sharedTab: "  ")])
        #expect(rows[0]["shared"]?.workspace == "PROJECT-Work")
    }

    @Test func aRowKeepsItsTabLabelWhenTheTabListFails() async throws {
        let rows = try await TabScene.run([.init(), .init(tabs: false)])
        #expect(rows[1]["shared"]?.workspace == "PROJECT-Refine-work")
        #expect(rows[1]["solo"]?.workspace == "PROJECT-Log-work")
    }

    @Test func aNewRowTakesTheWorkspaceLabelWhenTheTabListFails() async throws {
        let rows = try await TabScene.run([.init(tabs: false)])
        #expect(rows[0]["shared"]?.workspace == "PROJECT-Work")
    }

    @Test func aRenamedTabRelabelsItsSession() async throws {
        let rows = try await TabScene.run([.init(), .init(sharedTab: "PROJECT-Review-work")])
        #expect(rows[1]["shared"]?.workspace == "PROJECT-Review-work")
        #expect(rows[1]["shared"]?.section == "Review")
    }
}

/// Two panes: `shared` in a job workspace whose tab carries a lane's name,
/// `solo` alone in an old-style workspace whose one tab herdr numbered.
private struct TabScene: Sendable {
    var sharedTab = "PROJECT-Refine-work"
    var tabs = true

    static func run(_ scenes: [TabScene]) async throws -> [[String: SessionRow]] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var passes: [[String: SessionRow]] = []
        for (index, scene) in scenes.enumerated() {
            let log = try await SessionProbe(runner: TabRunner(scene: scene), directory: root.appendingPathComponent("private"),
                                             home: root).run(now: start.addingTimeInterval(Double(index) * 300))
            passes.append(Dictionary(log.sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first }))
        }
        return passes
    }
}

private struct TabRunner: ProcessRunning {
    let scene: TabScene
    func launch(_ spec: ProcessSpec) throws -> any ProcessSession {
        let args = spec.arguments
        func json(_ o: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self) }
        switch spec.executable.lastPathComponent {
        case "ps": return TabSession(["Thu Oct 15 01:00:00 2026"])
        case "herdr": break
        default: return TabSession([])
        }
        switch args {
        case ["pane", "list"]:
            let panes: [[String: Any]] = [
                ["pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "w1:t2", "agent_status": "working", "cwd": "/work/one",
                 "agent_session": ["kind": "id", "value": "shared"]],
                ["pane_id": "w2:p1", "workspace_id": "w2", "tab_id": "w2:t1", "agent_status": "working", "cwd": "/work/two",
                 "agent_session": ["kind": "id", "value": "solo"]],
            ]
            return TabSession([json(["result": ["type": "pane_list", "panes": panes]])])
        case ["workspace", "list"]:
            return TabSession([json(["result": ["workspaces": [["workspace_id": "w1", "label": "PROJECT-Work"],
                                                               ["workspace_id": "w2", "label": "PROJECT-Log-work"]]]])])
        case ["tab", "list"]:
            guard scene.tabs else { throw ProcessFailure("no answer") }
            // herdr's own shape: an unnamed tab's label is its number.
            let tabs: [[String: Any]] = [
                ["tab_id": "w1:t1", "workspace_id": "w1", "number": 1, "label": "1", "focused": true, "pane_count": 1, "agent_status": "idle"],
                ["tab_id": "w1:t2", "workspace_id": "w1", "number": 2, "label": scene.sharedTab, "focused": false, "pane_count": 1,
                 "agent_status": "working"],
                ["tab_id": "w2:t1", "workspace_id": "w2", "number": 1, "label": "1", "focused": true, "pane_count": 1, "agent_status": "working"],
            ]
            return TabSession([json(["result": ["type": "tab_list", "tabs": tabs]])])
        case ["pane", "process-info", "--pane", "w1:p1"], ["pane", "process-info", "--pane", "w2:p1"]:
            return TabSession([json(["result": ["process_info": ["foreground_processes": [["argv": ["claude"], "pid": args[3] == "w1:p1" ? 100 : 200]]]]])])
        default:
            return TabSession([])
        }
    }
}

private struct TabSession: ProcessSession {
    let stdoutLines: AsyncThrowingStream<String, Error>
    init(_ lines: [String]) {
        stdoutLines = AsyncThrowingStream { c in for l in lines { c.yield(l) }; c.finish() }
    }
    func send(_ line: String) throws {}
    func closeInput() {}
    func terminate() {}
}
