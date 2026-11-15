import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stopTVOnQuit()
    }
}

@main
struct StreamMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("StreamMate") {
            ContentView()
                .environmentObject(model)
                .onAppear { appDelegate.model = model }
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("TV") {
                HStack {
                    TextField("TV IP or IP:port", text: $model.tvAddress)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .help("Enter the TV’s IP address. You can add its DLNA port if discovery fails.")
                        .disabled(model.isCasting || model.isBusy)
                    Button("Find TV") {
                        Task { await model.findTV() }
                    }
                    .disabled(model.isBusy || model.isCasting)
                    Text(model.tvName.isEmpty ? "No TV found yet" : model.tvName)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(6)
            }

            GroupBox("What to cast") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Picker("Source", selection: $model.selectedSource) {
                            ForEach(model.sources) { item in
                                Text(item.title).tag(item.id)
                            }
                        }
                        .labelsHidden()
                        Button("Refresh") {
                            Task { await model.refreshSources() }
                        }
                    }
                    HStack(spacing: 18) {
                        Picker("Resolution", selection: $model.resolution) {
                            Text("1080p").tag(1080)
                            Text("720p").tag(720)
                        }
                        .frame(width: 170)
                        Picker("Quality", selection: $model.bitrateMbps) {
                            Text("4 Mbps").tag(4)
                            Text("6 Mbps").tag(6)
                            Text("10 Mbps").tag(10)
                        }
                        .frame(width: 170)
                    }
                    Toggle("Send the Mac's sound to the TV", isOn: $model.includeAudio)
                    Toggle("Save a 20-second stream sample to Downloads (for troubleshooting)", isOn: $model.saveSample)
                }
                .padding(6)
                .disabled(model.isCasting)
            }

            HStack {
                Button(model.isCasting ? "Stop casting" : "Start casting") {
                    Task {
                        if model.isCasting {
                            await model.stopCast()
                        } else {
                            await model.startCast()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy || (!model.isCasting && model.selectedSource.isEmpty))
                Text(model.status)
                    .foregroundColor(.secondary)
                Spacer()
            }

            ScrollView {
                Text(model.log.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(height: 150)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
        }
        .padding(16)
        .frame(width: 560)
        .task {
            await model.refreshSources()
        }
    }
}
