import Foundation
import Network

/// Tiny HTTP server that hands the live MPEG-TS stream to the TV.
final class StreamServer {
    private final class Client {
        let connection: NWConnection
        var request = Data()
        var streaming = false
        var started = false
        var pending = 0
        init(_ c: NWConnection) { connection = c }
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "streammate.server")
    private var clients: [ObjectIdentifier: Client] = [:]

    private var debugHandle: FileHandle?
    private var debugBytes = 0
    private var debugStarted = false

    var onNeedKeyframe: (() -> Void)?
    var onLog: ((String) -> Void)?
    var onViewers: ((Int) -> Void)?

    private let responseHeader =
        "HTTP/1.1 200 OK\r\n" +
        "Content-Type: video/mpeg\r\n" +
        "Connection: close\r\n" +
        "Cache-Control: no-cache\r\n" +
        "transferMode.dlna.org: Streaming\r\n" +
        "contentFeatures.dlna.org: DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000\r\n" +
        "\r\n"

    func start(port: UInt16) throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "StreamMate", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad port"])
        }
        let l = try NWListener(using: params, on: nwPort)
        l.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.onLog?("Server failed: \(error.localizedDescription)")
            }
        }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async {
            for c in self.clients.values { c.connection.cancel() }
            self.clients.removeAll()
            try? self.debugHandle?.close()
            self.debugHandle = nil
        }
    }

    /// Saves roughly the first 20 seconds of the stream to a file, for troubleshooting.
    func saveSample(to url: URL) {
        queue.async {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            self.debugHandle = try? FileHandle(forWritingTo: url)
            self.debugBytes = 0
            self.debugStarted = false
        }
    }

    /// Sends stream data to every connected viewer. A viewer starts at a keyframe.
    func broadcast(_ bytes: [UInt8], startsWithKeyframe: Bool) {
        let data = Data(bytes)
        queue.async {
            if let h = self.debugHandle {
                if startsWithKeyframe { self.debugStarted = true }
                if self.debugStarted {
                    h.write(data)
                    self.debugBytes += data.count
                    if self.debugBytes > 20_000_000 {
                        try? h.close()
                        self.debugHandle = nil
                        self.onLog?("Saved stream sample.")
                    }
                }
            }
            for (id, c) in self.clients where c.streaming {
                if !c.started {
                    if !startsWithKeyframe { continue }
                    c.started = true
                }
                if c.pending > 16_000_000 {
                    self.onLog?("TV is not keeping up with the stream; dropping the connection.")
                    self.drop(id)
                    continue
                }
                c.pending += data.count
                c.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    self?.queue.async {
                        c.pending -= data.count
                        if error != nil { self?.drop(id) }
                    }
                })
            }
        }
    }

    private func accept(_ conn: NWConnection) {
        let c = Client(conn)
        let id = ObjectIdentifier(c)
        clients[id] = c
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.drop(id) }
            default:
                break
            }
        }
        conn.start(queue: queue)
        read(c, id)
    }

    private func read(_ c: Client, _ id: ObjectIdentifier) {
        c.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let d = data, !c.streaming {
                c.request.append(d)
                if c.request.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.handleRequest(c, id)
                } else if c.request.count > 16384 {
                    self.drop(id)
                    return
                }
            }
            if isComplete || error != nil {
                self.drop(id)
                return
            }
            self.read(c, id)
        }
    }

    private func handleRequest(_ c: Client, _ id: ObjectIdentifier) {
        let text = String(decoding: c.request, as: UTF8.self)
        let line = text.components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : ""
        onLog?("TV request: \(method) \(path)")
        guard path.hasPrefix("/stream.ts") else {
            let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            c.connection.send(content: Data(notFound.utf8), completion: .contentProcessed { [weak self] _ in
                self?.queue.async { self?.drop(id) }
            })
            return
        }
        if method == "HEAD" {
            c.connection.send(content: Data(responseHeader.utf8), completion: .contentProcessed { [weak self] _ in
                self?.queue.async { self?.drop(id) }
            })
            return
        }
        c.connection.send(content: Data(responseHeader.utf8), completion: .contentProcessed { _ in })
        c.streaming = true
        onViewers?(clients.values.filter { $0.streaming }.count)
        onNeedKeyframe?()
    }

    private func drop(_ id: ObjectIdentifier) {
        guard let c = clients.removeValue(forKey: id) else { return }
        c.connection.cancel()
        if c.streaming {
            onViewers?(clients.values.filter { $0.streaming }.count)
        }
    }
}
