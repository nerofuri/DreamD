import Foundation
import AVFoundation
import CoreLocation
import UIKit
import Combine

enum KeepAliveMethod: String, CaseIterable, Identifiable {
    case audio
    case location
    var id: String { rawValue }
}

/// Keeps DreamD alive in the background so long-running downloads (torrents,
/// HLS, single-stream HTTP) keep making progress after you leave the app.
///
/// iOS only lets an app run in the background if it is doing something the
/// system permits. This offers the two techniques sideloaded apps use:
///
/// - **Audio:** plays a silent, looping audio buffer under the `audio`
///   background mode. Mixes with other audio, so it won't stop your music.
/// - **Location:** subscribes to background location updates (low accuracy,
///   used only as a wake source — nothing is stored or sent anywhere).
///
/// Both keep the app awake and therefore use extra battery, which is why it's
/// an opt-in toggle.
final class BackgroundKeepAlive: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = BackgroundKeepAlive()

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "keepAliveEnabled")
            apply()
        }
    }

    @Published var method: KeepAliveMethod {
        didSet {
            UserDefaults.standard.set(method.rawValue, forKey: "keepAliveMethod")
            if isEnabled { apply() }
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var locationDenied = false

    private var audioPlayer: AVAudioPlayer?
    private lazy var locationManager: CLLocationManager = {
        let m = CLLocationManager()
        m.delegate = self
        return m
    }()

    private override init() {
        isEnabled = UserDefaults.standard.bool(forKey: "keepAliveEnabled")
        let stored = UserDefaults.standard.string(forKey: "keepAliveMethod")
        method = KeepAliveMethod(rawValue: stored ?? "") ?? .audio
        super.init()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// Called once at launch so a previously-enabled session resumes.
    func applyOnLaunch() {
        apply()
    }

    /// Re-establishes keep-alive after something else (e.g. the video player)
    /// took over the audio session.
    func reassertIfNeeded() {
        if isEnabled { apply() }
    }

    // MARK: - Control

    private func apply() {
        guard isEnabled else {
            stopAll()
            return
        }
        switch method {
        case .audio:
            stopLocation()
            startAudio()
        case .location:
            stopAudio()
            startLocation()
        }
    }

    private func stopAll() {
        stopAudio()
        stopLocation()
        isRunning = false
    }

    // MARK: - Audio method

    private func startAudio() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            return
        }

        if audioPlayer == nil {
            guard let data = Self.makeSilentWAV() else { return }
            audioPlayer = try? AVAudioPlayer(data: data)
            audioPlayer?.numberOfLoops = -1     // loop forever
            audioPlayer?.volume = 0
            audioPlayer?.prepareToPlay()
        }
        audioPlayer?.play()
        isRunning = audioPlayer?.isPlaying ?? false
    }

    private func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard isEnabled, method == .audio,
              let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended {
            // Resume playing silence after another app (or our own video
            // player) finishes using the audio session.
            startAudio()
        }
    }

    @objc private func appDidBecomeActive() {
        // Re-assert the session in case it was torn down while suspended.
        if isEnabled, method == .audio, audioPlayer?.isPlaying == false {
            startAudio()
        }
    }

    // MARK: - Location method

    private func startLocation() {
        locationDenied = false
        let manager = locationManager
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 3000
        manager.pausesLocationUpdatesAutomatically = false

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            beginLocationUpdates()
        case .denied, .restricted:
            locationDenied = true
        @unknown default:
            break
        }
    }

    private func beginLocationUpdates() {
        let manager = locationManager
        if manager.authorizationStatus == .authorizedAlways
            || manager.authorizationStatus == .authorizedWhenInUse {
            // Only legal to enable when the location background mode is present.
            manager.allowsBackgroundLocationUpdates = true
        }
        manager.startUpdatingLocation()
        isRunning = true
    }

    private func stopLocation() {
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isEnabled, method == .location else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationDenied = false
            // Ask for Always so updates continue in the background.
            if manager.authorizationStatus == .authorizedWhenInUse {
                manager.requestAlwaysAuthorization()
            }
            beginLocationUpdates()
        case .denied, .restricted:
            locationDenied = true
            isRunning = false
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // We don't use the coordinates — updates only exist to keep the app awake.
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    // MARK: - Silent audio generation

    /// Builds a tiny in-memory silent PCM WAV so no audio resource needs bundling.
    private static func makeSilentWAV(seconds: Int = 1, sampleRate: Int = 8000) -> Data? {
        let channels = 1
        let bitsPerSample = 16
        let numSamples = seconds * sampleRate
        let dataSize = numSamples * channels * bitsPerSample / 8
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]) }
        func u16(_ v: UInt16) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }

        str("RIFF")
        u32(UInt32(36 + dataSize))
        str("WAVE")
        str("fmt ")
        u32(16)
        u16(1)                          // PCM
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(byteRate))
        u16(UInt16(blockAlign))
        u16(UInt16(bitsPerSample))
        str("data")
        u32(UInt32(dataSize))
        d.append(Data(count: dataSize)) // silence
        return d
    }
}
