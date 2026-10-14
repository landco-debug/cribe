import AppKit
import CoreAudio
import Foundation
import OSLog

/// One recording owns one temporary change of the *system output*, not the microphone.
/// A public API cannot pause arbitrary browsers/streams; those are quieted using the
/// default output-device mute (or its master volume, if mute is unavailable).
/// Music and Spotify are additionally paused through their own scripting interfaces.
@MainActor
final class MediaQuietDuringDictation {
    static let shared = MediaQuietDuringDictation()

    private let logger = Logger(subsystem: "online.nazarovych.cribe", category: "MediaQuiet")
    private let commands = DispatchQueue(label: "online.nazarovych.cribe.media-commands", qos: .userInitiated)
    private var active: Snapshot?

    private struct Player: Sendable {
        let bundleID: String
        let pid: pid_t
        let trackID: String
    }

    private struct Candidate: Sendable {
        let bundleID: String
        let pid: pid_t
    }

    private struct Snapshot {
        let output: OutputQuietSnapshot?
        let players: [Player]
    }

    /// Called only when the microphone is about to start, *after* the model/VAD warmup.
    /// Awaiting the pause avoids capturing the tail of a song as spoken words.
    func begin() async {
        guard active == nil else { return }
        let candidates = Self.runningPlayers()
        let paused: [Player] = await withCheckedContinuation { continuation in
            commands.async {
                let players = candidates.compactMap { candidate -> Player? in
                    guard let trackID = Self.execute(candidate.bundleID, action: "pause") else { return nil }
                    return Player(bundleID: candidate.bundleID, pid: candidate.pid, trackID: trackID)
                }
                continuation.resume(returning: players)
            }
        }
        let output = OutputQuietSnapshot.quiet()
        active = Snapshot(output: output, players: paused)
        logger.info("Скрыт вывод на время диктовки; приостановлено плееров: \(paused.count)")
    }

    /// Called at every terminal capture path (stop, Esc, auto-stop, recording failure).
    /// Output restoration is synchronous, so the end chime is audible. Player resumes are
    /// serialized with the next begin, avoiding a stale resume racing a subsequent pause.
    func end() {
        guard let saved = active else { return }
        active = nil
        saved.output?.restore()

        let stillRunning = Dictionary(
            Self.runningPlayers().map { ($0.bundleID, $0.pid) },
            uniquingKeysWith: { first, _ in first }
        )
        commands.async {
            for player in saved.players where stillRunning[player.bundleID] == player.pid {
                _ = Self.execute(player.bundleID, action: "resume", trackID: player.trackID)
            }
        }
    }

    /// A tiny allowlist: these applications expose both playback state and explicit
    /// pause/play. Never send a blind Play/Pause toggle to an arbitrary application.
    private static func runningPlayers() -> [Candidate] {
        ["com.spotify.client", "com.apple.Music"].flatMap { bundleID in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { !$0.isTerminated }
                .map { Candidate(bundleID: bundleID, pid: $0.processIdentifier) }
        }
    }

    /// AppleScript is executed only for apps already running, on a serial background queue.
    /// A 2-second Apple Event timeout prevents a hung player from blocking dictation forever.
    /// Return the track's stable identifier only if we actually issued pause to a playing app.
    nonisolated private static func execute(_ bundleID: String, action: String, trackID: String = "") -> String? {
        guard ["com.spotify.client", "com.apple.Music"].contains(bundleID) else { return nil }
        let isSpotify = bundleID == "com.spotify.client"
        let trackExpression = isSpotify ? "id of current track" : "persistent ID of current track"
        // Only internal allowlisted IDs reach AppleScript; never interpolate user input.
        let script: String
        if action == "pause" {
            script = """
            with timeout of 2 seconds
                tell application id "\(bundleID)"
                    if player state is not playing then return ""
                    set trackKey to ""
                    try
                        set trackKey to (\(trackExpression)) as text
                    end try
                    pause
                    return "PAUSED:" & trackKey
                end tell
            end timeout
            """
        } else {
            // A closed/restarted player is rejected earlier using the process identifier.
            // Do not start something that was already paused before Cribe started.
            let escapedTrackID = trackID.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            script = """
            with timeout of 2 seconds
                tell application id "\(bundleID)"
                    if player state is not paused then return ""
                    if "\(escapedTrackID)" is not "" then
                        try
                            if (\(trackExpression)) as text is not "\(escapedTrackID)" then return ""
                        on error
                            return ""
                        end try
                    end if
                    play
                    return "RESUMED"
                end tell
            end timeout
            """
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            // Automation permission sheets and broken players can otherwise hang osascript
            // indefinitely, preventing a new microphone capture. Keep this bounded.
            let watchdog = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(5), execute: watchdog)
            process.waitUntilExit()
            watchdog.cancel()
            guard process.terminationStatus == 0 else { return nil }
            let response = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if action == "pause" {
                guard response.hasPrefix("PAUSED:") else { return nil }
                return String(response.dropFirst("PAUSED:".count))
            }
            return response == "RESUMED" ? "" : nil
        } catch {
            return nil
        }
    }
}

/// Only modify a writable property of the default output device. If a USB/HDMI/
/// AirPlay device exposes neither mute nor software master gain, leave it alone.
private struct OutputQuietSnapshot {
    enum Kind { case mute, volume }
    let device: AudioObjectID
    let address: AudioObjectPropertyAddress
    let kind: Kind
    let previousMute: UInt32
    let previousVolume: Float32

    static func quiet() -> Self? {
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = kAudioObjectUnknown
        var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddress, 0, nil, &deviceSize, &device
        ) == noErr, device != kAudioObjectUnknown else { return nil }

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var writable: DarwinBoolean = false
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &muteAddress),
           AudioObjectIsPropertySettable(device, &muteAddress, &writable) == noErr, writable.boolValue,
           AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted) == noErr {
            // Never unmute a device that was muted before dictation.
            guard muted == 0 else { return nil }
            var yes: UInt32 = 1
            if AudioObjectSetPropertyData(device, &muteAddress, 0, nil, size, &yes) == noErr {
                return Self(device: device, address: muteAddress, kind: .mute, previousMute: muted, previousVolume: 0)
            }
        }

        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        writable = false
        size = UInt32(MemoryLayout<Float32>.size)
        var volume: Float32 = 0
        guard AudioObjectHasProperty(device, &volumeAddress),
              AudioObjectIsPropertySettable(device, &volumeAddress, &writable) == noErr, writable.boolValue,
              AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volume) == noErr,
              volume > 0 else { return nil }
        var zero: Float32 = 0
        guard AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, size, &zero) == noErr else { return nil }
        return Self(device: device, address: volumeAddress, kind: .volume, previousMute: 0, previousVolume: volume)
    }

    func restore() {
        var address = address
        switch kind {
        case .mute:
            var current: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &current) == noErr,
                  current == 1 else { return }
            var value = previousMute
            _ = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
        case .volume:
            var current: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &current) == noErr,
                  abs(current) < 0.0001 else { return }
            var value = previousVolume
            _ = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
        }
    }
}
