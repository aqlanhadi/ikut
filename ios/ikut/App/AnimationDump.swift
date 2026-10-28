#if DEBUG
import UIKit
import ObjectiveC

/// Debug-only diagnostic for Q21 (UI tests stalling at "App animations complete notification not received").
/// XCTest calls the app idle only when no Core Animation animation is running in its windows, so a layer whose
/// animation never ends makes every tap wait 60 s. With `IKUT_ANIM_DUMP=<file>` in the launch environment the app
/// appends, every two seconds, one line per layer that has a running animation (view or layer class, key, duration,
/// repeat count, remaining time) and a one-line "none" when nothing runs. Off by default; the UI test base class sets
/// it when `TEST_RUNNER_IKUT_ANIM_DUMP=<file>` is in the test's environment.
enum AnimationDump {
    @MainActor private static var timer: Timer?

    @MainActor static func startIfAsked() {
        guard let path = ProcessInfo.processInfo.environment["IKUT_ANIM_DUMP"], !path.isEmpty, timer == nil else { return }
        track(path: path)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { append(report(), to: path) }
        }
    }

    // XCTest decides "animations complete" from UIKit's UIViewAnimationState (XCTAutomationSupport swizzles its
    // animationDidStart: and animationDidStop:finished:): one started animation that never stops keeps every tap
    // waiting. These hooks log each start and stop and, every tick, the starts still waiting for their stop.
    nonisolated(unsafe) private static var open: [Int: (count: Int, what: String)] = [:]
    private static let lock = NSLock()
    private static let fileLock = NSLock()

    private static func track(path: String) {
        guard let cls = NSClassFromString("UIViewAnimationState") else { append("no UIViewAnimationState\n", to: path); return }
        let startSel = NSSelectorFromString("animationDidStart:")
        if let m = class_getInstanceMethod(cls, startSel) {
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            let old = unsafeBitCast(method_getImplementation(m), to: Fn.self)
            let block: @convention(block) (AnyObject, AnyObject?) -> Void = { me, anim in
                let id = key(anim)
                let what = describe(anim)
                let stack = Thread.callStackSymbols.dropFirst(2).prefix(40).filter { $0.contains("ikut") || $0.contains("SwiftUI") }.prefix(4)
                    .map { $0.split(separator: " ", maxSplits: 3).last.map(String.init)?.prefix(90) ?? "" }.joined(separator: " <- ")
                let frames = Thread.callStackSymbols.dropFirst(2).prefix(25).map { line -> String in
                    let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                    return parts.count > 3 ? String(parts[3].prefix(60)) : line
                }.joined(separator: " <- ")
                lock.lock()
                open[id] = (count: (open[id]?.count ?? 0) + 1, what: "\(what) at \(stamp()) from \(frames)")
                let n = open.values.reduce(0) { $0 + $1.count }; lock.unlock()
                append("\(stamp()) START open=\(n) \(what) from \(stack)\n", to: path)
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
                var known = false
                if let entry = open[id] { known = true; if entry.count <= 1 { open[id] = nil } else { open[id] = (entry.count - 1, entry.what) } }
                let n = open.values.reduce(0) { $0 + $1.count }; lock.unlock()
                append("\(stamp()) STOP open=\(n) finished=\(finished) known=\(known) \(describe(anim))\n", to: path)
                old(me, stopSel, anim, finished)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS'Z'"; f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: .now)
    }

    private static func key(_ anim: AnyObject?) -> Int {
        anim.map { Int(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0
    }

    private static func describe(_ anim: AnyObject?) -> String {
        guard let anim else { return "nil" }
        guard let a = anim as? CAAnimation else { return String(describing: type(of: anim)) }
        let keyPath = (a as? CAPropertyAnimation)?.keyPath ?? "-"
        return "\(type(of: a)) \(keyPath) d=\(a.duration) repeat=\(a.repeatCount) \(a.repeatDuration)"
    }

    @MainActor static func openStarts() -> String {
        lock.lock(); defer { lock.unlock() }
        let busy = (NSClassFromString("XCTAnimationsIdleNotifier") as AnyObject?).flatMap { cls -> Bool? in
            guard let m = class_getClassMethod(cls as? AnyClass, NSSelectorFromString("isAnimationInProgress")) else { return nil }
            typealias Fn = @convention(c) (AnyClass, Selector) -> Bool
            return unsafeBitCast(method_getImplementation(m), to: Fn.self)(cls as! AnyClass, NSSelectorFromString("isAnimationInProgress"))
        }
        let head = "\(stamp()) XCT-BUSY=\(busy.map(String.init) ?? "?") open=\(open.values.reduce(0) { $0 + $1.count })\n"
        return open.isEmpty ? head : head + "\(stamp()) OPEN: " + open.values.map { "\($0.count)x \($0.what)" }.joined(separator: " | ") + "\n"
    }

    @MainActor static func report() -> String {
        let stamp = ISO8601DateFormatter().string(from: .now)
        var lines: [String] = []
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            walk(window.layer, path: String(describing: type(of: window)), now: CACurrentMediaTime(), into: &lines)
        }
        return openStarts() + (lines.isEmpty ? "\(stamp) none\n" : lines.map { "\(stamp) \($0)\n" }.joined())
    }

    @MainActor private static func walk(_ layer: CALayer, path: String, now: CFTimeInterval, into lines: inout [String]) {
        let owner = (layer.delegate as? UIView).map { String(describing: type(of: $0)) } ?? String(describing: type(of: layer))
        let here = path + " > " + owner
        for key in layer.animationKeys() ?? [] {
            guard let animation = layer.animation(forKey: key) else { continue }
            let local = layer.convertTime(now, from: nil)
            let end = animation.beginTime + animation.duration * Double(animation.repeatCount == 0 ? 1 : animation.repeatCount)
            let remaining = animation.repeatCount.isInfinite || animation.autoreverses && animation.repeatDuration.isInfinite
                ? "forever" : String(format: "%.2f", animation.repeatDuration > 0 ? animation.beginTime + animation.repeatDuration - local : end - local)
            lines.append("\(here) key=\(key) \(type(of: animation)) duration=\(animation.duration) repeat=\(animation.repeatCount) remaining=\(remaining) hidden=\(layer.isHidden) opacity=\(layer.opacity) bounds=\(Int(layer.bounds.width))x\(Int(layer.bounds.height))")
        }
        for sub in layer.sublayers ?? [] { walk(sub, path: here, now: now, into: &lines) }
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
