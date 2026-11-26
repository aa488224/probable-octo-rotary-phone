import AVFoundation

/// Plays the CarWithin browser audio stream.
///
/// CarWithin sends audio on the same WebSocket as video, tagging each packet with a
/// leading type byte. The layout below was taken from its receiver page
/// (`onAudioPacket` / `drainAudio`) and `VideoOutputServer.appendAudio`:
///
///   [0]       UInt8      packet type, always 3 for audio
///   [1...8]   UInt64     capture timestamp in microseconds (big endian)
///   [9...12]  UInt32     sample rate 8000...48000 (big endian)
///   [13]      UInt8      channel count 1...2
///   [14]      UInt8      audio stream id
///   [15...]   Int16      interleaved PCM, little endian
///
/// Samples arrive already decoded (PCM16), so no AAC/Opus decoder is needed: the bytes
/// are widened to float and handed to AVAudioEngine, which resamples to the hardware
/// rate and mixes all streams (media, prompts, calls) into one output.
///
/// Packets are scheduled as a plain FIFO instead of being aligned to the video clock.
/// That keeps latency flat and avoids the drift-correcting playback-rate tricks the
/// browser page needs; the trade-off is that audio/video sync is "both stay near live"
/// rather than sample-accurate, which is fine for in-car listening.
final class AudioPlayer {

    struct Stats {
        var rate: Double = 0
        var channels: Int = 0
        var buffered: Double = 0        // seconds currently queued
        var packets: Int = 0
        var dropped: Int = 0
        var resets: Int = 0
    }

    var onStats: ((Stats) -> Void)?

    /// If the sender runs ahead of this device the FIFO only grows, so cap it and
    /// resynchronise from the newest packet instead of drifting seconds behind.
    private let maxBufferedSeconds: Double = 0.9

    private final class Stream {
        let node = AVAudioPlayerNode()
        var attached = false
        var rate: Double = 0
        var channels = 0
        var queuedFrames: Double = 0
    }

    private let engine = AVAudioEngine()
    private var streams: [Int: Stream] = [:]
    private var running = false
    private var ticker: Timer?
    private var stats = Stats()

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)

        _ = engine.mainMixerNode          // force the lazy graph so start() has a sink
        engine.prepare()
        do {
            try engine.start()
        } catch {
            return
        }
        running = true
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick(0.2)
        }
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        for (_, stream) in streams {
            stream.node.stop()
            if stream.attached { engine.detach(stream.node) }
        }
        streams.removeAll()
        engine.stop()
        running = false
        stats = Stats()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Packets

    func enqueue(_ data: Data) {
        guard data.count >= 17, data[0] == 3 else { return }
        let rate = Double(Self.bigEndian32(data, 9))
        let channels = Int(data[13])
        let streamID = Int(data[14])
        guard rate >= 8000, rate <= 48000, channels >= 1, channels <= 2 else {
            stats.dropped += 1
            return
        }
        let frames = (data.count - 15) / (2 * channels)
        guard frames >= 1, frames <= 4096 else {
            stats.dropped += 1
            return
        }

        if !running { start() }
        guard running else { return }

        let stream: Stream
        if let existing = streams[streamID] {
            stream = existing
        } else {
            let created = Stream()
            streams[streamID] = created
            stream = created
        }

        if stream.rate != rate || stream.channels != channels {
            guard connect(stream, rate: rate, channels: channels) else {
                stats.dropped += 1
                return
            }
            stream.rate = rate
            stream.channels = channels
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate,
                                         channels: AVAudioChannelCount(channels)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let planes = buffer.floatChannelData else {
            stats.dropped += 1
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for channel in 0..<channels {
                let plane = planes[channel]
                for frame in 0..<frames {
                    let offset = 15 + 2 * (frame * channels + channel)
                    let bits = UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
                    plane[frame] = Float(Int16(bitPattern: bits)) / 32768.0
                }
            }
        }

        stream.node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        stream.queuedFrames += Double(frames)
        stats.packets += 1
        stats.rate = rate
        stats.channels = channels
    }

    // MARK: - Engine graph

    private func connect(_ stream: Stream, rate: Double, channels: Int) -> Bool {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate,
                                         channels: AVAudioChannelCount(channels)) else { return false }
        if !stream.attached {
            engine.attach(stream.node)
            stream.attached = true
        }
        // A rate switch needs a new connection; drop whatever was queued for the old one.
        stream.node.stop()
        stream.queuedFrames = 0
        engine.disconnectNodeOutput(stream.node)
        engine.connect(stream.node, to: engine.mainMixerNode, format: format)
        stream.node.play()
        return true
    }

    private func tick(_ delta: Double) {
        var buffered: Double = 0
        for (_, stream) in streams {
            guard stream.rate > 0 else { continue }
            stream.queuedFrames = max(0, stream.queuedFrames - delta * stream.rate)
            let seconds = stream.queuedFrames / stream.rate
            if seconds > maxBufferedSeconds {
                stream.node.stop()
                stream.node.play()
                stream.queuedFrames = 0
                stats.resets += 1
                continue
            }
            buffered = max(buffered, seconds)
        }
        stats.buffered = buffered
        onStats?(stats)
    }

    private static func bigEndian32(_ data: Data, _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value = (value << 8) | UInt32(data[offset + index])
        }
        return value
    }
}
