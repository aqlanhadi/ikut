#if DEBUG
import UIKit
import ObjectiveC

/// Debug-only helpers for Q21: UI tests stalled for 60 s at every tap with "App animations complete notification
/// not received", though the app was idle (main thread at 0% CPU, nothing animating in its windows).
///
/// What XCTest calls idle: XCTAutomationSupport swizzles UIKit's `UIViewAnimationState` and keeps ONE global counter,
/// +1 in `animationDidStart:` and -1 in `animationDidStop:finished:` (`XCTAnimationsIdleNotifier`, class methods
/// `animationDidStart`, `animationDidStop`, `isAnimationInProgress` = counter > 0). When a UIKit transition (a sheet
/// hand-over, ~60 glass and spring animations in one go) is cut short, now and then one start never gets its stop; the
/// counter stays at 1 for the rest of that launch and every tap then waits the full 60 s. Nothing is animating on screen;
/// the shipped app is not affected.
///
/// - `IKUT_ANIM_DUMP=<file>`: every 2 s, one line with XCTest's busy flag and the animations UIKit started that never
///   stopped, plus one line per layer with a running animation (view or layer class, key, duration, repeat).
/// - `IKUT_IDLE_GUARD=1`: every 0.5 s, if XCTest has called the app busy for 2 s in a row (four ticks) while no finite
///   animation is running in any window, the leaked counts are given back (`animationDidStop`) so the next wait ends
///   at once. Set by `ConvoyUITestCase` for every UI test; off in every other launch.
/// - `IKUT_LEAK_ANIMATION=1`: leaks one count on purpose after launch, to see the guard work (UI test `IdleGuardUITests`).
enum AnimationDump {
    @MainActor private static var dumpTimer: Timer?
    @MainActor private static var guardTimer: Timer?
    @MainActor private static var busyTicks = 0
    @MainActor private static var dumpPath: String?
    nonisolated(unsafe) private static var open: [Int: (count: Int, what: String)] = [:]
    private static let lock = NSLock()
    private static let fileLock = NSLock()

    @MainActor static func startIfAsked() {
        let env = ProcessInfo.processInfo.environment
        let path = env["IKUT_ANIM_DUMP"].flatMap { $0.isEmpty ? nil : $0 }
        let guarding = env["IKUT_IDLE_GUARD"] == "1"
        if env["IKUT_LEAK_ANIMATION"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { _ = xctCall("animationDidStart") }
        }
        guard path != nil || guarding else { return }
        dumpPath = path
        if path != nil { track() }
        if let path {
            dumpTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated { append(report(), to: path) }
            }
        }
        if guarding {
            guardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated { guardTick() }
            }
        }
    }

    // MARK: The guard

    @MainActor private static func guardTick() {
        guard xctBusy() == true else { busyTicks = 0; return }
        busyTicks += 1
        guard busyTicks >= 4 else { return }
        guard finiteAnimations().isEmpty else { busyTicks = 0; return }
        var given = 0
        while xctBusy() == true, given < 10_000 { _ = xctCall("animationDidStop"); given += 1 }
        busyTicks = 0
        if let dumpPath { append("\(stamp()) GUARD gave back \(given) animation count(s)\n", to: dumpPath) }
    }

    // MARK: XCTest's counter

    private static func xctCall(_ name: String) -> Bool? {
        guard let cls = NSClassFromString("XCTAnimationsIdleNotifier"), let m = class_getClassMethod(cls, NSSelectorFromString(name)) else { return nil }
        typealias Fn = @convention(c) (AnyClass, Selector) -> Bool
        return unsafeBitCast(method_getImplementation(m), to: Fn.self)(cls, NSSelectorFromString(name))
    }

    private static func xctBusy() -> Bool? { xctCall("isAnimationInProgress") }

    /// UIKit's own count of starts without stops, for the dump: each start is kept by the animation's address until
    /// its stop.
    private static func track() {
        guard let cls = NSClassFromString("UIViewAnimationState") else { return }
        let startSel = NSSelectorFromString("animationDidStart:")
        if let m = class_getInstanceMethod(cls, startSel) {
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            let old = unsafeBitCast(method_getImplementation(m), to: Fn.self)
            let block: @convention(block) (AnyObject, AnyObject?) -> Void = { me, anim in
                let id = key(anim)
                lock.lock()
                open[id] = (count: (open[id]?.count ?? 0) + 1, what: "\(describe(anim)) since \(stamp())")
                lock.unlock()
                old(me, startSel, anim)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        let stopSel = NSSelectorFromString("animationDidStop:finished:")
        if let m = class_getInstanceMethod(cls, stopSel) {
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, Bool) -> Void
            let old = unsafeBitCast(method_getImplementation(m), to: Fn.self)
            let block: @convention(block) (AnyObject, AnyObject?, Bool) -> Void = { me, anim, finished in
                let id = key(anim)
                lock.lock()
                if let entry = open[id] { open[id] = entry.count <= 1 ? nil : (entry.count - 1, entry.what) }
                lock.unlock()
                old(me, stopSel, anim, finished)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }

    // MARK: The layer tree

    @MainActor private static func windows() -> [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    }

    /// Animations that will end by themselves: not the glass's `match-*` ones (duration infinite) or anything repeating.
    @MainActor private static func finiteAnimations() -> [String] {
        var lines: [String] = []
        for window in windows() { walk(window.layer, path: "", into: &lines, finiteOnly: true) }
        return lines
    }

    @MainActor static func report() -> String {
        let busy = xctBusy().map(String.init) ?? "?"
        lock.lock(); let unpaired = open.values.map { "\($0.count)x \($0.what)" }; lock.unlock()
        var text = "\(stamp()) XCT-BUSY=\(busy) unpaired=\(unpaired.count)\(unpaired.isEmpty ? "" : ": " + unpaired.prefix(8).joined(separator: " | "))\n"
        var lines: [String] = []
        for window in windows() { walk(window.layer, path: String(describing: type(of: window)), into: &lines, finiteOnly: false) }
        text += lines.isEmpty ? "\(stamp()) layers: none\n" : lines.map { "\(stamp()) \($0)\n" }.joined()
        return text
    }

    @MainActor private static func walk(_ layer: CALayer, path: String, into lines: inout [String], finiteOnly: Bool) {
        let owner = (layer.delegate as? UIView).map { String(describing: type(of: $0)) } ?? String(describing: type(of: layer))
        let here = finiteOnly ? owner : path + " > " + owner
        for key in layer.animationKeys() ?? [] {
            guard let a = layer.animation(forKey: key) else { continue }
            let endless = a.duration.isInfinite || a.repeatCount > 1 || a.repeatDuration > 0
            if finiteOnly && endless { continue }
            lines.append("\(here) key=\(key) \(type(of: a)) duration=\(a.duration) repeat=\(a.repeatCount)")
        }
        for sub in layer.sublayers ?? [] { walk(sub, path: here, into: &lines, finiteOnly: finiteOnly) }
    }

    // MARK: Small helpers

    private static func key(_ anim: AnyObject?) -> Int {
        anim.map { Int(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0
    }

    private static func describe(_ anim: AnyObject?) -> String {
        guard let a = anim as? CAAnimation else { return "nil" }
        return "\(type(of: a)) \((a as? CAPropertyAnimation)?.keyPath ?? "-") d=\(a.duration)"
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS'Z'"; f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: .now)
    }

    nonisolated private static func append(_ text: String, to path: String) {
        guard let data = text.data(using: .utf8) else { return }
        fileLock.lock(); defer { fileLock.unlock() }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
#endif
