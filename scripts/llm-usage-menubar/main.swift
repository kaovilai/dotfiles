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
//   --window-png PATH [--dark] [--layout horizontal|vertical|history] [--size WxH] [--graph bars|lines|both] [--stale]
//                                      [--hover vendor:<key>|provider:<key>|host:<name>|port:<n>] [--window-metric requests|tokens]
//                                      [--graph-hover MINUTE]  pin the graph hover readout to minute MINUTE (0 = oldest)
//                                      render the floating monitor window content to PNG (@2x) from --data-file
//   --dump-menu also takes --window-visible --window-layout L --window-graph G --window-metric M --chart-metric M --window-opacity N --window-click-through
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

// shared formatters: allocating one per call showed up as a large share of
// per-draw cost (2026-11-06 audit); both are main-thread only
private let isoFormatter = ISO8601DateFormatter()
private let clockFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

func parseISO(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    return isoFormatter.date(from: s)
}

func clock(_ d: Date) -> String {
    return clockFormatter.string(from: d)
}

/// "14:02" today, "Nov 1 00:00" otherwise.
func shortStamp(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "MMM d HH:mm"
    return f.string(from: d)
}

func pct(_ x: Double?) -> String { String(format: "%.0f%%", (x ?? 0) * 100) }

let restartCommands: [Int: String] = [
    4141: "claude-copilot-restart", 4142: "claude-vertex-restart", 4144: "claude-mlx-restart", 4145: "claude-openai-restart",
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
func requestsChart(_ d: J, metric: ChartMetric = .requests) -> (NSImage, String) {
    let s = d["series"]
    let req = s["requests"].arr.map { $0.int ?? 0 }
    let e429 = s["e429"].arr.map { $0.int ?? 0 }
    let e5 = s["e5xx"].arr.map { $0.int ?? 0 }
    let eo = s["eother"].arr.map { $0.int ?? 0 }
    let n = req.count
    let total = req.reduce(0, +)
    // Same per-vendor split and colours as the floating window, so both charts read alike.
    let bv = metric == .tokens ? s["tps_by_vendor"] : s["by_vendor"]
    let vendors: [(String, [Double])] = bv.exists
        ? bv.keys.map { k in (k, bv[k].arr.map { metric == .tokens ? ($0.dbl ?? 0) : Double($0.int ?? 0) }) }
            .sorted { ($0.1.reduce(0, +), $1.0) > ($1.1.reduce(0, +), $0.0) }
        : []
    let durVals = metric.isDuration
        ? (metric == .ttft ? s["ttft"].arr.map { $0.dbl ?? 0 } : s["latency"].arr.map { $0.dbl ?? 0 })
        : []
    let peak: Double = metric.isDuration
        ? max(durVals.max() ?? 0, 1)
        : max(metric == .tokens ? (s["tps"].arr.map { $0.dbl ?? 0 }.max() ?? 0) : Double(req.max() ?? 0), metric == .tokens ? 0.1 : 1)
    let peakText = metric.isDuration ? compactMs(peak) : (metric == .tokens ? compactRate(peak) : String(Int(peak)))
    let title = metric.isDuration ? (metric == .ttft ? "ttft p50" : "latency p50") : (metric == .tokens ? "tok/s" : "requests/min")
    let alt = metric.isDuration
        ? "\(title), last 60m: peak \(peakText), \(total) requests"
        : (metric == .tokens
            ? "tokens/s, last 60m: peak \(peakText)/s, \(total) requests, 429 \(e429.reduce(0, +)), 5xx \(e5.reduce(0, +)), other \(eo.reduce(0, +))"
            : "requests/min, last 60m: \(total) total, peak \(Int(peak))/min, 429 \(e429.reduce(0, +)), 5xx \(e5.reduce(0, +)), other \(eo.reduce(0, +))")
    let image = chartImage(height: 62) { rect in
        drawText("\(title) · last 60m · peak \(peakText)", at: NSPoint(x: 0, y: rect.height - 12))
        guard n > 0 else { drawText("no data", at: NSPoint(x: 0, y: 20)); return }
        let area = NSRect(x: 0, y: 2, width: rect.width, height: rect.height - 16)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 1, width: rect.width, height: 1).fill()
        let slot = area.width / CGFloat(n)
        let scale = (area.height - 1) / CGFloat(peak)
        if metric.isDuration {
            // one dot per sampled minute: gaps stay gaps, density reads directly
            let r = min(max(slot * 0.32, 1.3), 2.6)
            for (i, v) in durVals.enumerated() where i < n && v > 0 {
                let pt = NSPoint(x: area.minX + (CGFloat(i) + 0.5) * slot, y: area.minY + 0.5 + CGFloat(v) * scale)
                NSColor.systemBlue.setFill()
                NSBezierPath(roundedRect: NSRect(x: pt.x - r, y: pt.y - r, width: 2 * r, height: 2 * r), xRadius: r, yRadius: r).fill()
            }
            return
        }
        for i in 0..<n {
            let x = area.minX + CGFloat(i) * slot
            let w = max(slot - 1, 1)
            let a = i < e429.count ? e429[i] : 0
            let r5 = (i < e5.count ? e5[i] : 0) + (i < eo.count ? eo[i] : 0)
            var y = area.minY
            if vendors.isEmpty {
                let success = metric == .tokens ? 0 : max(req[i] - a - r5, 0)
                if success > 0 {
                    let h = max(CGFloat(success) * scale, 1)
                    NSColor.systemBlue.setFill()
                    NSRect(x: x, y: y, width: w, height: h).fill()
                    y += h
                }
            } else {
                for (key, values) in vendors where i < values.count && values[i] > 0 {
                    let h = max(CGFloat(values[i]) * scale, 1)
                    vendorColor(key).setFill()
                    NSRect(x: x, y: y, width: w, height: h).fill()
                    y += h
                }
            }
            // errors are a thin cap on the bar, the same language as the floating window
            if a + r5 > 0 {
                (r5 > 0 ? NSColor.systemRed : NSColor.systemOrange).setFill()
                NSRect(x: x, y: min(y + 0.5, area.maxY - 2), width: w, height: 2).fill()
            }
        }
    }
    return (image, alt)
}

struct Slice { let label: String; let count: Int; let note: String; let color: NSColor }

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
        for sl in slices {
            let w = rect.width * CGFloat(sl.count) / CGFloat(total)
            sl.color.setFill()
            NSRect(x: x, y: barY, width: max(w - 1, 1), height: 10).fill()
            x += w
        }
        for (i, sl) in slices.prefix(rows).enumerated() {
            let y = barY - 14 - CGFloat(i) * 13
            sl.color.setFill()
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
    LogoSpec(key: "qwen", label: "Qwen", bundleIds: [], monogram: "Q", brand: rgb(0x615CED)),
    LogoSpec(key: "github-copilot", label: "GitHub Copilot", bundleIds: ["com.github.githubapp"], monogram: "Co", brand: rgb(0x6E40C9)),
    LogoSpec(key: "vertex", label: "Vertex AI", bundleIds: [], monogram: "V", brand: rgb(0x4285F4)),
    LogoSpec(key: "mlx", label: "MLX (local)", bundleIds: [], monogram: "M", brand: rgb(0x5E5CE6)),
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

// MARK: - floating monitor window (Activity Monitor style: always-on-top, all Spaces, history graph + live numbers)

enum MonitorLayout: String, CaseIterable {
    case horizontal, vertical, history
    var title: String {
        switch self { case .horizontal: return "Horizontal"; case .vertical: return "Vertical"; case .history: return "History" }
    }
    var defaultSize: NSSize {
        switch self { case .horizontal: return NSSize(width: 250, height: 132); case .vertical: return NSSize(width: 150, height: 330); case .history: return NSSize(width: 230, height: 90) }
    }
    var minSize: NSSize {
        switch self { case .horizontal: return NSSize(width: 200, height: 104); case .vertical: return NSSize(width: 110, height: 220); case .history: return NSSize(width: 110, height: 52) }
    }
}

/// What the history graph draws: bars = requests per minute stacked by model vendor, lines = one rate line per provider.
enum GraphMode: String, CaseIterable {
    case bars, lines, both
    var title: String {
        switch self { case .bars: return "Bars = models"; case .lines: return "Lines = providers"; case .both: return "Both" }
    }
}

/// What the graph plots per minute: request count or completion tokens per second.
enum ChartMetric: String, CaseIterable {
    case requests, tokens, latency, ttft, all
    var title: String {
        switch self {
        case .requests: return "Requests/min"
        case .tokens: return "Tokens/s"
        case .latency: return "Latency p50"
        case .ttft: return "TTFT p50"
        case .all: return "All three"
        }
    }
    var isDuration: Bool { self == .latency || self == .ttft }
    var isStacked: Bool { self == .all }
}

func dynamicColor(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
}

/// Bar colours per model vendor. Claude/GPT/GLM follow the logo brand colours; DeepSeek and Gemini are moved off their
/// (blue) brand colours so the three stay apart from GLM at a glance.
let vendorChartColors: [String: NSColor] = [
    "claude": rgb(0xD97757), "openai": rgb(0x10A37F), "glm": rgb(0x3556E8), "deepseek": rgb(0x9B5DE5), "gemini": rgb(0x1AA6B7), "qwen": rgb(0x615CED), "other": rgb(0x8E8E93),
]
func vendorColor(_ key: String) -> NSColor { vendorChartColors[key] ?? vendorChartColors["other"]! }

/// Vendor key for a raw model string (same patterns and order as llm-usage's
/// MODEL_VENDORS), for data that arrives without the server's "vendor" field:
/// the in-flight bars read the proxies' files in-process and only know the model.
func vendorKey(forModel model: String) -> String {
    let m = model.lowercased()
    let rules: [(String, String)] = [
        ("claude", "opus|sonnet|haiku|fable|claude"),
        ("openai", "gpt|luna|codex|openai|^o[134](-|$)"),
        ("glm", "glm|zai"),
        ("deepseek", "deepseek"),
        ("gemini", "gemini"),
        ("qwen", "qwen"),
    ]
    for (key, pattern) in rules where m.range(of: pattern, options: .regularExpression) != nil { return key }
    return "other"
}

/// Line and throttle-ribbon colours per provider. Chosen to stay off the bar hues: lines are drawn over the bars.
func providerColor(_ key: String) -> NSColor {
    switch key {
    case "github-copilot": return dynamicColor(light: NSColor(white: 0.36, alpha: 1), dark: NSColor(white: 0.97, alpha: 1))  // white on dark, grey on light
    case "enmaas": return rgb(0xE5322D)
    case "vertex": return rgb(0xE84393)
    case "openai": return rgb(0x10A37F)
    case "anthropic": return rgb(0xC2410C)
    case "mlx": return rgb(0x5E5CE6)
    default:
        let palette = [rgb(0xF2B01E), rgb(0x00B8D4), rgb(0xA1887F), rgb(0x66BB6A)]
        return palette[Int(key.utf8.reduce(UInt32(7)) { $0 &* 31 &+ UInt32($1) } % UInt32(palette.count))]
    }
}

let amber429 = rgb(0xFFB000)

struct SpanItem {
    let provider: String, label: String, kind: String
    let start: Date, end: Date
    let endEstimated: Bool, startEstimated: Bool
    let count: Int
    let source: String, basis: String, resetSource: String?
}

struct ProviderSeries { let key: String; let label: String; let values: [Int]; let tps: [Double]; let latency: [Double]; let ttft: [Double] }
struct DriftItem { let kind: String; let detail: String; let hint: String; let count: Int; let proxy: String }

func spanItems(_ d: J) -> [SpanItem] {
    d["throttle_spans"].arr.compactMap { s in
        guard let a = parseISO(s["start"].str), let b = parseISO(s["end"].str) else { return nil }
        let key = s["provider"].str ?? "other"
        return SpanItem(provider: key, label: s["label"].str ?? key, kind: s["kind"].str ?? "rate-limit", start: a, end: b,
                        endEstimated: s["end_estimated"].exists ? s["end_estimated"].bool : true, startEstimated: s["start_estimated"].bool,
                        count: s["count"].int ?? 1, source: s["source"].str ?? "proxy-log", basis: s["basis"].str ?? "", resetSource: s["reset_source"].str)
    }
}

func providerSeries(_ d: J) -> [ProviderSeries] {
    d["series_by_provider"]["providers"].arr.compactMap { p in
        guard let key = p["key"].str else { return nil }
        return ProviderSeries(key: key, label: p["label"].str ?? key, values: p["requests"].arr.map { $0.int ?? 0 },
                              tps: p["tps"].arr.map { $0.dbl ?? 0 },
                              latency: p["latency"].arr.map { $0.dbl ?? 0 },
                              ttft: p["ttft"].arr.map { $0.dbl ?? 0 })
    }
}

func driftItems(_ d: J) -> [DriftItem] {
    d["drift"].arr.compactMap { r in
        guard let hint = r["hint"].str, !hint.isEmpty else { return nil }
        return DriftItem(kind: r["kind"].str ?? "?", detail: r["detail"].str ?? "", hint: hint, count: r["count"].int ?? 1, proxy: r["proxy"].str ?? "")
    }
}

let bodyFont = NSFont.systemFont(ofSize: 10)
let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
let tinyFont = NSFont.systemFont(ofSize: 8.5)
let boldFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)

func drawStr(_ s: String, in rect: NSRect, font: NSFont = bodyFont, color: NSColor = .labelColor, align: NSTextAlignment = .left) {
    let ps = NSMutableParagraphStyle()
    ps.lineBreakMode = .byTruncatingTail
    ps.alignment = align
    (s as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: ps])
}

/// Narrow-column label ("GitHub Copilot" would truncate everywhere).
func shortLabel(_ key: String, _ label: String) -> String { key == "github-copilot" ? "Copilot" : (key == "vertex" ? "Vertex" : label) }

func textWidth(_ s: String, _ font: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) }

/// Wait bar: empty until the oldest in-flight request has waited waitBarStartS, full at waitBarFullS; green -> yellow -> red as it fills.
let waitBarStartS = 2.0, waitBarFullS = 10.0
func waitFraction(_ seconds: Double) -> CGFloat { CGFloat(min(max((seconds - waitBarStartS) / (waitBarFullS - waitBarStartS), 0), 1)) }
func waitColor(_ f: CGFloat) -> NSColor {
    NSColor(hue: 0.33 * (1 - f), saturation: 0.85, brightness: 0.9, alpha: 1)  // hue 0.33 = green, 0 = red (passing through yellow)
}
func drawWaitBar(_ r: NSRect, fraction f: CGFloat) {
    guard r.width >= 8 else { return }
    let track = NSRect(x: r.minX, y: r.midY - 2.5, width: r.width, height: 5)
    NSColor.quaternaryLabelColor.setFill()
    NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
    guard f > 0 else { return }
    waitColor(f).setFill()
    NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: max(track.width * f, 5), height: track.height), xRadius: 2.5, yRadius: 2.5).fill()
}

func compactRate(_ v: Double) -> String { v >= 10 ? String(Int(v.rounded())) : String(format: "%.1f", v) }

func compactMs(_ ms: Double) -> String { ms >= 1000 ? String(format: "%.1fs", ms / 1000) : String(format: "%.0fms", ms) }

/// The animated in-flight strip: its own layer-backed view so a 20 Hz needle
/// repaints a few dozen pixels instead of the whole panel (charts included).
final class FlightBarsView: NSView {
    var fractions: [(id: String, fraction: CGFloat, vendor: String)] = [] {
        didSet {
            if fractions.count != oldValue.count || fractions.contains(where: { pair in
                !oldValue.contains { $0.id == pair.id && $0.fraction == pair.fraction }
            }) { needsDisplay = true }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    /// One thin bar per in-flight request, oldest at the bottom: a new request
    /// adds a bar on top while older ones are unfinished, each with its own
    /// length and colour for its own age.
    override func draw(_ dirty: NSRect) {
        let rows = max(1, Int((bounds.height + 1) / 3))
        let shown = Array(fractions.prefix(rows))  // fractions[0] is the oldest: keep the ones most likely to matter
        let h: CGFloat = 2, gap: CGFloat = 1
        var y = bounds.midY - (CGFloat(shown.count) * (h + gap) - gap) / 2
        for bar in shown {
            let track = NSRect(x: bounds.minX, y: y, width: bounds.width, height: h)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()
            vendorColor(bar.vendor).setFill()  // the model's color for the bar's whole life; length is the elapsed time
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: y, width: max(track.width * bar.fraction, 3), height: h), xRadius: h / 2, yRadius: h / 2).fill()
            y += h + gap
        }
    }
}

/// One live in-flight request (see llm-usage read_inflight): id is stable for
/// the request's whole life, seconds is its age at the sample.
struct Flight { let id: String; let model: String; let seconds: Double }

final class MonitorView: NSView {
    var data: J? {
        didSet {
            waitDataAt = Date()
            if waitFirstData {  // headless renders get sane bars without a running timer
                waitFirstData = false
                if flights.isEmpty, let rows = data?["inflight"]["requests"].arr, !rows.isEmpty {
                    flights = rows.compactMap { row in
                        guard let id = row["id"].str else { return nil }
                        return Flight(id: id, model: row["model"].str ?? "", seconds: row["seconds"].dbl ?? 0)
                    }
                    flightsAt = waitDataAt
                }
                waitNeedle = waitTarget(at: waitDataAt ?? Date())
                for f in flights { barShown[f.id] = waitTarget(at: waitDataAt ?? Date(), for: f); barVendor[f.id] = vendorKey(forModel: f.model) }
            }
            needsDisplay = true
        }
    }
    var now = Date()

    // Tachometer bars, one per in-flight request: a bar rises in real time
    // while its request runs, eases down (no snap) when that request finishes,
    // and bars stack upward as new requests arrive while older ones are still
    // unfinished. The aggregate needle (oldest request) stays for the compact
    // overlay pill.
    let barsView = FlightBarsView(frame: .zero)
    var flights: [Flight] = [] {
        didSet {
            flightsAt = Date()
            barsView.needsDisplay = true
            if !flights.isEmpty { startWaitAnimation() }  // a bar appeared: resume the needle timer
            // the row positions the strip during a panel draw, so the panel must
            // repaint when the strip row appears or disappears; an id change
            // alone only swaps bars inside the strip, which needsDisplay above
            // already covers (2026-11-06 audit: whole-panel redraw per request
            // start/end was ~20% of the app's draw cost)
            let was = !oldValue.isEmpty || !barShown.isEmpty || waitNeedle > 0.001
            if waitBarVisible != was { needsDisplay = true }
        }
    }
    private var flightsAt: Date?
    private var barShown: [String: CGFloat] = [:]
    private var barVendor: [String: String] = [:]  // id -> vendor key, kept until the bar has drained
    private var waitNeedle: CGFloat = 0
    private var waitTick: Date?
    private var waitDataAt: Date?
    private var waitFirstData = true
    private var waitTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(barsView)
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addSubview(barsView)
    }

    func startWaitAnimation() {
        guard waitTimer == nil else { return }
        waitTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 10.0, repeats: true) { [weak self] _ in self?.tickWait() }
        if let t = waitTimer { RunLoop.main.add(t, forMode: .common) }  // keep moving while a menu tracks
    }

    private func waitTarget(at t: Date, for f: Flight? = nil) -> CGFloat {
        if let f {
            return waitFraction(f.seconds + t.timeIntervalSince(flightsAt ?? t))
        }
        guard let oldest = flights.map({ $0.seconds + t.timeIntervalSince(flightsAt ?? t) }).max() else { return 0 }
        return waitFraction(oldest)
    }

    private func tickWait(_ t: Date = Date()) {
        let dt = min(max(t.timeIntervalSince(waitTick ?? t), 0), 0.5)
        waitTick = t
        var moved = false, barsMoved = false
        // per-request bars: present -> rise toward its age; gone -> drain out
        let live = Set(flights.map { $0.id })
        for f in flights {
            barVendor[f.id] = vendorKey(forModel: f.model)
            let target = waitTarget(at: t, for: f)
            let shown = barShown[f.id] ?? 0
            let next = shown + (target - shown) * CGFloat(1 - exp(-dt / 0.25))
            if next > 0.0015 { barShown[f.id] = next; barsMoved = barsMoved || abs(next - shown) > 0.0015 }
            else { barShown[f.id] = target > 0 ? target : 0 }
        }
        for (id, shown) in barShown where !live.contains(id) {
            let next = shown * CGFloat(exp(-dt / 0.4))
            if next > 0.01 { barShown[id] = next } else { barShown.removeValue(forKey: id); barVendor.removeValue(forKey: id) }
            barsMoved = true
        }
        // aggregate needle for the overlay pill (drawn with the rest of the
        // panel on data changes; the strip below carries the live motion)
        let target = waitTarget(at: t)
        let tau: Double = target >= waitNeedle ? 0.25 : 0.4
        let next = waitNeedle + (target - waitNeedle) * CGFloat(1 - exp(-dt / tau))
        waitNeedle = abs(next - waitNeedle) > 0.0015 ? next : target
        if moved || barsMoved {
            barsView.fractions = flightBars
        }
        // nothing live and every bar drained: park the timer until a bar appears
        if flights.isEmpty && barShown.isEmpty {
            waitTimer?.invalidate()
            waitTimer = nil
        }
    }

    /// Bars stay visible while they drain, not just while requests are live.
    var waitBarVisible: Bool { waitNeedle > 0.001 || !flights.isEmpty || !barShown.isEmpty }
    /// Bar values to draw, oldest request at the bottom (stack grows upward).
    var flightBars: [(id: String, fraction: CGFloat, vendor: String)] {
        var rows = barShown.filter { $0.value > 0.001 }.map { (id: $0.key, fraction: $0.value, vendor: barVendor[$0.key] ?? "other") }
        let order = flights.map { $0.id }
        rows.sort { a, b in
            let ia = order.firstIndex(of: a.id) ?? Int.max
            let ib = order.firstIndex(of: b.id) ?? Int.max
            return ia > ib  // flights[] is oldest-first, so draw newest first => oldest ends up at the bottom
        }
        return rows
    }
    var stale = false
    var layout: MonitorLayout = .horizontal { didSet { needsDisplay = true } }
    var graphMode: GraphMode = .both { didSet { needsDisplay = true } }
    var metric: ChartMetric = .requests { didSet { needsDisplay = true } }
    var drawsBackground = false  // the panel has its own material; the headless PNG render needs a fill
    var onCopyHint: ((String) -> Void)?
    var onToggleMetric: (() -> Void)?
    private var hintHit: (NSRect, String)?
    private var metricHit: NSRect?
    private var hoverMetric = false
    enum HoverTarget: Equatable { case vendor(String), provider(String), host(String) }
    private var hover: HoverTarget?
    private var hoverRects: [(NSRect, HoverTarget)] = []
    private var hoverTracking: NSTrackingArea?
    // Proxy dots (bottom of the stats column): hovering a port label swaps it for
    // the proxy's name. Hits are collected during draw, like hoverRects.
    private var portHits: [(rect: NSRect, port: Int, name: String)] = []
    private var hoverPort: Int?
    /// Headless PNG renders pin the port-label hover.
    var debugPortHover: Int?
    // Graph hover: the minute under the mouse gets a crosshair on every graph and a readout of that minute.
    private var graphHits: [(rect: NSRect, metric: ChartMetric)] = []
    private var graphModelCache: (key: String, model: GraphModel)?
    /// per-host 60-minute request series from the payload (fleet strip hover);
    /// refreshed alongside the graph model cache in draw()
    private var hostSeries: [String: [Int]] = [:]
    private var graphCursor: (graph: Int, minute: Int, x: CGFloat)?
    private var graphMinutes = 60
    /// Headless PNG renders pin the graph cursor to a minute index (0 = oldest).
    var debugGraphMinute: Int?

    override var isOpaque: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let r = metricHit, r.contains(p) { onToggleMetric?() }
        else if let (r, hint) = hintHit, r.contains(p) { onCopyHint?(hint) }
        else { super.mouseDown(with: event) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) { updateHover(convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { updateHover(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { updateHover(nil) }

    private func updateHover(_ point: NSPoint?) {
        updateGraphCursor(point)
        let next = point.flatMap { p in hoverRects.first { $0.0.contains(p) }?.1 }
        // proxy dots: hovering a port label swaps in the proxy's name; the native
        // tooltip carries both, since the swap hides the port number
        let port = point.flatMap { p in portHits.first { $0.rect.contains(p) } }
        if hoverPort != port?.port {
            hoverPort = port?.port
            needsDisplay = true
        }
        toolTip = port.map { "\($0.name) · :\($0.port)" }
        let overCaption = point.map { metricHit?.contains($0) ?? false } ?? false
        if overCaption != hoverMetric {
            hoverMetric = overCaption
            hoverMetric ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
            needsDisplay = true
        }
        if next != hover {
            hover = next
            needsDisplay = true
        }
    }

    private func updateGraphCursor(_ point: NSPoint?) {
        var next: (graph: Int, minute: Int, x: CGFloat)?
        if let p = point, let gi = graphHits.firstIndex(where: { $0.rect.contains(p) }) {
            let r = graphHits[gi].rect
            let minute = min(max(Int((p.x - r.minX) / (r.width / CGFloat(graphMinutes))), 0), graphMinutes - 1)
            next = (gi, minute, p.x)
        }
        // Redraw only when the minute (or graph) changes, not on every pixel of movement.
        if next?.graph != graphCursor?.graph || next?.minute != graphCursor?.minute {
            graphCursor = next
            needsDisplay = true
        } else if let next {
            graphCursor = next
        }
    }

    /// A host hover only filters the requests chart — on other metrics there is no
    /// host series, so every graph/share-row hover effect (dimming, chart chrome,
    /// overlays) treats it as no hover. The fleet row's own highlight still uses
    /// `hover` directly: it is row-local mouse feedback, not a graph filter.
    private var effectiveHover: HoverTarget? {
        if case .host = hover, metric != .requests { return nil }
        return hover
    }

    /// 1 for the hovered series, dimmed for everything else, unchanged when nothing is hovered.
    private func hoverAlpha(_ target: HoverTarget) -> CGFloat {
        guard let h = effectiveHover else { return 1 }
        return h == target ? 1 : 0.12
    }

    /// Headless PNG renders pin a hover: "vendor:<key>", "provider:<key>",
    /// "host:<name>" or "port:<n>" (the proxy-dot label swap).
    func setDebugHover(_ spec: String?) {
        hover = nil
        debugPortHover = nil
        switch spec {
        case let s? where s.hasPrefix("vendor:"): hover = .vendor(String(s.dropFirst(7)))
        case let s? where s.hasPrefix("provider:"): hover = .provider(String(s.dropFirst(9)))
        case let s? where s.hasPrefix("host:"): hover = .host(String(s.dropFirst(5)))
        case let s? where s.hasPrefix("port:"): debugPortHover = Int(s.dropFirst(5))
        default: break
        }
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        if drawsBackground { NSColor.windowBackgroundColor.setFill(); b.fill() }
        hintHit = nil
        metricHit = nil
        hoverRects = []
        portHits = []
        graphHits = []
        guard let d = data else {
            drawStr("waiting for data…", in: NSRect(x: 0, y: b.midY - 7, width: b.width, height: 14), color: .secondaryLabelColor, align: .center)
            return
        }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if stale { ctx.setAlpha(0.6) }  // last poll failed: dim, keep the last good numbers

        var summary = summarize(d, now: now, stale: stale)
        let spans = spanItems(d)
        let drifts = driftItems(d)
        // GraphModel(d) walks the whole 60-minute series; the payload only
        // changes on a poll (30 s), so cache it instead of rebuilding per draw
        let modelKey = d["generated_at"].str ?? ""
        if graphModelCache?.key != modelKey {
            graphModelCache = (modelKey, GraphModel(d))
            hostSeries = [:]
            for h in d["fleet"]["hosts"].arr {
                if let n = h["name"].str { hostSeries[n] = h["series"].arr.map { $0.int ?? 0 } }
            }
        }
        let model = graphModelCache!.model
        let live = spans.filter { $0.end > now }
        if summary.state == "normal" && !live.isEmpty { summary.state = "throttled" }  // e.g. Copilot: only its span says so
        var area = layout == .history ? b.insetBy(dx: 4, dy: 4) : b.insetBy(dx: 8, dy: 6)

        if layout != .history, let top = drifts.first {  // provider changed shape: say what to update; click copies the hint
            let r = NSRect(x: area.minX, y: area.minY, width: area.width, height: 12)
            let amber = dynamicColor(light: rgb(0x9A6700), dark: rgb(0xFFD60A))
            drawStr("⚠ code needs updating: \(top.hint)", in: r, font: NSFont.systemFont(ofSize: 9, weight: .medium), color: amber)
            hintHit = (r, top.hint)
            area.origin.y += 15
            area.size.height -= 15
        }

        switch layout {
        case .history:
            drawGraph(ctx, rect: area, model: model, spans: spans, metric: metric.isStacked ? .tokens : metric)
            drawOverlay(summary: summary, live: live, d: d, in: area)
        case .horizontal, .vertical:
            let header = NSRect(x: area.minX, y: area.maxY - 14, width: area.width, height: 14)
            drawHeader(ctx, summary: summary, live: live, d: d, in: header)
            let body = NSRect(x: area.minX, y: area.minY, width: area.width, height: area.height - 17)
            var graphCol: NSRect, stats: NSRect
            if layout == .horizontal {
                let sw = min(max(body.width * 0.42, 88), 150)
                graphCol = NSRect(x: body.minX, y: body.minY, width: body.width - sw - 8, height: body.height)
                stats = NSRect(x: body.maxX - sw, y: body.minY, width: sw, height: body.height)
            } else {
                let gh = min(max(body.height * 0.34, 74), 140)
                graphCol = NSRect(x: body.minX, y: body.maxY - gh, width: body.width, height: gh)
                stats = NSRect(x: body.minX, y: body.minY, width: body.width, height: body.height - gh - 6)
            }
            drawGraphColumn(ctx, rect: graphCol, model: model, spans: spans, d: d)
            drawStats(ctx, rect: stats, d: d, spans: spans)
        }
        graphMinutes = model.n
        drawGraphReadout(model: model, spans: spans, bounds: b)
    }

    // MARK: graph hover readout

    func vendorName(_ key: String) -> String {
        ["claude": "Claude", "openai": "GPT", "glm": "GLM", "deepseek": "DeepSeek", "gemini": "Gemini", "other": "Other"][key] ?? key
    }

    /// Crosshair on every graph at the hovered minute, plus a readout box for that minute next to the mouse.
    func drawGraphReadout(model: GraphModel, spans: [SpanItem], bounds b: NSRect) {
        let cursor: (graph: Int, minute: Int, x: CGFloat)
        if let c = graphCursor, c.graph < graphHits.count {
            cursor = c
        } else if let m = debugGraphMinute, !graphHits.isEmpty {
            let r = graphHits[0].rect
            let i = min(max(m, 0), model.n - 1)
            cursor = (0, i, r.minX + (CGFloat(i) + 0.5) * r.width / CGFloat(model.n))
        } else {
            return
        }
        let i = cursor.minute
        func at<T>(_ a: [T], _ zero: T) -> T { i < a.count ? a[i] : zero }

        for hit in graphHits {
            let r = hit.rect
            let slot = r.width / CGFloat(model.n)
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSRect(x: r.minX + CGFloat(i) * slot, y: r.minY, width: max(slot, 1), height: r.height).fill()
            NSColor.labelColor.withAlphaComponent(0.55).setFill()
            NSRect(x: r.minX + (CGFloat(i) + 0.5) * slot - 0.25, y: r.minY, width: 0.5, height: r.height).fill()
        }

        // Rows: (text, swatch colour or nil, emphasised)
        var rows: [(String, NSColor?, Bool)] = []
        let start = model.start ?? now.addingTimeInterval(-3600)
        let t0 = start.addingTimeInterval(Double(i) * 3600 / Double(model.n))
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let ago = Int(now.timeIntervalSince(t0) / 60)
        rows.append(("\(fmt.string(from: t0)) · \(ago <= 0 ? "now" : "\(ago)m ago")", nil, true))

        let m = graphHits[cursor.graph].metric
        switch m {
        case .latency, .ttft:
            let overall = at(m == .ttft ? model.ttft : model.latency, 0)
            rows.append(((m == .ttft ? "ttft p50 " : "latency p50 ") + (overall > 0 ? compactMs(overall) : "–"), nil, true))
            for p in model.providers {
                let v = at(m == .ttft ? p.ttft : p.latency, 0)
                if v > 0 { rows.append(("\(shortLabel(p.key, p.label))  \(compactMs(v))", providerColor(p.key), false)) }
            }
            for (key, values) in model.durationSeries(m) {
                let v = at(values, 0)
                if v > 0 { rows.append(("\(vendorName(key))  \(compactMs(v))", vendorColor(key), false)) }
            }
        case .tokens:
            rows.append(("\(compactRate(at(model.tps, 0))) tok/s", nil, true))
            for v in model.vendorTps where at(v.values, 0) > 0 {
                rows.append(("\(vendorName(v.key))  \(compactRate(at(v.values, 0)))", vendorColor(v.key), false))
            }
            for p in model.providers where at(p.tps, 0) > 0 {
                rows.append(("\(shortLabel(p.key, p.label))  \(compactRate(at(p.tps, 0)))", providerColor(p.key), false))
            }
        case .requests, .all:
            let total = at(model.totalsPerMinute(), 0)
            rows.append(("\(total) req", nil, true))
            for v in model.vendors where at(v.values, 0) > 0 {
                rows.append(("\(vendorName(v.key))  \(at(v.values, 0))", vendorColor(v.key), false))
            }
            for p in model.providers where at(p.values, 0) > 0 {
                rows.append(("\(shortLabel(p.key, p.label))  \(at(p.values, 0))", providerColor(p.key), false))
            }
            let lat = at(model.latency, 0), ttft = at(model.ttft, 0)
            if lat > 0 || ttft > 0 {
                rows.append(([lat > 0 ? "p50 \(compactMs(lat))" : nil, ttft > 0 ? "ttft \(compactMs(ttft))" : nil]
                    .compactMap { $0 }.joined(separator: " · "), nil, false))
            }
        }

        let e429 = at(model.e429, 0), e5 = at(model.e5, 0), eo = at(model.eo, 0)
        if e429 > 0 { rows.append(("429 ×\(e429)", amber429, false)) }
        if e5 > 0 { rows.append(("5xx ×\(e5)", .systemRed, false)) }
        if eo > 0 { rows.append(("other errors ×\(eo)", .systemRed, false)) }

        let t1 = t0.addingTimeInterval(3600 / Double(model.n))
        for sp in spans where sp.start < t1 && sp.end > t0 {
            let kind = sp.kind == "quota" ? "quota" : "rate limit"
            let end = sp.end > now.addingTimeInterval(3600 * 24) ? "open" : (sp.endEstimated ? "~" : "") + fmt.string(from: sp.end)
            rows.append(("\(shortLabel(sp.provider, sp.label)) \(kind) → \(end)", providerColor(sp.provider), false))
        }

        // Box beside the mouse, flipped left / clamped so it stays inside the window.
        let lineH: CGFloat = 11, pad: CGFloat = 5, sw: CGFloat = 8
        let textW = rows.map { textWidth($0.0, $0.2 ? valueFont : tinyFont) + ($0.1 == nil ? 0 : sw + 3) }.max() ?? 0
        let w = textW + pad * 2, h = CGFloat(rows.count) * lineH + pad * 2 - 2
        let graph = graphHits[cursor.graph].rect
        var x = cursor.x + 10
        if x + w > graph.maxX { x = cursor.x - 10 - w }  // keep it over the graph, not the stats beside it
        x = max(b.minX + 2, x)
        let y = min(max(graph.maxY - h, b.minY + 2), b.maxY - h - 2)
        let box = NSRect(x: x, y: y, width: w, height: h)
        let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
        var ly = box.maxY - pad - lineH + 1
        for (text, color, strong) in rows {
            var tx = box.minX + pad
            if let color {
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: tx, y: ly + 2.5, width: sw, height: 5), xRadius: 1.5, yRadius: 1.5).fill()
                tx += sw + 3
            }
            drawStr(text, in: NSRect(x: tx, y: ly, width: box.maxX - pad - tx, height: lineH),
                    font: strong ? valueFont : tinyFont, color: strong ? .labelColor : .secondaryLabelColor)
            ly -= lineH
        }
    }

    // MARK: header / overlay

    func stateColor(_ s: Summary) -> NSColor {
        switch s.state { case "throttled", "down": return .systemRed; case "spike": return .systemOrange; case "normal": return .systemGreen; default: return .secondaryLabelColor }
    }

    func headerText(_ s: Summary, live: [SpanItem], d: J) -> String {
        switch s.state {
        case "throttled":
            var names: [String] = []
            for sp in live where !names.contains(shortLabel(sp.provider, sp.label)) { names.append(shortLabel(sp.provider, sp.label)) }
            let until = parseISO(d["throttled"]["reset_at"].str) ?? live.map { $0.end }.max()
            let left = until.map { compactDuration(Int($0.timeIntervalSince(now).rounded(.up))) }
            return "429 · " + (names.isEmpty ? (d["throttled"]["proxy"].str ?? "throttled") : names.joined(separator: ", ")) + (left.map { " · \($0)" } ?? "")
        case "down": return "Proxy down"
        case "spike": return "Error spike"
        case "normal":
            // Follow the graph metric so the header and caption do not disagree.
            switch metric {
            case .tokens:
                if let out = d["tokens"]["m15"]["out"].int, out > 0 {
                    return "OK · \(compactRate(Double(out) / 900)) tok/s avg"
                }
            case .latency:
                if let p = d["latency"]["p50"].dbl { return "OK · p50 \(compactMs(p))" }
            case .ttft:
                if let t = d["latency"]["ttft_p50"].dbl { return "OK · ttft \(compactMs(t))" }
            case .requests, .all:
                break
            }
            return "OK · \(d["totals"]["m15"]["requests"].int ?? 0) req/15m"
        default: return s.state
        }
    }

    func drawHeader(_ ctx: CGContext, summary: Summary, live: [SpanItem], d: J, in r: NSRect) {
        stateColor(summary).setFill()
        NSBezierPath(ovalIn: NSRect(x: r.minX, y: r.midY - 3.5, width: 7, height: 7)).fill()
        drawStr(headerText(summary, live: live, d: d) + (stale ? " · stale" : ""), in: NSRect(x: r.minX + 11, y: r.minY, width: r.width - 11, height: r.height),
                font: boldFont, color: summary.state == "normal" ? .labelColor : stateColor(summary))
    }

    /// History layout: no text rows, so a small pill carries the state (and in-flight count) over the graph.
    /// Position (and feed) the animated strip; the strip repaints itself on
    /// the needle timer, the panel redraws only on data changes.
    func placeFlightBars(_ r: NSRect) {
        if barsView.frame != r { barsView.frame = r }
        barsView.isHidden = r.isEmpty || flightBars.isEmpty
        barsView.fractions = flightBars
    }

    func drawOverlay(summary: Summary, live: [SpanItem], d: J, in r: NSRect) {
        var parts: [String] = []
        if summary.state != "normal" { parts.append(headerText(summary, live: live, d: d)) }
        if let n = d["inflight"]["count"].int, n > 0 { parts.append("⏳\(n)") }
        if !driftItems(d).isEmpty { parts.append("⚠") }
        guard !parts.isEmpty else { return }
        let text = parts.joined(separator: " · ")
        let font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let barW: CGFloat = waitBarVisible ? 34 : 0  // wait bar after the text, while something is in flight or the needle drains
        let w = min(textWidth(text, font) + 14 + barW, r.width - 8)
        let laneCount = Set(spanItems(d).map { $0.provider }).count
        let pill = NSRect(x: r.minX + 4, y: r.maxY - 6 - CGFloat(laneCount) * 3.5 - 13, width: w, height: 13)  // top-left, under the throttle lanes
        NSColor.windowBackgroundColor.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6.5, yRadius: 6.5).fill()
        stateColor(summary).setFill()
        NSBezierPath(ovalIn: NSRect(x: pill.minX + 4, y: pill.midY - 2.5, width: 5, height: 5)).fill()
        drawStr(text, in: NSRect(x: pill.minX + 12, y: pill.minY + 0.5, width: pill.width - 14 - barW, height: 12), font: font)
        if barW > 0 { drawWaitBar(NSRect(x: pill.maxX - barW - 2, y: pill.minY, width: barW - 4, height: pill.height), fraction: waitNeedle) }
    }

    // MARK: graph

    struct GraphModel {
        var vendors: [(key: String, values: [Int])] = []
        var vendorTps: [(key: String, values: [Double])] = []
        var tps: [Double] = []
        var latency: [Double] = []
        var ttft: [Double] = []
        var latencyByVendor: [(key: String, values: [Double])] = []
        var ttftByVendor: [(key: String, values: [Double])] = []
        var providers: [ProviderSeries] = []
        var e429: [Int] = [], e5: [Int] = [], eo: [Int] = []
        var n = 60
        var peak = 3
        var peakTps: Double = 1
        var peakLatency: Double = 1
        var peakTtft: Double = 1
        var start: Date?
        var hasTraffic = false

        func vendorValues(_ metric: ChartMetric) -> [(key: String, values: [Double])] {
            metric == .tokens ? vendorTps : vendors.map { ($0.key, $0.values.map(Double.init)) }
        }

        func peakValue(_ metric: ChartMetric) -> Double {
            switch metric {
            case .tokens: return peakTps
            case .latency: return peakLatency
            case .ttft: return peakTtft
            case .requests, .all: return Double(peak)
            }
        }

        func durationSeries(_ metric: ChartMetric) -> [(key: String, values: [Double])] {
            metric == .ttft ? ttftByVendor : latencyByVendor
        }

        init(_ d: J) {
            let s = d["series"]
            let req = s["requests"].arr.map { $0.int ?? 0 }
            n = max(req.count, 1)
            let bv = s["by_vendor"]
            if bv.exists {
                vendors = bv.keys.map { k in (k, bv[k].arr.map { $0.int ?? 0 }) }.sorted { ($0.1.reduce(0, +), $1.0) > ($1.1.reduce(0, +), $0.0) }
            } else if !req.isEmpty {
                vendors = [("other", req)]  // older helper JSON: one grey stack from the proxy-log series
            }
            let tv = s["tps_by_vendor"]
            if tv.exists {
                vendorTps = tv.keys.map { k in (k, tv[k].arr.map { $0.dbl ?? 0 }) }
                    .sorted { ($0.1.reduce(0, +), $1.0) > ($1.1.reduce(0, +), $0.0) }
            } else if !vendors.isEmpty {
                vendorTps = vendors.map { v in (v.key, v.values.map { Double($0) }) }
            }
            tps = s["tps"].arr.map { $0.dbl ?? 0 }
            latency = s["latency"].arr.map { $0.dbl ?? 0 }
            ttft = s["ttft"].arr.map { $0.dbl ?? 0 }
            let lv = s["latency_by_vendor"]
            if lv.exists {
                latencyByVendor = lv.keys.map { k in (k, lv[k].arr.map { $0.dbl ?? 0 }) }
                    .sorted { ($0.1.max() ?? 0) > ($1.1.max() ?? 0) }
            }
            let tvv = s["ttft_by_vendor"]
            if tvv.exists {
                ttftByVendor = tvv.keys.map { k in (k, tvv[k].arr.map { $0.dbl ?? 0 }) }
                    .sorted { ($0.1.max() ?? 0) > ($1.1.max() ?? 0) }
            }
            if let longest = vendors.map({ $0.values.count }).max() { n = max(n, longest) }
            providers = providerSeries(d)
            e429 = s["e429"].arr.map { $0.int ?? 0 }
            e5 = s["e5xx"].arr.map { $0.int ?? 0 }
            eo = s["eother"].arr.map { $0.int ?? 0 }
            start = parseISO(s["start"].str)
            let totals = totalsPerMinute()
            hasTraffic = (totals.max() ?? 0) > 0 || providers.contains { ($0.values.max() ?? 0) > 0 }
            peak = max(totals.max() ?? 0, providers.compactMap { $0.values.max() }.max() ?? 0, 3)
            peakTps = max(tps.max() ?? 0, vendorTps.compactMap { $0.values.max() }.max() ?? 0,
                          providers.compactMap { $0.tps.max() }.max() ?? 0, 0.1)
            peakLatency = max(latency.max() ?? 0, latencyByVendor.compactMap { $0.values.max() }.max() ?? 0,
                              providers.compactMap { $0.latency.max() }.max() ?? 0, 1)
            peakTtft = max(ttft.max() ?? 0, ttftByVendor.compactMap { $0.values.max() }.max() ?? 0,
                           providers.compactMap { $0.ttft.max() }.max() ?? 0, 1)
        }

        func totalsPerMinute() -> [Int] {
            (0..<n).map { i in vendors.reduce(0) { $0 + (i < $1.values.count ? $1.values[i] : 0) } }
        }
    }

    func xFor(_ t: Date, _ r: NSRect, _ start: Date) -> CGFloat {
        r.minX + CGFloat(min(max(t.timeIntervalSince(start) / 3600, 0), 1)) * r.width
    }

    /// Graph with its caption above and the throttle legend below.
    func drawGraphColumn(_ ctx: CGContext, rect: NSRect, model: GraphModel, spans: [SpanItem], d: J) {
        if metric.isStacked {
            let metrics: [ChartMetric] = [.tokens, .ttft, .latency]
            let band = rect.height / CGFloat(metrics.count)
            for (i, m) in metrics.enumerated() {
                let r = NSRect(x: rect.minX, y: rect.minY + CGFloat(metrics.count - 1 - i) * band, width: rect.width, height: band)
                drawMiniGraph(ctx, rect: r, model: model, metric: m)
            }
            return
        }
        let capH: CGFloat = 11, legH: CGFloat = spans.isEmpty ? 0 : 12
        let peak = model.peakValue(metric)
        let label: String
        switch metric {
        case .requests: label = "req/min · 60m · peak \(Int(peak))"
        case .tokens: label = "tok/s · 60m · peak \(compactRate(peak))"
        case .latency: label = "latency p50 · 60m · peak \(compactMs(peak))"
        case .ttft: label = "ttft p50 · 60m · peak \(compactMs(peak))"
        case .all: label = "all metrics"
        }
        let caption = label + "  ⇄"
        let capRect = NSRect(x: rect.minX, y: rect.maxY - capH, width: rect.width, height: capH)
        metricHit = capRect  // click the caption to switch Requests/min <-> Tokens/s
        drawStr(caption, in: capRect, font: tinyFont, color: hoverMetric ? .labelColor : .secondaryLabelColor)
        if hoverMetric {
            NSColor.secondaryLabelColor.setFill()
            NSRect(x: rect.minX, y: capRect.minY + 0.5, width: min(textWidth(caption, tinyFont), rect.width), height: 0.5).fill()
        }
        let g = NSRect(x: rect.minX, y: rect.minY + legH, width: rect.width, height: rect.height - capH - legH - 1)
        drawGraph(ctx, rect: g, model: model, spans: spans, metric: metric)
        if !spans.isEmpty { drawSpanLegend(ctx, in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: legH - 2)) }
    }

    func drawMiniGraph(_ ctx: CGContext, rect: NSRect, model: GraphModel, metric m: ChartMetric) {
        let capH: CGFloat = 10
        let peak = model.peakValue(m)
        metricHit = rect  // clicking a stacked panel cycles the window metric
        // Range is part of the label: these are per-minute buckets over model.n
        // minutes, a different window and unit than the % rows' 15m share.
        let label: String
        switch m {
        case .tokens: label = "tok/s · \(model.n)m · peak \(compactRate(peak))"
        case .latency: label = "latency · \(model.n)m · peak \(compactMs(peak))"
        case .ttft: label = "ttft · \(model.n)m · peak \(compactMs(peak))"
        default: label = m.title
        }
        drawStr(label, in: NSRect(x: rect.minX, y: rect.maxY - capH, width: rect.width, height: capH), font: tinyFont, color: .secondaryLabelColor)
        // Throttle ribbons are omitted here so three stacked panels stay readable.
        drawGraph(ctx, rect: NSRect(x: rect.minX, y: rect.minY + 1, width: rect.width, height: rect.height - capH - 2),
                  model: model, spans: [], metric: m)
    }

    /// One dot per sampled minute for a duration metric (TTFT / latency p50):
    /// each request-carrying minute is a dot at its median, empty minutes stay
    /// empty, so request density and gaps read directly instead of a line that
    /// visually bridges (or breaks arbitrarily across) quiet stretches.
    func drawDurationDots(_ ctx: CGContext, rect: NSRect, values: [Double], n: Int, slot: CGFloat, scale: CGFloat,
                          color: NSColor, alpha: CGFloat, width: CGFloat, halo: Bool) {
        let r = min(max(width * 1.35, 1.4), 3)
        for (i, v) in values.enumerated() where i < n && v > 0 {
            let pt = NSPoint(x: rect.minX + (CGFloat(i) + 0.5) * slot, y: rect.minY + 0.5 + CGFloat(v) * scale)
            let dot = NSBezierPath(roundedRect: NSRect(x: pt.x - r, y: pt.y - r, width: 2 * r, height: 2 * r), xRadius: r, yRadius: r)
            if halo {
                dot.lineWidth = 1.7
                NSColor.windowBackgroundColor.withAlphaComponent(0.55 * alpha).setStroke()
                dot.stroke()  // ring so dots stay visible over bars and washes
            }
            color.withAlphaComponent(alpha).setFill()
            dot.fill()
        }
    }

    func drawGraph(_ ctx: CGContext, rect: NSRect, model: GraphModel, spans: [SpanItem], metric m: ChartMetric) {
        guard rect.width > 8, rect.height > 8 else { return }
        graphHits.append((rect, m))
        let clip = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        clip.fill()
        ctx.saveGState()
        clip.addClip()
        defer { ctx.restoreGState() }
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: 0.5).fill()  // half-scale gridline

        let n = model.n
        let slot = rect.width / CGFloat(n)
        let lanes = Array(Set(spans.map { $0.provider })).sorted()
        let laneStep: CGFloat = 3.5
        let lanesH = spans.isEmpty ? 0 : CGFloat(lanes.count) * laneStep + 1
        let plotTop = rect.maxY - lanesH
        let scale = max(plotTop - rect.minY - 1, 1) / CGFloat(model.peakValue(m))
        let minuteTotals: [Double] = (0..<n).map { i in
            m == .tokens ? (i < model.tps.count ? model.tps[i] : 0) : Double(model.totalsPerMinute()[i])
        }
        let start = model.start ?? now.addingTimeInterval(-3600)
        let chrome: CGFloat = effectiveHover == nil ? 1 : 0.22

        // throttle washes sit under the bars so the data stays readable; lanes and edges go on top afterwards
        for sp in spans {
            let c = providerColor(sp.provider)
            let x1 = xFor(sp.start, rect, start), x2 = max(xFor(sp.end, rect, start), x1 + 2)
            let band = NSRect(x: x1, y: rect.minY, width: x2 - x1, height: rect.height)
            if sp.kind == "quota" {
                c.withAlphaComponent(0.10 * chrome).setFill()
                band.fill()
                ctx.saveGState()
                ctx.clip(to: band)
                c.withAlphaComponent(0.55 * chrome).setStroke()
                let hatch = NSBezierPath()
                hatch.lineWidth = 0.8
                var x = band.minX - rect.height
                while x < band.maxX {
                    hatch.move(to: NSPoint(x: x, y: rect.minY)); hatch.line(to: NSPoint(x: x + rect.height, y: rect.maxY))
                    x += 4
                }
                hatch.stroke()
                ctx.restoreGState()
            } else {
                c.withAlphaComponent(0.22 * chrome).setFill()
                band.fill()
            }
        }

        if graphMode != .lines && !m.isDuration {
            for i in 0..<n {
                var y = rect.minY
                let x = rect.minX + CGFloat(i) * slot
                let w = slot > 2.4 ? slot - 0.6 : slot + 0.3
                for v in model.vendorValues(m) where i < v.values.count && v.values[i] > 0 {
                    let h = max(CGFloat(v.values[i]) * scale, 0.8)
                    vendorColor(v.key).withAlphaComponent(hoverAlpha(.vendor(v.key))).setFill()
                    NSRect(x: x, y: y, width: w, height: h).fill()
                    y += h
                }
            }
        }

        // failures: a wash across the minute plus a cap on top (429 amber, anything else red)
        for i in 0..<n where !m.isDuration {
            let a = i < model.e429.count ? model.e429[i] : 0
            let r5 = (i < model.e5.count ? model.e5[i] : 0) + (i < model.eo.count ? model.eo[i] : 0)
            guard a + r5 > 0 else { continue }
            let c = r5 > 0 ? NSColor.systemRed : amber429
            let x = rect.minX + CGFloat(i) * slot
            let w = max(slot, 2.5)
            c.withAlphaComponent(0.22 * chrome).setFill()
            NSRect(x: x - (w - slot) / 2, y: rect.minY, width: w, height: plotTop - rect.minY).fill()
            let top = (minuteTotals[i] > 0 ? CGFloat(minuteTotals[i]) * scale : 0) + rect.minY
            c.withAlphaComponent(chrome).setFill()
            NSRect(x: x - (w - slot) / 2, y: min(top + 0.5, plotTop - 3), width: w, height: 3).fill()
        }

        if graphMode != .bars && !m.isDuration {
            let bg = NSColor.windowBackgroundColor.withAlphaComponent(0.55)
            for p in model.providers {
                let values = m == .tokens ? p.tps : p.values.map(Double.init)
                guard (values.max() ?? 0) > 0 else { continue }
                let path = NSBezierPath()
                for (i, v) in values.enumerated() {
                    let pt = NSPoint(x: rect.minX + (CGFloat(i) + 0.5) * slot, y: rect.minY + 0.5 + CGFloat(v) * scale)
                    i == 0 ? path.move(to: pt) : path.line(to: pt)
                }
                path.lineJoinStyle = .round
                let alpha = hoverAlpha(.provider(p.key))
                path.lineWidth = 3.2
                bg.withAlphaComponent(0.55 * alpha).setStroke()
                path.stroke()  // halo so a line stays visible across any bar colour
                path.lineWidth = hover == .provider(p.key) ? 2 : 1.5
                providerColor(p.key).withAlphaComponent(alpha).setStroke()
                path.stroke()
            }
        }

        // Latency / TTFT are distributions: median dots, split by provider (Lines mode) and/or model vendor (Bars mode).
        if m.isDuration {
            if graphMode != .bars {
                for p in model.providers {
                    let values = m == .ttft ? p.ttft : p.latency
                    guard (values.max() ?? 0) > 0 else { continue }
                    drawDurationDots(ctx, rect: rect, values: values, n: n, slot: slot, scale: scale,
                                     color: providerColor(p.key), alpha: hoverAlpha(.provider(p.key)),
                                     width: hover == .provider(p.key) ? 2 : 1.6, halo: true)
                }
            }
            if graphMode != .lines {
                for (key, values) in model.durationSeries(m) where (values.max() ?? 0) > 0 {
                    drawDurationDots(ctx, rect: rect, values: values, n: n, slot: slot, scale: scale,
                                     color: vendorColor(key), alpha: hoverAlpha(.vendor(key)), width: 1, halo: false)
                }
            }
        }

        // lanes (one per provider, solid = rate limit, dotted = quota) and end edges (dashed = estimated reset)
        for sp in spans {
            let c = providerColor(sp.provider)
            let lane = CGFloat(lanes.firstIndex(of: sp.provider) ?? 0)
            let x1 = xFor(sp.start, rect, start), x2 = max(xFor(sp.end, rect, start), x1 + 2)
            let ly = rect.maxY - laneStep * (lane + 1)
            let bar = NSBezierPath()
            bar.lineWidth = 2.5
            bar.move(to: NSPoint(x: x1, y: ly + 1.25)); bar.line(to: NSPoint(x: x2, y: ly + 1.25))
            if sp.kind == "quota" { bar.setLineDash([3, 2], count: 2, phase: 0) }
            c.withAlphaComponent(0.95 * chrome).setStroke()
            bar.stroke()
            if sp.end <= start.addingTimeInterval(3598) {  // an end beyond the graph is open-ended: no edge
                let edge = NSBezierPath()
                edge.lineWidth = 1.2
                edge.move(to: NSPoint(x: x2, y: rect.minY)); edge.line(to: NSPoint(x: x2, y: rect.maxY))
                if sp.endEstimated { edge.setLineDash([2.5, 2], count: 2, phase: 0) }
                c.withAlphaComponent(0.95 * chrome).setStroke()
                edge.stroke()
            }
        }

        if !model.hasTraffic && spans.isEmpty {
            drawStr("idle", in: NSRect(x: rect.minX, y: rect.midY - 6, width: rect.width, height: 12), font: bodyFont, color: .tertiaryLabelColor, align: .center)
        }

        // host hover (fleet strip): the vendor bars and provider lines are dimmed
        // by the existing hoverAlpha (nothing matches a .host target); this line IS
        // the filter — the hovered host's per-minute traffic on the chart's scale
        if case .host(let name) = hover, let vals = hostSeries[name], m == .requests, vals.count == n, scale > 0 {
            let hostColor = dynamicColor(light: rgb(0x2a78d6), dark: rgb(0x3987e5))
            let line = NSBezierPath()
            line.lineWidth = 2
            line.lineCapStyle = .round
            line.lineJoinStyle = .round
            var last: NSPoint?
            for (i, v) in vals.enumerated() {
                guard v > 0 else { last = nil; continue }  // break the line at empty minutes
                let p = NSPoint(x: rect.minX + slot * (CGFloat(i) + 0.5), y: rect.minY + CGFloat(v) * scale)
                if let l = last { line.move(to: l); line.line(to: p) } else { line.move(to: p) }
                last = p
            }
            hostColor.setStroke()
            line.stroke()
            // a dot per active minute so isolated one-off requests stay visible
            hostColor.setFill()
            for (i, v) in vals.enumerated() where v > 0 {
                let x = rect.minX + slot * (CGFloat(i) + 0.5)
                let y = rect.minY + CGFloat(v) * scale
                NSBezierPath(ovalIn: NSRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)).fill()
            }
        }
    }

    /// Throttle ribbon key: wash = rate-limit 429, hatch = quota, dashed edge = estimated end, solid edge = known end. Items that do not fit drop off the right.
    func drawSpanLegend(_ ctx: CGContext, in r: NSRect) {
        let ink = NSColor.secondaryLabelColor
        var x = r.minX
        func item(_ label: String, _ sample: (NSRect) -> Void) -> Bool {
            let w = 10 + textWidth(label, tinyFont) + 5
            guard x + w <= r.maxX + 2 else { return false }
            sample(NSRect(x: x, y: r.minY + 1.5, width: 8, height: r.height - 3))
            drawStr(label, in: NSRect(x: x + 10, y: r.minY, width: w - 10, height: r.height), font: tinyFont, color: ink)
            x += w
            return true
        }
        _ = item("429") { s in
            NSColor.labelColor.withAlphaComponent(0.25).setFill(); s.fill()
            NSColor.labelColor.withAlphaComponent(0.8).setFill(); NSRect(x: s.minX, y: s.maxY - 1.5, width: s.width, height: 1.5).fill()
        } && item("quota") { s in
            NSColor.labelColor.withAlphaComponent(0.10).setFill(); s.fill()
            let h = NSBezierPath(); h.lineWidth = 0.7
            NSColor.labelColor.withAlphaComponent(0.6).setStroke()
            var hx = s.minX - s.height
            while hx < s.maxX { h.move(to: NSPoint(x: max(hx, s.minX), y: hx < s.minX ? s.minY + (s.minX - hx) : s.minY)); h.line(to: NSPoint(x: min(hx + s.height, s.maxX), y: hx + s.height > s.maxX ? s.maxY - (hx + s.height - s.maxX) : s.maxY)); hx += 3.5 }
            h.stroke()
        } && item("~end") { s in
            let e = NSBezierPath(); e.lineWidth = 1.2; e.setLineDash([2, 1.5], count: 2, phase: 0)
            NSColor.labelColor.withAlphaComponent(0.8).setStroke()
            e.move(to: NSPoint(x: s.midX, y: s.minY)); e.line(to: NSPoint(x: s.midX, y: s.maxY)); e.stroke()
        } && item("end") { s in
            let e = NSBezierPath(); e.lineWidth = 1.2
            NSColor.labelColor.withAlphaComponent(0.8).setStroke()
            e.move(to: NSPoint(x: s.midX, y: s.minY)); e.line(to: NSPoint(x: s.midX, y: s.maxY)); e.stroke()
        }
    }

    // MARK: stats rows

    func drawStats(_ ctx: CGContext, rect: NSRect, d: J, spans: [SpanItem]) {
        let rowH: CGFloat = 13
        var y = rect.maxY
        var rowsLeft = Int((rect.height + 1) / rowH)
        func next() -> NSRect? {
            guard rowsLeft > 0 else { return nil }
            rowsLeft -= 1
            y -= rowH
            return NSRect(x: rect.minX, y: y, width: rect.width, height: rowH)
        }

        // proxy dots go at the bottom: reserve their rows first
        let proxies = d["proxies"].arr.filter { $0["state"].str == "up" || $0["expected"].bool }
        let dotLabel: (J) -> String = { p in
            let port = p["port"].int.map(String.init) ?? "?"
            return rect.width < 140 ? String(port.suffix(2)) : port
        }
        var dotRows: [[J]] = [[]]
        var used: CGFloat = 0
        for p in proxies {
            let w = 5 + 2 + textWidth(dotLabel(p), tinyFont) + 5
            if used + w > rect.width + 8, !dotRows[dotRows.count - 1].isEmpty { dotRows.append([]); used = 0 }
            dotRows[dotRows.count - 1].append(p)
            used += w
        }
        if proxies.isEmpty { dotRows = [] }
        rowsLeft -= dotRows.count
        for (i, row) in dotRows.enumerated() {
            var x = rect.minX
            let ry = rect.minY + CGFloat(dotRows.count - 1 - i) * rowH
            var afterHover = false
            for p in row {
                let port = p["port"].int ?? 0
                let name = p["name"].str ?? ""
                let hasName = !name.isEmpty && name != ":\(port)"  // unnamed ad-hoc proxies carry ":<port>" as their name
                let slot = 5 + 2 + textWidth(dotLabel(p), tinyFont) + 5
                // hits for every port, even ones hidden by an active hover: sweeping
                // the mouse across the row re-hovers each in turn
                if hasName { portHits.append((NSRect(x: x, y: ry, width: slot, height: rowH), port, name)) }
                if !afterHover {
                    let up = p["state"].str == "up"
                    let notLogging = up && p["logging"].exists && !p["logging"].bool  // pre-callback code: up, but its traffic is missing
                    (notLogging ? NSColor.systemYellow : up ? NSColor.systemGreen : NSColor.systemRed).setFill()
                    NSBezierPath(ovalIn: NSRect(x: x, y: ry + 4, width: 5, height: 5)).fill()
                    if hasName && (debugPortHover ?? hoverPort) == port {
                        // hovered: the proxy's name replaces this label and the rest of
                        // the row — the full name, no truncation, no overlap; the row
                        // restores on exit (the native tooltip adds "· :port")
                        drawStr(name, in: NSRect(x: x + 7, y: ry, width: rect.maxX - x - 7, height: rowH),
                                font: tinyFont, color: .labelColor)
                        afterHover = true
                    } else {
                        let label = dotLabel(p)
                        drawStr(label, in: NSRect(x: x + 7, y: ry, width: textWidth(label, tinyFont) + 2, height: rowH),
                                font: tinyFont, color: .secondaryLabelColor)
                    }
                }
                x += slot
            }
        }

        if let r = next() {
            let fl = d["inflight"]
            let (value, strong): (String, Bool) = fl["available"].bool
                ? ((fl["count"].int ?? 0) > 0 ? ("\(fl["count"].int ?? 0) · \(compactDuration(fl["oldest_s"].int ?? 0))", true) : ("0", false)) : ("n/a", false)
            drawStr("In flight", in: r, color: .secondaryLabelColor)
            drawStr(value, in: r, font: valueFont, color: strong ? .labelColor : .secondaryLabelColor, align: .right)
            if fl["available"].bool, waitBarVisible {
                let x0 = r.minX + textWidth("In flight", bodyFont) + 8, x1 = r.maxX - textWidth(value, valueFont) - 8
                placeFlightBars(NSRect(x: x0, y: r.minY, width: x1 - x0, height: r.height))
            } else {
                placeFlightBars(.zero)
            }
        }

        let models = shareEntries(d["share"]["models"]), providers = shareEntries(d["share"]["providers"])
        // Three different metrics share this panel; the headers must say which is
        // which or the % rows and the history graph read as one contradictory number:
        //   * "In flight" row = live request count + age of the oldest. No window.
        //   * model/provider % = share of FINISHED requests (or tokens) over the share
        //     window (d.share.window, default 15m). A cumulative share, not a rate.
        //   * history graph = per-minute values over the last ~60m on a shared
        //     absolute scale (peak of all series in the band). A 49%-of-15m vendor is
        //     a sliver when its traffic is spread out or outside the peak minute,
        //     and duration bands only dot minutes that vendor finished requests in.
        //     % and bar/dot height are different units over different windows.
        let shareWindow = d["share"]["window"].str ?? "15m"
        let pctOf = (d["share"]["metric"].str == "tokens") ? "% tok" : "% req"
        let modelRows = min(models.count, layout == .vertical ? 4 : 3)
        if modelRows == 0, let r = next() { drawStr("idle · no traffic", in: r, color: .tertiaryLabelColor) }
        if modelRows > 0, rowsLeft >= 2, let r = next() {
            drawStr("Models · \(shareWindow) · \(pctOf)", in: r, font: tinyFont, color: .secondaryLabelColor)
        }
        for e in models.prefix(modelRows) {
            guard let r = next() else { break }
            drawShareRow(ctx, r, e, marker: graphMode == .lines ? nil : .tick(vendorColor(e.key)), circle: true, hover: .vendor(e.key))
        }
        if !providers.isEmpty, rowsLeft >= 2 {
            if let r = next() { drawStr("Providers · \(shareWindow) · \(pctOf)", in: r, font: tinyFont, color: .secondaryLabelColor) }
            for e in providers.prefix(min(rowsLeft, layout == .vertical ? 3 : 2)) {
                guard let r = next() else { break }
                drawShareRow(ctx, r, e, marker: graphMode == .bars ? nil : .line(providerColor(e.key)), circle: false, hover: .provider(e.key))
            }
        }
        // Reroutes: why traffic moved — the same kinds the menu's REROUTES
        // section lists (alias / vision / fallback:reason), compacted into one
        // row so the window shows redirect reasons without opening the menu.
        let rrs = d["reroutes"].arr
        if !rrs.isEmpty, rowsLeft >= 1, let r = next() {
            var kinds: [String: Int] = [:]
            for rr in rrs {
                if rr["kinds"].exists {
                    for k in rr["kinds"].keys { kinds[k, default: 0] += rr["kinds"][k].int ?? 0 }
                } else { kinds[rr["kind"].str ?? "?", default: 0] += rr["count"].int ?? 0 }
            }
            let total = kinds.values.reduce(0, +)
            let top = kinds.sorted { $0.value > $1.value }.prefix(2)
                .map { "\($0.key) \($0.value)" }.joined(separator: " · ")
            drawStr("↪ \(total) reroute\(total == 1 ? "" : "s") · \(top)", in: r, font: tinyFont, color: .secondaryLabelColor)
        }
        // Fleet: pulled peers (dot = up/stale/down), after the share rows — a long
        // host list must not crowd Models/Providers out — and capped at two.
        // Both layouts show it: the horizontal window's stats column has the
        // vertical's slack below Providers. When the column is too short for the
        // section, one compact line stands in; the menu holds the full list.
        let fhosts = d["fleet"]["enabled"].bool ? (d["fleet"]["hosts"].arr ?? []) : []
        let fleetShow = fhosts.prefix(2)
        let fleetMore = fhosts.count > fleetShow.count ? " · +\(fhosts.count - fleetShow.count) more" : ""
        if !fleetShow.isEmpty, rowsLeft >= fleetShow.count + 1, let r = next() {
            // "+N more" in the header: the menu holds the full host list, the window must say when it truncated one
            drawStr("Fleet · 15m" + fleetMore, in: r, font: tinyFont, color: .secondaryLabelColor)
            for h in fleetShow {
                guard let row = next() else { break }
                let state = h["state"].str ?? "down"
                let name = h["name"].str ?? "?"
                // hover target: hovering a host row filters the traffic graph to
                // that host's per-minute series (drawGraph reads it via hostSeries)
                hoverRects.append((row, .host(name)))
                if hover == .host(name) {
                    NSColor.labelColor.withAlphaComponent(0.07).setFill()
                    row.fill()
                }
                let dot: NSColor = state == "up" ? .systemGreen : (state == "stale" ? .systemYellow : .tertiaryLabelColor)
                dot.setFill()
                NSBezierPath(ovalIn: NSRect(x: row.minX, y: row.minY + 4, width: 5, height: 5)).fill()
                drawStr(state == "stale" ? "\(name) (stale)" : name,
                        in: NSRect(x: row.minX + 8, y: row.minY, width: row.width * 0.6, height: row.height),
                        color: state == "down" ? .tertiaryLabelColor : .labelColor)
                let e = h["m15"]["errors"]
                let errs = (e["429"].int ?? 0) + (e["5xx"].int ?? 0) + (e["other"].int ?? 0)
                let inflight = h["inflight"]["count"].int ?? 0
                let value = "\(h["m15"]["requests"].int ?? 0) req" + (errs > 0 ? " · \(errs) err" : "") + (inflight > 0 ? " · ⏳\(inflight)" : "")
                drawStr(value, in: row, font: tinyFont, color: errs > 0 ? NSColor.systemRed : .secondaryLabelColor, align: .right)
            }
        } else if !fleetShow.isEmpty, let r = next(), let first = fleetShow.first {
            // one line instead of the section: first host + how many others there are
            let fname = first["name"].str ?? "?"
            // the compact line stands in for the section, so it carries the first
            // host's hover target — hovering it filters the graph in small windows too
            hoverRects.append((r, .host(fname)))
            if hover == .host(fname) {
                NSColor.labelColor.withAlphaComponent(0.07).setFill()
                r.fill()
            }
            let e = first["m15"]["errors"]
            let errs = (e["429"].int ?? 0) + (e["5xx"].int ?? 0) + (e["other"].int ?? 0)
            let others = fhosts.count > 1 ? " · +\(fhosts.count - 1) host\(fhosts.count == 2 ? "" : "s")" : ""
            drawStr("Fleet · \(fname) \(first["m15"]["requests"].int ?? 0) req" + (errs > 0 ? " · \(errs) err" : "") + others,
                    in: r, font: tinyFont, color: errs > 0 ? NSColor.systemRed : .tertiaryLabelColor)
        }
        if let note = d["throttle_notes"]["github-copilot"].str, spans.allSatisfy({ $0.provider != "github-copilot" }), rowsLeft >= 1,
           providers.contains(where: { $0.key == "github-copilot" }), layout == .vertical, let r = next() {
            drawStr("Copilot: no throttle data", in: r, font: tinyFont, color: .tertiaryLabelColor)
            _ = note
        }
    }

    enum Marker { case tick(NSColor), line(NSColor) }

    func drawShareRow(_ ctx: CGContext, _ r: NSRect, _ e: ShareEntry, marker: Marker?, circle: Bool, hover target: HoverTarget) {
        hoverRects.append((r, target))
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if effectiveHover == target {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: 0.5), xRadius: 3, yRadius: 3).fill()
        } else if effectiveHover != nil {
            ctx.setAlpha(0.22)
        }
        var x = r.minX
        switch marker {
        case .tick(let c)?: c.setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: r.minY + 2, width: 3, height: 9), xRadius: 1.5, yRadius: 1.5).fill(); x += 6
        case .line(let c)?:
            let p = NSBezierPath(); p.lineWidth = 1.8; p.lineCapStyle = .round
            c.setStroke(); p.move(to: NSPoint(x: x + 1, y: r.midY)); p.line(to: NSPoint(x: x + 9, y: r.midY)); p.stroke(); x += 12
        case nil: break
        }
        let logoRect = CGRect(x: x, y: r.minY + 1, width: 11, height: 11)
        drawLogo(ctx, entry: ShareEntry(key: e.key, label: e.label, share: 1, requests: e.requests, tokens: e.tokens, models: e.models),
                 rect: logoRect, circle: circle, labelColor: NSColor.labelColor.cgColor)
        x += 14
        let pctText = String(format: "%.0f%%", e.share * 100)
        let pw = textWidth(pctText, valueFont)
        drawStr(shortLabel(e.key, e.label), in: NSRect(x: x, y: r.minY, width: max(r.maxX - x - pw - 3, 10), height: r.height))
        drawStr(pctText, in: NSRect(x: r.maxX - pw, y: r.minY, width: pw, height: r.height), font: valueFont, align: .right)
    }
}

/// Window content to PNG, @2x, light or dark (debug: no GUI needed).
func writeWindowPNG(_ d: J, layout: MonitorLayout, size: NSSize, dark: Bool, mode: GraphMode, metric: ChartMetric = .requests,
                    stale: Bool, hover: String? = nil, graphMinute: Int? = nil, to path: String) {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    let view = MonitorView(frame: NSRect(origin: .zero, size: size))
    view.layout = layout
    view.graphMode = mode
    view.metric = metric
    view.drawsBackground = true
    view.stale = stale
    view.setDebugHover(hover)
    view.debugGraphMinute = graphMinute
    view.now = parseISO(d["generated_at"].str) ?? Date()
    view.data = d
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = size
    appearance.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.current = gc
        view.draw(view.bounds)
        for sub in view.subviews where !sub.isHidden {  // the animated strip is a subview
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.translateBy(x: sub.frame.minX, y: sub.frame.minY)
            sub.draw(sub.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    print("window-png: \(Int(size.width))x\(Int(size.height))pt (\(rep.pixelsWide)x\(rep.pixelsHigh)px) \(dark ? "dark" : "light") layout=\(layout.rawValue) graph=\(mode.rawValue) metric=\(metric.rawValue) -> \(path)")
}

// Takes effect: see docs/notes/change-take-effect.md. main.swift: run `llm-usage menubar build`, then
// `launchctl kickstart -k gui/$UID/com.kaovilai.llm-usage-menubar`; building
// alone does not replace the running process.

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
    var chartMetric: ChartMetric = .requests
    var notifications: Bool
    var launchAgentInstalled: Bool
    var showImage = true
    var showText = true
    var shareWindow = "15m"   // "15m" | "1h"
    var shareMetric = "requests"  // "requests" | "tokens"
    var windowVisible = false
    var windowLayout = MonitorLayout.horizontal
    var windowGraph = GraphMode.both
    var windowMetric = ChartMetric.requests
    var windowOpacity = 1.0
    var windowClickThrough = false
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
        if up, p["logging"].exists, !p["logging"].bool { line += " NOT LOGGING (restart: llm-proxy-restart)" }
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

    func hostItem(_ h: J) -> NSMenuItem {
        let name = h["name"].str ?? "?"
        let state = h["state"].str ?? "down"
        let m15 = h["m15"], h1 = h["h1"]
        func errs(_ c: J) -> String {
            let e = c["errors"]
            let parts = [("429", e["429"].int ?? 0), ("5xx", e["5xx"].int ?? 0), ("oth", e["other"].int ?? 0)].filter { $0.1 > 0 }
            return parts.isEmpty ? "" : " " + parts.map { "\($0.0):\($0.1)" }.joined(separator: " ")
        }
        let glyph = state == "up" ? "●" : (state == "stale" ? "◐" : "○")
        var line = "\(glyph) \(name)  \(state)  \(m15["requests"].int ?? 0)/15m \(h1["requests"].int ?? 0)/1h\(errs(h1))"
        if let fl = h["inflight"]["count"].int, fl > 0 { line += "  ⏳\(fl)" }
        let item = info(line, dim: state == "down", mono: true)
        item.isEnabled = true  // a submenu parent must be enabled to open
        item.attributedTitle = NSAttributedString(string: line, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: state == "down" ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(info("\(name)  \(state)" + (state == "stale" ? " (unreachable; showing the last pulled snapshot)" : ""), mono: false))
        if let seen = h["last_event_s"].int { sub.addItem(info("last logged request \(longDuration(seen)) ago", dim: true)) }
        if let ok = h["last_ok_s"].int { sub.addItem(info("last pulled \(longDuration(ok)) ago", dim: true)) }
        sub.addItem(info("15m: \(m15["requests"].int ?? 0) req, error rate \(pct(m15["error_rate"].dbl))\(errs(m15))", dim: true))
        sub.addItem(info("1h:  \(h1["requests"].int ?? 0) req, error rate \(pct(h1["error_rate"].dbl))\(errs(h1))", dim: true))
        if (h["inflight"]["count"].int ?? 0) > 0 {
            sub.addItem(info("in flight: \(h["inflight"]["count"].int ?? 0), oldest \(longDuration(h["inflight"]["oldest_s"].int ?? 0))", dim: true))
        }
        if let err = h["last_error"].str { sub.addItem(info("last pull error: \(err)", dim: true)) }
        if !h["backfilled"].bool, h["last_ok_s"].int != nil { sub.addItem(info("history backfill in progress (30d per refresh)", dim: true)) }
        sub.addItem(.separator())
        sub.addItem(action("Copy host name (\(name))", #selector(AppController.copyText(_:)), represented: name))
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
            if th["estimated"].exists && !th["estimated"].bool {  // the logger recorded an upstream-reported reset: not an estimate
                add(info("reset reported by upstream (\(th["reset_source"].str ?? th["basis"].str ?? "upstream"))", dim: true))
            } else {
                add(info("ESTIMATE · \(basis[th["basis"].str ?? ""] ?? "estimated from the log")", dim: true))
            }
        }
        let spike = d["spike"]
        if spike["active"].bool {
            menu.addItem(.separator())
            add(info("⚠ Error spike: \(spike["errors"].int ?? 0) errors in the flagged minutes (last 10m)"))
        }

        // Throttle spans (last hour) and logger drift
        let spans = spanItems(d)
        let note = d["throttle_notes"]["github-copilot"].str
        let copilotSeen = providerSeries(d).contains { $0.key == "github-copilot" }
        if !spans.isEmpty || (note != nil && copilotSeen) {
            menu.addItem(.separator()); add(header("THROTTLE SPANS (last 1h)"))
            for sp in spans {
                let state = sp.end > c.now ? "until \(shortStamp(sp.end))\(sp.endEstimated ? " (est.)" : "")" : "ended \(shortStamp(sp.end))\(sp.endEstimated ? " (est.)" : "")"
                let tag = sp.source == "transcript" ? " [transcript-derived]" : (sp.source == "quota" ? " [copilot-api /usage]" : "")
                add(info("\(sp.label) · \(sp.kind) · \(sp.count > 1 ? "×\(sp.count) · " : "")since \(sp.startEstimated ? "≤" : "")\(shortStamp(sp.start)) · \(state)\(tag)"))
            }
            if let n = note, spans.allSatisfy({ $0.provider != "github-copilot" }) { add(info(n, dim: true)) }
        }
        for dr in driftItems(d).prefix(3) {  // the logger saw the provider change shape: click copies the hint
            menu.addItem(.separator())
            let item = action("⚠ code needs updating: \(dr.hint)\(dr.count > 1 ? "  (×\(dr.count))" : "")", #selector(AppController.copyText(_:)), represented: dr.hint)
            plain.append(item.title)
            menu.addItem(item)
            add(info("\(dr.kind) \(dr.detail)  [\(dr.proxy)]  · click to copy the hint", dim: true))
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

        // Fleet peers: usage pulled from the other machines (ssh, read-only)
        let fleetHosts = d["fleet"]["enabled"].bool ? (d["fleet"]["hosts"].arr ?? []) : []
        if !fleetHosts.isEmpty {
            menu.addItem(.separator()); add(header("FLEET (15m / 1h)"))
            for h in fleetHosts { add(hostItem(h)) }
        }

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
            menu.addItem(chartItem(requestsChart(d, metric: c.chartMetric)))
            let models = d["by_model"].arr.map { m -> Slice in
                let rr = m["reroutes"].int ?? 0
                let src = m["sources"].arr.compactMap { $0.str }.contains("transcript") ? "transcript" : ""
                let note = [rr > 0 ? "↪\(rr)" : "", src].filter { !$0.isEmpty }.joined(separator: " ")
                return Slice(label: m["model"].str ?? "?", count: m["requests"].int ?? 0, note: note,
                             color: vendorColor(m["vendor"].str ?? "other"))
            }
            menu.addItem(chartItem(stackedChart(title: "by model · last 1h", slices: models)))
            let proxies = d["by_proxy"].arr.map { p -> Slice in
                Slice(label: p["proxy"].str ?? "?", count: p["requests"].int ?? 0,
                      note: p["source"].str == "transcript" ? "transcript" : "",
                      color: providerColor(p["provider"].str ?? "other"))
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
            for r in rr {
                if r["kinds"].exists {
                    for k in r["kinds"].keys { kinds[k, default: 0] += r["kinds"][k].int ?? 0 }
                } else { kinds[r["kind"].str ?? "?", default: 0] += r["count"].int ?? 0 }
            }
            add(info(kinds.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · ") +
                     "  (alias = Claude name served by GLM/DeepSeek, vision = glm→deepseek, fallback:why = router retry, why = outage-500/rate-limit/…)", dim: true))
            for r in rr.prefix(6) {
                // one row per route: several reasons on it read as "a 2+b 1"
                let kinds = r["kinds"]
                let multi = kinds.exists && kinds.keys.count > 1
                let kindText = multi
                    ? kinds.keys.map { k in "\(k) \(kinds[k].int ?? 0)" }.sorted().joined(separator: "+")
                    : (r["kind"].str ?? "")
                add(info("\(r["from"].str ?? "?")→\(r["to"].str ?? "?") ×\(r["count"].int ?? 0) \(kindText)  [\(r["proxy"].str ?? "?")]", mono: true))
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
        let metricItem = NSMenuItem(title: "Chart Metric", action: nil, keyEquivalent: "")
        let metricMenu = NSMenu(); metricMenu.autoenablesItems = false
        for m in ChartMetric.allCases where !m.isStacked { metricMenu.addItem(action(m.title, #selector(AppController.setChartMetric(_:)), represented: m.rawValue, state: c.chartMetric == m)) }
        metricItem.submenu = metricMenu
        menu.addItem(metricItem)
        menu.addItem(action("Show logo image in menubar", #selector(AppController.toggleImage), state: c.showImage))
        menu.addItem(action("Show text next to the image", #selector(AppController.toggleText), state: c.showText))
        menu.addItem(action("Show 1h traffic window (off: 15m)", #selector(AppController.toggleWindow), state: c.shareWindow == "1h"))
        menu.addItem(action("Show tokens as traffic metric (off: requests)", #selector(AppController.toggleMetric), state: c.shareMetric == "tokens"))
        menu.addItem(.separator())
        menu.addItem(action("Floating Window", #selector(AppController.toggleFloatingWindow), state: c.windowVisible))
        let layoutItem = NSMenuItem(title: "Window Layout", action: nil, keyEquivalent: "")
        let layoutMenu = NSMenu(); layoutMenu.autoenablesItems = false
        for l in MonitorLayout.allCases { layoutMenu.addItem(action(l.title, #selector(AppController.setWindowLayout(_:)), represented: l.rawValue, state: c.windowLayout == l)) }
        layoutItem.submenu = layoutMenu
        menu.addItem(layoutItem)
        let graphItem = NSMenuItem(title: "Window Graph", action: nil, keyEquivalent: "")
        let graphMenu = NSMenu(); graphMenu.autoenablesItems = false
        for g in GraphMode.allCases { graphMenu.addItem(action(g.title, #selector(AppController.setWindowGraph(_:)), represented: g.rawValue, state: c.windowGraph == g)) }
        graphItem.submenu = graphMenu
        menu.addItem(graphItem)
        let windowMetricItem = NSMenuItem(title: "Window Metric", action: nil, keyEquivalent: "")
        let windowMetricMenu = NSMenu(); windowMetricMenu.autoenablesItems = false
        for m in ChartMetric.allCases { windowMetricMenu.addItem(action(m.title, #selector(AppController.setWindowMetric(_:)), represented: m.rawValue, state: c.windowMetric == m)) }
        windowMetricItem.submenu = windowMetricMenu
        menu.addItem(windowMetricItem)
        let opacityItem = NSMenuItem(title: "Window Opacity", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu(); opacityMenu.autoenablesItems = false
        for o in [100, 80, 60, 40] { opacityMenu.addItem(action("\(o)%", #selector(AppController.setWindowOpacity(_:)), represented: Double(o) / 100, state: abs(c.windowOpacity - Double(o) / 100) < 0.01)) }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)
        menu.addItem(action("Window Click-through (menu turns it off)", #selector(AppController.toggleWindowClickThrough), state: c.windowClickThrough))
        menu.addItem(.separator())
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

final class AppController: NSObject, NSMenuDelegate, NSWindowDelegate {
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
    // floating monitor window
    var panel: NSPanel?
    let monitorView = MonitorView(frame: .zero)
    var windowVisible: Bool { defaults.bool(forKey: "windowVisible") }
    var windowLayout: MonitorLayout { MonitorLayout(rawValue: defaults.string(forKey: "windowLayout") ?? "") ?? .horizontal }
    var windowGraph: GraphMode { GraphMode(rawValue: defaults.string(forKey: "windowGraph") ?? "") ?? .both }
    var windowMetric: ChartMetric { ChartMetric(rawValue: defaults.string(forKey: "windowMetric") ?? "") ?? .requests }
    var chartMetric: ChartMetric { ChartMetric(rawValue: defaults.string(forKey: "chartMetric") ?? "") ?? .requests }
    var windowOpacity: Double { defaults.object(forKey: "windowOpacity") as? Double ?? 1.0 }
    var windowClickThrough: Bool { defaults.bool(forKey: "windowClickThrough") }

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        render(title: Summary(glyph: "…", symbol: "ellipsis.circle", text: "", state: "loading"), stale: false)
        // light/dark menubar: the render cache key already includes the
        // effective appearance, so the 5 s tick re-renders within 5 s of a flip.
        // No KVO here: observing effectiveAppearance self-fed (render wrote
        // button properties -> AppKit flipped appearance -> observer -> tick ->
        // render ...) and burned a full core (2026-11-06 audit, 94-98% CPU).
        rebuildMenu()
        poll()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.poll() }
        // countdown in the title without hitting the CLI
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        // `llm-usage menubar window show|hide|toggle` drops a one-line command file; no IPC beyond that
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkWindowCommand()
            self?.refreshInflight()  // cheap file reads: catches a missed FS event
        }
        watchInflightDirs()
        watchFleetHosts()
        spawnFleetStream()
        if windowVisible { showWindow() }
    }

    /// Peer in-flight at request boundaries, not at the 30 s poll cadence: one
    /// detached `llm-usage fleet stream` holds a long-lived ssh per peer and
    /// rewrites fleet/<host>/inflight.json on every change; watchFleetHosts
    /// picks the rewrites up and refreshInflight reads them. Its own flock
    /// makes a second spawn a no-op (a relaunch while the old child still runs
    /// just adopts it), and it deliberately outlives this app: serve and the
    /// CLI read the same cache, so quitting the menubar keeps the cache warm.
    private var fleetStream: Process?
    private func spawnFleetStream() {
        guard let bin = findUsageBinary() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["fleet", "stream"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            fleetStream = p
        } catch {
            // not fatal: the 30 s pull path still fills the snapshots
        }
    }

    // Event-driven in-flight updates: the monitor plugin (copilot-api) and
    // litellm_usage_log rewrite inflight-<port>-<pid>.json on every request
    // start and end (atomic tmp+rename, ~50 ms), so watching the directory
    // turns the wait bar's rise and fall into a reaction to the actual request
    // boundary instead of the poll cadence. The timers above stay as backstops.
    private var inflightWatches: [(source: DispatchSourceFileSystemObject, path: String)] = []
    private var inflightPollPending = false

    private func inflightDirs() -> [String] {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        var dirs = [env["LLM_USAGE_DIR"] ?? "\(home)/.local/state/llm-usage"]
        if let monitor = env["COPILOT_API_MONITOR_DIR"], !monitor.isEmpty { dirs.append(monitor) }
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }
    }

    /// A vnode watch covers ONE directory's entries, not its descendants: the
    /// fleet cache rewrites happen inside fleet/<host>/, so `fleet` itself only
    /// reports host dirs appearing/vanishing. Watch the base for membership
    /// churn and each host dir for its inflight.json tmp+rename, reconciling
    /// the host watches whenever the base fires.
    private var fleetBaseWatch: DispatchSourceFileSystemObject?
    private var fleetHostWatches: [String: DispatchSourceFileSystemObject] = [:]

    private func fleetBaseDir() -> String {
        let env = ProcessInfo.processInfo.environment
        return (env["LLM_USAGE_DIR"] ?? "\(NSHomeDirectory())/.local/state/llm-usage") + "/fleet"
    }

    private func watchFleetHosts() {
        let base = fleetBaseDir()
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let fd = open(base, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self = self else { return }
            let events = source?.data ?? []
            if events.contains(.delete) || events.contains(.rename) {
                // the fleet dir itself was replaced: re-open it, then rescan hosts
                self.fleetBaseWatch?.cancel()
                self.fleetBaseWatch = nil
                self.watchFleetHosts()
                return
            }
            self.syncFleetHostWatches()
            self.inflightChanged()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fleetBaseWatch = source
        syncFleetHostWatches()
    }

    /// Watch every fleet/<host>/ dir that currently exists; drop watches for
    /// dirs that vanished. Cheap enough to run on every base-dir event.
    private func syncFleetHostWatches() {
        let base = fleetBaseDir()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { return }
        var wanted = Set<String>()
        for name in names {
            let dir = base + "/" + name
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            wanted.insert(dir)
        }
        for (path, source) in fleetHostWatches where !wanted.contains(path) {
            source.cancel()
            fleetHostWatches.removeValue(forKey: path)
        }
        for dir in wanted where fleetHostWatches[dir] == nil {
            let fd = open(dir, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                guard let self = self else { return }
                let events = source?.data ?? []
                if events.contains(.delete) || events.contains(.rename) {
                    self.syncFleetHostWatches()  // this host dir went away (or was replaced)
                }
                self.inflightChanged()
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            fleetHostWatches[dir] = source
        }
    }

    private func watchInflightDirs() {
        for dir in inflightDirs() {
            watchInflightDir(dir)
        }
    }

    private func watchInflightDir(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self = self else { return }
            // the directory itself went away (or was replaced): re-open it
            let events = source?.data ?? []
            if events.contains(.delete) || events.contains(.rename) {
                self.rewatchInflightDir(dir)
                return
            }
            self.inflightChanged()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        inflightWatches.append((source, dir))
    }

    private func rewatchInflightDir(_ dir: String) {
        for (source, path) in inflightWatches where path == dir {
            source.cancel()
        }
        inflightWatches.removeAll { $0.path == dir }
        watchInflightDir(dir)
        inflightChanged()
    }

    /// Coalesce a burst of file events (a request start rewrites the file, and
    /// several proxies write side by side) into one cheap in-flight read.
    private func inflightChanged() {
        guard !inflightPollPending else { return }
        inflightPollPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }
            self.inflightPollPending = false
            self.refreshInflight()
        }
    }

    /// The in-flight files are tiny and rewritten on every request boundary, so
    /// the app reads them itself on each event (microseconds) instead of
    /// spawning `llm-usage menubar-data` (process + full aggregation). The full
    /// poll keeps its own slow cadence, Activity-Monitor style: sample the hot
    /// metric cheaply and often, refresh everything else rarely.
    func refreshInflight() {
        let now = Date()
        var flights: [(age: Double, id: String, model: String)] = []
        for dir in inflightDirs() {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for name in entries where name.hasPrefix("inflight-") && name.hasSuffix(".json") {
                let path = dir + "/" + name
                guard let data = FileManager.default.contents(atPath: path),
                      let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let pid = (doc["pid"] as? NSNumber)?.int32Value,
                      kill(pid, 0) == 0 || errno == EPERM,
                      let requests = doc["requests"] as? [String: Any]
                else { continue }
                let port = (doc["port"] as? String) ?? "?"
                for (rid, raw) in requests {
                    guard let req = raw as? [String: Any], let t = (req["t"] as? NSNumber)?.doubleValue else { continue }
                    let model = (req["actual_model"] as? String) ?? (req["requested"] as? String) ?? (req["model"] as? String) ?? ""
                    flights.append((max(0, now.timeIntervalSince1970 - t), "\(port):\(rid)", model))
                }
            }
        }
        // peer snapshots: fleet/<host>/inflight.json, rewritten at request boundaries
        // by `fleet stream` (and by every pull). Gated on the last payload's fleet
        // config — a cached host dir from a disabled/reconfigured fleet must not
        // keep drawing bars (read_fleet_inflight filters the same way). Same
        // staleness drop as the CLI (2*TTL + ssh timeout on the doc's t, 110 s):
        // a dead stream must not leave ghost bars behind. Ages come from each
        // request's own t, so clock drift only ever clamps to 0, never negative.
        var fleetHosts = Set<String>()
        if let d = data, (d["fleet"]["enabled"].bool ?? false) {
            fleetHosts = Set(d["fleet"]["hosts"].arr.compactMap { $0["name"].str })
        }
        var freshHosts = Set<String>()
        if !fleetHosts.isEmpty {
            let fleetBase = fleetBaseDir()
            if let names = try? FileManager.default.contentsOfDirectory(atPath: fleetBase) {
                for host in names where fleetHosts.contains(host) {
                    let dirPath = fleetBase + "/" + host
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue,
                          let raw = FileManager.default.contents(atPath: dirPath + "/inflight.json"),
                          let doc = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
                          let t = (doc["t"] as? NSNumber)?.doubleValue,
                          now.timeIntervalSince1970 - t <= 110 else { continue }
                    // a host with a successfully read snapshot (EVEN an empty one) is
                    // owned by the file: the 30 s payload may still list requests the
                    // stream already watched finish, and must not re-add them
                    freshHosts.insert(host)
                    for req in (doc["requests"] as? [[String: Any]]) ?? [] {
                        guard let rt = (req["t"] as? NSNumber)?.doubleValue, let id = req["id"] as? String else { continue }
                        flights.append((max(0, now.timeIntervalSince1970 - rt), "\(host):\(id)", (req["model"] as? String) ?? ""))
                    }
                }
            }
        }
        // candidates: the files above plus the peer requests from the last payload
        // (a fallback for hosts whose files were not readable or fleet-disabled
        // runs). Sort fleet-wide by age, then keep the OLDEST 16 — capping the
        // local list first would let 16 young locals hide an older peer's bars.
        var candidates = flights
        var seen = Set(candidates.map { $0.id })
        if let d = data, let generated = parseISO(d["generated_at"].str) {
            let drift = max(0, now.timeIntervalSince(generated))
            for row in d["inflight"]["requests"].arr {
                guard let host = row["host"].str, !freshHosts.contains(host),
                      let id = row["id"].str, seen.insert(id).inserted else { continue }
                candidates.append((max(0, (row["seconds"].dbl ?? 0) + drift), id, row["model"].str ?? ""))
            }
        }
        candidates.sort { $0.age > $1.age }  // oldest first: bars stack upward above it
        monitorView.flights = candidates.prefix(16).map { Flight(id: $0.id, model: $0.model, seconds: $0.age) }
    }

    func context() -> MenuContext {
        MenuContext(data: data, now: Date(), refreshed: lastGood, stale: lastError != nil && data != nil, error: lastError,
                    charts: charts, chartMetric: chartMetric, notifications: notifications,
                    launchAgentInstalled: FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/com.kaovilai.llm-usage-menubar.plist"),
                    showImage: showImage, showText: showText, shareWindow: shareWindow, shareMetric: shareMetric,
                    windowVisible: windowVisible, windowLayout: windowLayout, windowGraph: windowGraph, windowMetric: windowMetric, windowOpacity: windowOpacity,
                    windowClickThrough: windowClickThrough)
    }

    func tick() {
        updateWindow()
        guard let d = data else { return }
        let c = context()
        let s = summarize(d, now: c.now, stale: c.stale)
        render(title: s, stale: c.stale)
        // the throttle expired: poll right away so the title returns to normal
        let th = d["throttled"]
        if th.exists, let reset = parseISO(th["reset_at"].str), reset <= c.now { poll() }

    }

    // The menu-bar image is rebuilt every 5 s tick and every poll; most of those
    // ticks change nothing but the text (countdown, same share, same state), so
    // the raster is cached under everything that shapes it.
    private var statusImageCache: (key: String, image: NSImage)?
    private var symbolImageCache: [String: NSImage] = [:]
    private var lastRenderKey: String?

    func render(title s: Summary, stale: Bool) {
        guard let button = statusItem.button else { return }
        // rewriting identical button properties still makes AppKit rebuild the
        // status item snapshot; skip when nothing that shapes it moved. The
        // share text shapes the logos/accessibility, and showImage/showText the
        // toggles — without them a toggle or a share change left the button stale.
        let shareKey = data?["share"].exists == true ? shareDescription(data!["share"]) : ""
        let renderKey = "\(s.state)|\(s.text)|\(stale)|\(button.effectiveAppearance.name.rawValue)|\(button.appearsDisabled)|\(showImage)|\(showText)|\(shareKey)"
        if renderKey == lastRenderKey { return }
        lastRenderKey = renderKey
        if showImage, let d = data, d["share"].exists {
            let share = d["share"]
            let shareText = shareDescription(share)
            let key = "\(s.state)|\(button.effectiveAppearance.name.rawValue)|\(shareText)"
            let img: NSImage
            if let hit = statusImageCache, hit.key == key {
                img = hit.image
            } else {
                img = statusImage(models: shareEntries(share["models"]), providers: shareEntries(share["providers"]),
                                  badge: badgeColor(for: s.state), appearance: button.effectiveAppearance)
                statusImageCache = (key, img)
            }
            let text = showText ? s.text : ""
            img.accessibilityDescription = "llm-usage \(s.state). " + shareText
            button.image = img
            button.imagePosition = text.isEmpty ? .imageOnly : .imageLeading
            button.title = text.isEmpty ? "" : " " + text
            button.setAccessibilityLabel("llm-usage \(s.state). " + shareText)
            button.appearsDisabled = stale
            button.toolTip = "llm-usage: \(s.state)\n" + shareText
            return
        }
        var symbol = symbolImageCache[s.symbol]
        if symbol == nil {
            symbol = NSImage(systemSymbolName: s.symbol, accessibilityDescription: s.state)
            symbol?.isTemplate = true
            if let symbol { symbolImageCache[s.symbol] = symbol }
        }
        if let img = symbol {
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

    /// The dashboard (:4150, `llm-usage serve`) keeps the transcript and proxy
    /// parse caches warm; polling its /api/menubar answers in milliseconds
    /// where a fresh `menubar-data` process costs ~0.3 s of parsing. Falls back
    /// to the CLI when the dashboard is not running.
    func dashboardMenubarData(window: String, metric: String) -> J? {
        let port = ProcessInfo.processInfo.environment["LLM_USAGE_PORT"] ?? "4150"
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/menubar?share_window=\(window)&share_metric=\(metric)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        var out: J?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { sem.signal() }
            guard let data,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            out = J(v: obj)
        }.resume()
        _ = sem.wait(timeout: .now() + 2)
        return out
    }

    func poll() {
        if polling { return }
        polling = true
        let args = ["menubar-data", "--share-window", shareWindow, "--share-metric", shareMetric]
        let window = shareWindow, metric = shareMetric
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = self?.dashboardMenubarData(window: window, metric: metric).map { Result<J, PollError>.success($0) }
                ?? runUsage(args).flatMap(parseJSON)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.polling = false
                switch result {
                case .success(let j):
                    self.data = j
                    self.refreshInflight()  // keep the bar list fresh with every full poll too
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
                self.updateWindow()
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

    // MARK: floating window
    func updateWindow() {
        guard let p = panel, p.isVisible else { return }
        monitorView.startWaitAnimation()  // 20 Hz needle; no-op once started
        monitorView.now = Date()
        monitorView.stale = lastError != nil && data != nil
        monitorView.graphMode = windowGraph
        monitorView.metric = windowMetric
        monitorView.data = data
    }

    func savedSize(_ l: MonitorLayout) -> NSSize {
        if let a = defaults.array(forKey: "windowSize.\(l.rawValue)") as? [Double], a.count == 2, a[0] >= l.minSize.width, a[1] >= l.minSize.height {
            return NSSize(width: a[0], height: a[1])
        }
        return l.defaultSize
    }

    func makePanel() -> NSPanel {
        let layout = windowLayout
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: savedSize(layout)),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = "LLM Usage"
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.acceptsMouseMovedEvents = true
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.delegate = self
        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: savedSize(layout)))
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        monitorView.frame = fx.bounds
        monitorView.autoresizingMask = [.width, .height]
        monitorView.layout = layout
        monitorView.onCopyHint = { [weak self] hint in self?.copy(hint) }
        monitorView.onToggleMetric = { [weak self] in self?.toggleWindowMetric() }
        fx.addSubview(monitorView)
        p.contentView = fx
        p.contentMinSize = layout.minSize
        if !p.setFrameAutosaveName("llm-usage-monitor"), let screen = NSScreen.main?.visibleFrame {  // first run: top right of the main screen
            p.setFrameTopLeftPoint(NSPoint(x: screen.maxX - p.frame.width - 16, y: screen.maxY - 16))
        }
        return p
    }

    func showWindow() {
        if panel == nil { panel = makePanel() }
        guard let p = panel else { return }
        p.alphaValue = CGFloat(windowOpacity)
        p.ignoresMouseEvents = windowClickThrough
        defaults.set(true, forKey: "windowVisible")
        p.orderFrontRegardless()
        updateWindow()
        rebuildMenu()
    }

    func hideWindow() {
        defaults.set(false, forKey: "windowVisible")
        panel?.orderOut(nil)
        rebuildMenu()
    }

    func windowWillClose(_ notification: Notification) {
        defaults.set(false, forKey: "windowVisible")
        rebuildMenu()
    }

    func windowDidResize(_ notification: Notification) {
        guard let p = panel, p.isVisible else { return }
        let size = p.contentRect(forFrameRect: p.frame).size
        defaults.set([Double(size.width), Double(size.height)], forKey: "windowSize.\(windowLayout.rawValue)")
    }

    func applyWindowLayout() {
        guard let p = panel else { return }
        let l = windowLayout
        let topLeft = NSPoint(x: p.frame.minX, y: p.frame.maxY)
        monitorView.layout = l
        p.contentMinSize = l.minSize
        p.setContentSize(savedSize(l))
        p.setFrameTopLeftPoint(topLeft)
    }

    func checkWindowCommand() {
        let path = stateDir() + "/menubar-window.cmd"
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: path)
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "show": showWindow()
        case "hide": hideWindow()
        case "toggle": toggleFloatingWindow()
        default: break
        }
    }

    // MARK: actions
    @objc func toggleFloatingWindow() { if windowVisible && panel?.isVisible == true { hideWindow() } else { showWindow() } }
    @objc func setWindowLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, MonitorLayout(rawValue: raw) != nil else { return }
        defaults.set(raw, forKey: "windowLayout")
        applyWindowLayout()
        rebuildMenu()
    }
    @objc func setWindowGraph(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, GraphMode(rawValue: raw) != nil else { return }
        defaults.set(raw, forKey: "windowGraph")
        updateWindow()
        rebuildMenu()
    }
    @objc func setWindowMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, ChartMetric(rawValue: raw) != nil else { return }
        defaults.set(raw, forKey: "windowMetric")
        updateWindow()
        rebuildMenu()
    }
    func toggleWindowMetric() {
        let all = ChartMetric.allCases
        let next = all[((all.firstIndex(of: windowMetric) ?? 0) + 1) % all.count]
        defaults.set(next.rawValue, forKey: "windowMetric")
        updateWindow()
        rebuildMenu()
    }
    @objc func setChartMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, ChartMetric(rawValue: raw) != nil else { return }
        defaults.set(raw, forKey: "chartMetric")
        rebuildMenu()
    }
    @objc func setWindowOpacity(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        defaults.set(v, forKey: "windowOpacity")
        panel?.alphaValue = CGFloat(v)
        rebuildMenu()
    }
    @objc func toggleWindowClickThrough() {
        defaults.set(!windowClickThrough, forKey: "windowClickThrough")
        panel?.ignoresMouseEvents = windowClickThrough  // the menubar menu is the way back
        rebuildMenu()
    }
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

func stateDir() -> String {
    ProcessInfo.processInfo.environment["LLM_USAGE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        ?? (ProcessInfo.processInfo.environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.local/state") + "/llm-usage"
}

func acquireSingleInstanceLock() -> Bool {
    let state = stateDir()
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

func argValue(_ name: String) -> String? {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return nil
}

if let path = argValue("--window-png") {
    _ = NSApplication.shared
    guard case .success(let j) = loadSource() else { FileHandle.standardError.write("window-png: no usable data\n".data(using: .utf8)!); exit(1) }
    let layout = MonitorLayout(rawValue: argValue("--layout") ?? "horizontal") ?? .horizontal
    var size = layout.defaultSize
    if let sz = argValue("--size")?.split(separator: "x"), sz.count == 2, let w = Double(sz[0]), let h = Double(sz[1]) { size = NSSize(width: w, height: h) }
    writeWindowPNG(j, layout: layout, size: size, dark: args.contains("--dark"), mode: GraphMode(rawValue: argValue("--graph") ?? "both") ?? .both,
                   metric: ChartMetric(rawValue: argValue("--window-metric") ?? "") ?? .requests,
                   stale: args.contains("--stale"), hover: argValue("--hover"),
                   graphMinute: argValue("--graph-hover").flatMap { Int($0) }, to: path)
    exit(0)
}

if args.contains("--dump-menu") {
    _ = NSApplication.shared
    let source = loadSource()
    var ctx = MenuContext(data: nil, now: Date(), refreshed: nil, stale: false, error: nil, charts: !args.contains("--no-charts"),
                          chartMetric: ChartMetric(rawValue: argValue("--chart-metric") ?? "") ?? .requests,
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
        ctx.windowVisible = args.contains("--window-visible")
        ctx.windowLayout = MonitorLayout(rawValue: argValue("--window-layout") ?? "") ?? .horizontal
        ctx.windowGraph = GraphMode(rawValue: argValue("--window-graph") ?? "") ?? .both
        ctx.windowMetric = ChartMetric(rawValue: argValue("--window-metric") ?? "") ?? .requests
        ctx.windowOpacity = Double(argValue("--window-opacity") ?? "") ?? 1.0
        ctx.windowClickThrough = args.contains("--window-click-through")
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
