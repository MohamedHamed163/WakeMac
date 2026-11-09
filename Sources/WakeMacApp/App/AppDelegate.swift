import AppKit
import Combine
import SwiftUI
import WakeKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState!
    var statusItem: NSStatusItem!
    var overlayPanel: NSPanel?
    var immersivePanel: ImmersivePanel?
    private var overlayObserver: AnyCancellable?
    private var phaseObserver: AnyCancellable?
    private var autoHide: Task<Void, Never>?
    var settingsWindow: NSWindow?
    var modesWindow: NSWindow?
    var hotkey: GlobalHotKey?
    var pushToTalkMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        state = AppState()
        installStatusItem()
        installHotkeys()
        buildOverlay()
        buildImmersiveOverlay()
        observeSession()
        Task { await state.bootstrap() }
    }

    func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.and.mic",
                                           accessibilityDescription: "Wake Mac")
        let menu = NSMenu()
        let items = [
            ("Wake Mac", #selector(wake), "k"),
            ("Show Overlay", #selector(showOverlay), nil),
            ("Settings…", #selector(openSettings), ","),
            ("Modes…", #selector(openModes), nil),
            ("Quit", #selector(NSApplication.terminate(_:)), "q"),
        ]
        for (title, action, key) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key ?? "")
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
    }

    func installHotkeys() {
        // Option-Space toggles the overlay. Registered through Carbon so it
        // works without Accessibility permission.
        hotkey = GlobalHotKey(keyCode: GlobalHotKey.Key.space, modifiers: .option) { [weak self] in
            self?.toggleOverlay()
        }
        // push-to-talk: hold right option
        pushToTalkMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.keyCode == UInt16(self.state.settings.pushToTalkKeycode) else { return }
            if event.type == .keyDown, self.state.phase == .standby {
                self.state.beginInteraction(fromVoice: true)
            }
        }
    }

    func buildOverlay() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: OverlayView(state: state))
        overlayPanel = panel
        positionOverlay()
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// Builds the edge-to-edge voice surface used for "hi mac" sessions.
    func buildImmersiveOverlay() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = ImmersivePanel(contentRect: frame,
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver            // above the menu bar and the Dock
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: ImmersiveOverlay(state: state) { [weak self] in
            self?.dismissImmersive()
        })
        panel.setFrame(frame, display: false)
        immersivePanel = panel
    }

    /// Mirrors the session's own overlay flag, so a voice wake opens the
    /// surface without the menu bar or a hotkey being involved.
    private func observeSession() {
        overlayObserver = state.$showingOverlay
            .removeDuplicates()
            .sink { [weak self] showing in
                guard let self else { return }
                if showing {
                    self.autoHide?.cancel()
                    self.presentImmersive()
                } else {
                    self.immersivePanel?.orderOut(nil)
                }
            }
        // A full-screen surface must never outstay the turn: once the session
        // settles back to standby the Mac has to be usable again.
        phaseObserver = state.$phase
            .removeDuplicates()
            .sink { [weak self] phase in
                guard let self else { return }
                self.autoHide?.cancel()
                guard phase == .standby, self.immersivePanel?.isVisible == true else { return }
                self.autoHide = Task { @MainActor [weak self] in
                    // Long enough to read the answer, short enough not to trap anyone.
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    guard !Task.isCancelled, let self else { return }
                    guard self.state.phase == .standby else { return }
                    self.state.showingOverlay = false
                    self.immersivePanel?.orderOut(nil)
                }
            }
    }

    func presentImmersive() {
        guard state.settings.immersiveOverlay else {
            overlayPanel?.orderFrontRegardless()
            positionOverlay()
            return
        }
        guard let panel = immersivePanel else { return }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main {
            panel.setFrame(screen.frame, display: true)
        }
        overlayPanel?.orderOut(nil)
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismissImmersive() {
        state.stopOrCancel()
        state.showingOverlay = false
        immersivePanel?.orderOut(nil)
    }

    @objc func screenChanged() {
        positionOverlay()
        if let screen = NSScreen.main { immersivePanel?.setFrame(screen.frame, display: true) }
    }

    private func positionOverlay() {
        guard let panel = overlayPanel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let safeTop = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : NSStatusBar.system.thickness
        let size = panel.frame.size
        let x = screen.frame.minX + (screen.frame.width - size.width) / 2
        let y = screen.frame.maxY - safeTop - size.height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func toggleOverlay() {
        let visible = state.settings.immersiveOverlay
            ? immersivePanel?.isVisible == true
            : overlayPanel?.isVisible == true
        if visible {
            dismissImmersive()
        } else {
            state.beginInteraction(fromVoice: false)   // also sets showingOverlay
            presentImmersive()
        }
    }

    @objc func wake() { toggleOverlay() }
    @objc func showOverlay() { toggleOverlay() }

    @objc func openSettings() {
        if let w = settingsWindow { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Wake Mac Settings"
        // Owned by this delegate and reopened later, so AppKit must not
        // release it on close (that left a dangling reference and crashed).
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView(state: state))
        w.center()
        settingsWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openModes() {
        if let w = modesWindow { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Saved Modes"
        // Owned by this delegate and reopened later, so AppKit must not
        // release it on close (that left a dangling reference and crashed).
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: ModesEditorView(state: state))
        w.center()
        modesWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}


/// Borderless panel that still accepts the keyboard, so the overlay's text
/// field works without turning Wake Mac into a regular foreground app.
final class ImmersivePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.dismissImmersive()
    }
}
