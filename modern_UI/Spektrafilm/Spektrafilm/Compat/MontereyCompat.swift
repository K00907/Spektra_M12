//  MontereyCompat.swift — the Intel / macOS 12 port's shims.
//
//  Upstream SpektraLab targets macOS 15 on Apple silicon. This branch runs the
//  same app on Intel Macs that stop at Monterey (an iMac 2015 with an AMD
//  Radeon R9 M395 is the machine it was written for). Everything here is a
//  macOS 12 stand-in for an API the SDK only offers from macOS 13 or later,
//  or a guard for a GPU that is not an Apple GPU. Each shim keeps the shape of
//  the API it replaces, so the call sites read the same as upstream.

import Accelerate
import AppKit
import Metal
import SwiftUI
import Perception

// MARK: - Task.sleep(for:) is macOS 13

extension Task where Success == Never, Failure == Never {
    /// `Task.sleep(for: .milliseconds(ms))`, which needs `Duration` (macOS 13).
    static func sleep(ms: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(ms, 0)) * 1_000_000)
    }
}

// MARK: - NSLocking.withLock is macOS 13

extension NSLocking {
    /// `NSLocking.withLock(_:)`, which Foundation only ships from macOS 13.
    func withLockCompat<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}

// MARK: - Float16 is arm64-only on macOS

enum HalfFloat {
    /// IEEE half-float bit patterns for `values`, round-to-nearest-even —
    /// what `Float16(x)` gives on Apple silicon.
    static func bits(_ values: [Float]) -> [UInt16] {
        var src = values
        var dst = [UInt16](repeating: 0, count: values.count)
        guard !values.isEmpty else { return dst }
        src.withUnsafeMutableBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                var sb = vImage_Buffer(data: s.baseAddress, height: 1,
                                       width: vImagePixelCount(s.count), rowBytes: s.count * 4)
                var db = vImage_Buffer(data: d.baseAddress, height: 1,
                                       width: vImagePixelCount(d.count), rowBytes: d.count * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&sb, &db, vImage_Flags(kvImageNoFlags))
            }
        }
        return dst
    }
}

// MARK: - onChange(of:initial:_:) with two values is macOS 14

extension View {
    /// The macOS 14 `onChange(of:initial:_:)` — old and new value — built on
    /// the macOS 11 single-value form.
    func onChangeCompat<V: Equatable>(of value: V, initial: Bool = false,
                                      _ action: @escaping (V, V) -> Void) -> some View {
        modifier(OnChangeCompat(value: value, initial: initial, action: action))
    }
}

private struct OnChangeCompat<V: Equatable>: ViewModifier {
    let value: V
    let initial: Bool
    let action: (V, V) -> Void
    @State private var previous: V?

    func body(content: Content) -> some View {
        content
            .onAppear {
                previous = value
                if initial { action(value, value) }
            }
            .onChange(of: value) { new in
                let old = previous ?? new
                previous = new
                action(old, new)
            }
    }
}

// MARK: - onContinuousHover is macOS 13

/// `HoverPhase`'s two cases, which is all the app switches over.
enum HoverPhaseCompat: Equatable {
    case active(CGPoint)
    case ended
}

extension View {
    /// `onContinuousHover(perform:)` (macOS 13): the pointer's location in the
    /// view's own coordinates while it is inside, then `.ended`. A tracking
    /// area on a view that refuses every hit, so it sees the pointer without
    /// taking a click or a drag from the view it decorates.
    func onContinuousHoverCompat(perform action: @escaping (HoverPhaseCompat) -> Void) -> some View {
        overlay(HoverTracking(action: action))
    }
}

private struct HoverTracking: NSViewRepresentable {
    let action: (HoverPhaseCompat) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.action = action
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.action = action
    }

    final class TrackingView: NSView {
        var action: ((HoverPhaseCompat) -> Void)?
        private var inside = false

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseEnteredAndExited, .mouseMoved,
                                                     .activeInActiveApp, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseExited(with event: NSEvent) {
            guard inside else { return }
            inside = false
            action?(.ended)
        }

        private func report(_ event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            guard bounds.contains(p) else {
                if inside { inside = false; action?(.ended) }
                return
            }
            inside = true
            action?(.active(p))
        }
    }
}

// MARK: - Window scenes are macOS 13

/// The three secondary windows — About, Settings, Export — that upstream
/// declares as SwiftUI `Window` scenes and opens with `openWindow(id:)`.
/// Both are macOS 13; on macOS 12 the app makes these windows itself, with
/// the same content and the same chrome.
@MainActor
final class AuxWindows: NSObject, NSWindowDelegate {
    static let shared = AuxWindows()

    enum Kind: String {
        case about, settings, export
    }

    private var windows: [Kind: NSWindow] = [:]

    func open(_ kind: Kind) {
        if let existing = windows[kind] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let session = SpektrafilmApp.session
        let root: AnyView
        var style: NSWindow.StyleMask = [.titled, .closable]
        let title: String
        switch kind {
        case .about:
            title = "About SpektraLab"
            root = AnyView(AboutWindow())
        case .settings:
            title = "Settings"
            root = AnyView(InterfaceScaled { SettingsWindow(session: session) })
        case .export:
            title = "Export"
            root = AnyView(InterfaceScaled { ExportWindow(session: session) })
            style.formUnion([.resizable, .miniaturizable, .fullSizeContentView])
        }
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.styleMask = style
        window.title = title
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.tabbingMode = .disallowed
        if kind == .export {
            // `.windowStyle(.hiddenTitleBar)` and `.windowToolbarStyle(.unifiedCompact)`.
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unifiedCompact
            window.setContentSize(NSSize(width: Theme.Metric.Export.width,
                                         height: Theme.Metric.Export.height))
            window.contentMinSize = NSSize(width: Theme.Metric.Export.width,
                                           height: Theme.Metric.minWindow.height)
        }
        window.delegate = self
        window.center()
        windows[kind] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A closed window is made again next time, as a `Window` scene's is.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        for (kind, window) in windows where window === closing {
            windows[kind] = nil
        }
    }
}

/// The scenes' `.id(InterfaceScaleStore.shared.scale)`: a new interface scale
/// rebuilds the page, which is how upstream applies one.
struct InterfaceScaled<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        WithPerceptionTracking {
            content().id(InterfaceScaleStore.shared.scale)
        }
    }
}

// MARK: - Metal storage on GPUs that are not Apple GPUs

enum GPUStorage {
    /// Whether the system GPU is an Apple GPU. Only Apple GPUs take
    /// `.shared` textures; on an Intel or AMD GPU a CPU-visible texture has to
    /// be `.managed` (the shared mode "isn't available for MTLTexture
    /// instances" on non-Apple family GPUs — Metal documentation).
    static let appleGPU: Bool = MTLCreateSystemDefaultDevice()?.supportsFamily(.apple1) ?? false

    /// The storage mode for a texture the CPU writes or reads.
    static var cpuTexture: MTLStorageMode { appleGPU ? .shared : .managed }
}

extension MTLTexture {
    /// Make the GPU's writes visible to `getBytes`. A no-op for shared and
    /// private textures; a managed texture the GPU rendered into has to be
    /// synchronised by a blit before the CPU can read it.
    func synchronizeForCPURead() {
        guard storageMode == .managed else { return }
        guard let queue = ManagedSync.queue(for: device),
              let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { return }
        blit.synchronize(resource: self)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }
}

private enum ManagedSync {
    nonisolated(unsafe) private static var queues: [ObjectIdentifier: MTLCommandQueue] = [:]
    private static let lock = NSLock()

    static func queue(for device: MTLDevice) -> MTLCommandQueue? {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(device)
        if let q = queues[key] { return q }
        let q = device.makeCommandQueue()
        queues[key] = q
        return q
    }
}

// MARK: - The Layout protocol is macOS 13

/// `FlowLayout` without `Layout`: items in a row that wraps onto the next
/// line rather than running past its container. Each item's size is measured
/// as it lays out and the rows are computed from those sizes.
struct FlowRow<Item: Identifiable, Content: View>: View {
    let items: [Item]
    var spacing: CGFloat = 2
    var lineSpacing: CGFloat = 3
    @ViewBuilder let content: (Item) -> Content

    @State private var sizes: [Item.ID: CGSize] = [:]
    @State private var width: CGFloat = 0

    private struct Placement {
        var offsets: [Item.ID: CGPoint] = [:]
        var height: CGFloat = 0
    }

    private func arrange() -> Placement {
        var placement = Placement()
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var rowItems: [(Item.ID, CGSize)] = []
        func closeRow() {
            for (id, size) in rowItems {
                if let p = placement.offsets[id] {
                    placement.offsets[id] = CGPoint(x: p.x, y: y + (rowHeight - size.height) / 2)
                }
            }
            rowItems.removeAll()
        }
        for item in items {
            let size = sizes[item.id] ?? .zero
            if !rowItems.isEmpty, x + spacing + size.width > width {
                closeRow()
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
            }
            let at = rowItems.isEmpty ? 0 : x + spacing
            placement.offsets[item.id] = CGPoint(x: at, y: y)
            rowItems.append((item.id, size))
            x = at + size.width
            rowHeight = max(rowHeight, size.height)
        }
        closeRow()
        placement.height = items.isEmpty ? 0 : y + rowHeight
        return placement
    }

    var body: some View {
        let placement = arrange()
        ZStack(alignment: .topLeading) {
            ForEach(items) { item in WithPerceptionTracking {
                content(item)
                    .fixedSize()
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { sizes[item.id] = g.size }
                            .onChangeCompat(of: g.size) { _, s in sizes[item.id] = s }
                    })
                    .offset(x: placement.offsets[item.id]?.x ?? 0,
                            y: placement.offsets[item.id]?.y ?? 0)
            } }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: placement.height, alignment: .topLeading)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { width = g.size.width }
                .onChangeCompat(of: g.size.width) { _, w in width = w }
        })
    }
}

/// `LongestThatFits` without `Layout`: the first of the candidate lines whose
/// width fits the width offered, measured with the same bold system font the
/// line is drawn in, or none.
struct LongestLine: View {
    let candidates: [String]
    let fontSize: CGFloat
    let color: Color
    var alignment: Alignment = .leading

    private func width(_ s: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        return ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    var body: some View {
        // A one-space line gives the row its height; the reader gives the
        // width it was offered.
        Text(" ")
            .font(.system(size: fontSize, weight: .bold))
            .lineLimit(1)
            .hidden()
            .frame(minWidth: 0, maxWidth: .infinity)
            .overlay(GeometryReader { geo in
                if let pick = candidates.first(where: { width($0) <= geo.size.width + 0.5 }) {
                    Text(pick)
                        .font(.system(size: fontSize, weight: .bold))
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: geo.size.width, height: geo.size.height,
                               alignment: Alignment(horizontal: alignment.horizontal, vertical: .center))
                }
            })
    }
}
