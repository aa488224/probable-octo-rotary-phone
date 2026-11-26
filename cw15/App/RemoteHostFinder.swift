// SPDX-License-Identifier: GPL-3.0-or-later
// 局域网里找 CarWithin 主机：先听 Bonjour，再扫同网段的视频端口，两条路互补。
import Foundation
import Network

struct RemoteHost: Equatable {
    var name: String
    let address: String
    var port: Int
    var display: String { "\(name) · \(address):\(port)" }
}

final class RemoteHostFinder: NSObject {

    var onUpdate: (([RemoteHost]) -> Void)?
    var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "carwithin.remote.discovery")
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var hosts: [String: RemoteHost] = [:]
    private var scanning = false

    /// 主机网页/视频端口，CarWithin 默认 9888。
    var videoPort: UInt16 = 9888

    func start() {
        stop()
        hosts.removeAll()
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: ReceiverConfiguration.discoveryType, inDomain: "local.")
        self.browser = browser
        scanSubnet()
    }

    func stop() {
        browser?.stop(); browser = nil
        services.forEach { $0.stop() }
        services.removeAll()
        scanning = false
    }

    private func publish() {
        let list = hosts.values.sorted { $0.address < $1.address }
        onUpdate?(list)
    }

    private func add(name: String, address: String, port: Int) {
        guard !address.isEmpty, !address.hasPrefix("127.") else { return }
        var host = hosts[address] ?? RemoteHost(name: name, address: address, port: port)
        if name != address { host.name = name }
        host.port = port
        hosts[address] = host
        publish()
    }

    // MARK: 同网段扫描

    private func scanSubnet() {
        guard !scanning else { return }
        guard let (local, mask) = Self.localIPv4() else {
            onLog?("未取得 Wi-Fi 地址，跳过网段扫描")
            return
        }
        scanning = true
        let parts = local.split(separator: ".").compactMap { Int($0) }
        let maskParts = mask.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, maskParts.count == 4 else { scanning = false; return }
        onLog?("扫描 \(parts[0]).\(parts[1]).\(parts[2]).1-254 的 \(videoPort) 端口")

        var pending: [String] = []
        for last in 1...254 where "\(parts[0]).\(parts[1]).\(parts[2]).\(last)" != local {
            pending.append("\(parts[0]).\(parts[1]).\(parts[2]).\(last)")
        }
        var index = 0
        let batch = 40
        func nextBatch() {
            guard scanning, index < pending.count else {
                if scanning { scanning = false; onLog?("网段扫描结束，共 \(hosts.count) 台") }
                return
            }
            let slice = pending[index..<min(index + batch, pending.count)]
            index += slice.count
            let group = DispatchGroup()
            for address in slice {
                group.enter()
                probe(address) { [weak self] reachable in
                    if reachable { self?.add(name: address, address: address, port: Int(self?.videoPort ?? 9888)) }
                    group.leave()
                }
            }
            group.notify(queue: queue) { nextBatch() }
        }
        queue.async(execute: nextBatch)
    }

    private func probe(_ address: String, completion: @escaping (Bool) -> Void) {
        guard let port = NWEndpoint.Port(rawValue: videoPort) else { completion(false); return }
        let connection = NWConnection(host: NWEndpoint.Host(address), port: port, using: .tcp)
        var finished = false
        func finish(_ reachable: Bool) {
            guard !finished else { return }
            finished = true
            connection.cancel()
            completion(reachable)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .failed, .cancelled, .waiting: finish(false)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 0.7) { finish(false) }
    }

    private static func localIPv4() -> (String, String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var wifi: (String, String)?
        var fallback: (String, String)?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard let mask = interface.ifa_netmask else { continue }
            let name = String(cString: interface.ifa_name)
            guard name != "lo0", let host = string(from: address), let netmask = string(from: mask) else { continue }
            if name == "en0" { wifi = (host, netmask) } else if fallback == nil { fallback = (host, netmask) }
        }
        return wifi ?? fallback
    }

    private static func string(from address: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(address.pointee.sa_len)
        guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
    }
}

extension RemoteHostFinder: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        onLog?("Bonjour 搜索失败，改用网段扫描")
    }
}

extension RemoteHostFinder: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        var address: String?
        for data in sender.addresses ?? [] {
            address = data.withUnsafeBytes { raw -> String? in
                guard let base = raw.baseAddress else { return nil }
                let family = base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
                guard family == UInt8(AF_INET) else { return nil }
                return RemoteHostFinder.string(from: base.assumingMemoryBound(to: sockaddr.self))
            }
            if address != nil { break }
        }
        guard let address else { return }
        add(name: sender.name, address: address, port: Int(videoPort))
    }
}
