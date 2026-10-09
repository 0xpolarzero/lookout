// Lookout in the notch, v3. Measured against Linear's own UI (linear.app's in-page product mockups):
// text 13/510 and 12/400, greys #f7f8f8 #d0d6e0 #8a8f98 #62666d, panel #0f1011 / raised #161718,
// 0.5pt white borders at 6–12%, 14pt status glyphs, 28pt controls, radii 6/8/12.
//   swiftc -O -parse-as-library Island.swift -o /tmp/island && /tmp/island shots
import AppKit
import SwiftUI

// MARK: - Tokens

enum C {
    static let shell = Color.black
    static let panel = rgb(15, 16, 17)
    static let raised = rgb(22, 23, 24)
    static let edge = Color.white.opacity(0.08)
    static let edgeSoft = Color.white.opacity(0.06)
    static let fill = Color.white.opacity(0.04)
    static let fillStrong = Color.white.opacity(0.06)
    static let hi = rgb(247, 248, 248)
    static let text = rgb(208, 214, 224)
    static let text2 = rgb(138, 143, 152)
    static let text3 = rgb(98, 102, 109)
    static let yellow = rgb(240, 191, 0)
    static let indigo = rgb(94, 106, 210)
    static let gray = rgb(156, 157, 161)
    static let red = rgb(235, 87, 87)
    static let green = rgb(76, 183, 130)
    static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r / 255, green: g / 255, blue: b / 255) }
}

enum F {
    static let title = Font.system(size: 13, weight: .medium)
    static let body = Font.system(size: 13)
    static let meta = Font.system(size: 12)
    static let metaM = Font.system(size: 12, weight: .medium)
    static let tiny = Font.system(size: 11, weight: .medium)
}

extension Text {
    func t(_ f: Font, _ c: Color) -> Text { self.font(f).foregroundColor(c) }
}

// MARK: - Glyphs, 14pt, to Linear's construction

enum G { case ask, plan, stuck, done, working, quiet, ciFail, ciRun, ciPass }

struct Glyph: View {
    let g: G
    var body: some View {
        ZStack {
            switch g {
            case .ask: filled(C.yellow) { Text("?").font(.system(size: 9, weight: .black, design: .rounded)).foregroundColor(.black).offset(y: -0.2) }
            case .stuck: filled(C.red) { Text("!").font(.system(size: 9, weight: .black, design: .rounded)).foregroundColor(.black) }
            case .done: filled(C.indigo) { check }
            case .quiet: filled(C.text3) { check }
            case .ciPass: filled(C.green) { check }
            case .ciFail: filled(C.red) { Image(systemName: "xmark").font(.system(size: 6, weight: .black)).foregroundColor(.black) }
            case .plan: ring(C.yellow, 0.75)
            case .working: ring(C.gray, 0.5)
            case .ciRun: ring(C.yellow, 0.5)
            }
        }
        .frame(width: 14, height: 14)
    }
    var check: some View { Image(systemName: "checkmark").font(.system(size: 6.5, weight: .black)).foregroundColor(.black) }
    func filled<V: View>(_ c: Color, @ViewBuilder _ mark: () -> V) -> some View {
        ZStack { Circle().fill(c).frame(width: 12, height: 12); mark() }
    }
    /// Linear's "in progress": a 12pt ring, 1.5pt, and a 3.5pt pie inside.
    func ring(_ c: Color, _ f: Double) -> some View {
        ZStack {
            Circle().strokeBorder(c, lineWidth: 1.5).frame(width: 12, height: 12)
            Pie(f: f).fill(c).frame(width: 7, height: 7)
        }
    }
}

struct Pie: Shape {
    var f: Double
    func path(in r: CGRect) -> Path {
        var p = Path(); let c = CGPoint(x: r.midX, y: r.midY)
        p.move(to: c)
        p.addArc(center: c, radius: r.width / 2, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * f), clockwise: false)
        p.closeSubpath(); return p
    }
}

// MARK: - Small parts

struct Pill: View {
    let label: String; var count: String? = nil; var on = false
    var body: some View {
        HStack(spacing: 6) {
            Text(label).t(F.title, on ? C.text : C.text2)
            if let count { Text(count).t(F.meta, C.text3) }
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(on ? C.fillStrong : .clear))
    }
}

struct Group: View {
    let label: String; let count: Int
    var body: some View {
        HStack(spacing: 6) { Text(label).t(F.metaM, C.text2); Text("\(count)").t(F.meta, C.text3); Spacer() }
            .padding(.horizontal, 10).frame(height: 28)
    }
}

/// One line, as Linear's list rows: glyph, title, then what's quiet on the right.
struct Row: View {
    let g: G; let title: String; var trail: String = ""; var time: String = ""; var on = false; var dim = false
    var body: some View {
        HStack(spacing: 10) {
            Glyph(g: g)
            Text(title).t(F.title, dim ? C.text2 : C.text).lineLimit(1)
            Spacer(minLength: 12)
            if !trail.isEmpty { Text(trail).t(F.meta, C.text3).lineLimit(1) }
            if !time.isEmpty { Text(time).t(F.meta, C.text3).monospacedDigit().fixedSize().frame(width: 28, alignment: .trailing) }
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(on ? C.fill : .clear))
    }
}

struct Composer: View {
    var to: String
    var draft: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let draft {
                (Text(draft).foregroundColor(C.hi) + Text("▏").foregroundColor(C.indigo)).font(F.body)
            } else {
                Text("Reply to \(to)…").t(F.body, C.text3)
            }
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "at").font(.system(size: 10.5, weight: .medium))
                    Text(to).font(F.metaM)
                }
                .foregroundColor(C.text2)
                .padding(.horizontal, 7).frame(height: 22)
                .background(Capsule().strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5))
                Spacer()
                Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold)).foregroundColor(draft == nil ? C.text3 : .black)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(draft == nil ? C.fillStrong : C.text))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(C.edge, lineWidth: 0.5))
    }
}

// MARK: - The island

enum Notch { static let w: CGFloat = 188; static let h: CGFloat = 32 }

struct IslandShape: Shape {
    var r: CGFloat; var flare: CGFloat = 6
    func path(in b: CGRect) -> Path {
        let w = b.width, h = b.height, f = flare, R = min(r, h / 2)
        var p = Path()
        p.move(to: .zero)
        p.addQuadCurve(to: CGPoint(x: f, y: f), control: CGPoint(x: f, y: 0))
        p.addLine(to: CGPoint(x: f, y: h - R))
        p.addArc(tangent1End: CGPoint(x: f, y: h), tangent2End: CGPoint(x: f + R, y: h), radius: R)
        p.addLine(to: CGPoint(x: w - f - R, y: h))
        p.addArc(tangent1End: CGPoint(x: w - f, y: h), tangent2End: CGPoint(x: w - f, y: h - R), radius: R)
        p.addLine(to: CGPoint(x: w - f, y: f))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - f, y: 0))
        p.closeSubpath(); return p
    }
}

/// What sits either side of the camera. The same in every state: the island grows from here.
struct Ears: View {
    var asks = 3
    var working = 2
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Glyph(g: .ask)
                Text("\(asks)").t(F.metaM, C.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: Notch.w)
            HStack(spacing: 6) {
                Text("\(working)").t(F.metaM, C.text2)
                Glyph(g: .working)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: Notch.h)
    }
}

/// The black shell (one with the notch) holding Linear's inset panel, corners concentric: 12 inside 18.
struct Island<P: View>: View {
    var width: CGFloat
    @ViewBuilder var panel: P
    var body: some View {
        VStack(spacing: 0) {
            Ears()
            panel
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 12).fill(C.panel))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(C.edge, lineWidth: 0.5))
                .padding(.horizontal, 6).padding(.bottom, 6)
        }
        .frame(width: width)
        .padding(.horizontal, 6)
        .background(IslandShape(r: 18).fill(C.shell))
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
    }
}

// MARK: - Desktop

struct Desk<Content: View>: View {
    var size = CGSize(width: 1512, height: 520)
    @ViewBuilder var content: Content
    var body: some View {
        ZStack(alignment: .top) {
            if let img = NSImage(contentsOfFile: "/tmp/island-proto/wall.png") {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: 982, alignment: .top).frame(height: size.height, alignment: .top).clipped()
            }
            menuBar
            content
        }
        .frame(width: size.width, height: size.height, alignment: .top).clipped()
    }
    var menuBar: some View {
        HStack(spacing: 20) {
            Image(systemName: "apple.logo").font(.system(size: 14))
            Text("Claude").font(.system(size: 13, weight: .bold))
            ForEach(["File", "Edit", "View", "Window", "Help"], id: \.self) { Text($0).font(.system(size: 13)) }
            Spacer()
            Image(systemName: "wifi").font(.system(size: 13))
            Image(systemName: "battery.75percent").font(.system(size: 15))
            Text("Thu 9 Oct  14:32").font(.system(size: 13))
        }
        .foregroundColor(.white.opacity(0.9))
        .padding(.horizontal, 18).frame(height: Notch.h)
        .overlay { IslandShape(r: 9, flare: 0).fill(.black).frame(width: Notch.w, height: Notch.h) }
    }
}

// MARK: - States

/// 1. At rest: the notch, a little wider. Nothing else on screen.
struct Rest: View {
    var body: some View {
        Desk(size: CGSize(width: 1512, height: 160)) {
            Ears()
                .frame(width: Notch.w + 104)
                .background(IslandShape(r: 10).fill(C.shell))
        }
    }
}

/// 2. A question arrives: the island holds it a few seconds, answerable from the keyboard.
struct Arrives: View {
    var body: some View {
        Desk(size: CGSize(width: 1512, height: 300)) {
            Island(width: 400) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text("api-server").t(F.metaM, C.text2)
                        Text("·").t(F.meta, C.text3)
                        Text("Database migration plan").t(F.meta, C.text3)
                        Spacer()
                        Text("now").t(F.meta, C.text3)
                    }
                    Text("Which database should the new jobs table live in?").t(F.title, C.hi)
                        .padding(.top, 6)
                    HStack(spacing: 6) {
                        option("1", "Postgres"); option("2", "SQLite"); option("3", "Redis")
                        Spacer()
                        Text("Reply").t(F.meta, C.text3)
                    }
                    .padding(.top, 12)
                }
                .padding(12)
            }
        }
    }
    func option(_ n: String, _ s: String) -> some View {
        HStack(spacing: 6) { Text(n).t(F.meta, C.text3); Text(s).t(F.metaM, C.text) }
            .padding(.horizontal, 9).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.02)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5))
    }
}

/// 3. Hover: what needs you, then what's running. One line each.
struct Glance: View {
    var body: some View {
        Desk(size: CGSize(width: 1512, height: 380)) {
            Island(width: 400) {
                VStack(spacing: 0) {
                    Group(label: "Needs you", count: 3)
                    Row(g: .ask, title: "Database migration plan", trail: "api-server", time: "2m", on: true)
                    Row(g: .plan, title: "Update notifications", trail: "lcu", time: "9m")
                    Row(g: .stuck, title: "Landing page", trail: "web", time: "14m")
                    Group(label: "Done", count: 1).padding(.top, 4)
                    Row(g: .done, title: "CI failure diagnosis", trail: "lookout", time: "4m")
                    Group(label: "Working", count: 2).padding(.top, 4)
                    Row(g: .working, title: "zig build test", trail: "zig", time: "12m", dim: true)
                    Row(g: .working, title: "3 commands left running", trail: "lookout", time: "", dim: true)
                }
                .padding(6)
            }
        }
    }
}

/// 4. Open (⌃⌥R or a click): the same panel, taller; the selected card opens in place.
struct Open: View {
    var body: some View {
        Desk(size: CGSize(width: 1512, height: 700)) {
            Island(width: 440) {
                VStack(spacing: 0) {
                    HStack(spacing: 2) {
                        Pill(label: "For you", count: "4", on: true)
                        Pill(label: "Inbox", count: "5")
                        Pill(label: "CI")
                        Spacer()
                        Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundColor(C.text3).frame(width: 26, height: 26)
                    }
                    .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 2)

                    VStack(spacing: 0) {
                        Group(label: "Needs you", count: 3)
                        expanded
                        Row(g: .plan, title: "Update notifications", trail: "lcu", time: "9m")
                        Row(g: .stuck, title: "Landing page", trail: "web", time: "14m")
                        Group(label: "Done", count: 1).padding(.top, 4)
                        Row(g: .done, title: "CI failure diagnosis", trail: "lookout", time: "4m")
                        Group(label: "Working", count: 2).padding(.top, 4)
                        Row(g: .working, title: "zig build test", trail: "zig", time: "12m", dim: true)
                    }
                    .padding(.horizontal, 6)

                    Composer(to: "api-server").padding(10).padding(.top, 2)
                }
            }
        }
    }

    var expanded: some View {
        VStack(alignment: .leading, spacing: 0) {
            Row(g: .ask, title: "Database migration plan", trail: "api-server", time: "2m")
            VStack(alignment: .leading, spacing: 10) {
                Text("Which database should the new jobs table live in? The rest of the schema is on Postgres.")
                    .t(F.body, C.hi).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    choice("1", "Postgres", "one migration path", on: true)
                    choice("2", "SQLite", "simplest locally")
                    choice("3", "Redis", "not durable")
                }
            }
            .padding(.leading, 34).padding(.trailing, 10).padding(.bottom, 10)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(C.raised))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(C.edgeSoft, lineWidth: 0.5))
    }

    func choice(_ n: String, _ s: String, _ d: String, on: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(n).t(F.meta, C.text3).frame(width: 10)
            Text(s).t(F.title, C.text)
            Text(d).t(F.meta, C.text3)
            Spacer()
            if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(C.indigo) }
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? C.fillStrong : .clear))
        .padding(.leading, -8)
    }
}

/// 5. A thread: you, the Router, the session. As Linear's agent panel.
struct Thread: View {
    var body: some View {
        Desk(size: CGSize(width: 1512, height: 640)) {
            Island(width: 440) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).foregroundColor(C.text3)
                        Glyph(g: .plan)
                        Text("Update notifications").t(F.title, C.text)
                        Text("lcu").t(F.meta, C.text3)
                        Spacer()
                        Text("Open in Claude").t(F.meta, C.text3)
                    }
                    .padding(.horizontal, 12).frame(height: 40)
                    Rectangle().fill(C.edgeSoft).frame(height: 0.5)

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Plan ready · 4 steps").t(F.meta, C.text3)
                        VStack(alignment: .leading, spacing: 7) {
                            step(1, "Poll releases hourly and on wake")
                            step(2, "Ask before installing, with “Always”")
                            step(3, "Verify the signature before swapping")
                            step(4, "Tests for the prompt and the rollback", struck: true)
                        }
                        HStack { Spacer(); bubble("approve, but skip the rollback tests") }
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 10, weight: .semibold))
                            Text("Approved with your note · just now").font(F.meta)
                        }
                        .foregroundColor(C.text3)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) { Glyph(g: .working); Text("lcu").t(F.metaM, C.text2); Text("is building it · 1m").t(F.meta, C.text3) }
                            Text("Skipping the rollback tests as asked. I'll stop once the prompt works and ping you.")
                                .t(F.body, C.text).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(14)

                    Composer(to: "lcu").padding(10)
                }
            }
        }
    }
    func step(_ n: Int, _ s: String, struck: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").t(F.meta, C.text3).monospacedDigit()
            Text(s).font(F.body).foregroundColor(struck ? C.text3 : C.text).strikethrough(struck, color: C.text3)
        }
    }
    func bubble(_ s: String) -> some View {
        Text(s).t(F.body, C.hi)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(C.raised))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(C.edgeSoft, lineWidth: 0.5))
    }
}

/// 6. Inbox: GitHub, same list, faces instead of glyphs.
struct Inbox: View {
    let rows: [(String, String, String, String, Bool)] = [
        ("andrewrk", "std.Io: add vectored reads to File", "zig#21877", "3m", true),
        ("allevato", "Respect trailing comma config", "swift-format#1042", "18m", true),
        ("mattt", "Pill overlaps the Dock on the right", "lookout#12", "42m", true),
        ("ahoppen", "Add --lines option to format a range", "swift-format#1051", "1h", false),
        ("kylef", "Add GitHub Enterprise host setting", "lookout#15", "1h", false),
    ]
    var body: some View {
        Desk(size: CGSize(width: 1512, height: 520)) {
            Island(width: 440) {
                VStack(spacing: 0) {
                    HStack(spacing: 2) {
                        Pill(label: "For you", count: "4")
                        Pill(label: "Inbox", count: "5", on: true)
                        Pill(label: "CI")
                        Spacer()
                        Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundColor(C.text3).frame(width: 26, height: 26)
                    }
                    .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 2)
                    VStack(spacing: 0) {
                        Group(label: "Today", count: 5)
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                            HStack(spacing: 10) {
                                avatar(r.0)
                                Text(r.1).t(F.title, r.4 ? C.text : C.text2).lineLimit(1)
                                Spacer(minLength: 12)
                                Text(r.2).t(F.meta, C.text3)
                                Text(r.3).t(F.meta, C.text3).monospacedDigit().fixedSize().frame(width: 28, alignment: .trailing)
                            }
                            .padding(.horizontal, 10).frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: 8).fill(i == 0 ? C.fill : .clear))
                        }
                        Group(label: "Main branches", count: 4).padding(.top, 4)
                        HStack(spacing: 16) {
                            ci(.ciFail, "swift-format"); ci(.ciRun, "zig"); ci(.ciPass, "lookout"); ci(.ciPass, "lcu")
                            Spacer()
                        }
                        .padding(.horizontal, 10).frame(height: 32)
                    }
                    .padding(.horizontal, 6).padding(.bottom, 6)
                }
            }
        }
    }
    func avatar(_ u: String) -> some View {
        ZStack {
            if let i = NSImage(contentsOfFile: "/tmp/island-proto/avatars/\(u).png") { Image(nsImage: i).resizable() }
        }
        .frame(width: 16, height: 16).clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }
    func ci(_ g: G, _ s: String) -> some View { HStack(spacing: 6) { Glyph(g: g); Text(s).t(F.meta, C.text2) } }
}

// MARK: - Render

@main
struct Render {
    @MainActor static func main() {
        let dir = CommandLine.arguments.dropFirst().first ?? "shots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Crops centred on the notch.
        func mid(_ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: (1512 - w) / 2, y: 0, width: w, height: h) }
        save(Rest(), "1-rest", dir, mid(760, 120))
        save(Arrives(), "2-arrives", dir, mid(760, 240))
        save(Glance(), "3-glance", dir, mid(760, 380))
        save(Open(), "4-open", dir, mid(760, 700))
        save(Thread(), "5-thread", dir, mid(760, 640))
        save(Inbox(), "6-inbox", dir, mid(760, 400))
    }

    @MainActor static func save<V: View>(_ v: V, _ name: String, _ dir: String, _ crop: CGRect) {
        let r = ImageRenderer(content: v.environment(\.colorScheme, .dark))
        r.scale = 2
        guard var cg = r.cgImage else { print("failed \(name)"); return }
        if let c = cg.cropping(to: CGRect(x: crop.minX * 2, y: crop.minY * 2, width: crop.width * 2, height: crop.height * 2)) { cg = c }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        print("\(dir)/\(name).png")
    }
}
