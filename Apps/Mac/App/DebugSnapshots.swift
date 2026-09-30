#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `--snapshot-dir <folder>` writes a PNG of every visible
/// window a few seconds after launch, so the UI can be reviewed while the
/// screen is locked (screen capture is unavailable then). Glass and other
/// live materials render flat in these images.
enum DebugSnapshots {
    @MainActor
    static func scheduleIfRequested(extraViews: [(name: String, size: CGSize, view: AnyView)] = []) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--snapshot-dir"), index + 1 < arguments.count else { return }
        let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        Task { @MainActor in
            // Views that live in windows opened on demand get their own
            // offscreen window, so they can be captured without a click.
            var extraWindows: [NSWindow] = []
            for extra in extraViews {
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: extra.size),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.title = extra.name
                window.contentViewController = NSHostingController(rootView: extra.view)
                window.setContentSize(extra.size)
                window.orderBack(nil)
                extraWindows.append(window)
            }
            try? await Task.sleep(for: .seconds(6))
            for (number, window) in NSApp.windows.enumerated() where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let name = window.title.isEmpty ? "window-\(number)" : window.title
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: folder.appendingPathComponent("\(name).png"))
            }
            extraWindows.forEach { $0.close() }
        }
    }
}
#endif
