import AVFoundation
import Flutter

class MetronomeChannel {
    private let methodChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private var eventSink: FlutterEventSink?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let tapPlayerNode = AVAudioPlayerNode()
    private var clickBuffer: AVAudioPCMBuffer?
    private var accentBuffer: AVAudioPCMBuffer?
    private var tapBuffer: AVAudioPCMBuffer?
    private var dispatchTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.rhythmtrainer.metronome", qos: .userInteractive)
    private let audioSetupQueue = DispatchQueue(label: "com.rhythmtrainer.setup", qos: .userInitiated)
    private var isMuted = false
    private var beatIndex = 0
    private let beatsPerMeasure = 4

    init(messenger: FlutterBinaryMessenger) {
        methodChannel = FlutterMethodChannel(name: "com.rhythmtrainer.metronome/control", binaryMessenger: messenger)
        eventChannel = FlutterEventChannel(name: "com.rhythmtrainer.metronome/beats", binaryMessenger: messenger)
        audioSetupQueue.async { self.setupEngine() }
        methodChannel.setMethodCallHandler(handle)
        eventChannel.setStreamHandler(StreamHandler { sink in
            self.eventSink = sink
        } onCancel: {
            self.eventSink = nil
        })
    }

    private func setupEngine() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {}

        engine.attach(playerNode)
        engine.attach(tapPlayerNode)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        engine.connect(tapPlayerNode, to: engine.mainMixerNode, format: format)
        try? engine.start()
        // prime the audio graph to avoid noise on first playback
        if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512) {
            silence.frameLength = 512
            playerNode.play()
            playerNode.scheduleBuffer(silence)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "prepare":
            if let typedData = call.arguments as? FlutterStandardTypedData {
                audioSetupQueue.async {
                    self.prepareSound(data: typedData.data)
                    DispatchQueue.main.async { result(nil) }
                }
            } else {
                result(nil)
            }
        case "prepareAccent":
            if let typedData = call.arguments as? FlutterStandardTypedData {
                audioSetupQueue.async {
                    self.prepareAccentSound(data: typedData.data)
                    DispatchQueue.main.async { result(nil) }
                }
            } else {
                result(nil)
            }
        case "prepareTapSound":
            if let typedData = call.arguments as? FlutterStandardTypedData {
                audioSetupQueue.async {
                    self.prepareTapSound(data: typedData.data)
                    DispatchQueue.main.async { result(nil) }
                }
            } else {
                result(nil)
            }
        case "playTapSound":
            playTap()
            result(nil)
        case "clearTapSound":
            tapBuffer = nil
            result(nil)
        case "start":
            if let bpm = call.arguments as? Double {
                start(bpm: bpm)
            }
            result(nil)
        case "stop":
            stop()
            result(nil)
        case "setMuted":
            isMuted = call.arguments as? Bool ?? false
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func prepareSound(data: Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("click_native.wav")
        try? data.write(to: url)
        guard let audioFile = try? AVAudioFile(forReading: url) else { return }
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else { return }
        try? audioFile.read(into: buffer)
        clickBuffer = buffer
    }

    private func prepareTapSound(data: Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tap_native.wav")
        try? data.write(to: url)
        guard let audioFile = try? AVAudioFile(forReading: url) else { return }
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else { return }
        try? audioFile.read(into: buffer)
        tapBuffer = buffer
    }

    private func prepareAccentSound(data: Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("accent_native.wav")
        try? data.write(to: url)
        guard let audioFile = try? AVAudioFile(forReading: url) else { return }
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else { return }
        try? audioFile.read(into: buffer)
        accentBuffer = buffer
    }

    private func playTap() {
        guard let buffer = tapBuffer else { return }
        if !engine.isRunning { try? engine.start() }
        tapPlayerNode.scheduleBuffer(buffer)
        if !tapPlayerNode.isPlaying { tapPlayerNode.play() }
    }

    private func start(bpm: Double) {
        stop()
        beatIndex = 0
        let interval = 60.0 / bpm
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .microseconds(500))
        t.setEventHandler { [weak self] in
            self?.playClick()
            DispatchQueue.main.async {
                self?.eventSink?(nil)
            }
        }
        t.resume()
        dispatchTimer = t
    }

    private func playClick() {
        guard !isMuted else { return }
        let buffer = (beatIndex == 0 ? accentBuffer : nil) ?? clickBuffer
        guard let buffer = buffer else { return }
        if !engine.isRunning { try? engine.start() }
        playerNode.scheduleBuffer(buffer)
        if !playerNode.isPlaying { playerNode.play() }
        beatIndex = (beatIndex + 1) % beatsPerMeasure
    }

    private func stop() {
        dispatchTimer?.cancel()
        dispatchTimer = nil
        playerNode.stop()
    }
}

class StreamHandler: NSObject, FlutterStreamHandler {
    private let onListen: (@escaping FlutterEventSink) -> Void
    private let onCancel: () -> Void
    init(onListen: @escaping (@escaping FlutterEventSink) -> Void, onCancel: @escaping () -> Void) {
        self.onListen = onListen
        self.onCancel = onCancel
    }
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        onListen(events)
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        onCancel()
        return nil
    }
}
