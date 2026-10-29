import AppKit

/// Scripted check of the updater (scripts/ui-demo-update.sh): Home finds the fake release in the
/// local feed, look-alikes are refused, then it installs over the script's throwaway copy and quits.
/// Writes `update.json` (and a screenshot of the banner) before quitting.
extension UIDemo {
    @MainActor static func runUpdate(model: EditorModel, outputDirectory: String) {
        Task { @MainActor in
            let out = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            var log: [[String: Any]] = []
            var failures: [String] = []
            @MainActor func check(_ ok: Bool, _ what: String, _ detail: Any? = nil) {
                print("ui-demo-update \(ok ? "ok  " : "FAIL") \(what)\(detail.map { " (\($0))" } ?? "")")
                log.append(["check": what, "ok": ok, "detail": "\(detail ?? "")"])
                if !ok { failures.append(what) }
            }
            @MainActor func save() {
                var all = log
                all.append(["failures": failures])
                if let data = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted]) {
                    try? data.write(to: out.appendingPathComponent("update.json"))
                }
            }
            model.showHome = true
            for _ in 0..<200 where model.updater.available == nil { try? await Task.sleep(for: .seconds(0.1)) }
            let release = model.updater.available
            check(release?.version == "9.9.9" && release?.download.isFileURL == true, "Home finds the new release", release?.version)
            check(!UpdateBanner.summary(release?.notes ?? "").isEmpty, "with its notes", UpdateBanner.summary(release?.notes ?? ""))
            check(Updater.isNewer("0.10.0", than: "0.9.2") && !Updater.isNewer("1.2", than: "1.2.0") && Updater.isNewer("1.2.1", than: "1.2"),
                  "versions compare by number")
            try? await Task.sleep(for: .seconds(1.2))
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
               let v = window.contentView?.superview ?? window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("update-01-home-banner.png"))
            }
            for path in (ProcessInfo.processInfo.environment["MOTIONFORGE_UPDATE_BAD_APPS"] ?? "").split(separator: ":") {
                let app = URL(fileURLWithPath: String(path))
                do {
                    try model.updater.verify(app, newerThan: Updater.currentVersion)
                    check(false, "refuses \(app.lastPathComponent)")
                } catch {
                    check(true, "refuses \(app.lastPathComponent)", error.localizedDescription)
                }
            }
            guard let release else { save(); exit(1) }
            save()  // installing quits the app
            await model.updater.install(release) { true }
            check(false, "installs and quits", "\(model.updater.state)")  // only reached if it didn't
            save()
            exit(1)
        }
    }
}
