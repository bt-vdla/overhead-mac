import SwiftUI
import AppKit
import MapKit
import OverheadCore

// MARK: - Window

/// The hardware notch (width 0 on screens without one) and whether the pointer is over the panel.
@MainActor @Observable final class NotchModel {
    var notch = CGSize(width: 0, height: 24)
    var hovering = false
}

/// A borderless panel pinned to the top centre of the screen. It never takes clicks: hover is read from the pointer's
/// position, so the menu bar under the transparent part keeps working.
@MainActor final class PanelController {
    static let shared = PanelController()
    let model = NotchModel()
    private var panel: NSPanel?
    private var monitors: [Any] = []

    static let frameSize = CGSize(width: 520, height: 440)

    func start() {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.frameSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: PanelView(tracker: .shared, model: model))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        place()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PanelController.shared.place() }
        }
        watchPhase()
    }

    /// The display with a notch if there is one, else the main display; flush with its top edge.
    func place() {
        guard let panel, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let left = screen.auxiliaryTopLeftArea?.width ?? 0, right = screen.auxiliaryTopRightArea?.width ?? 0
        let hasNotch = screen.safeAreaInsets.top > 0 && left > 0
        model.notch = CGSize(width: hasNotch ? screen.frame.width - left - right : 0,
                             height: hasNotch ? screen.safeAreaInsets.top : NSStatusBar.system.thickness)
        let f = screen.frame
        panel.setFrame(CGRect(x: f.midX - Self.frameSize.width / 2, y: f.maxY - Self.frameSize.height,
                              width: Self.frameSize.width, height: Self.frameSize.height), display: true)
    }

    /// Pointer tracking runs only while something is showing.
    private func watchPhase() {
        let showing = withObservationTracking { Tracker.shared.presenter.phase != .hidden } onChange: {
            Task { @MainActor in PanelController.shared.watchPhase() }
        }
        if showing, monitors.isEmpty {
            place()
            if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { _ in
                MainActor.assumeIsolated { PanelController.shared.hover() }
            }) { monitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { e in
                MainActor.assumeIsolated { PanelController.shared.hover() }
                return e
            }) { monitors.append(m) }
        } else if !showing, !monitors.isEmpty {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            model.hovering = false
        }
    }

    private func hover() {
        guard let panel else { return }
        let phase = Tracker.shared.presenter.phase
        let s = PanelView.size(phase: phase, open: PanelView.isOpen(phase, hovering: model.hovering), notch: model.notch)
        let f = panel.frame
        let inside = CGRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height).contains(NSEvent.mouseLocation)
        if inside != model.hovering { model.hovering = inside }
    }
}

// MARK: - Panel

struct PanelView: View {
    let tracker: Tracker
    let model: NotchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let ear: CGFloat = 92
    static let openWidth: CGFloat = 440
    static func openHeight(_ notch: CGSize) -> CGFloat { max(notch.height, 24) + 324 }

    static func isOpen(_ phase: Presenter.Phase, hovering: Bool) -> Bool {
        phase == .expanded || (phase == .compact && hovering)
    }

    /// The black body's size, not counting the shoulders' flare. Hidden on a notch it shrinks back to the notch itself, so
    /// the drop grows out of the hardware.
    static func size(phase: Presenter.Phase, open: Bool, notch: CGSize) -> CGSize {
        if open { return CGSize(width: openWidth, height: openHeight(notch)) }
        let pill = CGSize(width: notch.width > 0 ? notch.width + 2 * ear : 240, height: max(notch.height, 24))
        if phase != .hidden { return pill }
        return notch.width > 0 ? notch : CGSize(width: pill.width, height: 0)
    }

    var body: some View {
        let phase = tracker.presenter.phase
        let open = Self.isOpen(phase, hovering: model.hovering)
        let size = Self.size(phase: phase, open: open, notch: model.notch)
        let flare: CGFloat = open ? 18 : model.notch.width > 0 ? 8 : 0
        let shape = NotchShape(top: flare, bottom: open ? 24 : min(12, size.height / 2))
        let spring: Animation = reduceMotion ? .easeOut(duration: 0.2) : open ? .spring(duration: 0.55, bounce: 0.3) : .spring(duration: 0.4, bounce: 0.15)

        shape
            .fill(.black)
            .frame(width: size.width + 2 * flare, height: size.height)
            .overlay(alignment: .top) {
                if let flight = tracker.flight, let observer = tracker.observer {
                    Group {
                        if open {
                            ExpandedView(flight: flight, observer: observer, others: tracker.presenter.others, top: model.notch.height)
                                .frame(width: Self.openWidth, height: Self.openHeight(model.notch))
                        } else {
                            CompactView(flight: flight, observer: observer, others: tracker.presenter.others, notch: model.notch)
                                .frame(width: size.width, height: size.height)
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
                }
            }
            .clipShape(shape)
            .opacity(phase == .hidden ? 0 : 1)
            .animation(spring, value: open)
            .animation(spring, value: phase)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(.white)
            .preferredColorScheme(.dark)
            .dynamicTypeSize(...DynamicTypeSize.large)
    }
}

/// The notch's own silhouette, the same one as Skies: concave shoulders that flare into the screen's top edge, and
/// rounded bottom corners. It is `2 × top` wider than its body.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let t = min(top, w / 4, h), b = max(min(bottom, (w - 2 * t) / 2, h - t), 0)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: t, y: t), control: CGPoint(x: t, y: 0))
        p.addLine(to: CGPoint(x: t, y: h - b))
        p.addQuadCurve(to: CGPoint(x: t + b, y: h), control: CGPoint(x: t, y: h))
        p.addLine(to: CGPoint(x: w - t - b, y: h))
        p.addQuadCurve(to: CGPoint(x: w - t, y: h - b), control: CGPoint(x: w - t, y: h))
        p.addLine(to: CGPoint(x: w - t, y: t))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - t, y: 0))
        p.closeSubpath()
        return p.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    let flight: Flight
    let observer: Observer
    let others: Int
    let top: CGFloat

    var body: some View {
        VStack(spacing: 10) {
            Color.clear.frame(height: max(top, 24) - 6)
            header
            MapPane(flight: flight, observer: observer)
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            FooterView(motion: flight.motion, observer: observer)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var header: some View {
        let a = flight.aircraft, r = flight.route
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(a.callsign ?? a.hex.uppercased()).font(.system(size: 17, weight: .semibold))
                    if others > 0 { Badge(count: others) }
                }
                Text([r?.airline?.name, a.t].compactMap(\.self).joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                if let r {
                    Text("\(r.origin.code) → \(r.destination.code)").font(.system(size: 17, weight: .semibold))
                    Text([r.origin.municipality, r.destination.municipality].map { $0 ?? "—" }.joined(separator: " → "))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Text(a.desc?.capitalized ?? a.t ?? "Unknown type").font(.system(size: 15, weight: .medium))
                    Text("Route unknown").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(1)
    }
}

private struct Badge: View {
    let count: Int
    var body: some View {
        Text("+\(count)")
            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.white.opacity(0.18), in: Capsule())
            .accessibilityLabel("\(count) more overhead")
    }
}

private extension CLLocationCoordinate2D {
    init(_ a: Route.Airport) { self.init(latitude: a.latitude, longitude: a.longitude) }
}

/// North-up, flat, still. Only the aircraft glyph moves, drawn over the map at display refresh, so MapKit isn't
/// asked to rebuild every frame.
struct MapPane: View {
    let flight: Flight
    let observer: Observer

    var body: some View {
        let user = CLLocationCoordinate2D(latitude: observer.lat, longitude: observer.lon)
        // ponytail: the arc splits at the last fix, so the glyph can run up to one poll ahead onto the dotted part. Split at the
        // drawn position at 1 Hz if that shows.
        let fix = CLLocationCoordinate2D(latitude: flight.motion.fix.lat, longitude: flight.motion.fix.lon)
        MapReader { proxy in
            Map(initialPosition: .camera(MapCamera(centerCoordinate: user, distance: 45_000)), interactionModes: []) {
                if let r = flight.route {
                    MapPolyline(coordinates: [.init(r.origin), fix], contourStyle: .geodesic)
                        .stroke(.white.opacity(0.9), lineWidth: 2)
                    MapPolyline(coordinates: [fix, .init(r.destination)], contourStyle: .geodesic)
                        .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.5, 5]))
                }
                Annotation("", coordinate: user, anchor: .center) {
                    Circle().fill(.blue).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .accessibilityLabel("You")
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .mapControls {}
            .overlay {
                TimelineView(.animation) { ctx in
                    let p = flight.motion.position(at: ctx.date)
                    if let pt = proxy.convert(CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), to: .local) {
                        Image(systemName: "airplane")  // the symbol points east
                            .font(.system(size: 18, weight: .semibold))
                            .rotationEffect(.degrees(p.track - 90))
                            .position(pt)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .id(observer)
    }
}

struct FooterView: View {
    let motion: Motion
    let observer: Observer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let p = motion.position(at: ctx.date), l = look(from: observer, to: p)
            HStack(spacing: 18) {
                stat("Altitude", "\((Int(p.alt / 0.3048 / 10) * 10).formatted()) ft")
                stat("Speed", "\(Int(motion.fix.speed / 0.514444)) kt")
                stat("Distance", distance(l.range))
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(l.compass).font(.system(size: 15, weight: .semibold))
                        Text("\(Int(l.elevation.rounded()))° up").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    SkyDome(look: l).frame(width: 52, height: 52)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Int(l.elevation.rounded())) degrees up, \(l.compass)")
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func distance(_ metres: Double) -> String {
        let unit: UnitLength = Locale.current.measurementSystem == .metric ? .kilometers : .miles
        return Measurement(value: metres, unit: UnitLength.meters).converted(to: unit)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
    }
}

/// The sky seen from below: the rim is the horizon, the centre is straight up, north at the top.
struct SkyDome: View {
    let look: Look

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2 - 1, c = CGPoint(x: size.width / 2, y: size.height / 2)
            for (f, o) in [(1.0, 0.35), (2.0 / 3, 0.14), (1.0 / 3, 0.14)] {  // horizon, 30°, 60°
                ctx.stroke(Circle().path(in: CGRect(x: c.x - r * f, y: c.y - r * f, width: 2 * r * f, height: 2 * r * f)),
                           with: .color(.white.opacity(o)), lineWidth: 1)
            }
            ctx.draw(Text("N").font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.5)),
                     at: CGPoint(x: c.x, y: c.y - r + 6))
            let d = r * (90 - min(max(look.elevation, 0), 90)) / 90, a = look.azimuth * .pi / 180
            let pt = CGPoint(x: c.x + d * sin(a), y: c.y - d * cos(a))
            ctx.fill(Circle().path(in: CGRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7)), with: .color(.white))
        }
    }
}

// MARK: - Compact

/// Callsign to the left of the notch, where to look to the right. On a screen without a notch it's one pill.
struct CompactView: View {
    let flight: Flight
    let observer: Observer
    let others: Int
    let notch: CGSize

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let p = flight.motion.position(at: ctx.date), l = look(from: observer, to: p)
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "airplane").font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(p.track - 90))
                    Text(flight.aircraft.callsign ?? flight.aircraft.hex.uppercased())
                }
                Spacer(minLength: notch.width + 8)
                HStack(spacing: 5) {
                    Text("\(Int(l.elevation.rounded()))°").monospacedDigit()
                    Text(l.compass).foregroundStyle(.secondary)
                    if others > 0 { Badge(count: others) }
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
        }
    }
}
