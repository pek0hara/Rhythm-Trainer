import AVFoundation
import Flutter

class MetronomeChannel {
    private let methodChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private var eventSink: FlutterEventSink?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var clickBuffer: AVAudioPCMBuffer?
    private var dispatchTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.rhythmtrainer.metronome", qos: .userInteractive)
    private let audioSetupQueue = DispatchQueue(label: "com.rhythmtrainer.setup", qos: .userInitiated)
    private var isMuted = false

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
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {}

        engine.attach(playerNode)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        try? engine.start()
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

    private func start(bpm: Double) {
        stop()
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
        guard !isMuted, let buffer = clickBuffer else { return }
        if !engine.isRunning { try? engine.start() }
        playerNode.scheduleBuffer(buffer)
        if !playerNode.isPlaying { playerNode.play() }
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
