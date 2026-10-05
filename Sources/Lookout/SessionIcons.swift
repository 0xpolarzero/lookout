import AppKit

/// The SF Symbols a session can get as its icon: built into macOS (nothing bundled), and chosen to cover what coding
/// sessions are about. Jev picks from these (it takes at most 255 options per question).
enum SessionIcons {
    static let candidates: [String] = [
        // Code and tools
        "terminal", "chevron.left.forwardslash.chevron.right", "curlybraces", "function", "number", "textformat",
        "hammer", "wrench.and.screwdriver", "wrench.adjustable", "screwdriver", "gearshape", "gearshape.2",
        "slider.horizontal.3", "switch.2", "puzzlepiece", "puzzlepiece.extension", "cube", "cube.transparent",
        "shippingbox", "archivebox", "tray.full", "folder", "doc.text", "doc.on.doc", "doc.text.magnifyingglass",
        "magnifyingglass", "scope", "binoculars", "eye", "ladybug", "ant", "bandage", "cross.case", "stethoscope",
        "testtube.2", "flask", "atom", "brain", "brain.head.profile", "sparkles", "wand.and.stars", "lightbulb",
        "arrow.triangle.branch", "arrow.triangle.merge", "arrow.triangle.pull", "point.3.connected.trianglepath.dotted",
        "arrow.triangle.2.circlepath", "arrow.clockwise", "arrow.uturn.backward", "arrow.up.arrow.down", "arrow.left.arrow.right",
        "arrow.down.circle", "arrow.up.circle", "square.and.arrow.up", "square.and.arrow.down", "link", "paperclip",
        "scissors", "trash", "eraser", "pencil", "pencil.and.ruler", "ruler", "square.stack.3d.up", "square.grid.2x2",
        "rectangle.3.group", "rectangle.split.3x1", "sidebar.left", "macwindow", "menubar.rectangle", "dock.rectangle",
        "rectangle.on.rectangle", "uiwindow.split.2x1", "keyboard", "command", "option", "cursorarrow", "cursorarrow.rays",
        "hand.point.up.left", "hand.tap", "hand.draw", "rectangle.and.pencil.and.ellipsis", "character.cursor.ibeam",
        // Systems and infra
        "cpu", "memorychip", "server.rack", "externaldrive", "internaldrive", "opticaldiscdrive", "network", "wifi",
        "antenna.radiowaves.left.and.right", "dot.radiowaves.left.and.right", "cable.connector", "powerplug", "bolt",
        "bolt.horizontal", "battery.100", "cloud", "icloud", "cloud.bolt", "globe", "globe.americas", "map", "mappin",
        "location", "signpost.right", "speedometer", "gauge.with.dots.needle.67percent", "timer", "stopwatch", "clock",
        "hourglass", "calendar", "alarm", "bell", "bell.badge", "flag", "flag.checkered", "tag", "bookmark",
        "pin", "lock", "lock.open", "key", "key.horizontal", "shield", "checkmark.shield", "exclamationmark.shield",
        "hand.raised", "eye.slash", "person.badge.key", "faceid", "touchid", "lock.shield",
        // Data
        "chart.bar", "chart.line.uptrend.xyaxis", "chart.pie", "chart.xyaxis.line", "waveform.path.ecg", "waveform",
        "tablecells", "list.bullet", "list.bullet.rectangle", "checklist", "list.number", "line.3.horizontal.decrease",
        "arrow.up.arrow.down.circle", "sum", "percent", "plusminus", "x.squareroot", "cylinder", "cylinder.split.1x2",
        "square.stack", "rectangle.stack", "books.vertical", "book", "book.closed", "text.book.closed", "newspaper",
        "doc.richtext", "doc.plaintext", "note.text", "text.quote", "text.alignleft", "quote.bubble", "character.book.closed",
        // People and communication
        "person", "person.2", "person.3", "person.crop.circle", "figure.wave", "bubble.left", "bubble.left.and.bubble.right",
        "ellipsis.bubble", "envelope", "paperplane", "megaphone", "phone", "video", "mic", "speaker.wave.2", "headphones",
        "hand.thumbsup", "heart", "star", "crown", "trophy", "medal", "rosette", "graduationcap", "studentdesk",
        "briefcase", "building.2", "house", "storefront", "cart", "bag", "creditcard", "banknote", "dollarsign.circle",
        "eurosign.circle", "bitcoinsign.circle", "chart.line.flattrend.xyaxis", "gift", "giftcard", "ticket",
        // Media and design
        "paintbrush", "paintbrush.pointed", "paintpalette", "eyedropper", "swatchpalette", "photo", "photo.on.rectangle",
        "camera", "film", "play.rectangle", "music.note", "music.note.list", "guitars", "pianokeys", "theatermasks",
        "gamecontroller", "dice", "die.face.5", "suit.spade", "puzzlepiece.fill", "square.on.circle", "circle.hexagongrid",
        "hexagon", "triangle", "seal", "app", "app.badge", "apps.iphone", "iphone", "ipad", "laptopcomputer",
        "desktopcomputer", "display", "applewatch", "tv", "printer", "scanner", "visionpro",
        // World
        "leaf", "tree", "flame", "drop", "snowflake", "sun.max", "moon", "cloud.sun", "wind", "tornado", "mountain.2",
        "water.waves", "fish", "bird", "pawprint", "tortoise", "hare", "ladybug.fill", "carrot", "cup.and.saucer",
        "fork.knife", "car", "bicycle", "airplane", "sailboat", "tram", "fuelpump", "figure.run", "dumbbell",
        "sportscourt", "soccerball", "basketball", "tennisball", "medical.thermometer", "pills", "heart.text.square",
        "atom", "globe.europe.africa", "sparkle", "rocket", "binoculars.fill",
    ]

    /// The candidates that exist on this macOS, without duplicates (at most 255, Jev's limit).
    static let available: [String] = {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted && NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
            .prefix(255).map { $0 }
    }()
}
