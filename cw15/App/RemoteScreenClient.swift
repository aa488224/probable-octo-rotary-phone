// SPDX-License-Identifier: GPL-3.0-or-later
// 屏幕接收端：连接另一台 iPhone 上的 CarWithin，用 WebSocket 取回 H.264 画面与 PCM 伴音。
// 协议与浏览器接收页的 WebCodecs 通道一致：文本 JSON 控制，二进制首字节区分音视频。
import Foundation
import UIKit

final class RemoteScreenClient: NSObject, URLSessionWebSocketDelegate {

    enum State: Equatable {
        case idle
        case connecting
        case waiting
        case playing(width: Int, height: Int)
        case failed(String)
    }

    /// 视频格式（base64 avcC、宽、高）。
    var onFormat: ((String, Int, Int) -> Void)?
    /// 一帧 AVCC 样本（NAL 长度前缀），微秒时间戳，是否关键帧。
    var onFrame: ((Data, UInt64, Bool) -> Void)?
    /// PCM16LE 交错样本、采样率、声道数、CarPlay 流编号。
    var onAudio: ((Data, UInt32, Int, Int) -> Void)?
    var onState: ((State) -> Void)?
    var onLog: ((String) -> Void)?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var host = ""
    private var port = 9888
    private var running = false
    private var receiving = false
    private var pingTimer: Timer?
    private var retryTimer: Timer?
    private var attempts = 0
    private var lastDisplay: (Int, Int)?
    private let viewerID = UUID().uuidString.lowercased()

    var isRunning: Bool { running }
    var address: String { "\(host):\(port)" }

    func connect(host: String, port: Int) {
        stopQuietly()
        self.host = host
        self.port = port
        running = true
        attempts = 0
        open()
    }

    /// 用户主动断开（不再自动重连）。
    func disconnect() {
        running = false
        stopQuietly()
        onState?(.idle)
    }

    func requestKeyframe() {
        send(["type": "keyframe", "reason": "CarWithin 屏幕需要关键帧"])
        onLog?("已请求关键帧")
    }

    func sendTouches(_ points: [[String: Any]]) {
        send(["type": "touches", "points": points])
    }

    func press(_ name: String) {
        send(["type": "control", "name": name])
    }

    /// 上报本机屏幕尺寸，让主机按这块屏幕出画面。
    func updateDisplay() {
        let bounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        if let lastDisplay, lastDisplay == (width, height) { return }
        lastDisplay = (width, height)
        send(["type": "display", "w": width, "h": height, "dpr": Double(scale),
              "sw": width, "sh": height, "hz": 60, "h265": false, "fullscreen": true,
              "ua": "CarWithin/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (iOS)"])
        onLog?("已上报屏幕 \(width)×\(height)")
    }

    // MARK: 连接

    private func open() {
        guard running else { return }
        guard (1...65535).contains(port), !host.isEmpty,
              let url = URL(string: "ws://\(host):\(port)/stream") else {
            onState?(.failed("地址无效")); running = false; return
        }
        onState?(.connecting)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
        if !receiving { receiving = true; receiveNext() }
        startPing()
    }

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.send(["type": "ping", "t0": Double(Int(Date().timeIntervalSince1970 * 1_000_000))])
        }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8),
              let task else { return }
        task.send(.string(text)) { _ in }
    }

    private func sendReady() {
        send(["type": "ready", "decoder": "webcodecs", "viewer": viewerID, "audioClock": true])
        updateDisplay()
        send(["type": "audio", "enabled": true])
        onState?(.waiting)
    }

    private func receiveNext() {
        guard let task else { receiving = false; return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self.handleText(text)
                case .data(let data): self.handleBinary(data)
                @unknown default: break
                }
                self.receiveNext()
            case .failure:
                self.receiving = false
                self.handleDrop("连接中断")
            }
        }
    }

    private func handleDrop(_ reason: String) {
        guard running else { return }
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        session?.invalidateAndCancel(); session = nil
        receiving = false
        attempts += 1
        onState?(.failed(reason))
        retryTimer?.invalidate()
        let delay = min(4.0, 1.0 + Double(attempts) * 0.5)
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.running else { return }
            self.open()
        }
    }

    private func stopQuietly() {
        pingTimer?.invalidate(); pingTimer = nil
        retryTimer?.invalidate(); retryTimer = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        session?.invalidateAndCancel(); session = nil
        receiving = false
        lastDisplay = nil
    }

    // MARK: 协议

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onLog?("已连接 \(address)")
        attempts = 0
        sendReady()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        handleDrop("主机已断开")
    }

    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "status":
            if let message = object["text"] as? String { onLog?(message) }
        case "format":
            guard let description = object["description"] as? String,
                  let width = (object["width"] as? NSNumber)?.intValue,
                  let height = (object["height"] as? NSNumber)?.intValue else {
                onLog?("主机未提供 WebCodecs 视频格式")
                return
            }
            onLog?("视频格式 \(width)×\(height) \(object["codec"] as? String ?? "")")
            onFormat?(description, width, height)
            onState?(.playing(width: width, height: height))
        default:
            break
        }
    }

    private func handleBinary(_ data: Data) {
        // 用裸指针按偏移读，避免 Data 下标越界；格式不合法的包直接丢，不再有机会崩。
        data.withUnsafeBytes { raw in
            let count = raw.count
            guard count >= 10, let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let kind = base[0]
            if kind == 3 {
                guard count >= 16 else { return }
                let sampleRate = UInt32(base[9]) << 24 | UInt32(base[10]) << 16 | UInt32(base[11]) << 8 | UInt32(base[12])
                let channels = Int(base[13])
                let stream = Int(base[14])
                guard sampleRate >= 8000, sampleRate <= 96_000, (1...2).contains(channels), count > 15 else { return }
                let pcm = Data(bytes: base + 15, count: count - 15)
                onAudio?(pcm, sampleRate, channels, stream)
                return
            }
            var stamp: UInt64 = 0
            for offset in 1...8 { stamp = stamp << 8 | UInt64(base[offset]) }
            guard count > 9 else { return }
            onFrame?(Data(bytes: base + 9, count: count - 9), stamp, kind == 1)
        }
    }

    deinit { stopQuietly() }
}
