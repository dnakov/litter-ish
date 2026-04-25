import SwiftUI

@main
struct LitterISHSanityApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var status = "booting…"
    @State private var output = ""
    @State private var benchmark = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("LitterISH Sanity").font(.title).padding(.top)
                Text(status).font(.headline)
                if !benchmark.isEmpty {
                    Text(benchmark)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if !output.isEmpty {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await run() }
    }

    func run() async {
        do {
            let rootfsURL = try prepareRootfs()
            status = "rootfs ready at \(rootfsURL.lastPathComponent)"
            let dataPath = rootfsURL.appendingPathComponent("data").path

            status = "ish_init…"
            let t0 = Date()
            guard let ish = ish_init(dataPath, "/") else {
                status = "FAIL ish_init returned NULL"
                return
            }
            let bootMs = Int(Date().timeIntervalSince(t0) * 1000)
            status = "booted in \(bootMs) ms"

            defer { ish_shutdown(ish) }

            let lines = [
                try runOne(ish, "uname -a"),
                try runOne(ish, "cat /etc/alpine-release"),
                try runOne(ish, "/bin/busybox | head -1"),
                try runOne(ish, "/bin/ls /bin | head"),
            ]
            output = lines.joined(separator: "\n----\n")

            benchmark = bench(ish, [
                ("true", "true"),
                ("echo", "echo hello"),
                ("grep", "echo 'the quick brown fox' | grep brown"),
                ("awk", "echo '1 2 3' | awk '{print $2}'"),
                ("sed", "echo hello | sed 's/e/3/g'"),
                ("cat+pipe", "printf 'a\\nb\\nc\\n' | cat | wc -l"),
                ("find", "find /etc -maxdepth 1 -type f | head -5"),
            ])
        } catch {
            status = "FAIL: \(error)"
        }
    }

    func bench(_ ish: OpaquePointer, _ cases: [(String, String)]) -> String {
        var lines: [String] = []
        for (label, cmd) in cases {
            var durations: [Double] = []
            for _ in 0..<20 {
                let s = Date()
                _ = try? runOne(ish, cmd)
                durations.append(Date().timeIntervalSince(s) * 1000)
            }
            durations.sort()
            let p50 = durations[durations.count / 2]
            let p95 = durations[min(Int(Double(durations.count) * 0.95), durations.count - 1)]
            let padded = label.padding(toLength: 10, withPad: " ", startingAt: 0)
            lines.append(padded + String(
                format: " p50=%6.2fms  p95=%6.2fms  max=%6.2fms",
                p50, p95, durations.last ?? 0))
        }
        return lines.joined(separator: "\n")
    }

    func runOne(_ ish: OpaquePointer, _ cmd: String) throws -> String {
        var out: UnsafeMutablePointer<UInt8>? = nil
        var len: Int = 0
        var ec: Int32 = 0
        let rc = ish_run(ish, cmd, nil, 0, &out, &len, &ec)
        defer { if let p = out { ish_free(p) } }
        guard rc == 0 else { throw NSError(domain: "ish", code: Int(rc)) }
        var data = Data()
        if let p = out { data = Data(bytes: p, count: len) }
        let text = String(data: data, encoding: .utf8) ?? "<non-utf8 \(len) bytes>"
        return "$ \(cmd)  [\(ec)]\n\(text)"
    }

    func prepareRootfs() throws -> URL {
        let fm = FileManager.default
        let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)
        let dest = caches.appendingPathComponent("fs")
        if fm.fileExists(atPath: dest.path) { return dest }

        guard let src = Bundle.main.url(forResource: "fs", withExtension: nil) else {
            throw NSError(domain: "ish", code: -100,
                          userInfo: [NSLocalizedDescriptionKey: "rootfs not in bundle"])
        }
        try fm.copyItem(at: src, to: dest)

        // The bundled meta.db is packaged read-only in the app bundle. Copying
        // it above preserves perms; make it writable for SQLite.
        let db = dest.appendingPathComponent("meta.db")
        var attrs = try fm.attributesOfItem(atPath: db.path)
        attrs[.posixPermissions] = 0o644
        try fm.setAttributes(attrs, ofItemAtPath: db.path)

        return dest
    }
}
