import GehennaCore
import SwiftUI

struct ContentView: View {
  var body: some View {
    TabView {
      StatusView()
        .tabItem { Label("Status", systemImage: "waveform.path") }
      KeymapView()
        .tabItem { Label("Keymap", systemImage: "keyboard") }
      MacrosView()
        .tabItem { Label("Macros", systemImage: "bolt.horizontal") }
    }
    .frame(minWidth: 760, minHeight: 520)
  }
}

struct StatusView: View {
  @State private var status = "Idle"
  @State private var isRunning = false
  @State private var logText = "Log output will appear here."
  @State private var timer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      Divider()
      controls
      statusRow
      logViewer
      Spacer()
    }
    .padding(24)
    .onAppear {
      refreshStatus()
      refreshLog()
    }
    .onReceive(timer) { _ in
      refreshStatus()
      refreshLog()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Gehenna")
        .font(.largeTitle)
        .bold()
      Text("Razer Tartarus Pro controller for macOS.")
        .foregroundStyle(.secondary)
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Daemon Control")
        .font(.title2)
        .bold()
      HStack(spacing: 12) {
        Button("Start Seized Daemon") {
          runSeizedDaemon()
        }
        Button("Stop Daemon") {
          stopDaemon()
        }
        Button("Refresh Status") {
          refreshStatus()
          refreshLog()
        }
      }
    }
  }

  private var statusRow: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(isRunning ? Color.green : Color.red)
        .frame(width: 10, height: 10)
      Text("Status: \(status)")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private var logViewer: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Daemon Log")
        .font(.headline)
      ScrollView {
        Text(logText)
          .font(.system(.footnote, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .background(Color(.textBackgroundColor))
          .cornerRadius(8)
      }
    }
  }

  private func runSeizedDaemon() {
    let scriptURL = repoRoot().appendingPathComponent("scripts/gehenna-seize.sh")
    let process = Process()
    process.executableURL = scriptURL

    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    do {
      try process.run()
      status = "Launching daemon..."
      Task {
        let data = output.fileHandleForReading.readDataToEndOfFile()
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
          status = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
          status = "Daemon started."
        }
        refreshStatus()
        refreshLog()
      }
    } catch {
      status = "Failed to start daemon: \(error.localizedDescription)"
    }
  }

  private func stopDaemon() {
    let scriptURL = repoRoot().appendingPathComponent("scripts/gehenna-stop.sh")
    let process = Process()
    process.executableURL = scriptURL
    do {
      try process.run()
      status = "Stop signal sent."
      refreshStatus()
    } catch {
      status = "Failed to stop daemon: \(error.localizedDescription)"
    }
  }

  private func refreshStatus() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", "GehennaDaemon"]
    let output = Pipe()
    process.standardOutput = output
    do {
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      let text = String(data: data, encoding: .utf8) ?? ""
      isRunning = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      status = isRunning ? "Running" : "Stopped"
    } catch {
      isRunning = false
      status = "Stopped"
    }
  }

  private func refreshLog() {
    let logURL = FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Gehenna/daemon.log")
    guard let data = try? Data(contentsOf: logURL),
          let text = String(data: data, encoding: .utf8) else {
      logText = "No log found yet."
      return
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let tail = lines.suffix(200).joined(separator: "\n")
    logText = tail
  }
}

struct KeymapView: View {
  @State private var layoutRows: [[String]] = []
  @State private var labels: [String: String] = [:]
  @State private var status = "Not loaded"

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Keymap")
        .font(.largeTitle)
        .bold()
      Text("Windows-style layout for the Tartarus Pro.")
        .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        Button("Load Default Layout") {
          loadMapping()
        }
        Text(status)
          .foregroundStyle(.secondary)
      }
      if layoutRows.isEmpty {
        Text("No layout loaded yet.")
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(layoutRows.indices, id: \.self) { rowIndex in
            HStack(spacing: 8) {
              ForEach(layoutRows[rowIndex], id: \.self) { key in
                Text(labels[key] ?? key)
                  .frame(width: 90, height: 44)
                  .background(Color(.controlBackgroundColor))
                  .cornerRadius(8)
              }
            }
          }
        }
      }
      Spacer()
    }
    .padding(24)
    .onAppear(perform: loadMapping)
  }

  private func loadMapping() {
    let loader = MappingLoader()
    let url = repoRoot().appendingPathComponent("configs/tartarus-pro.windows-default.json")
    do {
      let mapping = try loader.load(from: url)
      layoutRows = mapping.layout.rows
      labels = mapping.layout.labels
      status = "Loaded \(mapping.layout.name)"
    } catch {
      status = "Failed: \(error.localizedDescription)"
    }
  }
}

struct MacrosView: View {
  @State private var macros: [Macro] = []
  @State private var status = "Not loaded"

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Macros")
        .font(.largeTitle)
        .bold()
      Text("Manage macro recordings and delays.")
        .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        Button("Reload Macros") {
          loadMacros()
        }
        Text(status)
          .foregroundStyle(.secondary)
      }
      if macros.isEmpty {
        Text("No macros defined yet.")
          .foregroundStyle(.secondary)
      } else {
        List(macros, id: \.id) { macro in
          VStack(alignment: .leading, spacing: 4) {
            Text(macro.name)
              .font(.headline)
            Text("\(macro.steps.count) steps")
              .foregroundStyle(.secondary)
          }
        }
      }
      Spacer()
    }
    .padding(24)
    .onAppear(perform: loadMacros)
  }

  private func loadMacros() {
    let loader = MacroLibraryLoader()
    let url = repoRoot().appendingPathComponent("configs/macros.json")
    do {
      let library = try loader.load(from: url)
      macros = library.macros
      status = "Loaded \(library.macros.count) macros"
    } catch {
      status = "Failed: \(error.localizedDescription)"
    }
  }
}

private func repoRoot() -> URL {
  URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}

@main
struct GehennaApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}
