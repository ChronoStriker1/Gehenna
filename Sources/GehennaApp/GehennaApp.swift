import SwiftUI

struct ContentView: View {
  @State private var status = "Idle"

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Gehenna")
        .font(.largeTitle)
        .bold()
      Text("Razer Tartarus Pro controller for macOS.")
        .foregroundStyle(.secondary)

      Divider()

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
      }

      Text("Status: \(status)")
        .font(.callout)
        .foregroundStyle(.secondary)

      Spacer()
    }
    .padding(24)
    .frame(minWidth: 520, minHeight: 360)
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
      }
    } catch {
      status = "Failed to start daemon: \(error.localizedDescription)"
    }
  }

  private func stopDaemon() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    process.arguments = ["-f", "GehennaDaemon"]
    do {
      try process.run()
      status = "Stop signal sent."
    } catch {
      status = "Failed to stop daemon: \(error.localizedDescription)"
    }
  }

  private func repoRoot() -> URL {
    URL(fileURLWithPath: #file)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

@main
struct GehennaApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}
