import ApplicationServices
import CoreGraphics
import Foundation

struct AXObserverSessionConfiguration: Sendable {
    var coalescingDelay: TimeInterval = 0.04
    var reconciliationInterval: TimeInterval = 1.0
    var messagingTimeout: Float = 0.075
    var bootstrapDuration: TimeInterval = 0.15
    var eventDuration: TimeInterval = 0.10
    var maxBootstrapElements = 1500
    var maxEventElements = 300
    var circuitFailureThreshold = 3
    var circuitRecoveryDelay: TimeInterval = 2.0
}

struct AXEventBurst: Sendable {
    private(set) var firstReceivedAt: TimeInterval?
    private(set) var lastReceivedAt: TimeInterval?
    private(set) var eventCount = 0

    @discardableResult
    mutating func receive(at timestamp: TimeInterval) -> Bool {
        let startsBurst = firstReceivedAt == nil
        if startsBurst { firstReceivedAt = timestamp }
        lastReceivedAt = timestamp
        eventCount += 1
        return startsBurst
    }

    mutating func drain() -> (firstReceivedAt: TimeInterval, eventCount: Int)? {
        guard let firstReceivedAt else { return nil }
        let result = (firstReceivedAt, eventCount)
        self = AXEventBurst()
        return result
    }
}

struct AXObserverRetrySchedule: Sendable {
    private(set) var deadline: TimeInterval?

    mutating func schedule(at now: TimeInterval, after delay: TimeInterval) -> TimeInterval? {
        guard deadline == nil else { return nil }
        let deadline = now + max(0, delay)
        self.deadline = deadline
        return deadline
    }

    mutating func beginScheduledAttempt() -> Bool {
        guard deadline != nil else { return false }
        deadline = nil
        return true
    }

    mutating func cancel() {
        deadline = nil
    }
}

final class MonotonicLatencySamples: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var values: [TimeInterval] = []

    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    func record(_ value: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        values.append(max(0, value))
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    func percentile(_ percentile: Double) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let bounded = min(1, max(0, percentile))
        let index = Int((Double(sorted.count - 1) * bounded).rounded(.up))
        return sorted[index]
    }
}

struct AXCircuitBreaker: Sendable {
    private(set) var consecutiveFailures = 0
    private(set) var openUntil: TimeInterval?

    mutating func recordSuccess() {
        consecutiveFailures = 0
        openUntil = nil
    }

    mutating func recordFailure(
        at now: TimeInterval,
        threshold: Int,
        recoveryDelay: TimeInterval
    ) {
        consecutiveFailures += 1
        if consecutiveFailures >= max(1, threshold) {
            openUntil = now + max(0, recoveryDelay)
        }
    }

    mutating func permitsAttempt(at now: TimeInterval) -> Bool {
        guard let openUntil else { return true }
        guard now >= openUntil else { return false }
        self.openUntil = nil
        return true
    }

    var isOpen: Bool { openUntil != nil }
}

struct AXSessionTiming: Sendable {
    let notificationReceivedAt: TimeInterval?
    let coalescingStartedAt: TimeInterval?
    let extractionStartedAt: TimeInterval
    let extractionFinishedAt: TimeInterval
    let decisionPublishedAt: TimeInterval

    var eventToDecisionLatency: TimeInterval? {
        notificationReceivedAt.map { max(0, decisionPublishedAt - $0) }
    }
}

struct AXSessionUpdate: Sendable {
    enum Trigger: String, Sendable {
        case bootstrap
        case notification
        case reconciliation
        case circuitOpen
        case stopped
    }

    let pid: pid_t
    let trigger: Trigger
    let effectiveFrom: TimeInterval
    let coverage: CoverageState
    let boxes: [PIIBox]
    let visitedElements: Int
    let timing: AXSessionTiming
}

private let observerCallback: AXObserverCallback = { _, element, _, context in
    guard let context else { return }
    let session = Unmanaged<AccessibilityObserverSession>.fromOpaque(context).takeUnretainedValue()
    session.receiveNotification(element: element)
}

/// Owns every live AX object for one process on a dedicated CFRunLoop thread.
/// Registry and coordinator callbacks receive immutable values only.
final class AccessibilityObserverSession: @unchecked Sendable {
    let pid: pid_t

    private let scanner: AccessibilityTextScanner
    private let configuration: AXObserverSessionConfiguration
    private let onUpdate: @Sendable (AXSessionUpdate) -> Void
    private let stateLock = NSLock()
    private var workerRunLoop: CFRunLoop?
    private var workerThread: Thread?
    private var isStopping = false

    // Worker-run-loop confined state.
    private var applicationElement: AXUIElement?
    private var observer: AXObserver?
    private var registeredNotifications: [String] = []
    private var pendingElement: AXUIElement?
    private var eventBurst = AXEventBurst()
    private var coalescingStartedAt: TimeInterval?
    private var coalescingTimer: CFRunLoopTimer?
    private var reconciliationTimer: CFRunLoopTimer?
    private var observerRecoveryTimer: CFRunLoopTimer?
    private var observerRetrySchedule = AXObserverRetrySchedule()
    private var geometry: CaptureGeometry
    private var breaker = AXCircuitBreaker()
    private var latestBoxes: [PIIBox] = []

    init(
        pid: pid_t,
        geometry: CaptureGeometry,
        scanner: AccessibilityTextScanner,
        configuration: AXObserverSessionConfiguration = AXObserverSessionConfiguration(),
        onUpdate: @escaping @Sendable (AXSessionUpdate) -> Void
    ) {
        self.pid = pid
        self.geometry = geometry
        self.scanner = scanner
        self.configuration = configuration
        self.onUpdate = onUpdate
    }

    func start() {
        stateLock.lock()
        guard workerThread == nil else {
            stateLock.unlock()
            return
        }
        let thread = Thread { [weak self] in self?.runWorker() }
        thread.name = "pii-stream.ax.\(pid)"
        thread.qualityOfService = .utility
        workerThread = thread
        stateLock.unlock()
        thread.start()
    }

    func updateGeometry(_ geometry: CaptureGeometry) {
        performOnWorker { $0.geometry = geometry }
    }

    func reconcile() {
        performOnWorker { $0.extract(trigger: .reconciliation, root: $0.applicationElement) }
    }

    func stop() {
        stateLock.lock()
        isStopping = true
        let runLoop = workerRunLoop
        stateLock.unlock()
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            self?.tearDownWorker()
            CFRunLoopStop(runLoop)
        }
        CFRunLoopWakeUp(runLoop)
    }

    fileprivate func receiveNotification(element: AXUIElement) {
        let now = ProcessInfo.processInfo.systemUptime
        let startsBurst = eventBurst.receive(at: now)
        if startsBurst {
            coalescingStartedAt = now
        }
        pendingElement = element
        if startsBurst {
            scheduleCoalescedExtraction()
        }
    }

    private func runWorker() {
        autoreleasepool {
            guard let runLoop = CFRunLoopGetCurrent() else { return }
            stateLock.lock()
            workerRunLoop = runLoop
            let shouldStop = isStopping
            stateLock.unlock()
            guard !shouldStop else { return }

            let application = AXUIElementCreateApplication(pid)
            applicationElement = application
            AXUIElementSetMessagingTimeout(application, configuration.messagingTimeout)

            startObserver(on: runLoop, application: application)
            CFRunLoopRun()
        }
    }

    private func startObserver(on runLoop: CFRunLoop, application: AXUIElement) {
        guard !isSessionStopping, observer == nil else { return }

        var createdObserver: AXObserver?
        let createError = AXObserverCreate(pid, observerCallback, &createdObserver)
        guard createError == .success, let createdObserver else {
            publishUnavailable(trigger: .circuitOpen, reason: "observer creation failed: \(createError.rawValue)")
            scheduleObserverRecovery(on: runLoop, application: application)
            return
        }

        observer = createdObserver
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(createdObserver), .defaultMode)
        registerNotifications(observer: createdObserver, application: application)
        guard !registeredNotifications.isEmpty else {
            publishUnavailable(trigger: .circuitOpen, reason: "no supported AX notifications")
            tearDownWorker()
            return
        }

        scheduleReconciliationTimer(on: runLoop)
        extract(trigger: .bootstrap, root: application)
    }

    private func scheduleObserverRecovery(on runLoop: CFRunLoop, application: AXUIElement) {
        guard !isSessionStopping, observer == nil, observerRecoveryTimer == nil else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard let fireAt = observerRetrySchedule.schedule(
            at: now,
            after: configuration.circuitRecoveryDelay
        ) else { return }
        let timer = CFRunLoopTimerCreateWithHandler(nil, fireAt, 0, 0, 0) { [weak self] _ in
            guard let self, self.observerRetrySchedule.beginScheduledAttempt() else { return }
            self.observerRecoveryTimer = nil
            self.startObserver(on: runLoop, application: application)
        }
        observerRecoveryTimer = timer
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
    }

    private func registerNotifications(observer: AXObserver, application: AXUIElement) {
        let notifications = [
            kAXValueChangedNotification,
            kAXSelectedTextChangedNotification,
            kAXFocusedUIElementChangedNotification,
            kAXFocusedWindowChangedNotification,
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXMovedNotification,
            kAXResizedNotification,
            kAXTitleChangedNotification,
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        for notification in notifications {
            let error = AXObserverAddNotification(observer, application, notification as CFString, context)
            if error == .success || error == .notificationAlreadyRegistered {
                registeredNotifications.append(notification)
            }
        }
    }

    private func scheduleCoalescedExtraction() {
        guard coalescingTimer == nil else { return }
        let fireAt = CFAbsoluteTimeGetCurrent() + configuration.coalescingDelay
        let timer = CFRunLoopTimerCreateWithHandler(nil, fireAt, 0, 0, 0) { [weak self] _ in
            guard let self else { return }
            self.coalescingTimer = nil
            let element = self.pendingElement
            self.pendingElement = nil
            self.extract(trigger: .notification, root: element ?? self.applicationElement)
        }
        coalescingTimer = timer
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
    }

    private func scheduleReconciliationTimer(on runLoop: CFRunLoop) {
        let interval = max(0.25, configuration.reconciliationInterval)
        let timer = CFRunLoopTimerCreateWithHandler(
            nil,
            CFAbsoluteTimeGetCurrent() + interval,
            interval,
            0,
            0
        ) { [weak self] _ in
            guard let self else { return }
            self.extract(trigger: .reconciliation, root: self.applicationElement)
        }
        reconciliationTimer = timer
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
    }

    private func extract(
        trigger: AXSessionUpdate.Trigger,
        root: AXUIElement?,
        effectiveFrom overrideEffectiveFrom: TimeInterval? = nil
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        guard breaker.permitsAttempt(at: now) else {
            publishUnavailable(trigger: .circuitOpen, reason: "AX circuit is open")
            return
        }
        guard let root else {
            recordFailure(trigger: trigger, reason: "AX root is unavailable")
            return
        }

        let receivedAt: TimeInterval?
        let coalescingAt: TimeInterval?
        if trigger == .notification {
            receivedAt = eventBurst.drain()?.firstReceivedAt
            coalescingAt = coalescingStartedAt
            coalescingStartedAt = nil
        } else {
            receivedAt = nil
            coalescingAt = nil
        }
        let extractionStartedAt = ProcessInfo.processInfo.systemUptime
        let isBootstrap = trigger == .bootstrap || trigger == .reconciliation
        let result = scanner.scan(
            root: root,
            geometry: geometry,
            maxDuration: isBootstrap ? configuration.bootstrapDuration : configuration.eventDuration,
            maxElements: isBootstrap ? configuration.maxBootstrapElements : configuration.maxEventElements
        )
        let extractionFinishedAt = ProcessInfo.processInfo.systemUptime

        if result.exhaustedBudget {
            recordFailure(trigger: trigger, reason: "bounded AX extraction timed out")
            return
        }
        breaker.recordSuccess()
        let effectiveFrom = overrideEffectiveFrom ?? receivedAt ?? extractionStartedAt
        if trigger == .notification {
            if !result.boxes.isEmpty {
                let combined = latestBoxes + result.boxes
                publish(
                    trigger: trigger,
                    effectiveFrom: effectiveFrom,
                    boxes: combined,
                    visitedElements: result.visitedElements,
                    receivedAt: receivedAt,
                    coalescingAt: coalescingAt,
                    extractionStartedAt: extractionStartedAt,
                    extractionFinishedAt: extractionFinishedAt
                )
            }
            // A targeted event can add protection immediately, but only a
            // bounded application reconciliation can remove old findings or
            // publish a clear process snapshot.
            extract(
                trigger: .reconciliation,
                root: applicationElement,
                effectiveFrom: effectiveFrom
            )
            return
        }

        latestBoxes = result.boxes
        publish(
            trigger: trigger,
            effectiveFrom: effectiveFrom,
            boxes: result.boxes,
            visitedElements: result.visitedElements,
            receivedAt: receivedAt,
            coalescingAt: coalescingAt,
            extractionStartedAt: extractionStartedAt,
            extractionFinishedAt: extractionFinishedAt
        )
    }

    private func publish(
        trigger: AXSessionUpdate.Trigger,
        effectiveFrom: TimeInterval,
        boxes: [PIIBox],
        visitedElements: Int,
        receivedAt: TimeInterval?,
        coalescingAt: TimeInterval?,
        extractionStartedAt: TimeInterval,
        extractionFinishedAt: TimeInterval
    ) {
        let publishedAt = ProcessInfo.processInfo.systemUptime
        onUpdate(AXSessionUpdate(
            pid: pid,
            trigger: trigger,
            effectiveFrom: effectiveFrom,
            coverage: .verified,
            boxes: boxes,
            visitedElements: visitedElements,
            timing: AXSessionTiming(
                notificationReceivedAt: receivedAt,
                coalescingStartedAt: coalescingAt,
                extractionStartedAt: extractionStartedAt,
                extractionFinishedAt: extractionFinishedAt,
                decisionPublishedAt: publishedAt
            )
        ))
    }

    private func recordFailure(trigger: AXSessionUpdate.Trigger, reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        breaker.recordFailure(
            at: now,
            threshold: configuration.circuitFailureThreshold,
            recoveryDelay: configuration.circuitRecoveryDelay
        )
        publishUnavailable(
            trigger: breaker.isOpen ? .circuitOpen : trigger,
            reason: reason
        )
    }

    private func publishUnavailable(trigger: AXSessionUpdate.Trigger, reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        onUpdate(AXSessionUpdate(
            pid: pid,
            trigger: trigger,
            effectiveFrom: now,
            coverage: .unavailable(reason: reason),
            boxes: [],
            visitedElements: 0,
            timing: AXSessionTiming(
                notificationReceivedAt: eventBurst.firstReceivedAt,
                coalescingStartedAt: coalescingStartedAt,
                extractionStartedAt: now,
                extractionFinishedAt: now,
                decisionPublishedAt: now
            )
        ))
    }

    private func performOnWorker(_ operation: @escaping (AccessibilityObserverSession) -> Void) {
        stateLock.lock()
        let runLoop = workerRunLoop
        let stopping = isStopping
        stateLock.unlock()
        guard let runLoop, !stopping else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            guard let self else { return }
            operation(self)
        }
        CFRunLoopWakeUp(runLoop)
    }

    private var isSessionStopping: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isStopping
    }

    private func clearObserver(on runLoop: CFRunLoop) {
        if let observer, let applicationElement {
            for notification in registeredNotifications {
                AXObserverRemoveNotification(observer, applicationElement, notification as CFString)
            }
            CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        registeredNotifications.removeAll()
        observer = nil
    }

    private func tearDownWorker() {
        coalescingTimer.map(CFRunLoopTimerInvalidate)
        reconciliationTimer.map(CFRunLoopTimerInvalidate)
        observerRecoveryTimer.map(CFRunLoopTimerInvalidate)
        coalescingTimer = nil
        reconciliationTimer = nil
        observerRecoveryTimer = nil
        observerRetrySchedule.cancel()
        clearObserver(on: CFRunLoopGetCurrent())
        applicationElement = nil
        let now = ProcessInfo.processInfo.systemUptime
        onUpdate(AXSessionUpdate(
            pid: pid,
            trigger: .stopped,
            effectiveFrom: now,
            coverage: .unavailable(reason: "AX session stopped"),
            boxes: [],
            visitedElements: 0,
            timing: AXSessionTiming(
                notificationReceivedAt: nil,
                coalescingStartedAt: nil,
                extractionStartedAt: now,
                extractionFinishedAt: now,
                decisionPublishedAt: now
            )
        ))
    }
}

struct AXRegistryUpdate: Sendable {
    let boxes: [PIIBox]
    let coverage: CoverageState
    let observedAt: TimeInterval
    let effectiveFrom: TimeInterval
    let activeSessionCount: Int
    let trigger: AXSessionUpdate.Trigger
    let visitedElements: Int
    let eventToDecisionLatency: TimeInterval?
}

/// Reconciles visible process membership at a bounded cadence and aggregates
/// per-process session output into one Accessibility detection source batch.
final class AccessibilityProcessRegistry: @unchecked Sendable {
    private struct SessionState {
        let session: AccessibilityObserverSession
        var boxes: [PIIBox] = []
        var coverage: CoverageState = .unknown(reason: "bootstrap pending")
    }

    private let queue = DispatchQueue(label: "pii-stream.ax.registry", qos: .utility)
    private let scanner: AccessibilityTextScanner
    private let geometryProvider: @Sendable () -> CaptureGeometry?
    private let windowTarget: CGWindowID?
    private let configuration: AXObserverSessionConfiguration
    private let onUpdate: @Sendable (AXRegistryUpdate) -> Void
    private var sessions: [pid_t: SessionState] = [:]
    private var discoveryTimer: DispatchSourceTimer?

    init(
        scanner: AccessibilityTextScanner,
        geometryProvider: @escaping @Sendable () -> CaptureGeometry?,
        windowTarget: CGWindowID?,
        configuration: AXObserverSessionConfiguration = AXObserverSessionConfiguration(),
        onUpdate: @escaping @Sendable (AXRegistryUpdate) -> Void
    ) {
        self.scanner = scanner
        self.geometryProvider = geometryProvider
        self.windowTarget = windowTarget
        self.configuration = configuration
        self.onUpdate = onUpdate
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.discoveryTimer == nil else { return }
            self.reconcileProcesses()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            let interval = max(0.25, self.configuration.reconciliationInterval)
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.reconcileProcesses() }
            self.discoveryTimer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            discoveryTimer?.cancel()
            discoveryTimer = nil
            for state in sessions.values { state.session.stop() }
            sessions.removeAll()
        }
    }

    private func reconcileProcesses() {
        guard AccessibilityTextScanner.isTrusted, let geometry = geometryProvider() else {
            let now = ProcessInfo.processInfo.systemUptime
            onUpdate(AXRegistryUpdate(
                boxes: [],
                coverage: .unavailable(reason: "Accessibility permission is unavailable"),
                observedAt: now,
                effectiveFrom: now,
                activeSessionCount: sessions.count,
                trigger: .reconciliation,
                visitedElements: 0,
                eventToDecisionLatency: nil
            ))
            return
        }

        let pids = visiblePIDs(geometry: geometry)
        for pid in sessions.keys where !pids.contains(pid) {
            sessions.removeValue(forKey: pid)?.session.stop()
        }
        for pid in pids {
            if let state = sessions[pid] {
                state.session.updateGeometry(geometry)
            } else {
                let session = AccessibilityObserverSession(
                    pid: pid,
                    geometry: geometry,
                    scanner: scanner,
                    configuration: configuration
                ) { [weak self] update in
                    self?.queue.async { self?.accept(update) }
                }
                sessions[pid] = SessionState(session: session)
                session.start()
            }
        }

        if sessions.isEmpty {
            let now = ProcessInfo.processInfo.systemUptime
            onUpdate(AXRegistryUpdate(
                boxes: [],
                coverage: .unknown(reason: "no relevant visible AX processes"),
                observedAt: now,
                effectiveFrom: now,
                activeSessionCount: 0,
                trigger: .reconciliation,
                visitedElements: 0,
                eventToDecisionLatency: nil
            ))
        }
    }

    private func accept(_ update: AXSessionUpdate) {
        guard update.trigger != .stopped, var state = sessions[update.pid] else { return }
        state.boxes = update.boxes
        state.coverage = update.coverage
        sessions[update.pid] = state

        let coverage: CoverageState
        if let incomplete = sessions.values.map(\.coverage).first(where: { !$0.permitsClearDecision }) {
            coverage = incomplete
        } else {
            coverage = .verified
        }
        let observedAt = ProcessInfo.processInfo.systemUptime
        onUpdate(AXRegistryUpdate(
            boxes: sessions.values.flatMap(\.boxes),
            coverage: coverage,
            observedAt: observedAt,
            effectiveFrom: update.effectiveFrom,
            activeSessionCount: sessions.count,
            trigger: update.trigger,
            visitedElements: update.visitedElements,
            eventToDecisionLatency: update.timing.eventToDecisionLatency.map { _ in
                max(0, observedAt - update.effectiveFrom)
            }
        ))
    }

    private func visiblePIDs(geometry: CaptureGeometry) -> Set<pid_t> {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var pids: [pid_t] = []
        for entry in info {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            if let windowTarget {
                guard let number = entry[kCGWindowNumber as String] as? CGWindowID,
                      number == windowTarget else { continue }
            } else {
                let rect = CGRect(
                    x: bounds["X"] ?? 0,
                    y: bounds["Y"] ?? 0,
                    width: bounds["Width"] ?? 0,
                    height: bounds["Height"] ?? 0
                )
                guard rect.intersects(geometry.globalRect) else { continue }
            }
            if !pids.contains(pid) { pids.append(pid) }
            if pids.count == 6 { break }
        }
        return Set(pids)
    }
}
