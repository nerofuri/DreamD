import SwiftUI
import AVKit
import AVFoundation
import UIKit

#if canImport(VLCKitSPM)
import VLCKitSPM
#elseif canImport(MobileVLCKit)
import MobileVLCKit
#endif

#if canImport(VLCKitSPM) || canImport(MobileVLCKit)
let vlcPlaybackAvailable = true
#else
let vlcPlaybackAvailable = false
#endif

enum PlaybackEngine {
    /// Extensions AVFoundation decodes natively with hardware acceleration.
    static let avNative: Set<String> = [
        "mp4", "m4v", "mov", "qt",
        "m4a", "mp3", "aac", "wav", "caf", "aif", "aiff", "m3u8", "mp2"
    ]

    /// All media extensions we consider playable in-app.
    static let playable: Set<String> = avNative.union([
        "mkv", "avi", "flv", "ts", "m2ts", "mts", "wmv", "webm", "ogv", "ogg",
        "mpg", "mpeg", "vob", "3gp", "3g2", "asf", "rm", "rmvb", "divx", "f4v",
        "m4b", "opus", "wma", "flac", "dts", "ac3", "amr", "mkv3d"
    ])

    static func isPlayable(_ url: URL) -> Bool {
        playable.contains(url.pathExtension.lowercased())
    }

    /// Decides which engine to use. VLC handles everything, so anything not in
    /// the native set (or when it's a container VLC does better) goes to VLC.
    static func useVLC(for url: URL) -> Bool {
        guard vlcPlaybackAvailable else { return false }
        let ext = url.pathExtension.lowercased()
        // AVPlayer is unreliable with raw MPEG-TS; prefer VLC there.
        if ext == "ts" || ext == "m2ts" || ext == "mts" || ext == "mp2" { return true }
        return !avNative.contains(ext)
    }
}

/// Plays a local or remote media URL in whichever engine can actually decode it.
struct UniversalPlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                #if canImport(VLCKitSPM) || canImport(MobileVLCKit)
                if PlaybackEngine.useVLC(for: url) {
                    VLCPlayerContainer(url: url)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    avPlayer
                }
                #else
                avPlayer
                #endif
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    private var avPlayer: some View {
        VideoPlayer(player: AVPlayer(url: url))
            .ignoresSafeArea(edges: .bottom)
    }
}

#if canImport(VLCKitSPM) || canImport(MobileVLCKit)

/// SwiftUI wrapper around a VLCKit-backed player with custom transport controls.
struct VLCPlayerContainer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> VLCPlayerViewController {
        VLCPlayerViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: VLCPlayerViewController, context: Context) {}
}

final class VLCPlayerViewController: UIViewController {
    private let url: URL
    private let mediaPlayer = VLCMediaPlayer()
    private let videoView = UIView()

    private let controlsBar = UIView()
    private let playPauseButton = UIButton(type: .system)
    private let slider = UISlider()
    private let currentTimeLabel = UILabel()
    private let durationLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let errorLabel = UILabel()

    private var isScrubbing = false
    private var controlsHidden = false
    private var hideTimer: Timer?

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupVideoView()
        setupControls()
        setupSpinner()
        setupGestures()

        mediaPlayer.delegate = self
        mediaPlayer.drawable = videoView
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=1500")
        mediaPlayer.media = media
        mediaPlayer.play()
        spinner.startAnimating()
        scheduleAutoHide()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        hideTimer?.invalidate()
        if mediaPlayer.isPlaying { mediaPlayer.stop() }
    }

    // MARK: - Layout

    private func setupVideoView() {
        videoView.translatesAutoresizingMaskIntoConstraints = false
        videoView.backgroundColor = .black
        view.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupSpinner() {
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        errorLabel.textColor = .white
        errorLabel.font = .systemFont(ofSize: 15)
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorLabel)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)
        ])
    }

    private func setupControls() {
        controlsBar.translatesAutoresizingMaskIntoConstraints = false
        controlsBar.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        controlsBar.layer.cornerRadius = 14
        view.addSubview(controlsBar)

        playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)

        let backButton = UIButton(type: .system)
        backButton.setImage(UIImage(systemName: "gobackward.10"), for: .normal)
        backButton.tintColor = .white
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.addTarget(self, action: #selector(skipBackward), for: .touchUpInside)

        let forwardButton = UIButton(type: .system)
        forwardButton.setImage(UIImage(systemName: "goforward.10"), for: .normal)
        forwardButton.tintColor = .white
        forwardButton.translatesAutoresizingMaskIntoConstraints = false
        forwardButton.addTarget(self, action: #selector(skipForward), for: .touchUpInside)

        for label in [currentTimeLabel, durationLabel] {
            label.textColor = .white
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        currentTimeLabel.text = "0:00"
        durationLabel.text = "0:00"

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minimumTrackTintColor = UIColor(ChromeColor.googleBlue)
        slider.maximumValue = 1
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderTouchDown), for: .touchDown)
        slider.addTarget(self, action: #selector(sliderTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        controlsBar.addSubview(backButton)
        controlsBar.addSubview(playPauseButton)
        controlsBar.addSubview(forwardButton)
        controlsBar.addSubview(currentTimeLabel)
        controlsBar.addSubview(slider)
        controlsBar.addSubview(durationLabel)

        NSLayoutConstraint.activate([
            controlsBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            controlsBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            controlsBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            controlsBar.heightAnchor.constraint(equalToConstant: 84),

            backButton.leadingAnchor.constraint(equalTo: controlsBar.leadingAnchor, constant: 18),
            backButton.topAnchor.constraint(equalTo: controlsBar.topAnchor, constant: 12),
            playPauseButton.centerXAnchor.constraint(equalTo: controlsBar.centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            forwardButton.trailingAnchor.constraint(equalTo: controlsBar.trailingAnchor, constant: -18),
            forwardButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),

            currentTimeLabel.leadingAnchor.constraint(equalTo: controlsBar.leadingAnchor, constant: 14),
            currentTimeLabel.bottomAnchor.constraint(equalTo: controlsBar.bottomAnchor, constant: -14),
            durationLabel.trailingAnchor.constraint(equalTo: controlsBar.trailingAnchor, constant: -14),
            durationLabel.centerYAnchor.constraint(equalTo: currentTimeLabel.centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: currentTimeLabel.trailingAnchor, constant: 10),
            slider.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -10),
            slider.centerYAnchor.constraint(equalTo: currentTimeLabel.centerYAnchor)
        ])

        playPauseButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        playPauseButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
    }

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        view.addGestureRecognizer(tap)
    }

    // MARK: - Controls behavior

    @objc private func togglePlay() {
        if mediaPlayer.isPlaying {
            mediaPlayer.pause()
            playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        } else {
            mediaPlayer.play()
            playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        }
        scheduleAutoHide()
    }

    @objc private func skipBackward() {
        mediaPlayer.jumpBackward(10)
        scheduleAutoHide()
    }

    @objc private func skipForward() {
        mediaPlayer.jumpForward(10)
        scheduleAutoHide()
    }

    @objc private func sliderTouchDown() {
        isScrubbing = true
        hideTimer?.invalidate()
    }

    @objc private func sliderChanged() {
        let total = durationMilliseconds
        if total > 0 {
            currentTimeLabel.text = format(ms: Int(slider.value * Float(total)))
        }
    }

    @objc private func sliderTouchUp() {
        mediaPlayer.position = slider.value
        isScrubbing = false
        scheduleAutoHide()
    }

    @objc private func toggleControls() {
        controlsHidden.toggle()
        UIView.animate(withDuration: 0.25) {
            self.controlsBar.alpha = self.controlsHidden ? 0 : 1
        }
        if !controlsHidden { scheduleAutoHide() }
    }

    private func scheduleAutoHide() {
        hideTimer?.invalidate()
        controlsBar.alpha = 1
        controlsHidden = false
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self, self.mediaPlayer.isPlaying, !self.isScrubbing else { return }
            self.controlsHidden = true
            UIView.animate(withDuration: 0.25) { self.controlsBar.alpha = 0 }
        }
    }

    private var durationMilliseconds: Int {
        Int(mediaPlayer.media?.length.intValue ?? 0)
    }

    private func format(ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

extension VLCPlayerViewController: VLCMediaPlayerDelegate {
    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard !isScrubbing else { return }
        let elapsed = Int(mediaPlayer.time.intValue)
        currentTimeLabel.text = format(ms: elapsed)
        let total = durationMilliseconds
        if total > 0 {
            durationLabel.text = format(ms: total)
            slider.value = mediaPlayer.position
        }
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        switch mediaPlayer.state {
        case .buffering, .opening:
            if mediaPlayer.isPlaying { spinner.stopAnimating() } else { spinner.startAnimating() }
        case .playing:
            spinner.stopAnimating()
            errorLabel.isHidden = true
            playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        case .paused, .stopped:
            spinner.stopAnimating()
            playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        case .error:
            spinner.stopAnimating()
            errorLabel.text = "This file couldn't be played."
            errorLabel.isHidden = false
        case .ended:
            spinner.stopAnimating()
            mediaPlayer.position = 0
            mediaPlayer.pause()
            playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        default:
            break
        }
    }
}

#endif
