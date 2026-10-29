#if canImport(Darwin)
import Darwin
import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCLISleepInhibitorTests {
    private static func buildWatchdogExecutable(in directory: URL) throws -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot.appendingPathComponent("Sources/CodexBarClaudeWatchdog/main.swift")
        let outputURL = directory.appendingPathComponent("CodexBarClaudeWatchdog")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", sourceURL.path, "-o", outputURL.path]
        try compiler.run()
        compiler.waitUntilExit()
        #expect(compiler.terminationStatus == 0)
        return outputURL
    }

    @Test(arguments: [false, true])
    func `passive captures release only caffeinate in their owned process groups`(useWatchdog: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-sleep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let companion = directory.appendingPathComponent("caffeinate")
        try FileManager.default.createSymbolicLink(atPath: companion.path, withDestinationPath: "/bin/sleep")
        let scriptName = useWatchdog ? "claude" : "synthetic-claude"
        let script = directory.appendingPathComponent(scriptName)
        try """
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *"/status"*)
              /usr/bin/caffeinate -i -t 30 &
              inhibitor=$!
              '\(companion.path)' 30 &
              companion=$!
              /bin/sleep 0.1
              printf 'Probe ready: %s %s %s %s\\n' "$$" "$PPID" "$inhibitor" "$companion"
              ;;
          esac
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        var environment: [String: String] = ["PATH": "/usr/bin:/bin", "HOME": directory.path]
        if useWatchdog {
            let watchdogURL = try Self.buildWatchdogExecutable(in: directory)
            environment["CODEXBAR_HELPER_CODEXBARCLAUDEWATCHDOG"] = watchdogURL.path
        }

        // A real executable in a separate synthetic group proves the group boundary, without a live account.
        let outside = Process()
        outside.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        outside.arguments = ["-i", "-t", 30.description]
        try outside.run()
        defer {
            if outside.isRunning { outside.terminate() }
            outside.waitUntilExit()
        }
        let session = ClaudeCLISession(workingDirectory: directory)
        do {
            var previousGroup: pid_t?
            for _ in 0..<2 {
                let output = try await session.capture(
                    subcommand: "/status",
                    binary: script.path,
                    timeout: 8,
                    environment: environment,
                    stopOnSubstrings: ["Probe ready:"])
                let line = try #require(output.components(separatedBy: "\n").first { $0.contains("Probe ready: ") })
                let pids = line.split(separator: " ")
                    .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                #expect(pids.count == 4)
                let claudePID = try #require(pids.first)
                let parentPID = try #require(pids.dropFirst().first)
                let inhibitor = try #require(pids.dropFirst(2).first)
                let companionPID = try #require(pids.last)
                let claudeGroup = getpgid(claudePID)
                if let previousGroup { #expect(claudeGroup == previousGroup) }
                previousGroup = claudeGroup
                #expect(claudeGroup == claudePID)
                if useWatchdog {
                    #expect(getpgid(parentPID) == parentPID)
                    #expect(claudeGroup != getpgid(parentPID))
                }
                #expect(getpgid(companionPID) == claudeGroup)
                #expect(getpgid(outside.processIdentifier) != claudeGroup)
                let deadline = Date().addingTimeInterval(1)
                while DarwinProcessEnumerator.executablePath(pid: inhibitor) == "/usr/bin/caffeinate",
                      Date() < deadline
                {
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(DarwinProcessEnumerator.executablePath(pid: inhibitor) != "/usr/bin/caffeinate")
                #expect(kill(companionPID, 0) == 0)
                #expect(outside.isRunning)
            }
            await session.reset()
        } catch {
            await session.reset()
            throw error
        }
    }

    @Test
    func `session reset reaps marked watchdog child group and rejects unmarked isolated groups`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-reap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let watchdogURL = try Self.buildWatchdogExecutable(in: directory)
        let script = directory.appendingPathComponent("claude")
        try """
        #!/bin/sh
        trap '' TERM
        /bin/sleep 30 &
        descendant=$!
        while IFS= read -r line; do
          case "$line" in
            *"/status"*)
              printf 'Probe ready: %s %s\\n' "$$" "$descendant"
              ;;
          esac
        done
        /bin/sleep 30
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        unrelated.arguments = ["-i", "-t", "30"]
        try unrelated.run()
        let unrelatedPID = unrelated.processIdentifier
        _ = setpgid(unrelatedPID, unrelatedPID)
        defer {
            if unrelated.isRunning { unrelated.terminate() }
            unrelated.waitUntilExit()
        }

        let environment: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "HOME": directory.path,
            "CODEXBAR_HELPER_CODEXBARCLAUDEWATCHDOG": watchdogURL.path,
        ]
        let session = ClaudeCLISession(workingDirectory: directory)
        let output = try await session.capture(
            subcommand: "/status",
            binary: script.path,
            timeout: 8,
            environment: environment,
            stopOnSubstrings: ["Probe ready:"])
        let line = try #require(output.components(separatedBy: "\n").first { $0.contains("Probe ready: ") })
        let pids = line.split(separator: " ")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        #expect(pids.count == 2)
        let claudePID = try #require(pids.first)
        let descendantPID = try #require(pids.last)
        #expect(kill(claudePID, 0) == 0)
        #expect(kill(descendantPID, 0) == 0)
        #expect(unrelated.isRunning)

        await session.reset()

        let deadline = Date().addingTimeInterval(2.0)
        while (kill(claudePID, 0) == 0 || kill(descendantPID, 0) == 0) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(kill(claudePID, 0) != 0)
        #expect(kill(descendantPID, 0) != 0)
        #expect(unrelated.isRunning)
    }
}
#endif
