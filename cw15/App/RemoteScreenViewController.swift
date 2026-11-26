// SPDX-License-Identifier: GPL-3.0-or-later
// 作为屏幕：本机只负责显示另一台 iPhone 上的 CarPlay 画面，并把触控回传给主机。
import UIKit
import AVFoundation

final class RemoteScreenViewController: UIViewController {

    private let client = RemoteScreenClient()
    private let renderer = RemoteScreenRenderer()
    private let audio = RemoteAudioPlayer()
    private let finder = RemoteHostFinder()

    private let videoView = UIView()
    private let overlay = UIView()
    private let addressField = UITextField()
    private let connectButton = UIButton(type: .system)
    private let scanButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private let hostStack = UIStackView()
    private let revealButton = UIButton(type: .system)
    private let muteButton = UIButton(type: .system)

    private var activeTouches: [Int: Int] = [:]
    private var lastPoints: [Int: (Double, Double)] = [:]
    private var nextFingerID = 1
    private var overlayVisible = true
    private var muted = false
    /// 查找与自动连接推迟到界面出现之后，避免还没上屏就收到回调。
    private var didStartDiscovery = false

    private static let addressKey = "cw.remote.host"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        UIApplication.shared.isIdleTimerDisabled = true
        setupVideoLayer()
        setupOverlay()
        setupRevealButton()
        bind()
        addressField.text = UserDefaults.standard.string(forKey: Self.addressKey) ?? ""
        updateStatus("正在查找局域网内的 CarWithin 主机…")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStartDiscovery else { return }
        didStartDiscovery = true
        finder.videoPort = 9888
        finder.start()
        // 已经用过的主机直接连，省一步。
        if let saved = UserDefaults.standard.string(forKey: Self.addressKey), !saved.isEmpty {
            startConnection(saved)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            client.disconnect()
            finder.stop()
            audio.stop()
        }
    }

    // MARK: 画面

    private func setupVideoLayer() {
        videoView.translatesAutoresizingMaskIntoConstraints = false
        videoView.backgroundColor = .black
        view.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        videoView.layer.addSublayer(renderer.layer)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.layer.frame = videoView.bounds
        CATransaction.commit()
    }

    // MARK: 控制条

    private func setupOverlay() {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        overlay.layer.cornerRadius = 16
        overlay.layer.cornerCurve = .continuous
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12)
        ])

        let back = UIButton(type: .system)
        back.setTitle("返回", for: .normal)
        back.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        back.addTarget(self, action: #selector(close), for: .touchUpInside)

        let title = UILabel()
        title.text = "作为屏幕接收 CarPlay"
        title.textColor = .white
        title.font = .systemFont(ofSize: 16, weight: .semibold)

        let hide = UIButton(type: .system)
        hide.setTitle("隐藏", for: .normal)
        hide.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        hide.addTarget(self, action: #selector(toggleOverlay), for: .touchUpInside)

        let header = UIStackView(arrangedSubviews: [back, title, hide])
        header.axis = .horizontal
        header.alignment = .center
        header.distribution = .equalSpacing

        addressField.placeholder = "主机地址，如 192.168.31.55:9888"
        addressField.textColor = .white
        addressField.attributedPlaceholder = NSAttributedString(string: "主机地址，如 192.168.31.55:9888",
            attributes: [.foregroundColor: UIColor.lightGray])
        addressField.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        addressField.layer.cornerRadius = 9
        addressField.layer.cornerCurve = .continuous
        addressField.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        addressField.keyboardType = .numbersAndPunctuation
        addressField.autocorrectionType = .no
        addressField.autocapitalizationType = .none
        addressField.clearButtonMode = .whileEditing
        addressField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        addressField.leftViewMode = .always
        addressField.heightAnchor.constraint(equalToConstant: 40).isActive = true

        connectButton.setTitle("连接", for: .normal)
        connectButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        connectButton.backgroundColor = UIColor.systemBlue
        connectButton.tintColor = .white
        connectButton.layer.cornerRadius = 9
        connectButton.layer.cornerCurve = .continuous
        connectButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        connectButton.widthAnchor.constraint(equalToConstant: 78).isActive = true
        connectButton.addTarget(self, action: #selector(toggleConnection), for: .touchUpInside)

        let connectRow = UIStackView(arrangedSubviews: [addressField, connectButton])
        connectRow.axis = .horizontal
        connectRow.spacing = 8

        scanButton.setTitle("自动查找局域网主机", for: .normal)
        scanButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        scanButton.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        scanButton.tintColor = .white
        scanButton.layer.cornerRadius = 9
        scanButton.layer.cornerCurve = .continuous
        scanButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        scanButton.addTarget(self, action: #selector(rescan), for: .touchUpInside)

        muteButton.setTitle("静音", for: .normal)
        muteButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        muteButton.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        muteButton.tintColor = .white
        muteButton.layer.cornerRadius = 9
        muteButton.layer.cornerCurve = .continuous
        muteButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        muteButton.addTarget(self, action: #selector(toggleMute), for: .touchUpInside)

        let actionRow = UIStackView(arrangedSubviews: [scanButton, muteButton])
        actionRow.axis = .horizontal
        actionRow.spacing = 8
        actionRow.distribution = .fillEqually

        statusLabel.textColor = .lightGray
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.numberOfLines = 2

        hintLabel.textColor = .tertiaryLabel
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.numberOfLines = 0
        hintLabel.text = "在另一台 iPhone 上启动 CarPlay，把这里显示的地址填进另一台手机的浏览器，或直接用本页连接它。画面在本机原生显示，不需要浏览器。"

        hostStack.axis = .vertical
        hostStack.spacing = 6

        let column = UIStackView(arrangedSubviews: [header, connectRow, actionRow, statusLabel, hostStack, hintLabel])
        column.axis = .vertical
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 12),
            column.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -12),
            column.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -12)
        ])
    }

    private func setupRevealButton() {
        revealButton.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        revealButton.tintColor = .white
        revealButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        revealButton.layer.cornerRadius = 18
        revealButton.translatesAutoresizingMaskIntoConstraints = false
        revealButton.alpha = 0
        revealButton.addTarget(self, action: #selector(toggleOverlay), for: .touchUpInside)
        view.addSubview(revealButton)
        NSLayoutConstraint.activate([
            revealButton.widthAnchor.constraint(equalToConstant: 36),
            revealButton.heightAnchor.constraint(equalToConstant: 36),
            revealButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            revealButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    // MARK: 绑定

    private func bind() {
        client.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .idle:
                self.updateStatus("未连接")
                self.connectButton.setTitle("连接", for: .normal)
            case .connecting:
                self.updateStatus("正在连接…")
                self.connectButton.setTitle("断开", for: .normal)
            case .waiting:
                self.updateStatus("已连上主机，等待第一帧…")
            case .playing(let width, let height):
                self.updateStatus("正在显示 \(width)×\(height)")
                self.hideOverlay(after: 2.5)
            case .failed(let reason):
                self.updateStatus("\(reason)，正在重试…")
            }
        }
        client.onLog = { [weak self] message in
            self?.updateStatus(message)
        }
        client.onFormat = { [weak self] description, width, height in
            guard let self else { return }
            if !self.renderer.configure(descriptionBase64: description, width: width, height: height) {
                self.updateStatus("无法解析主机的视频格式")
                return
            }
            self.client.requestKeyframe()
        }
        client.onFrame = { [weak self] sample, stamp, keyframe in
            self?.renderer.enqueue(avcc: sample, timestampUs: stamp, keyframe: keyframe)
        }
        client.onAudio = { [weak self] pcm, rate, channels, stream in
            self?.audio.append(pcm, sampleRate: rate, channels: channels, stream: stream)
        }
        renderer.onNeedsKeyframe = { [weak self] in
            self?.client.requestKeyframe()
        }
        audio.onLog = { [weak self] message in
            self?.updateStatus(message)
        }
        finder.onUpdate = { [weak self] hosts in
            self?.showHosts(hosts)
        }
        finder.onLog = { [weak self] message in
            self?.updateStatus(message)
        }
    }

    private func showHosts(_ hosts: [RemoteHost]) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.showHosts(hosts) }
            return
        }
        guard isViewLoaded else { return }
        hostStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for host in hosts.prefix(6) {
            let button = UIButton(type: .system)
            button.setTitle(host.display, for: .normal)
            button.titleLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            button.contentHorizontalAlignment = .leading
            button.setTitleColor(.white, for: .normal)
            button.backgroundColor = UIColor.white.withAlphaComponent(0.1)
            button.layer.cornerRadius = 8
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            button.addAction(UIAction { [weak self] _ in
                self?.addressField.text = "\(host.address):\(host.port)"
                self?.startConnection("\(host.address):\(host.port)")
            }, for: .touchUpInside)
            hostStack.addArrangedSubview(button)
        }
        if hosts.isEmpty, scanningFinished {
            let label = UILabel()
            label.text = "没有找到主机：确认两台手机在同一个 Wi-Fi，另一台已启动 CarPlay。"
            label.textColor = .systemOrange
            label.font = .systemFont(ofSize: 12)
            label.numberOfLines = 0
            hostStack.addArrangedSubview(label)
        }
    }

    private var scanningFinished = false

    // MARK: 操作

    @objc private func close() {
        client.disconnect()
        finder.stop()
        audio.stop()
        if let navigation = navigationController, navigation.viewControllers.count > 1 {
            navigation.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func toggleConnection() {
        view.endEditing(true)
        if client.isRunning {
            client.disconnect()
            updateStatus("已断开")
            return
        }
        startConnection(addressField.text ?? "")
    }

    private func startConnection(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var host = text
        var port = 9888
        if let separator = text.range(of: ":", options: .backwards),
           let parsed = Int(text[separator.upperBound...]) {
            host = String(text[..<separator.lowerBound])
            port = parsed
        }
        guard !host.isEmpty else {
            updateStatus("请先填写主机 IP，例如 192.168.31.55:9888")
            return
        }
        renderer.reset()
        audio.stop()
        UserDefaults.standard.set("\(host):\(port)", forKey: Self.addressKey)
        addressField.text = "\(host):\(port)"
        client.connect(host: host, port: port)
        connectButton.setTitle("断开", for: .normal)
    }

    @objc private func rescan() {
        updateStatus("正在自动查找…")
        scanningFinished = false
        finder.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.scanningFinished = true
            self?.showHosts([])
        }
    }

    @objc private func toggleOverlay() {
        if overlayVisible { hideOverlay(after: nil) } else { showOverlay() }
    }

    private func hideOverlay(after delay: TimeInterval?) {
        let work = { [weak self] in
            guard let self else { return }
            self.overlayVisible = false
            UIView.animate(withDuration: 0.2) {
                self.overlay.alpha = 0
                self.revealButton.alpha = 1
            }
        }
        if let delay { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) } else { work() }
    }

    private func showOverlay() {
        overlayVisible = true
        UIView.animate(withDuration: 0.2) {
            self.overlay.alpha = 1
            self.revealButton.alpha = 0
        }
    }

    @objc private func toggleMute() {
        muted.toggle()
        audio.setMuted(muted)
        muteButton.setTitle(muted ? "取消静音" : "静音", for: .normal)
    }

    private func updateStatus(_ text: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.updateStatus(text) }
            return
        }
        guard isViewLoaded else { return }
        statusLabel.text = text
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.client.updateDisplay()
        }
    }

    // MARK: 触控回传

    private func videoRect() -> CGRect {
        let bounds = videoView.bounds
        let size = renderer.videoSize
        guard size.width > 1, size.height > 1 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, lifting: true)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, lifting: true)
    }

    private func send(_ touches: Set<UITouch>, lifting: Bool = false) {
        guard client.isRunning else { return }
        let rect = videoRect()
        if lifting {
            for touch in touches { activeTouches.removeValue(forKey: touch.hash) }
        } else {
            for touch in touches {
                if activeTouches[touch.hash] == nil {
                    activeTouches[touch.hash] = nextFingerID
                    nextFingerID = nextFingerID % 255 + 1
                }
                guard let id = activeTouches[touch.hash] else { continue }
                let location = touch.location(in: videoView)
                guard rect.width > 0, rect.height > 0, rect.contains(location) else { continue }
                let x = Double((location.x - rect.minX) / rect.width)
                let y = Double((location.y - rect.minY) / rect.height)
                lastPoints[id] = (min(max(x, 0), 1), min(max(y, 0), 1))
            }
        }
        let points = activeTouches.values.compactMap { id -> [String: Any]? in
            guard let point = lastPoints[id] else { return nil }
            return ["id": id, "x": point.0, "y": point.1]
        }
        client.sendTouches(points)
        if activeTouches.isEmpty { lastPoints.removeAll() }
    }

    override var prefersStatusBarHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { [.bottom, .right] }
}
