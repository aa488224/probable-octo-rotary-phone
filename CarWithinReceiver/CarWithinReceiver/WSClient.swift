import Foundation
import UIKit

/// Minimal CarWithin browser-protocol client.
/// Speaks the `webcodecs` dialect so the sender emits raw AVCC H.264 samples
/// (1 byte keyframe flag + 8 byte BE microsecond timestamp + NAL data),
/// which H264Renderer feeds into AVSampleBufferDisplayLayer.
final class WSClient: NSObject, URLSessionWebSocketDelegate {

    enum State: String {
        case idle, connecting, waiting, playing, error
    }

    var onState: ((State, String) -> Void)?
    var onFormat: ((String, Int, Int) -> Void)?   // description(base64), width, height
    var onFrame: ((Data, UInt64, Bool) -> Void)?  // avcc sample, timestampUs, keyframe
    var onAudio: ((Data) -> Void)?                // raw audio packet, leading byte 3
    var onAudioAvailable: ((Bool) -> Void)?       // sender's browser audio switch

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var host: String = ""
    private var port: Int = 9888
    private var viewerID = UUID().uuidString.lowercased()
    private var receiveLoopRunning = false
    private var pingTimer: Timer?
    private var retryTimer: Timer?
    private var manualStop = false

    func connect(host: String, port: Int) {
        disconnect(startRetry: false)
        self.host = host
        self.port = port
        self.manualStop = false
        // A9 (iPhone 6s Plus) has no HEVC hardware decoder -> force H.264 on the sender.
        start()
    }

    private func start() {
        onState?(.connecting, "Connecting…")
        let urlString = "ws://\(host):\(port)/stream"
        guard let url = URL(string: urlString) else {
            onState?(.error, "Bad address"); return
        }
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        task = session.webSocketTask(with: url)
        task?.resume()
        if !receiveLoopRunning {
            receiveLoopRunning = true
            receiveNext()
        }
        startPing()
    }

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sendJSON(["type": "ping", "t0": Int64(Date().timeIntervalSince1970 * 1_000_000)])
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func ready() {
        // audioClock:true makes the sender treat this client as audio capable. The
        // receiver page sends `!!AudioContextClass`, i.e. true whenever it can play
        // sound -- which is exactly our case now that AVAudioEngine is in the app.
        sendJSON([
            "type": "ready",
            "decoder": "webcodecs",
            "viewer": viewerID,
            "audioClock": true
        ])
        let w = Int(UIScreen.main.bounds.width * UIScreen.main.scale)
        let h = Int(UIScreen.main.bounds.height * UIScreen.main.scale)
        sendJSON([
            "type": "display",
            "w": w, "h": h,
            "dpr": UIScreen.main.scale,
            "sw": w, "sh": h,
            "hz": 60,
            "h265": false,          // critical: A9 cannot hardware-decode HEVC
            "fullscreen": true,
            "ua": "CarWithinReceiver/1.0 (iOS)"
        ])
        onState?(.waiting, "Connected, waiting for video…")
        enableAudio()
    }

    /// Ask the sender to start forwarding PCM. The server keeps audio off until a client
    /// that advertised `audioClock` explicitly enables it, and it also waits for the
    /// first keyframe, so this is safe to repeat.
    func enableAudio() {
        sendJSON(["type": "audio", "enabled": true])
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleText(text)
                case .data(let data):
                    self.handleBinary(data)
                @unknown default:
                    break
                }
                self.receiveNext()
            case .failure:
                self.receiveLoopRunning = false
                if !self.manualStop { self.scheduleRetry("Connection lost") }
            }
        }
    }

    private func handleText(_ text: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "hello":
            // `audio` mirrors the sender's "browser audio" switch; without it the server
            // never forwards PCM no matter what we ask for.
            onAudioAvailable?(obj["audio"] as? Bool == true)
            ready()
        case "status":
            if let msg = obj["text"] as? String { onState?(.waiting, msg) }
        case "format":
            guard let desc = obj["description"] as? String,
                  let w = obj["width"] as? Int,
                  let h = obj["height"] as? Int else { return }
            onFormat?(desc, w, h)
        default:
            break
        }
    }

    private func handleBinary(_ data: Data) {
        guard let first = data.first else { return }
        // CarWithin multiplexes audio onto the video socket: a leading 3 means a PCM
        // packet (see AudioPlayer for the layout), anything else is an H.264 sample.
        if first == 3 {
            onAudio?(data)
            return
        }
        guard data.count >= 9 else { return }
        let keyframe = first == 1
        // Built byte by byte: a single eight-term shift/or expression makes the type
        // checker give up ("unable to type-check in reasonable time").
        var ts: UInt64 = 0
        for index in 1...8 {
            ts = (ts << 8) | UInt64(data[index])
        }
        let sample = data.subdata(in: 9..<data.count)
        onFrame?(sample, ts, keyframe)
    }

    /// Send normalized touch points (0...1) back to CarPlay.
    func sendTouches(_ points: [[String: Any]]) {
        sendJSON(["type": "touches", "points": points])
    }

    func requestKeyframe() {
        sendJSON(["type": "keyframe", "reason": "Receiver needs a keyframe"])
    }

    private func scheduleRetry(_ reason: String) {
        onState?(.error, "\(reason) — retrying…")
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            guard let self = self, !self.manualStop else { return }
            self.start()
        }
    }

    func disconnect(startRetry: Bool = true) {
        manualStop = !startRetry
        pingTimer?.invalidate(); pingTimer = nil
        retryTimer?.invalidate(); retryTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        receiveLoopRunning = false
    }

    deinit { disconnect(startRetry: false) }
}
