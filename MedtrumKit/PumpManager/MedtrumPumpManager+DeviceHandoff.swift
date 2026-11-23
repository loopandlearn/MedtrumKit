import Foundation
import LoopKit

// Handing the patch to another controller, such as Trio on Apple Watch.
//
// The patch accepts any controller that has its serial number and session token, and keeps one
// Bluetooth link at a time. So the releasing side drops its link and stops reconnecting, and the
// adopting side connects with the exported state. Each side books only the doses it commanded:
// the open basal dose is closed at the release and started fresh at a take or an adopt.
//
// The patch doesn't say which controller started a delivery, and has no session counter like
// Omnipod's. But it keeps one link at a time, so while this controller is linked no other one can
// start anything: delivery that began after this controller last heard the patch is another one's
// (`foreignDeliveryEvidence`). It is checked at each connection, before any command of our own, on
// the patch's own start times, not on when its records arrive. So that a controller that would dose
// nothing still leaves a mark the other can find, a shared patch always runs a temp basal: at the
// scheduled rate when nothing else runs (`keepControlMarked`). The detection follows @EJM0's
// "Stand aside when another controller has run the patch", EJM0/MedtrumKit 326eaa4, in loopandlearn/MedtrumKit#6.

// MARK: - Configuration sharing

extension MedtrumPumpManager: DeviceConfigurationSharing {
    public func exportConfiguration() -> SharedDeviceConfiguration {
        if !state.sharedWithAnotherController {
            state.sharedWithAnotherController = true
            notifyStateDidChange()
        }

        let shared = MedtrumPumpState(rawValue: state.rawValue)
        shared.peripheralIdentifier = nil
        shared.controlReleased = false
        shared.supersedingUntil = nil
        shared.refusesAfterForeignDelivery = false
        shared.foreignDeliveryDetectedAt = nil
        shared.expectsForeignDelivery = false
        shared.lastContactAt = nil
        shared.unansweredDeliveryCommandAt = nil
        shared.bolusDose = nil

        return SharedDeviceConfiguration(
            managerIdentifier: pluginIdentifier,
            asOf: state.reservoirReadAt ?? state.lastSync,
            deliveredUnits: deliveredUnits?.units,
            state: shared.rawValue
        )
    }

    /// The state an adopting manager starts from, or nil if the export can't drive a patch.
    static func adoptedState(from configuration: SharedDeviceConfiguration, localState: [String: Any]?) -> MedtrumPumpState? {
        guard configuration.managerIdentifier == "Medtrum" else {
            return nil
        }

        let state = MedtrumPumpState(rawValue: configuration.state)
        guard !state.pumpSN.isEmpty, !state.sessionToken.isEmpty, !state.patchSessionEnded else {
            return nil
        }

        state.peripheralIdentifier = handle(in: localState, forPumpSN: state.pumpSN)
        state.controlReleased = false
        state.sharedWithAnotherController = true
        // the first connection meets the exporter's delivery
        state.expectsForeignDelivery = true
        state.basalDose = UnfinalizedDose(
            basalRate: state.currentBaseBasalRate,
            insulinType: state.insulinType,
            startDate: Date.now
        )
        state.bolusDose = nil
        return state
    }

    /// This device's Bluetooth handle for the patch. Never in the export.
    public var localState: [String: Any]? {
        guard let identifier = state.peripheralIdentifier else {
            return nil
        }
        return ["pumpSN": state.pumpSN, "peripheralIdentifier": identifier.uuidString]
    }

    static func handle(in localState: [String: Any]?, forPumpSN pumpSN: Data) -> UUID? {
        guard let localState, localState["pumpSN"] as? Data == pumpSN else {
            return nil
        }
        return (localState["peripheralIdentifier"] as? String).flatMap(UUID.init(uuidString:))
    }
}

// MARK: - Exclusive control

extension MedtrumPumpManager: ExclusiveDeviceControl {
    public var isControlReleased: Bool {
        state.controlReleased
    }

    /// Refused while a bolus is running: only this controller could follow it to the end.
    public func releaseControl() {
        guard !state.controlReleased else {
            return
        }
        guard state.bolusState == .noBolus else {
            log.warning("Release refused: a bolus is running")
            return
        }

        let now = Date.now
        var events = finalizedTempBasal(endedAt: now)
        if !events.isEmpty {
            events.append(NewPumpEvent.basal(dose: UnfinalizedDose(
                basalRate: state.currentBaseBasalRate,
                insulinType: state.insulinType,
                startDate: now
            ).toDoseEntry()))
        }
        state.basalDose = UnfinalizedDose(basalRate: state.currentBaseBasalRate, insulinType: state.insulinType, startDate: now)
        state.controlReleased = true
        state.sharedWithAnotherController = true
        state.supersedingUntil = nil
        notifyStateDidChange()
        if !events.isEmpty {
            emitPumpEvents(events)
        }

        log.info("Control released to another controller")
        bluetooth?.disconnectForRelease()
    }

    public func takeControl() {
        take(supersedingUntil: nil, liftingRefusal: false)
    }

    public func takeControl(supersedingAnotherControllerUntil until: Date?) {
        take(supersedingUntil: until, liftingRefusal: until != nil)
    }

    public func takeControlLiftingRefusal() {
        take(supersedingUntil: nil, liftingRefusal: true)
    }

    public func stopSupersedingAnotherController() {
        state.supersedingUntil = nil
        notifyStateDidChange()
    }

    private func take(supersedingUntil until: Date?, liftingRefusal: Bool) {
        if liftingRefusal {
            state.refusesAfterForeignDelivery = false
            state.foreignDeliveryDetectedAt = nil
        } else if state.refusesAfterForeignDelivery {
            // as OmnipodKit: a plain take of a refused patch stays refused and off the radio
            logDeviceCommunication("[trust] plain take of a refused patch: stays refused", type: .connection)
            return
        }

        let wasReleased = state.controlReleased
        state.supersedingUntil = until
        if wasReleased || liftingRefusal || until != nil {
            // the other controller's delivery from before this take shows at the next connection
            state.expectsForeignDelivery = true
        }
        if wasReleased || liftingRefusal {
            // the other controller booked its own doses; start ours from now
            state.basalDose = UnfinalizedDose(
                basalRate: state.currentBaseBasalRate,
                insulinType: state.insulinType,
                startDate: Date.now
            )
            state.bolusDose = nil
        }
        state.controlReleased = false
        notifyStateDidChange()
        log.info("Taking control of the patch")

        ensureConnectedAndActive { error in
            if let error {
                self.log.warning("Take: no connection yet: \(error.localizedDescription)")
                return
            }
            self.pumpDelegate.notify { delegate in
                delegate?.deviceManagerControlDidBecomeReady(self)
            }
        }
    }

    /// Connect for each command or status read instead of keeping the link open; Trio on Apple Watch sets it.
    /// Patch alarms then show at the next contact, at most a loop cycle later.
    public func setConnectsOnDemand(_ onDemand: Bool) {
        bluetooth?.setConnectsOnDemand(onDemand)
    }

    public var isControlReady: Bool {
        guard !state.controlReleased, !state.refusesAfterForeignDelivery, let bluetooth else {
            return false
        }
        return bluetooth.isConnected
    }

    /// True when there is no Bluetooth handle for this patch here, so a take has to scan, which only works in the foreground.
    public static func takeControlNeedsSearch(adopting configuration: SharedDeviceConfiguration, localState: [String: Any]?) -> Bool {
        let pumpSN = configuration.state["pumpSN"] as? Data ?? Data()
        return handle(in: localState, forPumpSN: pumpSN) == nil
    }

    /// After another controller ran the patch outside a superseding take, this manager sends the patch nothing and
    /// connects to nothing, until the host takes control with a date or lifting the refusal.
    public var refusesSessions: Bool {
        state.refusesAfterForeignDelivery
    }

    /// When another controller was last found to have run the patch. Each finding updates the state, so the host is
    /// told every time.
    public var foreignSessionDetectedAt: Date? {
        state.foreignDeliveryDetectedAt
    }

    public var deliveryStartedAt: Date? {
        state.patchActivatedAt
    }

    public var deliveryEndsAt: Date? {
        state.patchExpiresAt
    }
}

// MARK: - Detecting another controller

extension MedtrumPumpState {
    /// Newest history records a connection reads, newest first
    static let foreignRecordsRead: UInt64 = 8
    /// How long an unanswered command may have taken to reach the patch: the write timeout
    static let unansweredCommandWindow: TimeInterval = 30

    /// At a connection's first status, before any command of ours: delivery the patch never starts by itself - a
    /// temp basal, a bolus - that began after this controller last heard the patch (`since`), when only another
    /// controller can have been linked. Our own commands are answered, which moves `since` past them; one whose
    /// answer was lost (`unansweredDeliveryCommandAt`) is allowed for. Alarms, suspends, a temp basal running out and
    /// daily totals, which the patch writes by itself, prove nothing. The connection an adopt or a take expects
    /// (`expectsForeignDelivery`) is not checked. Both expectations are used up here.
    /// A bolus whose record the patch writes only at its end goes unseen while it runs; the next temp basal shows it.
    /// - Parameters:
    ///   - previousSequence: the newest history record this controller saw before this connection
    ///   - basal: what the patch runs, from this connection's first status
    ///   - readRecord: reads one history record over this connection
    /// - Returns: what shows another controller ran the patch, for the log
    func foreignDeliveryEvidence(
        since: Date?,
        previousSequence: UInt64?,
        basal: BasalData?,
        readRecord: (UInt64) -> GetRecordPacketResponse?
    ) -> String? {
        let expected = expectsForeignDelivery
        let unanswered = unansweredDeliveryCommandAt
        expectsForeignDelivery = false
        unansweredDeliveryCommandAt = nil
        guard sharedWithAnotherController, !expected, let since else {
            return nil
        }

        let slack = patchClockSlack
        let after = since.addingTimeInterval(slack)
        func isOurs(_ start: Date) -> Bool {
            guard let unanswered else { return false }
            return start >= unanswered.addingTimeInterval(-slack) &&
                start <= unanswered.addingTimeInterval(Self.unansweredCommandWindow + slack)
        }

        if let basal, basal.type.isTemp {
            let start = deviceTime(basal.startTime)
            if start > after, !isOurs(start) {
                return "a temp basal of \(basal.rate) U/h started \(start), after this controller's last contact \(since)"
            }
        }

        guard let previous = previousSequence, let latest = latestRecordSequence, latest > previous else {
            return nil
        }

        let oldest = max(previous + 1, latest - min(latest, Self.foreignRecordsRead - 1))
        for index in stride(from: latest, through: oldest, by: -1) {
            guard let bolus = readRecord(index)?.bolus else { continue }
            let start = deviceTime(bolus.startedAt)
            if start > after, !isOurs(start) {
                return "a bolus of \(bolus.amount) U started \(start) (record #\(index)), " +
                    "after this controller's last contact \(since)"
            }
        }
        return nil
    }
}

extension MedtrumPumpManager {
    /// Another controller ran the patch since this one last did. Within a superseding take it is only reported:
    /// the superseded controller may not have heard yet. Otherwise, as OmnipodKit at a foreign session, this
    /// controller sends nothing more and drops its link until the host takes control with a date or lifting the
    /// refusal. The other controller booked its own delivery, and ours from before stays booked.
    /// - Returns: this controller stands aside
    func foreignDeliveryFound(_ evidence: String) -> Bool {
        let now = Date.now
        state.foreignDeliveryDetectedAt = now
        if let until = state.supersedingUntil, until > now {
            logDeviceCommunication("[trust] another controller used the patch: \(evidence) - superseding it until \(until)", type: .connection)
            notifyStateDidChange()
            return false
        }

        state.refusesAfterForeignDelivery = true
        // what the patch runs now is the other controller's; the next take starts our booking afresh
        state.basalDose = UnfinalizedDose(basalRate: state.currentBaseBasalRate, insulinType: state.insulinType, startDate: now)
        notifyStateDidChange()
        logDeviceCommunication(
            "[trust] another controller used the patch: \(evidence) - sending nothing until control is taken again",
            type: .connection
        )
        bluetooth?.disconnectForRelease()
        return true
    }

    /// Notes a temp basal or bolus command that got no answer: the patch may have started it
    func noteUnansweredDeliveryCommand(sentAt: Date) {
        guard state.sharedWithAnotherController else { return }
        state.unansweredDeliveryCommandAt = sentAt
        notifyStateDidChange()
    }
}

// MARK: - Marking control

extension MedtrumPumpManager {
    /// The longest mark: a host's own temp basals are no longer
    static let markDuration: TimeInterval = .minutes(30)
    /// The shortest mark worth setting before the schedule changes rate
    static let shortestMark: TimeInterval = .minutes(5)

    /// On a patch shared with another controller, a temp basal at the scheduled rate whenever none of ours runs, so
    /// the other controller always finds delivery it didn't start, even when this one's host doses nothing. It ends
    /// at the next change of the schedule, so it delivers exactly the scheduled basal. A temp basal the patch runs
    /// that isn't ours (the superseded controller's, after a take) is replaced. Runs after full syncs; never on a
    /// patch released, refused, suspended or bolusing, and never over a temp basal of ours.
    func keepControlMarked() {
        guard mayMarkControl(), markDurationNow() != nil, !markIsBusy() else {
            return
        }

        ensureConnectedAndActive { error in
            guard error == nil else {
                self.markDone()
                return
            }
            self.deliveryCommandLock.lock()
            defer {
                self.deliveryCommandLock.unlock()
                self.markDone()
            }
            // the host may have set a temp basal meanwhile
            guard self.mayMarkControl(), let duration = self.markDurationNow() else {
                return
            }

            if self.state.basalState == .tempBasal {
                // another controller's temp basal, or one of ours whose answer was lost: ours from now
                if case let .failure(error) = self.bluetooth.write(CancelTempBasalPacket()) {
                    self.log.warning("Marking control: cancelling the temp basal running failed: \(error.localizedDescription)")
                    return
                }
                self.state.basalState = .active
            }

            let rate = self.state.currentBaseBasalRate
            let sentAt = Date.now
            if case let .failure(error) = self.bluetooth.write(SetTempBasalPacket(rate: rate, duration: duration)) {
                self.log.warning("Marking control failed: \(error.localizedDescription)")
                self.noteUnansweredDeliveryCommand(sentAt: sentAt)
                return
            }

            self.logDeviceCommunication("[trust] marked control: temp basal at the scheduled \(rate) U/h for \(Int(duration.minutes)) min")
            self.bookTempBasal(decisionId: nil, unitsPerHour: rate, duration: duration, automatic: true)
        }
    }

    private func mayMarkControl() -> Bool {
        state.sharedWithAnotherController && !state.controlReleased && !state.refusesAfterForeignDelivery &&
            !state.patchSessionEnded && (state.pumpState == .active || state.pumpState == .active_alt) &&
            state.basalState != .suspended && (state.basalDose.type == .basal || state.basalDose.type == .resume) &&
            state.bolusState == .noBolus && state.currentBaseBasalRate > 0
    }

    /// Whole minutes up to the next schedule change, at most `markDuration`; nil if that is too short
    func markDurationNow(at now: Date = .now) -> TimeInterval? {
        let startOfDay = Calendar.current.startOfDay(for: now)
        let sinceMidnight = now.timeIntervalSince(startOfDay)
        let nextChange = state.basalSchedule.entries.map(\.startTime).filter { $0 > sinceMidnight }.min() ?? .hours(24)
        let minutes = (min(Self.markDuration, nextChange - sinceMidnight) / 60).rounded(.down)
        return minutes * 60 >= Self.shortestMark ? minutes * 60 : nil
    }
}

// MARK: - Delivered-total odometer

extension MedtrumPumpManager: PumpDeliveryOdometer {
    static let pulseSize = 0.05

    /// The starting reservoir minus the current one, in whole pulses.
    public var deliveredUnits: (units: Double, at: Date)? {
        guard let initial = state.initialReservoir, let readAt = state.reservoirReadAt else {
            return nil
        }
        let pulses = ((initial - state.reservoir) / Self.pulseSize).rounded()
        return (max(0, pulses) * Self.pulseSize, readAt)
    }

    public var deliveryPulseUnits: Double {
        Self.pulseSize
    }

    public var deliveredUnitsAreFinal: Bool {
        state.pumpState.isFault || state.pumpState.isTerminated
    }

    public func refreshDeliveredUnits() async -> Bool {
        let before = state.reservoirReadAt
        let synced: Date? = await withCheckedContinuation { continuation in
            syncPumpData { continuation.resume(returning: $0) }
        }
        guard synced != nil, let after = state.reservoirReadAt else {
            return false
        }
        return before.map { after > $0 } ?? true
    }

    /// Our own bolus only: the patch reports what a bolus delivered so far, not how much it will give.
    public var bolusUnderWayEndsAt: Date? {
        guard state.bolusState != .noBolus, let bolus = state.bolusDose else {
            return nil
        }
        return bolus.estimatedEndDate
    }

    /// Reads the status if it is older than `age`.
    public func readStatusIfOlder(than age: TimeInterval, completion: @escaping (Date?) -> Void) {
        guard !state.controlReleased, !state.refusesAfterForeignDelivery,
              Date.now.timeIntervalSince(state.lastSync) > age
        else {
            completion(state.lastSync)
            return
        }
        syncPumpData { _ in
            completion(self.state.lastSync)
        }
    }
}

extension BasalType {
    var isTemp: Bool {
        self == .ABSOLUTE_TEMP || self == .RELATIVE_TEMP
    }
}
