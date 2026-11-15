import Foundation

struct Renderer {
    let name: String
    let descriptionURL: URL
    let controlURL: URL
}

struct TVAddress {
    static let hotelTVHost = "192.168.49.1"

    let host: String
    let descriptionURL: URL?

    init(_ value: String) throws {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = input.split(separator: ":", omittingEmptySubsequences: false)
        var address = in_addr()
        guard let ip = parts.first, parts.count <= 2,
              inet_pton(AF_INET, String(ip), &address) == 1 else {
            throw DLNAError.notFound("Enter the TV’s IPv4 address, optionally followed by its DLNA port.")
        }
        host = String(ip)
        if parts.count == 2 {
            guard let port = UInt16(parts[1]), port > 0 else {
                throw DLNAError.notFound("Enter a DLNA port between 1 and 65535.")
            }
            descriptionURL = URL(string: "http://\(host):\(port)/")
        } else {
            descriptionURL = nil
        }
    }
}

enum DLNAError: LocalizedError {
    case notFound(String)
    case soap(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let m): return m
        case .soap(let m): return m
        }
    }
}

private func firstGroup(_ pattern: String, _ text: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    let ns = text as NSString
    guard let m = re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
          m.numberOfRanges > 1 else { return nil }
    return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func xmlEscape(_ s: String) -> String {
    return s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

enum DLNA {
    static let avTransport = "urn:schemas-upnp-org:service:AVTransport:1"

    private final class DescriptionRedirects: NSObject, URLSessionTaskDelegate {
        let host: String

        init(host: String) { self.host = host }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, DLNA.isTVURL(url, host: host) else { return nil }
            return request
        }
    }

    private static func isTVURL(_ url: URL, host: String) -> Bool {
        (url.scheme == "http" || url.scheme == "https") && url.host == host
            && url.user == nil && url.password == nil
    }

    /// This Mac's address on the network that reaches `host`.
    static func localIP(toward host: String) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(9).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &local) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        guard got == 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var sin = local.sin_addr
        guard inet_ntop(AF_INET, &sin, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buf)
    }

    /// Searches for descriptions advertised by the TV at the entered address.
    private static func discoverLocations(host: String) -> [URL] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else { return [] }
        var interface = in_addr()
        if let local = localIP(toward: host), inet_pton(AF_INET, local, &interface) == 1 {
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &interface, socklen_t(MemoryLayout<in_addr>.size))
        }

        let searchTypes = ["urn:schemas-upnp-org:device:MediaRenderer:1", avTransport, "upnp:rootdevice"]
        for target in [host, "239.255.255.250"] {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(1900).bigEndian
            guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { continue }
            for searchType in searchTypes {
                let message = "M-SEARCH * HTTP/1.1\r\nHOST: \(target):1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\n" +
                    "ST: \(searchType)\r\n\r\n"
                let bytes = Array(message.utf8)
                _ = withUnsafePointer(to: &addr) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, bytes, bytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var found: [URL] = []
        let deadline = DispatchTime.now() + .seconds(3)
        var buf = [UInt8](repeating: 0, count: 4096)
        while DispatchTime.now() < deadline {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { continue }
            let text = String(decoding: buf[0..<n], as: UTF8.self)
            guard text.hasPrefix("HTTP/1.1 200") || text.hasPrefix("HTTP/1.0 200") else { continue }
            guard let line = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("location:") }),
                  let url = URL(string: line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)),
                  isTVURL(url, host: host), !found.contains(url) else { continue }
            found.append(url)
        }
        return found
    }

    static func findRenderer(address: TVAddress, previousURL: URL? = nil) async throws -> Renderer {
        var tried = Set<URL>()
        for url in [address.descriptionURL, previousURL].compactMap({ $0 }) {
            guard isTVURL(url, host: address.host), tried.insert(url).inserted else { continue }
            if let renderer = await readRenderer(at: url, host: address.host) { return renderer }
        }
        let locations = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: discoverLocations(host: address.host))
            }
        }
        for url in locations where !tried.contains(url) {
            tried.insert(url)
            if let renderer = await readRenderer(at: url, host: address.host) { return renderer }
        }
        if address.host == TVAddress.hotelTVHost,
           localIP(toward: address.host)?.hasPrefix("192.168.49.") == true,
           let renderer = await findHotelRenderer(host: address.host, excluding: tried) {
            return renderer
        }
        if let directURL = address.descriptionURL, let port = directURL.port {
            throw DLNAError.notFound("No DLNA renderer found at \(address.host):\(port) or through discovery. The TV may have changed ports.")
        }
        throw DLNAError.notFound("No DLNA renderer announced itself at \(address.host). Check the TV’s network or enter its address with the DLNA port.")
    }

    /// This LG has advertised its renderer on different ports in this range.
    private static func findHotelRenderer(host: String, excluding tried: Set<URL>) async -> Renderer? {
        let configuration = URLSessionConfiguration.ephemeral
        let batchSize = 20
        configuration.httpMaximumConnectionsPerHost = batchSize
        configuration.timeoutIntervalForResource = 0.5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        for firstPort in stride(from: 1000, through: 2000, by: batchSize) {
            if Task.isCancelled { return nil }
            let renderer = await withTaskGroup(of: Renderer?.self) { group -> Renderer? in
                for port in firstPort...min(firstPort + batchSize - 1, 2000) {
                    guard let url = URL(string: "http://\(host):\(port)/"), !tried.contains(url) else { continue }
                    group.addTask { await readRenderer(at: url, host: host, session: session) }
                }
                for await result in group {
                    if let result {
                        group.cancelAll()
                        return result
                    }
                }
                return nil
            }
            if let renderer { return renderer }
        }
        return nil
    }

    private static func readRenderer(at url: URL, host: String, session: URLSession = .shared) async -> Renderer? {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        guard let (data, response) = try? await session.data(for: request, delegate: DescriptionRedirects(host: host)),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = http.url, isTVURL(finalURL, host: host),
              let xml = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
              let root = xml.rootElement(), root.localName == "root" else { return nil }

        let base = root.elements(forLocalName: "URLBase", uri: root.uri).first?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = base.flatMap { URL(string: $0, relativeTo: finalURL)?.absoluteURL } ?? finalURL
        let devices = (try? root.nodes(forXPath: ".//*[local-name()='device']")) ?? []
        for case let device as XMLElement in devices {
            let deviceType = device.elements(forLocalName: "deviceType", uri: device.uri).first?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard deviceType.hasPrefix("urn:schemas-upnp-org:device:MediaRenderer:") else { continue }
            let services = (try? device.nodes(forXPath: "./*[local-name()='serviceList']/*[local-name()='service']")) ?? []
            for case let service as XMLElement in services {
                let type = service.elements(forLocalName: "serviceType", uri: service.uri).first?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard type == avTransport,
                      let control = service.elements(forLocalName: "controlURL", uri: service.uri).first?.stringValue?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !control.isEmpty,
                      let controlURL = URL(string: control, relativeTo: baseURL)?.absoluteURL,
                      isTVURL(controlURL, host: host) else { continue }
                let name = device.elements(forLocalName: "friendlyName", uri: device.uri).first?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return Renderer(name: name.isEmpty ? "TV" : name,
                                descriptionURL: finalURL, controlURL: controlURL)
            }
        }
        return nil
    }

    @discardableResult
    static func soap(_ renderer: Renderer, action: String, args: [(String, String)], timeout: TimeInterval = 20) async throws -> String {
        let body = args.map { "<\($0.0)>\(xmlEscape($0.1))</\($0.0)>" }.joined()
        let envelope = "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
            "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" " +
            "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>" +
            "<u:\(action) xmlns:u=\"\(avTransport)\">\(body)</u:\(action)></s:Body></s:Envelope>"
        var req = URLRequest(url: renderer.controlURL)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(avTransport)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        req.setValue("StreamMate/0.1 UPnP/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = Data(envelope.utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let text = String(decoding: data, as: UTF8.self)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let code = firstGroup("<errorCode>([^<]+)</errorCode>", text) ?? "\(http.statusCode)"
            let desc = firstGroup("<errorDescription>([^<]+)</errorDescription>", text) ?? ""
            throw DLNAError.soap("\(action) failed: error \(code) \(desc)")
        }
        return text
    }

    static func play(_ renderer: Renderer, streamURL: String) async throws {
        let features = "DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
        let didl = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" " +
            "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" " +
            "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">" +
            "<item id=\"0\" parentID=\"-1\" restricted=\"1\"><dc:title>StreamMate</dc:title>" +
            "<upnp:class>object.item.videoItem</upnp:class>" +
            "<res protocolInfo=\"http-get:*:video/mpeg:\(features)\">\(xmlEscape(streamURL))</res></item></DIDL-Lite>"
        _ = try? await soap(renderer, action: "Stop", args: [("InstanceID", "0")], timeout: 8)
        try await soap(renderer, action: "SetAVTransportURI", args: [
            ("InstanceID", "0"), ("CurrentURI", streamURL), ("CurrentURIMetaData", didl),
        ])
        do {
            try await soap(renderer, action: "Play", args: [("InstanceID", "0"), ("Speed", "1")])
        } catch let error as URLError where error.code == .timedOut {
            // This TV sometimes answers Play late even though playback starts.
        }
    }

    static func stop(_ renderer: Renderer) async {
        _ = try? await soap(renderer, action: "Stop", args: [("InstanceID", "0")], timeout: 5)
    }

    static func transportState(_ renderer: Renderer) async -> String? {
        guard let text = try? await soap(renderer, action: "GetTransportInfo", args: [("InstanceID", "0")], timeout: 5) else { return nil }
        return firstGroup("<CurrentTransportState[^>]*>([^<]*)</CurrentTransportState>", text)
    }
}
