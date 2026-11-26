// SPDX-License-Identifier: GPL-3.0-or-later
// 远端伴音：把 WebSocket 收到的 PCM16LE 直接推到 AVAudioEngine 播放。
import Foundation
import AVFoundation

final class RemoteAudioPlayer {

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "carwithin.remote.audio")
    private var players: [Int: AVAudioPlayerNode] = [:]
    private var formats: [Int: AVAudioFormat] = [:]
    private var pendingFrames: [Int: Int] = [:]
    private var running = false
    private var silent = false

    var onLog: ((String) -> Void)?

    func setMuted(_ muted: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.silent = muted
            self.engine.mainMixerNode.outputVolume = muted ? 0 : 1
        }
    }

    func append(_ pcm: Data, sampleRate: UInt32, channels: Int, stream: Int) {
        guard !pcm.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            guard self.startIfNeeded(sampleRate: sampleRate, channels: channels, stream: stream) else { return }
            guard let format = self.formats[stream], let player = self.players[stream] else { return }
            let bytesPerFrame = 2 * channels
            let frames = pcm.count / bytesPerFrame
            guard frames > 0 else { return }
            // 积压超过 1.2 秒就丢掉旧队列，让声音追上画面。
            let backlog = self.pendingFrames[stream] ?? 0
            if backlog > Int(format.sampleRate * 1.2) {
                player.stop()
                self.pendingFrames[stream] = 0
                player.play()
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let destination = buffer.int16ChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            pcm.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                destination.update(from: base.assumingMemoryBound(to: Int16.self), count: frames * channels)
            }
            self.pendingFrames[stream, default: 0] += frames
            player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
                guard let self else { return }
                self.queue.async {
                    self.pendingFrames[stream] = max(0, (self.pendingFrames[stream] ?? 0) - frames)
                }
            }
            if !player.isPlaying { player.play() }
        }
    }

    private func startIfNeeded(sampleRate: UInt32, channels: Int, stream: Int) -> Bool {
        if players[stream] != nil, let format = formats[stream],
           format.sampleRate == Double(sampleRate), format.channelCount == AVAudioChannelCount(channels) {
            if !running { return startEngine() }
            return true
        }
        players[stream]?.stop()
        if let node = players[stream] {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate),
                                         channels: AVAudioChannelCount(channels), interleaved: true) else { return false }
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        players[stream] = node
        formats[stream] = format
        pendingFrames[stream] = 0
        onLog?("伴音 \(Int(sampleRate)) Hz / \(channels) 声道")
        if !running { return startEngine() }
        node.play()
        return true
    }

    private func startEngine() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            engine.prepare()
            try engine.start()
            engine.mainMixerNode.outputVolume = silent ? 0 : 1
            running = true
            players.values.forEach { $0.play() }
            return true
        } catch {
            onLog?("伴音启动失败：\(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.players.values.forEach { $0.stop() }
            for (stream, node) in self.players {
                self.engine.disconnectNodeOutput(node)
                self.engine.detach(node)
                self.pendingFrames[stream] = 0
            }
            self.players.removeAll()
            self.formats.removeAll()
            if self.running { self.engine.stop() }
            self.running = false
        }
    }
}
