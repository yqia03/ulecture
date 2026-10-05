import Foundation
import AVFoundation
import CoreAudio

/// Opt-in physical microphone regression. PCM is only counted, never saved,
/// played, transcribed, or sent to a service. No permission prompt is requested.
private final class MicrophoneObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var failure: String?

    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        frames += Int(buffer.frameLength)
    }
    func failed(_ reason: String) {
        lock.lock(); defer { lock.unlock() }
        if failure == nil { failure = reason }
    }
    var snapshot: (frames: Int, failure: String?) {
        lock.lock(); defer { lock.unlock() }
        return (frames, failure)
    }
}

@main struct MicrophoneDeviceChecks {
    private static func require(_ condition: Bool, _ reason: String) throws {
        if !condition { throw AudioFailure.message(reason) }
    }

    private static func defaultInputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        try require(status == noErr && device != 0, "Cannot read the system default input: \(status)")
        return device
    }

    private static func requireHealthy(_ backend: HardwareAudioCaptureBackend, configuration: AudioConfiguration,
                                       observations: MicrophoneObservations) async throws {
        if let failure = observations.snapshot.failure { throw AudioFailure.message("Capture callback failed: \(failure)") }
        if let reason = await backend.microphoneHealth(configuration: configuration) { throw AudioFailure.message(reason) }
    }

    static func main() async {
        guard CommandLine.arguments.dropFirst() == ["--hardware"] else {
            print("BLOCKED: physical microphone capture requires --hardware; no capture or permission request performed.")
            exit(2)
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("BLOCKED: microphone authorization must already be granted; no permission prompt requested.")
            exit(2)
        }
        let systemDefault: AudioDeviceID
        do { systemDefault = try defaultInputDevice() }
        catch { print("BLOCKED: \(error.localizedDescription)"); exit(2) }
        let devices = classroomInputDevices()
        guard devices.contains(where: { $0.id == systemDefault }) else {
            print("BLOCKED: the system default input is unavailable for the mismatch assertion; system settings left unchanged.")
            exit(2)
        }
        guard let selected = devices.first(where: { $0.builtIn && $0.id != systemDefault }) else {
            print("BLOCKED: no built-in microphone differs from system default \(systemDefault); system settings left unchanged.")
            exit(2)
        }
        print("Selected built-in input: \(selected.name), id=\(selected.id); systemDefault=\(systemDefault); nonDefault=true")

        let backend = HardwareAudioCaptureBackend()
        var configuration = AudioConfiguration()
        configuration.deviceID = selected.id
        configuration.saveRecording = false
        do {
            // The missing-device path must reject before constructing hardware.
            var unavailable = configuration
            var unavailableID = UInt32.max
            while devices.contains(where: { $0.id == unavailableID }) { unavailableID -= 1 }
            unavailable.deviceID = unavailableID
            let invalidRequest = UUID()
            try await backend.prepare(requestID: invalidRequest)
            var missingDeviceRejected = false
            do {
                try await backend.start(requestID: invalidRequest, configuration: unavailable,
                                        receive: { _ in }, failed: { _ in })
            } catch {
                missingDeviceRejected = error.localizedDescription == "所选输入设备失联；不会自动换设备。"
            }
            try await backend.stop()
            try require(missingDeviceRejected, "Unavailable input did not fail with the missing-device error")
            try require(await backend.microphoneHealth(configuration: unavailable) == nil, "Stopped backend reported unhealthy after missing-device rejection")
            print("PASS: unavailable selected device rejected")

            for cycle in 1...3 {
                try require(try defaultInputDevice() == systemDefault, "System default input changed during the check")
                let observations = MicrophoneObservations(), request = UUID()
                try await backend.prepare(requestID: request)
                try await backend.start(requestID: request, configuration: configuration,
                                        receive: { observations.receive($0) }, failed: { observations.failed($0) })
                // Catch the reported mismatch directly at the start boundary.
                try await requireHealthy(backend, configuration: configuration, observations: observations)
                if cycle == 1 {
                    var mismatched = configuration
                    mismatched.deviceID = systemDefault
                    let reason = await backend.microphoneHealth(configuration: mismatched)
                    try require(reason == "麦克风设备与选择不符", "Healthy capture did not reject a different available input configuration")
                    try await requireHealthy(backend, configuration: configuration, observations: observations)
                    print("PASS: different available input configuration rejected without changing hardware")
                }
                for _ in 0..<20 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    try await requireHealthy(backend, configuration: configuration, observations: observations)
                }
                try await backend.stop()
                let stoppedFrames = observations.snapshot.frames
                try await Task.sleep(nanoseconds: 100_000_000)
                let result = observations.snapshot
                try require(result.failure == nil, "Capture callback failed: \(result.failure ?? "")")
                try require(result.frames > 0, "Cycle \(cycle) delivered no physical PCM frames")
                try require(result.frames == stoppedFrames, "Cycle \(cycle) delivered PCM after stop returned")
                try require(await backend.microphoneHealth(configuration: configuration) == nil, "Stopped backend reported unhealthy in cycle \(cycle)")
                try require(try defaultInputDevice() == systemDefault, "System default input changed during the check")
                print("PASS: cycle \(cycle), healthy nondefault input for 2 seconds, \(result.frames) frames discarded, stopped cleanly")
            }
            print("PASS: physical microphone selection and health; 3 start/stop cycles; no recording, playback, models, network, or system-device changes")
        } catch {
            do { try await backend.stop() }
            catch { print("FAIL: cleanup stop failed: \(error.localizedDescription)") }
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }
}
