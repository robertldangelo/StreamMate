import AppKit
import Foundation
import ScreenCaptureKit
import SwiftUI

struct SourceItem: Identifiable, Hashable {
    let id: String
    let title: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var tvAddress = TVAddress.hotelTVHost
    @Published var tvName = ""
    @Published var sources: [SourceItem] = []
    @Published var selectedSource = ""
    @Published var resolution = 1080
    @Published var bitrateMbps = 6
    @Published var includeAudio = true
    @Published var fillTV = true
    @Published var saveSample = false
    @Published var isCasting = false
    @Published var isBusy = false
    @Published var status = "Not connected"
    @Published var log: [String] = []

    private let port: UInt16 = 8765
    private var renderer: Renderer?
    private var displays: [String: SCDisplay] = [:]
    private var windows: [String: SCWindow] = [:]
    private let server = StreamServer()
    private let engine = CaptureEngine()
    private var monitor: Task<Void, Never>?

    init() {
        server.onLog = { [weak self] message in
            Task { @MainActor in self?.addLog(message) }
        }
        server.onViewers = { [weak self] count in
            Task { @MainActor in
                guard let self = self, self.isCasting else { return }
                self.status = count > 0 ? "Casting to \(self.tvName)" : "Waiting for the TV to connect…"
            }
        }
        engine.onError = { [weak self] message in
            Task { @MainActor in self?.addLog(message) }
        }
    }

    func addLog(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(message)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    func refreshSources() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            var items: [SourceItem] = []
            displays.removeAll()
            windows.removeAll()
            for (i, d) in content.displays.enumerated() {
                let id = "display-\(d.displayID)"
                displays[id] = d
                items.append(SourceItem(id: id, title: "Entire screen \(i + 1) (\(d.width)×\(d.height))"))
            }
            let me = Bundle.main.bundleIdentifier ?? "com.streammate.app"
            for w in content.windows {
                guard w.windowLayer == 0, w.frame.width > 200, w.frame.height > 150,
                      let app = w.owningApplication, app.bundleIdentifier != me,
                      let title = w.title, !title.isEmpty else { continue }
                let id = "window-\(w.windowID)"
                windows[id] = w
                items.append(SourceItem(id: id, title: "\(app.applicationName): \(title)"))
            }
            sources = items
            if !items.contains(where: { $0.id == selectedSource }) {
                selectedSource = items.first?.id ?? ""
            }
        } catch {
            status = "Screen Recording permission needed"
            addLog("Could not list screens and windows: \(error.localizedDescription). " +
                   "Allow StreamMate under System Settings → Privacy & Security → Screen & System Audio Recording, then reopen the app.")
        }
    }

    func findTV() async {
        guard !isCasting, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        _ = await resolveTV()
    }

    private func resolveTV() async -> (Renderer, TVAddress)? {
        status = "Looking for the TV…"
        do {
            let address = try TVAddress(tvAddress)
            let r = try await DLNA.findRenderer(address: address, previousURL: renderer?.descriptionURL)
            renderer = r
            tvName = r.name
            status = "Found \(r.name)"
            addLog("Found \(r.name) at \(r.controlURL.absoluteString)")
            return (r, address)
        } catch {
            renderer = nil
            tvName = ""
            status = "TV not found"
            addLog(error.localizedDescription)
            return nil
        }
    }

    func startCast() async {
        guard !isCasting, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        guard let (r, address) = await resolveTV() else { return }
        guard let myIP = DLNA.localIP(toward: address.host) else {
            status = "No network route to the TV"
            return
        }
        let filter: SCContentFilter
        let sourceSize: CGSize
        var isDisplay = false
        if let d = displays[selectedSource] {
            filter = SCContentFilter(display: d, excludingWindows: [])
            sourceSize = CGSize(width: d.width, height: d.height)
            isDisplay = true
        } else if let w = windows[selectedSource] {
            filter = SCContentFilter(desktopIndependentWindow: w)
            sourceSize = w.frame.size
        } else {
            status = "Choose what to cast first"
            return
        }
        let height = resolution
        let width = resolution == 1080 ? 1920 : 1280
        var sourceRect: CGRect?
        let target = 16.0 / 9.0
        let aspect = sourceSize.height > 0 ? Double(sourceSize.width / sourceSize.height) : target
        if abs(aspect - target) > 0.01 {
            if fillTV && isDisplay {
                // Crop the screen to 16:9 around its centre so the TV picture has no bars.
                if aspect < target {
                    let h = Double(sourceSize.width) / target
                    sourceRect = CGRect(x: 0, y: (Double(sourceSize.height) - h) / 2, width: Double(sourceSize.width), height: h)
                } else {
                    let w = Double(sourceSize.height) * target
                    sourceRect = CGRect(x: (Double(sourceSize.width) - w) / 2, y: 0, width: w, height: Double(sourceSize.height))
                }
            }
        }
        addLog("Stream size \(width)×\(height)" + (sourceRect != nil ? ", cropped to fill the TV" : ""))

        do {
            try server.start(port: port)
            if saveSample {
                let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("streammate_sample.ts")
                server.saveSample(to: url)
                addLog("Saving a stream sample to \(url.path)")
            }
            try await engine.start(filter: filter, width: width, height: height, fps: 30,
                                   bitrate: bitrateMbps * 1_000_000, includeAudio: includeAudio,
                                   sourceRect: sourceRect, server: server)
            isCasting = true
            status = "Starting playback on the TV…"
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let url = "http://\(myIP):\(port)/stream.ts"
            addLog("Asking the TV to play \(url)")
            try await DLNA.play(r, streamURL: url)
            startMonitor(r)
        } catch {
            addLog("Could not start: \(error.localizedDescription)")
            status = "Could not start casting"
            await teardown(stopTV: false)
        }
    }

    func stopCast() async {
        guard isCasting else { return }
        isBusy = true
        defer { isBusy = false }
        await teardown(stopTV: true)
        status = tvName.isEmpty ? "Not connected" : "Found \(tvName)"
    }

    private func teardown(stopTV: Bool) async {
        monitor?.cancel()
        monitor = nil
        isCasting = false
        if stopTV, let r = renderer { await DLNA.stop(r) }
        await engine.stop()
        server.stop()
    }

    private func startMonitor(_ r: Renderer) {
        monitor?.cancel()
        monitor = Task { [weak self] in
            var last = ""
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                guard let state = await DLNA.transportState(r) else { continue }
                if state != last {
                    last = state
                    self?.addLog("TV state: \(state)")
                }
            }
        }
    }

    /// Best-effort: tell the TV to stop when the app quits.
    func stopTVOnQuit() {
        guard isCasting, let r = renderer else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await DLNA.stop(r)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }
}
