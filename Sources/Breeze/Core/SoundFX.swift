import AppKit
import AVFoundation

enum Sound: String, CaseIterable {
    case scanStart, scanDone, clean, tap, drill, warn
}

/// Plays Breeze's sound effects. Respects the "Sound effects" setting and volume.
@MainActor
final class SoundFX {
    static let shared = SoundFX()
    private var cache: [Sound: AVAudioPlayer] = [:]
    private var suppressed = 0

    nonisolated static let enabledKey = "soundsEnabled"
    nonisolated static let volumeKey = "soundVolume"

    var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
    var volume: Float { Float(UserDefaults.standard.object(forKey: Self.volumeKey) as? Double ?? 0.6) }

    func play(_ s: Sound, force: Bool = false) {
        guard force || (enabled && suppressed == 0) else { return }
        guard let snd = sound(s) else { return }
        snd.currentTime = 0
        snd.volume = volume
        snd.play()
    }

    /// Silences sounds triggered inside `work` (e.g. Smart Scan running several scans at once).
    func quietly<T>(_ work: () async -> T) async -> T {
        suppressed += 1
        defer { suppressed -= 1 }
        return await work()
    }

    private func sound(_ s: Sound) -> AVAudioPlayer? {
        if let c = cache[s] { return c }
        guard let url = Bundle.main.url(forResource: s.rawValue, withExtension: "wav") else {
            CleanLog.log("Sound missing from bundle: \(s.rawValue).wav")
            return nil
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            cache[s] = p
            return p
        } catch {
            CleanLog.log("Sound failed to load \(s.rawValue): \(error.localizedDescription)")
            return nil
        }
    }
}
