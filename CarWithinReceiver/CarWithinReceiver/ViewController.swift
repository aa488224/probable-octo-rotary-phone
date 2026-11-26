import UIKit
import AVFoundation

final class ViewController: UIViewController {

    private let renderer = H264Renderer()
    private let client = WSClient()

    private let addressField = UITextField()
    private let connectButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let infoLabel = UILabel()
    private let videoContainer = UIView()
    private let touchLayerView = UIView()
    private let controlPanel = UIView()

    private var activeTouches: [Int: Int] = [:]  // UITouch hash -> finger id
    private var nextFingerID: Int = 1

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        UIApplication.shared.isIdleTimerDisabled = true  // stay awake while driving

        setupVideo()
        setupControls()
        setupTouches()

        client.onState = { [weak self] state, text in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.statusLabel.text = text
                self.statusLabel.textColor = state == .playing ? .systemGreen :
                                             state == .error ? .systemOrange : .lightGray
                self.connectButton.setTitle(state == .idle || state == .error ? "Connect" : "Stop", for: .normal)
            }
        }
        client.onFormat = { [weak self] desc, w, h in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if self.renderer.configure(descriptionBase64: desc, width: w, height: h) {
                    self.client.onState?(.playing, "CarPlay \(w)×\(h) · H.264")
                    self.infoLabel.text = "\(w)×\(h) · H.264"
                    self.client.requestKeyframe()
                } else {
                    self.statusLabel.text = "Cannot parse video format"
                    self.statusLabel.textColor = .systemRed
                }
            }
        }
        client.onFrame = { [weak self] sample, ts, key in
            self?.renderer.enqueue(avcc: sample, timestampUs: ts, keyframe: key)
        }

        // Pre-fill last used address.
        addressField.text = UserDefaults.standard.string(forKey: "cw.host") ?? "192.168.1.1:9888"
    }

    private func setupVideo() {
        videoContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoContainer)
        NSLayoutConstraint.activate([
            videoContainer.topAnchor.constraint(equalTo: view.topAnchor),
            videoContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        renderer.layer.frame = view.bounds
        renderer.layer.videoGravity = .resizeAspect
        videoContainer.layer.addSublayer(renderer.layer)
    }

    private func setupControls() {
        let panel = controlPanel
        panel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12)
        ])

        addressField.placeholder = "IP:port  e.g. 192.168.1.23:9888"
        addressField.textColor = .white
        addressField.attributedPlaceholder = NSAttributedString(
            string: addressField.placeholder ?? "", attributes: [.foregroundColor: UIColor.lightGray])
        addressField.keyboardType = .numbersAndPunctuation
        addressField.autocorrectionType = .no
        addressField.autocapitalizationType = .none
        addressField.borderStyle = .roundedRect
        addressField.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        addressField.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(addressField)

        connectButton.setTitle("Connect", for: .normal)
        connectButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        connectButton.addTarget(self, action: #selector(toggleConnect), for: .touchUpInside)
        panel.addSubview(connectButton)

        statusLabel.text = "Not connected"
        statusLabel.textColor = .lightGray
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(statusLabel)

        infoLabel.text = ""
        infoLabel.textColor = .systemGray
        infoLabel.font = .systemFont(ofSize: 12)
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(infoLabel)

        NSLayoutConstraint.activate([
            addressField.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            addressField.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            addressField.trailingAnchor.constraint(equalTo: connectButton.leadingAnchor, constant: -8),
            connectButton.centerYAnchor.constraint(equalTo: addressField.centerYAnchor),
            connectButton.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            connectButton.widthAnchor.constraint(equalToConstant: 70),
            statusLabel.topAnchor.constraint(equalTo: addressField.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            infoLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 2),
            infoLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            infoLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            infoLabel.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8)
        ])

        // Tap anywhere on the video area hides/shows the control panel.
        let hideTap = UITapGestureRecognizer(target: self, action: #selector(togglePanel))
        hideTap.numberOfTapsRequired = 1
        videoContainer.addGestureRecognizer(hideTap)
    }

    private func setupTouches() {
        touchLayerView.translatesAutoresizingMaskIntoConstraints = false
        touchLayerView.backgroundColor = .clear
        touchLayerView.isMultipleTouchEnabled = true
        view.addSubview(touchLayerView)
        NSLayoutConstraint.activate([
            touchLayerView.topAnchor.constraint(equalTo: view.topAnchor),
            touchLayerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            touchLayerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            touchLayerView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    @objc private func toggleConnect() {
        view.endEditing(true)
        let title = connectButton.title(for: .normal) ?? ""
        if title == "Stop" {
            client.disconnect(startRetry: false)
            renderer.reset()
            statusLabel.text = "Not connected"
            statusLabel.textColor = .lightGray
            infoLabel.text = ""
            connectButton.setTitle("Connect", for: .normal)
        } else {
            let raw = (addressField.text ?? "").trimmingCharacters(in: .whitespaces)
            var host = raw
            var port = 9888
            if let range = raw.range(of: ":", options: .backwards),
               let p = Int(raw[range.upperBound...]) {
                host = String(raw[..<range.lowerBound])
                port = p
            }
            guard !host.isEmpty else {
                statusLabel.text = "Enter the IP shown in CarWithin"
                statusLabel.textColor = .systemRed
                return
            }
            UserDefaults.standard.set("\(host):\(port)", forKey: "cw.host")
            connectButton.setTitle("Stop", for: .normal)
            renderer.reset()
            client.connect(host: host, port: port)
        }
    }

    @objc private func togglePanel() {
        UIView.animate(withDuration: 0.2) { self.controlPanel.isHidden.toggle() }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        sendPoints(touches)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        sendPoints(touches)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        sendPoints(touches, lifting: true)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        sendPoints(touches, lifting: true)
    }

    private func sendPoints(_ touches: Set<UITouch>, lifting: Bool = false) {
        var points: [[String: Any]] = []
        for t in touches {
            let key = t.hash
            let id: Int
            if lifting {
                guard let existing = activeTouches.removeValue(forKey: key) else { continue }
                id = existing
            } else {
                if let existing = activeTouches[key] { id = existing } else {
                    id = nextFingerID; nextFingerID = (nextFingerID + 1) & 255
                    activeTouches[key] = id
                }
                let p = t.location(in: videoContainer)
                let x = max(0, min(1, p.x / view.bounds.width))
                let y = max(0, min(1, p.y / view.bounds.height))
                points.append(["id": id, "x": x, "y": y])
            }
        }
        if lifting || !points.isEmpty {
            client.sendTouches(points)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        renderer.layer.frame = videoContainer.bounds
    }

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscapeRight }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { [.bottom, .right] }
}
