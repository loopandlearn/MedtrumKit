import CoreBluetooth

class BluetoothManager: NSObject, CBCentralManagerDelegate {
    public weak var pumpManager: MedtrumPumpManager?

    let logger = MedtrumLogger(category: "BluetoothManager")

    var manager: CBCentralManager!
    let managerQueue = DispatchQueue(label: "com.nightscout.MedtrumKit.bluetoothManagerQueue", qos: .unspecified)

    private var peripheral: CBPeripheral?
    private var peripheralManager: PeripheralManager?
    private var forcedDisconnect: Bool = false

    private var scanCompletion: ((MedtrumScanResult) -> Void)?

    private var attempt: ConnectAttempt?

    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?

    /// This manager's connect and disconnect edges, for the hand-off's diagnostics
    let connectClock = ConnectClock()

    // MARK: Connect on demand (managerQueue-isolated)

    /// Idle-disconnect delay after the last command, as OmnipodKit's. Kept short so that in the background the link
    /// drops before iOS suspends the app; the foreground and a keep-alive hold the link separately
    /// (`MedtrumPumpManager.shouldHoldConnection`), so this only takes effect while backgrounded. A status read and the
    /// dose after it share one connection only when the dose comes within this delay: each command restarts it.
    static var idleDisconnectSeconds: TimeInterval {
        (UserDefaults.standard.object(forKey: "MedtrumKit.idleDisconnectSeconds") as? Double) ?? 4
    }

    /// True while the app is frontmost: the link is held so in-app commands are instant. Written on managerQueue, read
    /// across queues by the pump manager (benign bool race, as OmnipodKit's).
    private(set) var isAppForeground = false

    private var idleDisconnect: DispatchWorkItem?

    // MARK: Hand-off (managerQueue-isolated unless noted)

    /// Released to another controller: no connect, no write, no reconnect until taken back. Lock-guarded, the write
    /// path reads it off managerQueue.
    private let releasedLock = NSLock()
    private var releasedStorage = false
    var isReleasedForLoan: Bool {
        get { releasedLock.withLock { releasedStorage } }
        set { releasedLock.withLock { releasedStorage = newValue } }
    }

    /// A release waiting for the write under way to finish, so the patch is not left mid-exchange
    private var pendingRelease = false

    /// Longest a release waits for a write under way; the write's own timeout ends it sooner
    static let releaseWaitLimit: TimeInterval = 20

    /// A take until the patch first answers: connects are retried until then, or until released
    private var takeInProgress = false
    private var takeEscalationToken: UUID?

    /// The take escalated, or this controller holds no handle for the base: find it by its serial number in the
    /// advertisement, since CoreBluetooth handles are per device
    private var takeoverSearching = false

    // MUST NOT be called from within managerQueue - deadlock
    public var isConnected: Bool {
        managerQueue.sync { isConnectedOnQueue }
    }

    /// a live link alone is not yet a usable session
    private var isConnectedOnQueue: Bool {
        if let peripheral = peripheral, peripheral.state == .connected, peripheralManager?.isReady == true {
            return true
        }

        return false
    }

    deinit {
        logger.info("BluetoothManager deallocated")
    }

    /// The identifier we were paired with when the central was created. `CBCentralManager` can
    /// deliver `willRestoreState` on `managerQueue` the moment it exists - which is inside
    /// `MedtrumPumpManager.init`, before that initialiser reaches `bluetooth.pumpManager = self` - so
    /// restoration cannot rely on reading the identifier off `pumpManager`. It is only read while
    /// validating restoration, which happens once at creation and therefore before anything can
    /// change it; `pumpManager` is the authority everywhere else.
    private let identifierAtLaunch: UUID?

    init(knownPeripheralIdentifier: UUID?, controlReleased: Bool) {
        identifierAtLaunch = knownPeripheralIdentifier

        super.init()

        // Before the central exists: its first callbacks can come before `pumpManager` is set
        isReleasedForLoan = controlReleased

        managerQueue.sync {
            #if os(iOS)
                let options: [String: Any] = [
                    CBCentralManagerOptionRestoreIdentifierKey: "com.nightscout.MedtrumKit.bluetoothManager"
                ]
            #else
                // watchOS has no state restoration: the watch host owns the process lifetime
                let options: [String: Any] = [:]
            #endif
            self.manager = CBCentralManager(delegate: self, queue: managerQueue, options: options)
        }

        let center = NotificationCenter.default
        center.addObserver(forName: HostAppState.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.managerQueue.async {
                self?.enterForeground()
            }
        }
        center.addObserver(forName: HostAppState.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.managerQueue.async {
                self?.enterBackground()
            }
        }

        // Seed from the live application state: a manager built after the app became active never sees the
        // notification for this launch (loopandlearn/OmnipodKit#133). If the notification wins, this is a no-op.
        DispatchQueue.main.async { [weak self] in
            guard HostAppState.isActive else {
                return
            }
            self?.managerQueue.async {
                guard let self, !self.isAppForeground else {
                    return
                }
                self.enterForeground()
            }
        }
    }

    /// The app came to the front: hold the link, connecting now if it is down, so in-app commands are instant
    private func enterForeground() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        isAppForeground = true
        logger.info("[lifecycle] app foreground")
        connectToHold(why: "foreground - pre-connecting to hold the link")
    }

    /// The app went to the background: drop the held link, unless a keep-alive holds it (the heartbeat, silent tones)
    /// or a command or a bolus still needs it
    private func enterBackground() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        isAppForeground = false
        logger.info("[lifecycle] app background")

        if pumpManager?.shouldHoldConnection == true {
            connectToHold(why: "background - keep-alive holding the link")
            return
        }

        if attempt != nil || peripheralManager?.isWriting == true {
            // Mid-command: the idle disconnect drops the link after it
            logger.info("[connectOnDemand] background - command in flight, deferring disconnect to idle")
            armIdleDisconnect()
            return
        }

        guard pumpManager?.needsLink != true else {
            return
        }

        cancelLinkOnQueue(why: "background")
    }

    /// Connects if the link should be held and is down
    private func connectToHold(why: String) {
        guard pumpManager?.shouldHoldConnection == true, pumpManager?.state.pumpState.isRunning == true,
              !isReleasedForLoan, attempt == nil, !isConnectedOnQueue,
              peripheral != nil || pumpManager?.state.peripheralIdentifier != nil
        else {
            return
        }

        logger.info("[connectOnDemand] \(why)")
        ensureConnectedOnQueue { error in
            if let error {
                self.logger.warning("Failed to connect to hold the link: \(error)")
            }
        }
    }

    private func startScan(_ completion: @escaping (_ result: MedtrumScanResult) -> Void) {
        if let pumpManager = self.pumpManager, pumpManager.state.pumpSN.isEmpty {
            completion(.failure(error: .noSerialNumberAvailable))
            return
        }
        guard manager.state == .poweredOn else {
            completion(.failure(error: .invalidBluetoothState(state: manager.state)))
            return
        }

        if manager.isScanning {
            manager.stopScan()
        }

        scanCompletion = completion
        manager.scanForPeripherals(withServices: [])

        logger.info("Started scanning")
        // TODO: Add scan timeout - 15s?
    }

    private func connect(peripheral: CBPeripheral) {
        if manager.isScanning {
            manager.stopScan()
            scanCompletion = nil
        }

        // cancelling a pending connect does not always produce a didDisconnect
        forcedDisconnect = false

        self.peripheral = peripheral

        // a connect from an earlier attempt can still be pending
        guard peripheral.state != .connecting else {
            logger.info("Connect already pending, waiting on it")
            return
        }

        logger.info("Connecting to \(peripheral)")
        manager.connect(peripheral)
    }

    /// anything that mutates connection state must check this.
    private func isCurrent(_ candidate: CBPeripheral) -> Bool {
        candidate.identifier == peripheral?.identifier
    }

    /// Disconnects only if `manager` is still the one driving the link
    func disconnect(ifCurrent candidate: PeripheralManager) {
        managerQueue.async {
            guard self.peripheralManager === candidate else {
                return
            }

            self.disconnectOnQueue(force: false)
        }
    }

    /// Hands a result to a caller. Never on the current thread: completions issue blocking BLE
    /// writes: from the main thread that freezes the UI for up to 30s per packet (syncPumpTime
    /// sends three), and from managerQueue - which every caller of this is now on - it would
    /// deadlock outright, since that is the queue the response has to be delivered on.
    private func report(_ error: MedtrumConnectError?, to completion: @escaping (MedtrumConnectError?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(error)
        }
    }

    /// Reports `attempt` to everyone waiting on it, if nobody has yet. Must be called on
    /// `managerQueue`.
    private func finish(_ attempt: ConnectAttempt, _ error: MedtrumConnectError?) {
        guard attempt.claim() else {
            return
        }

        if self.attempt === attempt {
            self.attempt = nil
        }

        if error == nil {
            reconnectAttempts = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            rememberPeripheral()

            // ExclusiveDeviceControl readiness: a fresh session, or the answer a take was waiting for
            if attempt.connected || takeInProgress {
                if takeoverSearching {
                    connectionLog("take: found the base by its serial number and connected")
                }
                takeInProgress = false
                takeEscalationToken = nil
                takeoverSearching = false
                pumpManager?.notifyControlReady()
            }
            armIdleDisconnect()
        } else if shouldReconnect {
            scheduleReconnect()
        }

        for completion in attempt.takeCompletions() {
            report(error, to: completion)
        }
    }

    private func rememberPeripheral() {
        guard let pumpManager, let peripheral, pumpManager.state.peripheralIdentifier != peripheral.identifier else {
            return
        }

        pumpManager.state.peripheralIdentifier = peripheral.identifier
        pumpManager.notifyStateDidChange()
    }

    /// Connect on demand: a dropped or failed link comes back only while something needs it - the host's
    /// heartbeat, a bolus under way, patch setup - or a take is reaching for the patch. Never while released.
    private var shouldReconnect: Bool {
        guard !isReleasedForLoan else {
            return false
        }

        return takeInProgress || pumpManager?.needsLink == true
    }

    /// Must be called on `managerQueue`.
    private func scheduleReconnect() {
        // `ensureConnectedOnQueue` can retrieve the peripheral from stored identifier, or scan for a takeover
        guard peripheral != nil || pumpManager?.state.peripheralIdentifier != nil || takeoverSearching else {
            // otherwise we would be retrying a scan, which doesn't work in the background
            return
        }

        let seconds: TimeInterval = reconnectAttempts == 0
            ? 0
            : min(TimeInterval(1 << min(reconnectAttempts, 6)), 60)
        reconnectAttempts += 1

        logger.info("Scheduling reconnect #\(reconnectAttempts) in \(Int(seconds))s")

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            if seconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                if Task.isCancelled {
                    return
                }
            }

            guard let self else {
                return
            }

            managerQueue.async {
                guard self.attempt == nil,
                      !self.isConnectedOnQueue,
                      self.shouldReconnect,
                      self.peripheral != nil || self.pumpManager?.state.peripheralIdentifier != nil || self.takeoverSearching
                else {
                    return
                }

                self.ensureConnectedOnQueue { error in
                    if let error = error {
                        self.logger.warning("Failed to auto-reconnect: \(error)")
                    }
                }
            }
        }
    }

    func ensureConnected(_ completion: @escaping (MedtrumConnectError?) -> Void) {
        managerQueue.async {
            self.ensureConnectedOnQueue(completion)
        }
    }

    private func ensureConnectedOnQueue(_ completion: @escaping (MedtrumConnectError?) -> Void) {
        // Wait on the connect already in flight instead of failing. A connect owns the link for as
        // long as auth, synchronize and subscribe take, and anything the loop or the user asks for
        // in that window used to be turned away outright - a bolus issued in the same second as a
        // reconnect would fail while the link it needed came up moments later.
        if let inFlight = attempt {
            logger.debug("EnsureConnected is already running, waiting on it")
            inFlight.addCompletion(completion)
            return
        }

        guard !isReleasedForLoan else {
            logger.info("Control is released to another controller, not connecting")
            report(.controlReleased, to: completion)
            return
        }

        let attempt = ConnectAttempt(completion)
        self.attempt = attempt
        idleDisconnect?.cancel()

        if isConnectedOnQueue {
            logger.debug("Already connect!")
            finish(attempt, nil)
            return
        }

        if let peripheral = peripheral, peripheral.state == .connected {
            logger.warning("Connected but the session is not ready, dropping the link to rebuild it")
            startTimeout(attempt, seconds: .seconds(15))
            manager.cancelPeripheralConnection(peripheral)
            return
        }

        if takeoverSearching, let stale = peripheral {
            // This device's handle never reached the base: search for it instead
            if stale.state != .disconnected {
                manager.cancelPeripheralConnection(stale)
            }
            peripheral = nil
        }

        if let peripheral = peripheral {
            // We've the peripheral reference to a previous connection
            // Just try to reconnect
            logger.info("Reconnecting to the peripheral of the previous connection")
            startTimeout(attempt, seconds: .seconds(15))
            connect(peripheral: peripheral)
            return
        }

        // We lost the reference but know which device we are paired with. Ask CoreBluetooth for it
        // back rather than scanning: a connect to a known peripheral is honoured in the background
        // (and stays pending until the pump is in range again), while a scan only ever discovers
        // anything while the app is in the foreground.
        if !takeoverSearching, manager.state == .poweredOn,
           let identifier = pumpManager?.state.peripheralIdentifier,
           let peripheral = manager.retrievePeripherals(withIdentifiers: [identifier]).first
        {
            logger.info("Retrieved known peripheral \(identifier), reconnecting")
            startTimeout(attempt, seconds: .seconds(15))
            connect(peripheral: peripheral)
            return
        }

        guard var pumpSNState = pumpManager?.state.pumpSN else {
            logger.error("No pump serial number found")
            finish(attempt, .failedToFindDevice)
            return
        }

        pumpSNState = Data(pumpSNState.reversed())

        // We are disconnected and have no reference to the previous connection
        // Start to scan for patch and reconnect the long way
        logger.info("No known peripheral, scanning for the base with our serial number")
        startTimeout(attempt, seconds: .seconds(15))
        startScan { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case let .failure(error):
                self.logger.error("Error during scanning: \(error.localizedDescription)")
                self.manager.stopScan()
                self.finish(attempt, .failedToFindDevice)

            case let .success(peripheral, pumpSN, _, _):
                guard pumpSN == pumpSNState else {
                    // Other patch pump found. IGNORE
                    return
                }

                self.connect(peripheral: peripheral)
            }
        }
    }

    /// Arms the deadline for `attempt`, replacing any deadline already on it. Called at each point
    /// the connect flow makes progress, so the allowance for waking up suspended starts over.
    private func startTimeout(_ attempt: ConnectAttempt, seconds: TimeInterval) {
        attempt.remainingExtensions = ConnectAttempt.maxExtensions
        armTimeout(attempt, seconds: seconds)
    }

    private func armTimeout(_ attempt: ConnectAttempt, seconds: TimeInterval) {
        attempt.timeout?.cancel()
        attempt.armedAt = .now
        attempt.timeoutGeneration &+= 1
        let generation = attempt.timeoutGeneration

        attempt.timeout = Task { [weak self, weak attempt] in
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            } catch {
                // Cancelled, because the attempt was reported before we woke
                return
            }

            guard let self else {
                return
            }

            managerQueue.async { [weak self, weak attempt] in
                // is this still the attempt in flight? Covers being superseded by a re-arm, and waking a moment before cancellation landed.
                guard let self, let attempt, self.attempt === attempt,
                      attempt.timeoutGeneration == generation
                else {
                    return
                }

                // `Task.sleep` is frozen while iOS has the app suspended, so waking far past the budget
                // means we were asleep for most of it rather than waiting on a pump that never answered
                // - and we typically wake because the connection we were waiting for just arrived. Give
                // the attempt the budget it never got instead of failing a connect that may be landing
                // in this very instant. Bounded, so a phone that keeps suspending still terminates.
                let elapsed = Date.now.timeIntervalSince(attempt.armedAt)
                if elapsed > seconds * 2, attempt.remainingExtensions > 0 {
                    attempt.remainingExtensions -= 1
                    self.logger
                        .warning(
                            "Timeout woke after \(Int(elapsed))s of a \(Int(seconds))s budget - app was suspended, re-arming"
                        )
                    self.armTimeout(attempt, seconds: seconds)
                    return
                }

                // Don't skip this just because the peripheral is connected by now: the link coming up
                // is not the same as being ready, since auth, synchronize and subscribe still follow.
                // Skipping would leave the attempt in flight with nothing to clear it, wedging every
                // later ensureConnected. didConnect re-arms us on a longer budget.
                self.logger.error("Failed to connect: Timeout reached...")

                if self.manager.isScanning {
                    self.manager.stopScan()
                    self.scanCompletion = nil
                }

                self.finish(attempt, .failedToConnectToDevice)
            }
        }
    }

    func write(_ packet: any MedtrumBasePacketProtocol) -> MedtrumWriteResult<Any> {
        guard !isReleasedForLoan else {
            return .failure(error: .controlReleased)
        }

        // Only the lookup is serialised. writePacket blocks for up to 30s waiting for a response
        // that is delivered on managerQueue, so it must not be holding the queue while it waits.
        guard let peripheralManager = managerQueue.sync(execute: { self.peripheralManager }) else {
            return .failure(error: .noManager)
        }

        return peripheralManager.writePacket(packet)
    }

    func disconnect(force: Bool = false) {
        managerQueue.async {
            self.disconnectOnQueue(force: force)
        }
    }

    private func disconnectOnQueue(force: Bool) {
        // forcedDisconnect is set to true only here, normal disconnects should not abort the force disconnect
        if force {
            forcedDisconnect = true
        }

        // both .connected AND .connecting
        if let peripheral, peripheral.state != .disconnected {
            manager.cancelPeripheralConnection(peripheral)
        }

        if force {
            clearPeripheralOnQueue()
        }
    }

    // MARK: - Connect on demand

    /// (Re-)arms the idle disconnect. Must be called on `managerQueue`.
    private func armIdleDisconnect() {
        idleDisconnect?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.disconnectIfIdle()
        }
        idleDisconnect = work
        managerQueue.asyncAfter(deadline: .now() + Self.idleDisconnectSeconds, execute: work)
    }

    private func disconnectIfIdle() {
        guard let peripheral, peripheral.state != .disconnected,
              attempt == nil,
              peripheralManager?.isWriting != true,
              pumpManager?.needsLink != true
        else {
            return
        }

        logger.info("Idle for \(Int(Self.idleDisconnectSeconds))s, nothing needs the link - disconnecting")
        manager.cancelPeripheralConnection(peripheral)
    }

    /// A command or a notification just went over the link
    func noteActivity() {
        managerQueue.async {
            self.armIdleDisconnect()
        }
    }

    /// A write finished: a release waiting on it goes through, otherwise the idle clock starts over
    func writeDidFinish() {
        managerQueue.async {
            if self.pendingRelease {
                self.finishPendingRelease(why: "the write under way finished")
                return
            }
            self.armIdleDisconnect()
        }
    }

    /// The host's need for the link changed (heartbeat, a bolus): connect if it is needed now, otherwise let the link
    /// go idle
    func linkNeedChanged() {
        managerQueue.async {
            guard !self.isReleasedForLoan else {
                return
            }

            if self.pumpManager?.needsLink == true, self.pumpManager?.state.pumpState.isRunning == true,
               !self.isConnectedOnQueue, self.attempt == nil
            {
                self.ensureConnectedOnQueue { error in
                    if let error {
                        self.logger.warning("Failed to connect for the link the host needs: \(error)")
                    }
                }
            } else {
                self.armIdleDisconnect()
            }
        }
    }

    // MARK: - Hand-off

    /// Stops bidding for the base's single connection so another controller holds it uncontested. Pairing and session
    /// token are kept. A write under way finishes first (at most `releaseWaitLimit`), so the patch is not left
    /// mid-exchange; a command still waiting for its connection fails at once, having sent nothing.
    func releaseForLoan() {
        managerQueue.async {
            self.isReleasedForLoan = true
            self.takeInProgress = false
            self.takeoverSearching = false
            self.takeEscalationToken = nil
            self.idleDisconnect?.cancel()
            self.reconnectTask?.cancel()
            self.reconnectTask = nil
            self.reconnectAttempts = 0
            if self.manager.isScanning {
                self.manager.stopScan()
                self.scanCompletion = nil
            }
            if let attempt = self.attempt {
                self.finish(attempt, .controlReleased)
            }

            guard self.peripheralManager?.isWriting == true else {
                self.cancelLinkOnQueue(why: "released")
                return
            }

            self.pendingRelease = true
            self.connectionLog("[release] a write is under way - releasing the patch when it finishes")
            self.managerQueue.asyncAfter(deadline: .now() + Self.releaseWaitLimit) {
                self.finishPendingRelease(why: "wait limit reached")
            }
        }
    }

    private func finishPendingRelease(why: String) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard pendingRelease else {
            return
        }

        pendingRelease = false
        connectionLog("[release] releasing the patch - \(why)")
        cancelLinkOnQueue(why: "released")
    }

    /// Drops the link but keeps the peripheral and its identifier, unlike a forced disconnect
    private func cancelLinkOnQueue(why: String) {
        guard let peripheral, peripheral.state != .disconnected else {
            return
        }

        logger.info("Cancelling the link: \(why)")
        manager.cancelPeripheralConnection(peripheral)
    }

    /// Lifts a release and connects: by this device's handle, or by searching for the base's serial number when it has
    /// none. Retried until the patch answers or control is released.
    func take(search: Bool) {
        managerQueue.async {
            self.liftReleaseOnQueue()
            self.takeInProgress = true
            self.reconnectAttempts = 0
            if search {
                self.connectionLog("take: no handle for this base on this device - searching for it by serial number")
                self.takeoverSearching = true
            }

            self.ensureConnectedOnQueue { error in
                if let error {
                    self.logger.warning("Take: first connect failed, retrying: \(error)")
                }
            }
        }
    }

    /// The patch is no longer this controller's to release (deactivated elsewhere): lift the release without connecting
    func liftRelease() {
        managerQueue.async {
            self.liftReleaseOnQueue()
        }
    }

    private func liftReleaseOnQueue() {
        isReleasedForLoan = false
        // Taken back before a waiting release landed: the release is void
        pendingRelease = false
    }

    /// After `delay`, a take the patch has not answered scans for the base by its serial number, until it answers or
    /// control is released. A later take replaces it.
    func scheduleTakeEscalation(after delay: TimeInterval) {
        managerQueue.async {
            let token = UUID()
            self.takeEscalationToken = token
            self.managerQueue.asyncAfter(deadline: .now() + delay) {
                guard self.takeEscalationToken == token else {
                    return
                }

                self.takeEscalationToken = nil
                guard self.takeInProgress, !self.isReleasedForLoan, !self.isConnectedOnQueue else {
                    return
                }

                self.connectionLog(
                    "take: the patch has not answered after \(Int(delay)) s - scanning for it by serial number · " +
                        self.diagnostics
                )
                self.takeoverSearching = true
                self.reconnectAttempts = 0
                if let attempt = self.attempt {
                    // Its connect waits on a handle that is not reaching the base
                    if let peripheral = self.peripheral, peripheral.state != .disconnected {
                        self.manager.cancelPeripheralConnection(peripheral)
                    }
                    self.finish(attempt, .failedToConnectToDevice)
                } else {
                    self.scheduleReconnect()
                }
            }
        }
    }

    /// One line of link state for the device log
    var diagnostics: String {
        let radio: String
        switch manager.state {
        case .poweredOn: radio = "on"
        case .poweredOff: radio = "OFF"
        case .resetting: radio = "resetting"
        case .unauthorized: radio = "unauthorized"
        case .unsupported: radio = "unsupported"
        case .unknown: radio = "unknown"
        @unknown default: radio = "unknown(\(manager.state.rawValue))"
        }
        let link: String
        switch peripheral?.state {
        case .none: link = "no-peripheral"
        case .disconnected: link = "disconnected"
        case .connecting: link = "connecting"
        case .connected: link = "connected"
        case .disconnecting: link = "disconnecting"
        @unknown default: link = "unknown"
        }
        return "radio=\(radio) scanning=\(manager.isScanning) base=\(link) search=\(takeoverSearching) · " +
            connectClock.summary(since: connectClock.attemptStartedAt)
    }

    /// What changes who controls the patch, or explains a failure: to the device log as well
    private func connectionLog(_ message: String) {
        logger.info(message)
        pumpManager?.logDeviceCommunication(message, type: .connection)
    }

    /// Forgets the device entirely - used when the patch is deactivated and when the pump base is
    /// swapped for another one. It also drops the stored identifier, so the next connect has to
    /// find the base by scanning, which is fine: both of those are foreground activities.
    func clearPeripheral() {
        managerQueue.async {
            self.clearPeripheralOnQueue()
        }
    }

    private func clearPeripheralOnQueue(forgetIdentifier: Bool = true) {
        if manager.isScanning {
            manager.stopScan()
        }
        scanCompletion = nil

        pumpManager?.state.isConnected = false

        peripheral = nil
        // didDisconnectPeripheral returns early on a forced disconnect, so this is the only place
        // the forced path can invalidate the manager - releasing it is not enough, its auth/sync
        // worker holds its own reference and would keep writing to pumpManager.state.
        peripheralManager?.cleanup()
        peripheralManager = nil

        if forgetIdentifier, pumpManager?.state.peripheralIdentifier != nil {
            pumpManager?.state.peripheralIdentifier = nil
            pumpManager?.notifyStateDidChange()
        }

        if let attempt = attempt {
            finish(attempt, .failedToFindDevice)
        }

        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0
    }
}

extension BluetoothManager {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("\(String(describing: central.state.rawValue))")

        guard central.state == .poweredOn else {
            // CBPeripheral is invalid after a reset or when Bluetooth is unusable, need to retrieve it again
            if [.resetting, .unsupported, .unauthorized].contains(central.state) {
                clearPeripheralOnQueue(forgetIdentifier: false)
                pumpManager?.notifyStateDidChange()
            }
            return
        }

        guard !isReleasedForLoan, pumpManager?.state.controlReleased != true else {
            // A relaunch must not take the patch back from the controller holding it
            logger.info("Powered on with control released, not connecting")
            return
        }

        guard attempt == nil else {
            // Somebody is already connecting and owns the attempt. Installing ours over it would
            // strand that caller - they would never be called back at all.
            logger.info("Powered on while a connect attempt is in flight, leaving it be")
            return
        }

        if let peripheral = self.peripheral, pumpManager?.needsLink != true {
            // Connect on demand: a restored link nobody needs goes idle, the next command connects
            if peripheral.state != .disconnected {
                logger.info("Restored a link nothing needs, disconnecting")
                manager.cancelPeripheralConnection(peripheral)
            }
            return
        }

        if let peripheral = self.peripheral {
            logger.info("Reconnecting to restored state...")

            let attempt = ConnectAttempt { [weak self] (error: MedtrumConnectError?) in
                if let error = error {
                    self?.logger.error("Failed to restore state: \(error)")
                } else {
                    self?.logger.info("Restored state!")
                }
            }
            self.attempt = attempt

            // Without this the restore path has no deadline at all: a connect that never completes
            // leaves the attempt in flight for good, and every later ensureConnected fails.
            startTimeout(attempt, seconds: .seconds(15))
            connect(peripheral: peripheral)
            return
        }

        if !isConnectedOnQueue, pumpManager?.state.pumpState.isRunning == true, pumpManager?.needsLink == true {
            ensureConnectedOnQueue { error in
                if let error = error {
                    self.logger.error("Failed to auto reconnect on boot: \(error)")
                }
            }
        }
    }

    func centralManager(
        _: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi _: NSNumber
    ) {
        guard let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String, !name.isEmpty, name == "MT" else {
            return
        }

        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey]
        guard let manufacturerData = manufacturerData as? Data, manufacturerData.count >= 7 else {
            // Simulator bypass -> 200u
            scanCompletion?(
                .success(
                    peripheral: peripheral,
                    pumpSN: Data([0x28, 0xD8, 0x12, 0x4A]),
                    deviceType: 1,
                    version: 1
                )
            )
            // Simulator bypass -> 300u
            scanCompletion?(
                .success(
                    peripheral: peripheral,
                    pumpSN: Data([0x14, 0x16, 0xDF, 0x52]),
                    deviceType: 1,
                    version: 1
                )
            )
            return
        }

        // Index:
        // 0 & 1 -> Manufacturer ID
        // 2-5 -> PumpSN
        // 6 -> Device type
        // 7 -> Version
        scanCompletion?(
            .success(
                peripheral: peripheral,
                pumpSN: manufacturerData[2 ..< 6],
                deviceType: manufacturerData[6],
                version: manufacturerData[7]
            )
        )
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.info("Connected to pump: \(peripheral.name ?? "<NO_NAME>")!")
        connectClock.noteConnect()

        if isReleasedForLoan {
            // A connect that landed as control was released: the other controller needs the base's one connection
            logger.info("Dropping a connection that landed after control was released")
            central.cancelPeripheralConnection(peripheral)
            return
        }

        if forcedDisconnect {
            logger.info("Dropping a connection that landed after a forced disconnect")
            central.cancelPeripheralConnection(peripheral)
            return
        }

        guard isCurrent(peripheral) else {
            logger.info("Dropping a connection for a peripheral we are not driving")
            central.cancelPeripheralConnection(peripheral)
            return
        }

        // A real reconnect passes through didDisconnect first, which cleans the manager up - so a
        // ready session here means this callback is a duplicate.
        if peripheralManager?.isReady == true {
            logger.info("Ignoring duplicate didConnect - session already established")
            return
        }

        // This guard drops the link rather than just returning. `peripheral` is already set at this
        // point, so bailing out would leave a live peripheral with no PeripheralManager behind it:
        // the next ensureConnected reports "Already connect!" while every write fails with
        // .noManager, and nothing clears that until the link happens to drop on its own.
        guard let pumpManager = pumpManager else {
            logger.warning("No pumpManager...")
            disconnectOnQueue(force: true)
            return
        }

        // The attempt this belongs to already gave up - typically its deadline fired while the app
        // was suspended, in the same instant the link finally came up. Do not throw the connection
        // away: reconnecting to a known peripheral is the only thing that works while backgrounded,
        // and dropping it here strands us on the scan path, which does not. Nobody is waiting on
        // the result any more, so adopt it under an attempt of our own and finish the flow.
        let attempt: ConnectAttempt
        if let inFlight = self.attempt {
            attempt = inFlight
        } else {
            logger.info("No connectCompletion, adopting the connection anyway")

            attempt = ConnectAttempt { [weak self] (error: MedtrumConnectError?) in
                if let error = error {
                    self?.logger.error("Failed to complete adopted connection: \(error)")
                } else {
                    self?.logger.info("Adopted connection is ready")
                }
            }
            self.attempt = attempt
        }

        forcedDisconnect = false
        attempt.connected = true

        self.peripheral = peripheral

        peripheralManager?.cleanup()
        peripheralManager = PeripheralManager(peripheral, self, pumpManager) { [weak self, weak attempt] error in
            // Called from two queues: the CBPeripheralDelegate callbacks report discovery failures
            // on managerQueue, while the auth flow runs on a global worker and reports from there.
            // Land both on managerQueue, since that is where finish reads and clears the attempt.
            self?.managerQueue.async {
                guard let self, let attempt else {
                    return
                }

                self.finish(attempt, error)
            }
        }

        // The link is up but the flow is not done - auth, synchronize and subscribe still have to
        // run, and each of those is a writePacket with its own 30s timeout. Re-arm on a budget that
        // covers all of them, so a stalled flow still reports back instead of hanging the caller.
        startTimeout(attempt, seconds: .seconds(150))

        peripheral.discoverServices([CBUUID.SERVICE_UUID])
    }

    #if os(iOS)
    func centralManager(_ centralManager: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        guard !peripherals.isEmpty else {
            logger.warning("No restored peripherals!")
            return
        }

        // `pumpManager` is usually still nil here - see `identifierAtLaunch`.
        let knownIdentifier = pumpManager?.state.peripheralIdentifier ?? identifierAtLaunch

        for peripheral in peripherals {
            if peripheral.services?.first(where: { $0.uuid == CBUUID.SERVICE_UUID }) == nil {
                logger.warning("Couldnt restore state, since no service is available...")
                centralManager.cancelPeripheralConnection(peripheral)
                continue
            }

            guard peripheral.identifier == knownIdentifier else {
                logger.warning("Dropping restored peripheral \(peripheral.identifier): not our known base")
                centralManager.cancelPeripheralConnection(peripheral)
                continue
            }

            logger.info("Restored our known base \(peripheral.identifier)")
            self.peripheral = peripheral
        }
    }
    #endif

    func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectClock.noteDisconnect(error: error)
        logger
            .info(
                "Device disconnected, name: \(peripheral.name ?? "<NO_NAME>"), error: \(error?.localizedDescription ?? "No error")"
            )

        guard isCurrent(peripheral) else {
            logger.info("Ignoring disconnect for a peripheral we are not driving")
            return
        }

        if forcedDisconnect {
            forcedDisconnect = false
            return
        }

        if let pumpManager = self.pumpManager {
            pumpManager.state.isConnected = false
            pumpManager.notifyStateDidChange()
        }

        if let peripheralManager = peripheralManager {
            peripheralManager.cleanup()
            self.peripheralManager = nil
        }

        idleDisconnect?.cancel()
        pendingRelease = false

        if let attempt = attempt {
            logger.info("Disconnected during the connect sequence")
            finish(attempt, .failedToConnectToDevice)
        } else if shouldReconnect {
            scheduleReconnect()
        }
    }

    func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectClock.noteFailToConnect(error: error)
        logger
            .info(
                "Device connect error, name: \(peripheral.name ?? "<NO_NAME>"), error: \(error?.localizedDescription ?? "No error")"
            )

        guard isCurrent(peripheral) else {
            logger.info("Ignoring connect error for a peripheral we are not driving")
            return
        }

        if let pumpManager = self.pumpManager {
            pumpManager.state.isConnected = false
            pumpManager.notifyStateDidChange()
        }

        // The attempt is over, so report it now. Leaving it to the timeout means the caller waits
        // out the full budget for a failure we already know about.
        if let attempt = attempt {
            finish(attempt, .failedToConnectToDevice)
        }
    }
}
