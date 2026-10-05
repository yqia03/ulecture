import Foundation
import AppKit
import AVFoundation

/// Opt-in real system-audio -> production local ASR check. Captured audio and
/// transcript text stay in memory and are discarded. The report contains counts
/// and fixture-word matches only. No provider requests or permission prompts.
@main struct SystemAudioHardwareChecks {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        guard args.count == 5, args[1] == "--hardware" else { exit(2) }
        let root = URL(fileURLWithPath: args[2]), out = URL(fileURLWithPath: args[3])
        let sample = URL(fileURLWithPath: args[4])
        var report: [String: Any] = ["actualSystemCapture": false, "actualLocalASR": false,
            "actualMicrophone": false, "networkDenied": true, "providerRequests": 0,
            "captureSaved": false, "transcriptTextSaved": false, "permissionPromptRequested": false,
            "fixture": "first 12 seconds of project fictional English lecture"]
        func finish(_ status: String, _ code: Int32) -> Never {
            report["status"] = status
            report["finishedUTC"] = ISO8601DateFormatter().string(from: Date())
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appendingPathComponent("system-audio-hardware.json"))
            }
            print(status); exit(code)
        }
        guard CGPreflightScreenCaptureAccess() else {
            report["reason"] = "System audio permission is not already granted; no prompt or playback attempted."
            finish("blocked_permission", 2)
        }
        let models = ModelManager(cacheDirectory: out.appendingPathComponent("models"))
        models.bundledDirectoryForChecks = root.appendingPathComponent("app/Resources/Models")
        let controller = AudioController(modelManager: models)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [sample.path]
        player.standardOutput = FileHandle.nullDevice; player.standardError = FileHandle.nullDevice
        var rowCount = 0, matches = Set<String>(), gaps = 0, peakLevel = -80.0
        controller.onConfirmed = { row in
            rowCount += 1
            let text = row.text.lowercased()
            for word in ["fictional", "lesson", "learning", "memory", "information", "example"] {
                if text.contains(word) { matches.insert(word) }
            }
        }
        controller.onGap = { _ in gaps += 1 }
        do {
            await models.restoreAtLaunch(); _ = try await models.ensureLoaded()
            report["actualLocalASR"] = true
            var configuration = AudioConfiguration()
            configuration.source = .system; configuration.language = "en"; configuration.saveRecording = false
            await controller.configure(configuration)
            let began = ProcessInfo.processInfo.systemUptime
            try await controller.start(sessionID: UUID().uuidString, elapsedOffset: 0,
                recordingDirectory: nil, maximumCaptureDuration: 18)
            report["actualSystemCapture"] = controller.phase == .capturing
            try player.run()
            while player.isRunning, ProcessInfo.processInfo.systemUptime - began < 16 {
                peakLevel = max(peakLevel, controller.level)
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if player.isRunning { player.terminate() }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            await controller.pause()
            report["wallSeconds"] = ProcessInfo.processInfo.systemUptime - began
            report["recognizedSegments"] = rowCount
            report["fixtureWordMatches"] = matches.sorted()
            report["capturePeakDBFS"] = peakLevel
            report["gapCount"] = gaps
            report["stoppedAndDrained"] = controller.phase == .paused && !controller.draining && !controller.ownsCaptureLease
            report["playbackExitCode"] = player.terminationStatus
            report["boundary"] = "Short real system capture and local recognition of external afplay fixture; not live microphone, cloud translation, or sustained-session acceptance."
            // Release Metal resources before process exit, as normal app shutdown
            // does after draining; exit() does not unwind this async Swift scope.
            let unloaded = await models.unload()
            report["modelUnloaded"] = unloaded
            let passed = rowCount > 0 && matches.count >= 2 && peakLevel > -70 && !controller.ownsCaptureLease && player.terminationStatus == 0 && unloaded
            finish(passed ? "passed" : "failed_capture_or_recognition", passed ? 0 : 1)
        } catch {
            if player.isRunning { player.terminate() }
            await controller.pause()
            report["modelUnloaded"] = await models.unload()
            report["reason"] = "Hardware start, local recognition, playback, or drain failed."
            report["errorType"] = String(describing: type(of: error))
            finish("failed", 1)
        }
    }
}
