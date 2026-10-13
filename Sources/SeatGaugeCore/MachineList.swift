import Foundation

/// Adds a machine to `seats.json` as text, so the user's comments and
/// layout stay as they were. The result is decoded before it is handed back,
/// so a file this cannot edit cleanly is never written.
public enum MachineList {
    /// An id from a host or label: lowercase letters and digits, with `-`
    /// between words, such as `studio` from `studio.local`.
    public static func id(from name: String) -> String {
        let first = name.split(separator: "@").last.map(String.init) ?? name
        let host = first.split(separator: ".").first.map(String.init) ?? first
        let words = host.lowercased().split { !($0.isLetter || $0.isNumber) || !$0.isASCII }
        return words.isEmpty ? "machine" : words.joined(separator: "-")
    }

    /// `text` with `machine` at the end of its `machines` list. With no list
    /// yet, the list is made with this Mac first, since a missing list meant
    /// this Mac alone.
    public static func adding(_ machine: Machine, here: Machine, to text: String) throws -> String {
        let config = try ConfigLoader.decode(Data(text.utf8))
        if config.machines.contains(where: { $0.id == machine.id }) {
            throw ConfigProblem("seats.json already has a machine with the id \"\(machine.id)\".")
        }
        if let ssh = machine.ssh, config.machines.contains(where: { $0.ssh == ssh }) {
            throw ConfigProblem("seats.json already lists \(ssh).")
        }
        let edited: String
        if let list = text.range(of: #""machines"\s*:\s*\["#, options: .regularExpression),
           let close = closing(text, from: list.upperBound) {
            let before = text[..<close]
            let trimmed = before.reversed().drop { $0.isWhitespace }
            let comma = trimmed.first.map { $0 != "," && $0 != "[" } ?? false
            let body = String(before[..<trimmed.startIndex.base])
            edited = body + (comma ? "," : "") + "\n    " + entry(machine) + ",\n  " + text[close...]
        } else {
            guard let end = text.lastIndex(of: "}") else { throw ConfigProblem("seats.json has no closing brace.") }
            let before = text[..<end]
            let trimmed = before.reversed().drop { $0.isWhitespace }
            let comma = trimmed.first.map { $0 != "," && $0 != "{" } ?? false
            let body = String(before[..<trimmed.startIndex.base])
            edited = body + (comma ? "," : "") + "\n  \"machines\": [\n    " + entry(here) + ",\n    "
                + entry(machine) + ",\n  ],\n" + text[end...]
        }
        let check = try ConfigLoader.decode(Data(edited.utf8))
        guard check.seats == config.seats, check.machines.last == machine else {
            throw ConfigProblem("seats.json could not be edited cleanly; add \(entry(machine)) to its \"machines\" list by hand.")
        }
        return edited
    }

    /// The `]` that closes the list opened just before `start`, past any
    /// string or comment that holds a bracket.
    static func closing(_ text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var index = start
        var quoted = false
        while index < text.endIndex {
            let character = text[index]
            if quoted {
                if character == "\\" { index = text.index(after: index) } else if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true
            } else if character == "/", text[index...].hasPrefix("//") {
                index = text[index...].firstIndex(of: "\n") ?? text.endIndex
                continue
            } else if character == "[" {
                depth += 1
            } else if character == "]" {
                if depth == 0 { return index }
                depth -= 1
            }
            index = text.index(after: index)
        }
        return nil
    }

    public static func entry(_ machine: Machine) -> String {
        let quote = ConfigLoader.quoted
        return "{ \"id\": \(quote(machine.id)), \"label\": \(quote(machine.label))"
            + (machine.ssh.map { ", \"ssh\": \(quote($0))" } ?? "") + " }"
    }
}
