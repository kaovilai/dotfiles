// llm-usage-menubar: macOS menubar monitor for LLM usage and rate limits.
//
// Single-file AppKit helper (no Xcode project, no app bundle). It polls
// `llm-usage menubar-data` every 30s on a background queue and renders the JSON.
// Build/run/install it with `llm-usage menubar build|run|install|uninstall|status`.
//
// Debug (no GUI):
//   --dump-menu [--data-file FILE|-]   print title + menu structure and exit
//   --chart-png PATH                   with --dump-menu: also write the chart images to PNG
//   --no-charts                        with --dump-menu: render with charts off
//   --status-png PATH [--dark]         render the status item image (+ text) to PNG from --data-file (no GUI)
//                                      [--no-text]; --dump-menu also takes --no-image / --no-text
//   --list-logos                       which source each logo key resolves to
import AppKit
import Foundation

// MARK: - tolerant JSON access (missing/old fields never crash)

struct J {
    let v: Any?
    subscript(_ k: String) -> J { J(v: (v as? [String: Any])?[k]) }
    var str: String? { v as? String }
    var int: Int? { (v as? NSNumber)?.intValue }
    var dbl: Double? { (v as? NSNumber)?.doubleValue }
    var bool: Bool { (v as? NSNumber)?.boolValue ?? false }
    var arr: [J] { (v as? [Any])?.map { J(v: $0) } ?? [] }
    var exists: Bool { v != nil && !(v is NSNull) }
    var keys: [String] { Array(((v as? [String: Any]) ?? [:]).keys) }
}

// MARK: - formatting

func human(_ n: Int) -> String {
    let d = Double(n)
    if d >= 1e9 { return String(format: "%.1fB", d / 1e9) }
    if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
    if d >= 1e3 { return String(format: "%.1fk", d / 1e3) }
    return "\(n)"
}

/// "9d", "2h", "3m", "45s": status-bar sized.
func compactDuration(_ seconds: Int) -> String {
    if seconds >= 86400 { return "\(seconds / 86400)d" }
    if seconds >= 3600 { return "\(seconds / 3600)h" }
    if seconds >= 60 { return "\((seconds + 59) / 60)m" }
    return "\(max(seconds, 0))s"
}

func longDuration(_ seconds: Int) -> String {
    let s = max(seconds, 0)
    let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60, sec = s % 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m \(sec)s" }
    return "\(sec)s"
}

func parseISO(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    let f = ISO8601DateFormatter()
    return f.date(from: s)
}

func clock(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: d)
}

func pct(_ x: Double?) -> String { String(format: "%.0f%%", (x ?? 0) * 100) }

let restartCommands: [Int: String] = [
    4141: "claude-copilot-restart", 4142: "claude-vertex-restart", 4145: "claude-openai-restart",
    4146: "claude-enmaas-restart", 4147: "codex-hosted-only-restart", 4148: "claude-hosted-only-restart",
]

func restartCommand(port: Int) -> String { restartCommands[port] ?? "llm-proxy-restart" }

// MARK: - state derived from the JSON

struct Summary {
    var glyph: String       // text fallback glyph
    var symbol: String      // SF Symbol name
    var text: String        // compact text next to the glyph
    var state: String       // normal | throttled | down | spike | error
}

func summarize(_ d: J, now: Date, stale: Bool) -> Summary {
    var suffix = ""
    let flight = d["inflight"]["count"].int ?? 0
    if flight > 0 { suffix += " ⏳\(flight)" }
    let reroutes = d["reroutes_15m"].int ?? 0
    if reroutes > 0 { suffix += " ↪\(reroutes)" }

    var base: Summary
    let th = d["throttled"]
    if th.exists, let reset = parseISO(th["reset_at"].str), reset > now {
        base = Summary(glyph: "⚠", symbol: "exclamationmark.triangle.fill",
                       text: "429 \(compactDuration(Int(reset.timeIntervalSince(now).rounded(.up))))", state: "throttled")
    } else if d["any_down"].bool {
        base = Summary(glyph: "✖", symbol: "xmark.octagon.fill", text: "", state: "down")
    } else if d["spike"]["active"].bool {
        base = Summary(glyph: "⚠", symbol: "exclamationmark.triangle", text: "spike", state: "spike")
    } else {
        base = Summary(glyph: "●", symbol: "circle.fill", text: "\(d["totals"]["m15"]["requests"].int ?? 0)", state: "normal")
    }
    base.text += suffix
    base.text = base.text.trimmingCharacters(in: .whitespaces)
    if stale { base.text += base.text.isEmpty ? "?" : " ?" }
    return base
}

// MARK: - charts (drawn with system colors only, so light/dark just work)

let modelPalette: [NSColor] = [.systemBlue, .systemTeal, .systemPurple, .systemIndigo, .systemGreen, .systemPink]
let chartWidth: CGFloat = 380

func chartImage(height: CGFloat, _ draw: @escaping (NSRect) -> Void) -> NSImage {
    NSImage(size: NSSize(width: chartWidth, height: height), flipped: false) { rect in
        draw(rect)
        return true
    }
}

let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

func drawText(_ text: String, at p: NSPoint, color: NSColor = .secondaryLabelColor, font: NSFont = smallFont) {
    (text as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
}

/// Requests per minute for the last hour; 429 / 5xx / other failures stacked on top of the successes.
func requestsChart(_ d: J) -> (NSImage, String) {
    let s = d["series"]
    let req = s["requests"].arr.map { $0.int ?? 0 }
    let e429 = s["e429"].arr.map { $0.int ?? 0 }
    let e5 = s["e5xx"].arr.map { $0.int ?? 0 }
    let eo = s["eother"].arr.map { $0.int ?? 0 }
    let n = req.count
    let peak = max(req.max() ?? 0, 1)
    let total = req.reduce(0, +)
    let alt = "requests/min, last 60m: \(total) total, peak \(req.max() ?? 0)/min, 429 \(e429.reduce(0, +)), 5xx \(e5.reduce(0, +)), other \(eo.reduce(0, +))"
    let image = chartImage(height: 62) { rect in
        drawText("requests/min · last 60m · peak \(peak)", at: NSPoint(x: 0, y: rect.height - 12))
        guard n > 0 else { drawText("no data", at: NSPoint(x: 0, y: 20)); return }
        let area = NSRect(x: 0, y: 2, width: rect.width, height: rect.height - 16)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 1, width: rect.width, height: 1).fill()
        let slot = area.width / CGFloat(n)
        for i in 0..<n {
            let x = area.minX + CGFloat(i) * slot
            let scale = (area.height - 1) / CGFloat(peak)
            let failed = (i < e429.count ? e429[i] : 0) + (i < e5.count ? e5[i] : 0) + (i < eo.count ? eo[i] : 0)
            var y = area.minY
            let segments: [(Int, NSColor)] = [
                (max(req[i] - failed, 0), .systemBlue),
                (i < e429.count ? e429[i] : 0, .systemOrange),
                (i < e5.count ? e5[i] : 0, .systemRed),
                (i < eo.count ? eo[i] : 0, .systemYellow),
            ]
            for (count, color) in segments where count > 0 {
                let h = max(CGFloat(count) * scale, 1)
                color.setFill()
                NSRect(x: x, y: y, width: max(slot - 1, 1), height: h).fill()
                y += h
            }
        }
    }
    return (image, alt)
}

struct Slice { let label: String; let count: Int; let note: String }

/// One stacked bar plus a legend row per slice.
func stackedChart(title: String, slices: [Slice]) -> (NSImage, String) {
    let total = max(slices.reduce(0) { $0 + $1.count }, 1)
    let rows = min(slices.count, 5)
    let height = CGFloat(18 + 14 + rows * 13 + 2)
    let alt = "\(title): " + slices.map { "\($0.label) \($0.count)\($0.note.isEmpty ? "" : " " + $0.note)" }.joined(separator: ", ")
    let image = chartImage(height: height) { rect in
        drawText(title, at: NSPoint(x: 0, y: rect.height - 12))
        guard !slices.isEmpty else { drawText("no requests", at: NSPoint(x: 0, y: rect.height - 26)); return }
        var x: CGFloat = 0
        let barY = rect.height - 28
        for (i, sl) in slices.enumerated() {
            let w = rect.width * CGFloat(sl.count) / CGFloat(total)
            modelPalette[i % modelPalette.count].setFill()
            NSRect(x: x, y: barY, width: max(w - 1, 1), height: 10).fill()
            x += w
        }
        for (i, sl) in slices.prefix(rows).enumerated() {
            let y = barY - 14 - CGFloat(i) * 13
            modelPalette[i % modelPalette.count].setFill()
            NSRect(x: 0, y: y + 2, width: 8, height: 8).fill()
            let share = String(format: "%.0f%%", 100 * Double(sl.count) / Double(total))
            drawText("\(sl.label)  \(sl.count) (\(share))\(sl.note.isEmpty ? "" : "  " + sl.note)",
                     at: NSPoint(x: 13, y: y), color: .labelColor)
        }
    }
    return (image, alt)
}

func writePNG(_ images: [NSImage], to path: String) {
    let gap: CGFloat = 8
    let size = NSSize(width: chartWidth + 20, height: images.reduce(CGFloat(10)) { $0 + $1.size.height + gap })
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.windowBackgroundColor.setFill()
    NSRect(origin: .zero, size: size).fill()
    var y = size.height - 5
    for img in images {
        y -= img.size.height
        img.draw(in: NSRect(x: 10, y: y, width: img.size.width, height: img.size.height))
        y -= gap
    }
    NSGraphicsContext.restoreGraphicsState()
    if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
}

// MARK: - logos (never bundled: user dir > fetched dir > installed app icon > generated monogram)

struct LogoSpec {
    let key: String
    let label: String
    let bundleIds: [String]   // installed apps whose icon stands in for the logo
    let monogram: String
    let brand: NSColor        // plain colour constant for the generated monogram, not a logo
}

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}

/// Data-driven: add a row (and a PROVIDER_PORTS / MODEL_VENDORS entry in llm-usage) to support another key.
let logoSpecs: [LogoSpec] = [
    LogoSpec(key: "claude", label: "Claude", bundleIds: ["com.anthropic.claudefordesktop"], monogram: "C", brand: rgb(0xD97757)),
    LogoSpec(key: "anthropic", label: "Anthropic", bundleIds: ["com.anthropic.claudefordesktop"], monogram: "A", brand: rgb(0xB5543A)),
    LogoSpec(key: "openai", label: "OpenAI / GPT", bundleIds: ["com.openai.codex"], monogram: "O", brand: rgb(0x10A37F)),
    LogoSpec(key: "glm", label: "GLM / Z.ai", bundleIds: [], monogram: "Z", brand: rgb(0x3556E8)),
    LogoSpec(key: "deepseek", label: "DeepSeek", bundleIds: [], monogram: "D", brand: rgb(0x4D6BFE)),
    LogoSpec(key: "gemini", label: "Gemini", bundleIds: ["com.google.GeminiMacOS"], monogram: "✦", brand: rgb(0x5B7FEB)),
    LogoSpec(key: "github-copilot", label: "GitHub Copilot", bundleIds: ["com.github.githubapp"], monogram: "Co", brand: rgb(0x6E40C9)),
    LogoSpec(key: "vertex", label: "Vertex AI", bundleIds: [], monogram: "V", brand: rgb(0x4285F4)),
    LogoSpec(key: "enmaas", label: "EnMaaS", bundleIds: [], monogram: "E", brand: rgb(0xCC2B2B)),
    LogoSpec(key: "other", label: "Other", bundleIds: [], monogram: "•", brand: rgb(0x7A7F87)),
]

enum LogoKind: String { case color, mono, app, monogram }

struct Logo {
    let key: String
    let kind: LogoKind
    let image: CGImage?   // nil for monogram
    let source: String    // where it came from, for `menubar logos`
}

func envDir(_ name: String) -> String? { ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 } }
func userLogosDir() -> String { (envDir("LLM_USAGE_CONFIG_DIR") ?? NSHomeDirectory() + "/.config/llm-usage") + "/logos" }
func fetchedLogosDir() -> String { (envDir("LLM_USAGE_MENUBAR_DIR") ?? NSHomeDirectory() + "/.local/share/llm-usage") + "/logos" }

func cgImage(of image: NSImage, maxPixels: Int = 256) -> CGImage? {
    var rect = NSRect(origin: .zero, size: NSSize(width: maxPixels, height: maxPixels))
    if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil), cg.width > 0, cg.height > 0 { return cg }
    return nil
}

func loadImageFile(_ path: String) -> CGImage? {
    guard FileManager.default.fileExists(atPath: path), let img = NSImage(contentsOfFile: path), img.size.width > 0 else { return nil }
    return cgImage(of: img)
}

var logoCache: [String: Logo] = [:]

func resolveLogo(_ key: String) -> Logo {
    if let hit = logoCache[key] { return hit }
    let found = findLogo(key)
    logoCache[key] = found
    return found
}

func findLogo(_ key: String) -> Logo {
    let user = userLogosDir(), fetched = fetchedLogosDir()
    for ext in ["png", "pdf", "svg"] {
        let path = "\(user)/\(key).\(ext)"
        if let cg = loadImageFile(path) { return Logo(key: key, kind: .color, image: cg, source: "user dir: \(path)") }
    }
    for ext in ["png", "pdf", "svg"] {
        let path = "\(user)/\(key).mono.\(ext)"
        if let cg = loadImageFile(path) { return Logo(key: key, kind: .mono, image: cg, source: "user dir (mono, tinted): \(path)") }
    }
    let colorPath = "\(fetched)/\(key).png"
    if let cg = loadImageFile(colorPath) { return Logo(key: key, kind: .color, image: cg, source: "fetched: \(colorPath)") }
    let monoPath = "\(fetched)/\(key).mono.png"
    if let cg = loadImageFile(monoPath) { return Logo(key: key, kind: .mono, image: cg, source: "fetched (mono, tinted): \(monoPath)") }
    if let spec = logoSpecs.first(where: { $0.key == key }) {
        for id in spec.bundleIds {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                if let cg = cgImage(of: icon) { return Logo(key: key, kind: .app, image: cg, source: "app icon: \(url.path) (\(id))") }
            }
        }
    }
    return Logo(key: key, kind: .monogram, image: nil, source: "generated monogram")
}

func listLogos() {
    print("logo key         source")
    var keys = logoSpecs.map { $0.key }
    for extra in keysInDirs() where !keys.contains(extra) { keys.append(extra) }
    for key in keys {
        let l = resolveLogo(key)
        print(key.padding(toLength: 16, withPad: " ", startingAt: 0) + " \(l.kind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(l.source)")
    }
}

/// Keys the user dropped in a logos dir that the built-in table does not know (shown, but not used until a mapping emits that key).
func keysInDirs() -> [String] {
    var out: [String] = []
    for dir in [userLogosDir(), fetchedLogosDir()] {
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where ["png", "pdf", "svg"].contains((f as NSString).pathExtension) {
            var base = (f as NSString).deletingPathExtension
            if base.hasSuffix(".mono") { base = String(base.dropLast(5)) }
            if !out.contains(base) { out.append(base) }
        }
    }
    return out.sorted()
}

var tintCache: [String: CGImage] = [:]

/// A single-colour glyph recoloured to `color` (alpha of the PNG is the mask).
func tinted(_ cg: CGImage, color: CGColor, cacheKey: String) -> CGImage {
    let comps = (color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? color).components ?? []
    let id = cacheKey + comps.map { String(format: "%.3f", Double($0)) }.joined(separator: ",")
    if let hit = tintCache[id] { return hit }
    let n = 128
    guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return cg }
    let rect = CGRect(x: 0, y: 0, width: n, height: n)
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: rect)
    ctx.setBlendMode(.sourceIn)
    ctx.setFillColor(color)
    ctx.fill(rect)
    let out = ctx.makeImage() ?? cg
    tintCache[id] = out
    return out
}

// MARK: - status item image

struct ShareEntry {
    let key: String
    let label: String
    let share: Double
    let requests: Int
    let tokens: Int
    let models: [String]
}

func shareEntries(_ j: J) -> [ShareEntry] {
    j.arr.compactMap { e in
        guard let key = e["key"].str, let share = e["share"].dbl, share > 0 else { return nil }
        return ShareEntry(key: key, label: e["label"].str ?? key, share: share, requests: e["requests"].int ?? 0,
                          tokens: e["tokens"].int ?? 0, models: e["models"].arr.compactMap { $0.str })
    }.sorted { $0.share > $1.share }
}

/// More traffic = more opaque; small shares stay visible. sqrt flattens the top so a 40% logo is not half-faded.
func logoOpacity(_ share: Double) -> CGFloat { CGFloat(min(1.0, 0.25 + 0.75 * share.squareRoot())) }

let imageHeight: CGFloat = 22
let logoSize: CGFloat = 16
let logoStep: CGFloat = 9  // 7 buried the minority logos (slivers); 9 keeps every glyph recognisable
let maxLogosPerCluster = 4

func clusterWidth(_ count: Int, overflow: Bool) -> CGFloat {
    logoSize + CGFloat(max(min(count, maxLogosPerCluster) - 1, 0)) * logoStep + (overflow ? 12 : 0)
}

func shapePath(_ rect: CGRect, circle: Bool) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: circle ? rect.width / 2 : 4, cornerHeight: circle ? rect.height / 2 : 4, transform: nil)
}

func drawMonogram(_ ctx: CGContext, spec: LogoSpec?, key: String, rect: CGRect, circle: Bool) {
    let brand = spec?.brand ?? rgb(0x7A7F87)
    let rect = rect.insetBy(dx: 1, dy: 1)  // same visual weight as the 14pt glyph logos
    ctx.addPath(shapePath(rect, circle: circle))
    ctx.setFillColor(brand.cgColor)
    ctx.fillPath()
    let text = spec?.monogram ?? String(key.prefix(1)).uppercased()
    let font = NSFont.systemFont(ofSize: text.count > 1 ? 7.5 : 10, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let size = (text as NSString).size(withAttributes: attrs)
    (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
}

func drawLogo(_ ctx: CGContext, entry: ShareEntry, rect: CGRect, circle: Bool, labelColor: CGColor) {
    let logo = resolveLogo(entry.key)
    let spec = logoSpecs.first { $0.key == entry.key }
    ctx.saveGState()
    ctx.setAlpha(logoOpacity(entry.share))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.interpolationQuality = .high
    switch logo.kind {
    case .color, .mono:
        guard let cg = logo.image else { break }
        let glyph = logo.kind == .mono ? tinted(cg, color: labelColor, cacheKey: entry.key) : cg
        ctx.draw(glyph, in: rect.insetBy(dx: 0.5, dy: 0.5))
    case .app:
        if let cg = logo.image {
            ctx.addPath(shapePath(rect, circle: circle))
            ctx.clip()
            ctx.draw(cg, in: rect)
        }
    case .monogram:
        drawMonogram(ctx, spec: spec, key: entry.key, rect: rect, circle: circle)
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

/// `<models cluster> | <providers cluster>` as an avatar-stack image. Drawn with an explicit appearance so the
/// single-colour logos and placeholders follow the menubar's light/dark mode (the caller re-renders on change).
func statusImage(models: [ShareEntry], providers: [ShareEntry], badge: NSColor?, appearance: NSAppearance, scale: CGFloat = 2) -> NSImage {
    let mOverflow = models.count > maxLogosPerCluster, pOverflow = providers.count > maxLogosPerCluster
    let mw = clusterWidth(max(models.count, 1), overflow: mOverflow), pw = clusterWidth(max(providers.count, 1), overflow: pOverflow)
    let gap: CGFloat = 10
    let size = NSSize(width: ceil(1 + mw + gap + pw + (badge != nil ? 2 : 1)), height: imageHeight)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage(size: size) }
    rep.size = size
    appearance.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.current = gc
        let ctx = gc.cgContext
        ctx.clear(CGRect(origin: .zero, size: size))
        let label = NSColor.labelColor.cgColor
        let y = (imageHeight - logoSize) / 2

        func cluster(_ entries: [ShareEntry], x0: CGFloat, circle: Bool) {
            guard !entries.isEmpty else {  // idle: one faint outline per cluster
                ctx.addPath(shapePath(CGRect(x: x0 + 0.6, y: y + 0.6, width: logoSize - 1.2, height: logoSize - 1.2), circle: circle))
                ctx.setStrokeColor(label.copy(alpha: 0.35) ?? label)
                ctx.setLineWidth(1.2)
                ctx.strokePath()
                return
            }
            let shown = Array(entries.prefix(maxLogosPerCluster))
            for i in shown.indices.reversed() {  // smallest share first, so the dominant logo ends up on top
                let rect = CGRect(x: x0 + CGFloat(i) * logoStep, y: y, width: logoSize, height: logoSize)
                if i < shown.count - 1 {  // carve a gap in what is underneath: avatar-stack outline that works on any bar colour
                    ctx.saveGState()
                    ctx.setBlendMode(.clear)
                    ctx.addPath(shapePath(rect.insetBy(dx: -1.2, dy: -1.2), circle: circle))
                    ctx.fillPath()
                    ctx.restoreGState()
                }
                drawLogo(ctx, entry: shown[i], rect: rect, circle: circle, labelColor: label)
            }
            if entries.count > maxLogosPerCluster {
                let chip = CGRect(x: x0 + clusterWidth(shown.count, overflow: false) + 1, y: y + (logoSize - 11) / 2, width: 11, height: 11)
                ctx.setFillColor(label.copy(alpha: 0.18) ?? label)
                ctx.fillEllipse(in: chip)
                let text = "+\(entries.count - maxLogosPerCluster)"
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 6.5, weight: .bold), .foregroundColor: NSColor.labelColor.withAlphaComponent(0.75)]
                let ts = (text as NSString).size(withAttributes: attrs)
                (text as NSString).draw(at: NSPoint(x: chip.midX - ts.width / 2, y: chip.midY - ts.height / 2), withAttributes: attrs)
            }
        }
        cluster(models, x0: 1, circle: true)
        ctx.setFillColor(label.copy(alpha: 0.25) ?? label)
        ctx.fill(CGRect(x: 1 + mw + gap / 2 - 0.5, y: (imageHeight - 12) / 2, width: 1, height: 12))
        cluster(providers, x0: 1 + mw + gap, circle: false)

        if let badge = badge {
            let d: CGFloat = 7
            let dot = CGRect(x: size.width - d - 0.5, y: size.height - d - 0.5, width: d, height: d)
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: dot.insetBy(dx: -1.5, dy: -1.5))
            ctx.restoreGState()
            ctx.setFillColor(badge.cgColor)
            ctx.fillEllipse(in: dot)
        }
    }
    let image = NSImage(size: size)
    image.addRepresentation(rep)
    image.isTemplate = false
    return image
}

func badgeColor(for state: String) -> NSColor? {
    switch state {
    case "throttled", "down": return .systemRed
    case "spike": return .systemOrange
    default: return nil
    }
}

func shareDescription(_ share: J) -> String {
    func side(_ name: String, _ arr: [ShareEntry]) -> String {
        name + ": " + (arr.isEmpty ? "idle" : arr.map { "\($0.label) \(pct($0.share))" }.joined(separator: ", "))
    }
    return side("Models", shareEntries(share["models"])) + " · " + side("Providers", shareEntries(share["providers"]))
}

/// Status item image + text on a menubar-coloured background (debug: no GUI needed).
func writeStatusPNG(_ d: J, summary: Summary, dark: Bool, showText: Bool, to path: String) {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    let share = d["share"]
    let img = statusImage(models: shareEntries(share["models"]), providers: shareEntries(share["providers"]),
                          badge: badgeColor(for: summary.state), appearance: appearance)
    let font = NSFont.menuBarFont(ofSize: 0)
    let text = showText ? summary.text : ""
    var textWidth: CGFloat = 0
    if !text.isEmpty { textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 4 }
    let size = NSSize(width: 10 + img.size.width + textWidth + 10, height: 24)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = size
    appearance.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (dark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
        NSRect(origin: .zero, size: size).fill()
        img.draw(in: NSRect(x: 10, y: (size.height - img.size.height) / 2, width: img.size.width, height: img.size.height))
        if !text.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let ts = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: 10 + img.size.width + 4, y: (size.height - ts.height) / 2), withAttributes: attrs)
        }
    }
    if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    print("status-png: \(Int(size.width))x\(Int(size.height))pt (\(rep.pixelsWide)x\(rep.pixelsHigh)px) \(dark ? "dark" : "light") state=\(summary.state) text=\"\(text)\" -> \(path)")
    print(shareDescription(share))
}

// MARK: - CLI discovery and polling

func findUsageBinary() -> String? {
    let fm = FileManager.default
    var candidates: [String] = []
    if let env = ProcessInfo.processInfo.environment["LLM_USAGE_BIN"], !env.isEmpty { candidates.append(env) }
    candidates.append(NSHomeDirectory() + "/git/dotfiles/scripts/llm-usage")
    var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    dirs += [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    candidates += dirs.map { $0 + "/llm-usage" }
    return candidates.first { fm.isExecutableFile(atPath: $0) }
}

enum PollError: Error { case message(String) }

func runUsage(_ args: [String], timeout: TimeInterval = 25) -> Result<Data, PollError> {
    guard let bin = findUsageBinary() else {
        return .failure(.message("llm-usage not found (set LLM_USAGE_BIN or put it on PATH)"))
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return .failure(.message("cannot run \(bin): \(error.localizedDescription)")) }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    var errData = Data()
    let errDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); errDone.signal() }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()
    errDone.wait()
    if p.terminationStatus != 0 {
        let msg = String(data: errData, encoding: .utf8)?.split(separator: "\n").last.map(String.init) ?? "exit \(p.terminationStatus)"
        return .failure(.message(msg))
    }
    return .success(data)
}

func parseJSON(_ data: Data) -> Result<J, PollError> {
    guard let obj = try? JSONSerialization.jsonObject(with: data), obj is [String: Any] else {
        return .failure(.message("llm-usage menubar-data returned invalid JSON"))
    }
    return .success(J(v: obj))
}

// MARK: - menu construction (shared by the GUI and --dump-menu)

struct MenuContext {
    var data: J?
    var now: Date
    var refreshed: Date?
    var stale: Bool
    var error: String?
    var charts: Bool
    var notifications: Bool
    var launchAgentInstalled: Bool
    var showImage = true
    var showText = true
    var shareWindow = "15m"   // "15m" | "1h"
    var shareMetric = "requests"  // "requests" | "tokens"
}

final class Builder {
    let target: AnyObject?
    var chartImages: [NSImage] = []
    init(target: AnyObject?) { self.target = target }

    func info(_ title: String, dim: Bool = false, mono: Bool = false, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let font = mono ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.menuFont(ofSize: 0)
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font, .foregroundColor: dim ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        return item
    }

    func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    func action(_ title: String, _ sel: Selector, represented: Any? = nil, state: Bool? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = target
        item.representedObject = represented
        if let s = state { item.state = s ? .on : .off; item.tag = 1 }  // tag 1 = checkbox row (dump shows [x]/[ ])
        return item
    }

    func chartItem(_ pair: (NSImage, String)) -> NSMenuItem {
        let item = NSMenuItem(title: "[chart] " + pair.1, action: nil, keyEquivalent: "")
        let view = NSImageView(frame: NSRect(x: 0, y: 0, width: chartWidth + 28, height: pair.0.size.height + 6))
        pair.0.isTemplate = false
        let inset = NSImageView(frame: NSRect(x: 14, y: 3, width: chartWidth, height: pair.0.size.height))
        inset.image = pair.0
        view.addSubview(inset)
        item.view = view
        chartImages.append(pair.0)
        return item
    }

    func proxyItem(_ p: J) -> NSMenuItem {
        let name = p["name"].str ?? "?"
        let port = p["port"].int ?? 0
        let up = p["state"].str == "up"
        let expected = p["expected"].bool
        let m15 = p["m15"], h1 = p["h1"]
        func errs(_ c: J) -> String {
            let e = c["errors"]
            let parts = [("429", e["429"].int ?? 0), ("5xx", e["5xx"].int ?? 0), ("oth", e["other"].int ?? 0)].filter { $0.1 > 0 }
            return parts.isEmpty ? "" : " " + parts.map { "\($0.0):\($0.1)" }.joined(separator: " ")
        }
        let glyph = up ? "●" : (expected ? "✖" : "○")
        let src = p["source"].str == "transcript" ? " (transcript)" : ""
        let label = name == ":\(port)" ? name : "\(name) :\(port)"
        var line = "\(glyph) \(label)  \(up ? "up" : (expected ? "DOWN" : "off"))"
        line += "  \(m15["requests"].int ?? 0)/15m \(h1["requests"].int ?? 0)/1h\(errs(h1))\(src)"
        if let fl = p["inflight"].exists ? p["inflight"]["count"].int : nil, fl > 0 { line += "  ⏳\(fl)" }
        let item = info(line, dim: !up && !expected, mono: true)
        item.isEnabled = true  // a submenu parent must be enabled to open
        item.attributedTitle = NSAttributedString(string: line, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: (!up && !expected) ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(info("\(label)  \(up ? "up" : "down")", mono: false))
        sub.addItem(info("15m: \(m15["requests"].int ?? 0) req, error rate \(pct(m15["error_rate"].dbl))\(errs(m15))", dim: true))
        sub.addItem(info("1h:  \(h1["requests"].int ?? 0) req, error rate \(pct(h1["error_rate"].dbl))\(errs(h1))", dim: true))
        if let t = h1["tokens"].exists ? h1["tokens"] : nil {
            sub.addItem(info("1h tokens: in \(human(t["in"].int ?? 0)) · out \(human(t["out"].int ?? 0)) · cache read \(human(t["cache_read"].int ?? 0))", dim: true))
        }
        if p["inflight"].exists {
            sub.addItem(info("in flight: \(p["inflight"]["count"].int ?? 0), oldest \(longDuration(p["inflight"]["oldest_s"].int ?? 0))", dim: true))
        } else {
            sub.addItem(info("in flight: n/a" + (p["source"].str == "transcript" ? " (no usage callback)" : " (restart proxy with the updated callback)"), dim: true))
        }
        if let seen = p["last_seen_s"].int { sub.addItem(info("last logged request \(longDuration(seen)) ago", dim: true)) }
        sub.addItem(.separator())
        sub.addItem(action("Copy port (\(port))", #selector(AppController.copyText(_:)), represented: "\(port)"))
        sub.addItem(action("Copy restart command: \(restartCommand(port: port))", #selector(AppController.copyText(_:)),
                           represented: restartCommand(port: port)))
        item.submenu = sub
        return item
    }

    func build(_ c: MenuContext) -> (NSMenu, [String]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var plain: [String] = []  // text for "Copy status"
        func add(_ item: NSMenuItem, copy: Bool = true) {
            menu.addItem(item)
            if copy, !item.isSeparatorItem, item.view == nil { plain.append(item.title) }
        }

        let stamp = c.refreshed.map { clock($0) } ?? "never"
        add(header("LLM USAGE · refreshed \(stamp)" + (c.stale ? " · STALE" : "")))
        if let err = c.error {
            add(info("⚠ poll failed: \(err)"))
            if c.data != nil { add(info("showing last good data from \(stamp)", dim: true)) }
        }
        guard let d = c.data else {
            menu.addItem(.separator())
            addActions(menu, c, plainCopy: nil)
            return (menu, plain)
        }

        // Throttled
        let th = d["throttled"]
        if th.exists, let reset = parseISO(th["reset_at"].str), reset > c.now {
            let left = Int(reset.timeIntervalSince(c.now).rounded(.up))
            let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"
            menu.addItem(.separator()); add(header("THROTTLED"))
            add(info("⚠ \(th["proxy"].str ?? "?") · \(th["model"].str ?? "?") · \(th["kind"].str ?? "rate-limit") 429"))
            add(info("resets in \(longDuration(left)) (≈ \(f.string(from: reset)))", dim: false))
            let basis: [String: String] = ["retry_after": "from the logged retry_after", "next-month-utc": "quota 429 with no retry_after: assumed next UTC month start",
                                           "assumed-60s": "rate limit with no retry_after: assumed 60s"]
            add(info("ESTIMATE · \(basis[th["basis"].str ?? ""] ?? "estimated from the log")", dim: true))
        }
        let spike = d["spike"]
        if spike["active"].bool {
            menu.addItem(.separator())
            add(info("⚠ Error spike: \(spike["errors"].int ?? 0) errors in the flagged minutes (last 10m)"))
        }

        // In flight
        menu.addItem(.separator()); add(header("IN FLIGHT"))
        let fl = d["inflight"]
        if fl["available"].bool {
            var line = "\(fl["count"].int ?? 0) in flight"
            if fl["oldest"].exists {
                line += " · oldest \(fl["oldest"]["model"].str ?? "?") waiting \(longDuration(fl["oldest"]["seconds"].int ?? 0))"
            }
            add(info(line))
            let byModel = fl["by_model"]
            let parts = byModel.keys.sorted { (byModel[$0].int ?? 0) > (byModel[$1].int ?? 0) }.map { "\($0) ×\(byModel[$0].int ?? 0)" }
            if !parts.isEmpty { add(info(parts.joined(separator: " · "), dim: true)) }
        } else {
            add(info("n/a · no proxy reports in-flight yet (restart: llm-proxy-restart)", dim: true))
        }

        // Proxies
        menu.addItem(.separator()); add(header("PROXIES (15m / 1h)"))
        for p in d["proxies"].arr { add(proxyItem(p)) }

        // Traffic share (what the status item image draws)
        let share = d["share"]
        if share.exists {
            menu.addItem(.separator())
            add(header("TRAFFIC SHARE (\(share["window"].str ?? "15m") · \(share["metric"].str ?? "requests"))"))
            if share["metric"].str != c.shareMetric && c.shareMetric == "tokens" {
                add(info("no token counts in this window: showing requests", dim: true))
            }
            func block(_ title: String, _ entries: [ShareEntry]) {
                add(info(title, dim: true))
                if entries.isEmpty { add(info("  idle: no traffic in the window", dim: true)); return }
                for e in entries {
                    let name = e.label.padding(toLength: 16, withPad: " ", startingAt: 0)
                    let tok = e.tokens > 0 ? "  \(human(e.tokens)) tok" : ""
                    let sub = e.models.isEmpty ? "" : "  [\(e.models.joined(separator: ", "))]"
                    add(info("  \(name) \(String(format: "%3.0f%%", e.share * 100))  \(e.requests) req\(tok)\(sub)", mono: true))
                }
            }
            block("Models", shareEntries(share["models"]))
            block("Providers", shareEntries(share["providers"]))
        }

        // Charts
        if c.charts {
            menu.addItem(.separator())
            menu.addItem(chartItem(requestsChart(d)))
            let models = d["by_model"].arr.map { m -> Slice in
                let rr = m["reroutes"].int ?? 0
                let src = m["sources"].arr.compactMap { $0.str }.contains("transcript") ? "transcript" : ""
                let note = [rr > 0 ? "↪\(rr)" : "", src].filter { !$0.isEmpty }.joined(separator: " ")
                return Slice(label: m["model"].str ?? "?", count: m["requests"].int ?? 0, note: note)
            }
            menu.addItem(chartItem(stackedChart(title: "by model · last 1h", slices: models)))
            let proxies = d["by_proxy"].arr.map { p -> Slice in
                Slice(label: p["proxy"].str ?? "?", count: p["requests"].int ?? 0, note: p["source"].str == "transcript" ? "transcript" : "")
            }
            menu.addItem(chartItem(stackedChart(title: "by proxy · last 1h", slices: proxies)))
        }

        // Reroutes
        menu.addItem(.separator()); add(header("REROUTES (1h)"))
        let rr = d["reroutes"].arr
        if rr.isEmpty {
            add(info("none: every request served the model it asked for", dim: true))
        } else {
            var kinds: [String: Int] = [:]
            for r in rr { kinds[r["kind"].str ?? "?", default: 0] += r["count"].int ?? 0 }
            add(info(kinds.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · ") +
                     "  (alias = Claude name served by GLM/DeepSeek, vision = glm→deepseek, fallback = router retry)", dim: true))
            for r in rr.prefix(6) {
                add(info("\(r["from"].str ?? "?")→\(r["to"].str ?? "?") ×\(r["count"].int ?? 0) \(r["kind"].str ?? "")  [\(r["proxy"].str ?? "?")]", mono: true))
            }
        }

        // Copilot
        let cop = d["copilot"]
        if cop.exists {
            menu.addItem(.separator()); add(header("COPILOT-API (:4141) · TRANSCRIPT-DERIVED"))
            let m15 = cop["m15"], h1 = cop["h1"]
            func tok(_ c: J) -> String {
                let t = c["tokens"]
                return t.exists ? " · in \(human(t["in"].int ?? 0)) out \(human(t["out"].int ?? 0)) cache \(human(t["cache_read"].int ?? 0))" : ""
            }
            add(info("15m \(m15["requests"].int ?? 0) req\(tok(m15))"))
            add(info("1h  \(h1["requests"].int ?? 0) req\(tok(h1))"))
            let models = cop["models"].arr.map { "\($0["model"].str ?? "?") ×\($0["requests"].int ?? 0)" }
            if !models.isEmpty { add(info(models.joined(separator: " · "), dim: true)) }
            add(info("in flight: n/a (no usage callback)", dim: true))
            let q = cop["quota"]
            if q.exists {
                var line = "premium: "
                if q["unlimited"].bool { line += "unlimited" } else {
                    line += "\(q["remaining"].int ?? 0)/\(q["entitlement"].int ?? 0) left (\(q["percent_remaining"].int ?? 0)%)"
                }
                if let used = q["credits_used"].int, used > 0 { line += " · \(human(used)) credits used" }
                if (q["overage_count"].int ?? 0) > 0 { line += " · overage \(q["overage_count"].int ?? 0)" }
                if let reset = q["reset_date"].str { line += " · resets \(reset.prefix(10))" }
                add(info(line))
                add(info("quota from copilot-api /usage (GitHub); counts above are from transcripts, not Copilot's own meter", dim: true))
            } else {
                add(info("quota: unavailable · \(cop["quota_note"].str ?? "no /usage data")", dim: true))
            }
        }

        // Top models + last error
        if !c.charts {
            let top = d["top_models"].arr.map { "\($0["model"].str ?? "?") ×\($0["requests"].int ?? 0)" }
            if !top.isEmpty { menu.addItem(.separator()); add(info("Top models (1h): " + top.joined(separator: " · "))) }
        }
        menu.addItem(.separator())
        let le = d["last_error"]
        if le.exists {
            let msg = (le["message"].str ?? "").prefix(90)
            add(info("Last error \(longDuration(le["ago_s"].int ?? 0)) ago: \(le["proxy"].str ?? "?") \(le["status"].str ?? "?") \(le["model"].str ?? "") \(msg)"))
        } else {
            add(info("Last error: none logged", dim: true))
        }

        menu.addItem(.separator())
        addActions(menu, c, plainCopy: plain)
        return (menu, plain)
    }

    func addActions(_ menu: NSMenu, _ c: MenuContext, plainCopy: [String]?) {
        let le = c.data?["last_error"]
        menu.addItem(action("Open dashboard", #selector(AppController.openDashboard)))
        menu.addItem(action("Open logs folder", #selector(AppController.openLogs)))
        menu.addItem(action("Refresh now", #selector(AppController.refreshNow)))
        menu.addItem(action("Copy status", #selector(AppController.copyStatus)))
        if let le = le, le.exists {
            menu.addItem(action("Copy last error", #selector(AppController.copyText(_:)),
                                represented: "\(le["at"].str ?? "") \(le["proxy"].str ?? "") \(le["status"].str ?? "") \(le["model"].str ?? ""): \(le["message"].str ?? "")"))
        }
        menu.addItem(.separator())
        menu.addItem(action("Show charts", #selector(AppController.toggleCharts), state: c.charts))
        menu.addItem(action("Show logo image in menubar", #selector(AppController.toggleImage), state: c.showImage))
        menu.addItem(action("Show text next to the image", #selector(AppController.toggleText), state: c.showText))
        menu.addItem(action("Show 1h traffic window (off: 15m)", #selector(AppController.toggleWindow), state: c.shareWindow == "1h"))
        menu.addItem(action("Show tokens as traffic metric (off: requests)", #selector(AppController.toggleMetric), state: c.shareMetric == "tokens"))
        menu.addItem(action("Notifications (throttled / proxy down)", #selector(AppController.toggleNotifications), state: c.notifications))
        menu.addItem(info("Launch at login: \(c.launchAgentInstalled ? "on (LaunchAgent installed)" : "off (llm-usage menubar install)")", dim: true))
        menu.addItem(.separator())
        menu.addItem(action("Quit", #selector(AppController.quit)))
    }
}

func dump(_ menu: NSMenu, indent: String = "") {
    for item in menu.items {
        if item.isSeparatorItem { print("\(indent)---"); continue }
        let mark = item.state == .on ? "[x] " : (item.tag == 1 ? "[ ] " : "")
        print("\(indent)\(mark)\(item.title)")
        if let sub = item.submenu { dump(sub, indent: indent + "    ") }
    }
}

// MARK: - app

final class AppController: NSObject, NSMenuDelegate {
    let defaults = UserDefaults(suiteName: "com.kaovilai.llm-usage-menubar") ?? .standard
    var statusItem: NSStatusItem!
    var data: J?
    var lastGood: Date?
    var lastError: String?
    var polling = false
    var menuOpen = false
    var plainStatus: [String] = []
    // notification de-duplication
    var baselined = false
    var lastThrottleKey: String?
    var lastDown: Set<String> = []

    var charts: Bool { defaults.object(forKey: "charts") as? Bool ?? true }
    var notifications: Bool { defaults.object(forKey: "notifications") as? Bool ?? true }
    var showImage: Bool { defaults.object(forKey: "showImage") as? Bool ?? true }
    var showText: Bool { defaults.object(forKey: "showText") as? Bool ?? true }
    var shareWindow: String { defaults.string(forKey: "shareWindow") == "1h" ? "1h" : "15m" }
    var shareMetric: String { defaults.string(forKey: "shareMetric") == "tokens" ? "tokens" : "requests" }
    var appearanceObservation: NSKeyValueObservation?

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        render(title: Summary(glyph: "…", symbol: "ellipsis.circle", text: "", state: "loading"), stale: false)
        // light/dark menubar: the single-colour logos are drawn for one appearance, so redraw when it flips
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.tick() }
        }
        rebuildMenu()
        poll()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.poll() }
        // countdown in the title without hitting the CLI
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func context() -> MenuContext {
        MenuContext(data: data, now: Date(), refreshed: lastGood, stale: lastError != nil && data != nil, error: lastError,
                    charts: charts, notifications: notifications,
                    launchAgentInstalled: FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/com.kaovilai.llm-usage-menubar.plist"),
                    showImage: showImage, showText: showText, shareWindow: shareWindow, shareMetric: shareMetric)
    }

    func tick() {
        guard let d = data else { return }
        let c = context()
        let s = summarize(d, now: c.now, stale: c.stale)
        render(title: s, stale: c.stale)
        // the throttle expired: poll right away so the title returns to normal
        let th = d["throttled"]
        if th.exists, let reset = parseISO(th["reset_at"].str), reset <= c.now { poll() }
    }

    func render(title s: Summary, stale: Bool) {
        guard let button = statusItem.button else { return }
        if showImage, let d = data, d["share"].exists {
            let share = d["share"]
            let img = statusImage(models: shareEntries(share["models"]), providers: shareEntries(share["providers"]),
                                  badge: badgeColor(for: s.state), appearance: button.effectiveAppearance)
            let text = showText ? s.text : ""
            img.accessibilityDescription = "llm-usage \(s.state). " + shareDescription(share)
            button.image = img
            button.imagePosition = text.isEmpty ? .imageOnly : .imageLeading
            button.title = text.isEmpty ? "" : " " + text
            button.setAccessibilityLabel("llm-usage \(s.state). " + shareDescription(share))
            button.appearsDisabled = stale
            button.toolTip = "llm-usage: \(s.state)\n" + shareDescription(share)
            return
        }
        if let img = NSImage(systemSymbolName: s.symbol, accessibilityDescription: s.state) {
            img.isTemplate = true
            button.image = img
            button.imagePosition = s.text.isEmpty ? .imageOnly : .imageLeading
            button.title = s.text.isEmpty ? "" : " " + s.text
        } else {
            button.image = nil
            button.title = (s.glyph + " " + s.text).trimmingCharacters(in: .whitespaces)
        }
        button.appearsDisabled = stale  // greyed when the last poll failed
        button.toolTip = "llm-usage: \(s.state)"
    }

    func rebuildMenu() {
        let c = context()
        let builder = Builder(target: self)
        let (menu, plain) = builder.build(c)
        plainStatus = plain
        // reuse the status item's menu object so the delegate stays attached
        let target = statusItem.menu ?? NSMenu()
        target.removeAllItems()
        target.autoenablesItems = false
        for item in menu.items { menu.removeItem(item); target.addItem(item) }
        target.delegate = self
        statusItem.menu = target
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        rebuildMenu()  // fresh countdowns
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    func poll() {
        if polling { return }
        polling = true
        let args = ["menubar-data", "--share-window", shareWindow, "--share-metric", shareMetric]
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = runUsage(args).flatMap(parseJSON)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.polling = false
                switch result {
                case .success(let j):
                    self.data = j
                    self.lastGood = Date()
                    self.lastError = nil
                    self.notifyIfNeeded(j)
                case .failure(.message(let msg)):
                    self.lastError = msg
                }
                let c = self.context()
                if let d = self.data {
                    self.render(title: summarize(d, now: c.now, stale: c.stale), stale: c.stale)
                } else {
                    self.render(title: Summary(glyph: "?", symbol: "questionmark.circle", text: "", state: "error"), stale: true)
                }
                if !self.menuOpen { self.rebuildMenu() }
            }
        }
    }

    // One notification per transition; the first poll only sets the baseline so launching never spams.
    func notifyIfNeeded(_ d: J) {
        let th = d["throttled"]
        let throttleKey = th.exists ? "\(th["proxy"].str ?? "")|\(th["model"].str ?? "")|\(th["reset_at"].str ?? "")" : nil
        let down = Set(d["proxies"].arr.filter { $0["state"].str == "down" && $0["expected"].bool }.compactMap { $0["name"].str })
        if baselined && notifications {
            if let key = throttleKey, key != lastThrottleKey {
                notify(title: "LLM throttled: \(th["proxy"].str ?? "?")",
                       body: "\(th["model"].str ?? "?") \(th["kind"].str ?? "rate-limit") 429, resets in about \(longDuration(th["seconds_left"].int ?? 0)) (estimate)")
            }
            for name in down.subtracting(lastDown).sorted() {
                notify(title: "LLM proxy down", body: "\(name) stopped answering. Restart with its *-restart command.")
            }
        }
        lastThrottleKey = throttleKey
        lastDown = down
        baselined = true
    }

    func notify(title: String, body: String) {
        // An unbundled binary cannot use UNUserNotificationCenter; osascript needs no bundle.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "on run argv", "-e", "display notification (item 1 of argv) with title (item 2 of argv)", "-e", "end run", body, title]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: actions
    @objc func refreshNow() { poll() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func toggleCharts() { defaults.set(!charts, forKey: "charts"); rebuildMenu() }
    @objc func toggleNotifications() { defaults.set(!notifications, forKey: "notifications"); rebuildMenu() }
    @objc func toggleImage() { defaults.set(!showImage, forKey: "showImage"); refreshDisplay() }
    @objc func toggleText() { defaults.set(!showText, forKey: "showText"); refreshDisplay() }
    @objc func toggleWindow() { defaults.set(shareWindow == "1h" ? "15m" : "1h", forKey: "shareWindow"); poll(); refreshDisplay() }
    @objc func toggleMetric() { defaults.set(shareMetric == "tokens" ? "requests" : "tokens", forKey: "shareMetric"); poll(); refreshDisplay() }

    func refreshDisplay() {
        if let d = data { let c = context(); render(title: summarize(d, now: c.now, stale: c.stale), stale: c.stale) }
        rebuildMenu()
    }

    @objc func copyText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        copy(text)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func copyStatus() { copy(plainStatus.joined(separator: "\n")) }

    @objc func openLogs() {
        let dir = data?["log_dir"].str ?? (ProcessInfo.processInfo.environment["LLM_USAGE_DIR"] ?? NSHomeDirectory() + "/.local/state/llm-usage")
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    @objc func openDashboard() {
        let port = data?["dashboard_port"].int ?? Int(ProcessInfo.processInfo.environment["LLM_USAGE_PORT"] ?? "") ?? 4150
        DispatchQueue.global().async {
            if !isListening(port: port), let bin = findUsageBinary() {
                // detached so the dashboard outlives menu interactions; same host/port rules as `llm-usage serve`
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", "nohup \"$0\" serve --port \"$1\" >/dev/null 2>&1 &", bin, String(port)]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                for _ in 0..<40 { if isListening(port: port) { break }; Thread.sleep(forTimeInterval: 0.15) }
            }
            DispatchQueue.main.async { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(port)/")!) }
        }
    }
}

func isListening(port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    return r == 0
}

// MARK: - single instance

func acquireSingleInstanceLock() -> Bool {
    let state = ProcessInfo.processInfo.environment["LLM_USAGE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        ?? (ProcessInfo.processInfo.environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.local/state") + "/llm-usage"
    try? FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let fd = open(state + "/menubar.lock", O_RDWR | O_CREAT, 0o600)
    if fd < 0 { return true }  // cannot lock: run anyway
    if flock(fd, LOCK_EX | LOCK_NB) != 0 { return false }
    ftruncate(fd, 0)
    let pid = "\(getpid())\n"
    _ = pid.withCString { write(fd, $0, strlen($0)) }
    return true  // fd stays open for the life of the process, holding the lock
}

// MARK: - entry point

let args = Array(CommandLine.arguments.dropFirst())

func loadSource() -> Result<J, PollError> {
    if let i = args.firstIndex(of: "--data-file"), i + 1 < args.count {
        let path = args[i + 1]
        let data = path == "-" ? FileHandle.standardInput.readDataToEndOfFile() : (FileManager.default.contents(atPath: path) ?? Data())
        return parseJSON(data)
    }
    return runUsage(["menubar-data"]).flatMap(parseJSON)
}

if args.contains("--list-logos") {
    _ = NSApplication.shared
    listLogos()
    exit(0)
}

if let i = args.firstIndex(of: "--status-png"), i + 1 < args.count {
    _ = NSApplication.shared
    guard case .success(let j) = loadSource() else { FileHandle.standardError.write("status-png: no usable data\n".data(using: .utf8)!); exit(1) }
    let now = parseISO(j["generated_at"].str) ?? Date()
    writeStatusPNG(j, summary: summarize(j, now: now, stale: false), dark: args.contains("--dark"), showText: !args.contains("--no-text"), to: args[i + 1])
    exit(0)
}

if args.contains("--dump-menu") {
    _ = NSApplication.shared
    let source = loadSource()
    var ctx = MenuContext(data: nil, now: Date(), refreshed: nil, stale: false, error: nil, charts: !args.contains("--no-charts"),
                          notifications: true, launchAgentInstalled: false)
    switch source {
    case .success(let j):
        ctx.data = j
        ctx.now = parseISO(j["generated_at"].str) ?? Date()  // countdowns relative to the data, so fixtures are stable
        ctx.refreshed = ctx.now
        ctx.shareWindow = j["share"]["window"].str ?? "15m"  // the data was computed for these: the toggles show them
        ctx.shareMetric = j["share"]["metric_requested"].str ?? j["share"]["metric"].str ?? "requests"
        ctx.showImage = !args.contains("--no-image")
        ctx.showText = !args.contains("--no-text")
    case .failure(.message(let m)): ctx.error = m
    }
    let builder = Builder(target: nil)
    let (menu, _) = builder.build(ctx)
    if let d = ctx.data {
        let s = summarize(d, now: ctx.now, stale: false)
        print("title: \((s.glyph + " " + s.text).trimmingCharacters(in: .whitespaces))")
    } else {
        print("title: ?")
    }
    dump(menu)
    if let i = args.firstIndex(of: "--chart-png"), i + 1 < args.count { writePNG(builder.chartImages, to: args[i + 1]) }
    exit(ctx.data == nil ? 1 : 0)
}

if !acquireSingleInstanceLock() {
    FileHandle.standardError.write("llm-usage-menubar: already running\n".data(using: .utf8)!)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menubar only: no Dock icon, no app menu
let controller = AppController()
controller.start()
app.run()
