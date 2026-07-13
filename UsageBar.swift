import Cocoa

// Menu-bar app: shows Claude + GPT(codex/sol) usage %. Polls fetch.py.
let FETCH = (NSHomeDirectory() as NSString).appendingPathComponent("usage-bar/fetch.py")
let POLL: TimeInterval = 90          // Claude is free; GPT is internally cached to ~5 min

func sevColor(_ p: Double?) -> NSColor {
    guard let p = p else { return .secondaryLabelColor }
    if p >= 90 { return NSColor.systemRed }
    if p >= 70 { return NSColor.systemOrange }
    return NSColor.systemGreen
}

func fmtReset(unix: Double?) -> String {
    guard let u = unix, u > 0 else { return "" }
    let s = u - Date().timeIntervalSince1970
    return fmtDur(s)
}
func fmtResetISO(_ iso: String?) -> String {
    guard let iso = iso else { return "" }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var d = f.date(from: iso)
    if d == nil { f.formatOptions = [.withInternetDateTime]; d = f.date(from: iso) }
    guard let dd = d else { return "" }
    return fmtDur(dd.timeIntervalSinceNow)
}
func fmtDur(_ s: Double) -> String {
    if s <= 0 { return "곧" }
    let m = Int(s / 60)
    if m < 60 { return "\(m)분" }
    let h = m / 60
    if h < 24 { return "\(h)시간 \(m % 60)분" }
    return "\(h / 24)일 \(h % 24)시간"
}

final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.title = "…"
        refresh(force: false)
        timer = Timer.scheduledTimer(withTimeInterval: POLL, repeats: true) { [weak self] _ in
            self?.refresh(force: false)
        }
    }

    @objc func manualRefresh() { refresh(force: true) }
    @objc func quit() { NSApp.terminate(nil) }

    func refresh(force: Bool) {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = force ? [FETCH, "--gpt-force"] : [FETCH]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
            var obj: [String: Any] = [:]
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { obj = o }
            } catch { }
            DispatchQueue.main.async { self.render(obj) }
        }
    }

    func d(_ o: Any?) -> [String: Any] { (o as? [String: Any]) ?? [:] }
    func num(_ o: Any?) -> Double? {
        if let n = o as? Double { return n }
        if let n = o as? Int { return Double(n) }
        return nil
    }

    func render(_ obj: [String: Any]) {
        let claude = d(obj["claude"]), gpt = d(obj["gpt"])
        let cWeek = num(d(claude["weekly"])["pct"])
        let gWeek = num(d(gpt["weekly"])["pct"])

        // ---- menu bar title: "C95 G11" colored by severity ----
        let title = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        func seg(_ label: String, _ pct: Double?, _ ok: Bool) {
            let txt = ok && pct != nil ? "\(label)\(Int(pct!))" : "\(label)–"
            title.append(NSAttributedString(string: txt, attributes: [
                .foregroundColor: ok ? sevColor(pct) : NSColor.tertiaryLabelColor, .font: font]))
        }
        seg("C", cWeek, (claude["ok"] as? Bool) ?? false)
        title.append(NSAttributedString(string: " ", attributes: [.font: font]))
        seg("G", gWeek, (gpt["ok"] as? Bool) ?? false)
        item.button?.attributedTitle = title

        // ---- dropdown ----
        let menu = NSMenu()
        func header(_ s: String) {
            let it = NSMenuItem(title: s, action: nil, keyEquivalent: "")
            it.attributedTitle = NSAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.secondaryLabelColor])
            it.isEnabled = false; menu.addItem(it)
        }
        func row(_ label: String, _ pct: Double?, _ reset: String) {
            let pctStr = pct != nil ? "\(Int(pct!))%" : "–"
            let s = "   \(label.padding(toLength: 12, withPad: " ", startingAt: 0))\(pctStr)"
            let it = NSMenuItem(title: s, action: nil, keyEquivalent: "")
            let a = NSMutableAttributedString(string: s, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor])
            if let r = s.range(of: pctStr) {
                a.addAttribute(.foregroundColor, value: sevColor(pct),
                               range: NSRange(r, in: s))
            }
            if !reset.isEmpty {
                a.append(NSAttributedString(string: "   ↺ \(reset)", attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            it.attributedTitle = a; it.isEnabled = false; menu.addItem(it)
        }

        if (claude["ok"] as? Bool) ?? false {
            header("CLAUDE · \(claude["plan"] as? String ?? "")")
            row("세션 5h", num(claude["session"]), "")
            let w = d(claude["weekly"])
            row("주간 전체", num(w["pct"]), fmtResetISO(w["resets_at"] as? String))
            let f = d(claude["fable"])
            row(f["name"] as? String ?? "주간", num(f["pct"]), fmtResetISO(f["resets_at"] as? String))
        } else {
            header("CLAUDE · 오류"); row("keychain", nil, "")
        }
        menu.addItem(.separator())
        if (gpt["ok"] as? Bool) ?? false {
            let stale = (gpt["stale"] as? Bool) ?? false
            header("GPT(sol) · \(gpt["plan"] as? String ?? "")\(stale ? " · stale" : "")")
            let fh = d(gpt["fivehour"]), wk = d(gpt["weekly"])
            if !fh.isEmpty { row("5시간", num(fh["pct"]), fmtReset(unix: num(fh["reset_at"]))) }
            row("주간", num(wk["pct"]), fmtReset(unix: num(wk["reset_at"])))
        } else {
            header("GPT · 오류"); row("codex", nil, "")
        }
        menu.addItem(.separator())
        let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
        let ts = NSMenuItem(title: "갱신 " + tf.string(from: Date()), action: nil, keyEquivalent: "")
        ts.isEnabled = false; menu.addItem(ts)
        menu.addItem(NSMenuItem(title: "지금 갱신", action: #selector(manualRefresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q"))
        for mi in menu.items where mi.action != nil { mi.target = self }
        item.menu = menu
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)     // no Dock icon
let delegate = App()
app.delegate = delegate
app.run()
