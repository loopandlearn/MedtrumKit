//
//  MedtrumPumpManager+DeviceHandoff.swift
//  MedtrumKit
//
//  Handing the patch to another controller: LoopKit's DeviceConfigurationSharing, ExclusiveDeviceControl and
//  PumpDeliveryOdometer, as OmnipodKit does (loopandlearn/OmnipodKit#177). The kit keeps the contract's rules here:
//  an export carries no local state; this controller's own handle for the base travels only in its `localState`, which
//  the host saves and hands back at the next adopt; an adopter owns the in-flight doses under the exporter's
//  identities; a controller that released drops its copies when it takes control back; and none books delivery it did
//  not command (StateSyncer). A failed patch can be ended by the controller holding it, and the other forgets it
//  without booking.
//
//  Medtrum needs less than Omnipod: the session token authorizes any controller and the write sequence starts over on
//  every connection, so the export carries the token and there is no counter to resynchronize. Without such a counter,
//  another controller's use shows in the delivery the patch reports: a temp basal or a bolus that began while this
//  controller was not connected (`otherControllerEvidence`). A controller that finds one stands aside until its host
//  takes control again, as OmnipodKit's does at an unexpected session resync.
//

import Foundation
import LoopKit

private let handoffLog = MedtrumLogger(category: "DeviceHandoff")

// MARK: - Configuration sharing

extension MedtrumPumpManager: DeviceConfigurationSharing {
    /// Marks the patch shared: another controller may run it from this copy
    public func exportConfiguration() -> SharedDeviceConfiguration {
        if !state.isShared, !state.patchId.isEmpty {
            state.sharedPatchId = state.patchId
            notifyStateDidChange()
        }

        return SharedDeviceConfiguration(
            managerIdentifier: pluginIdentifier,
            asOf: state.reservoirReadAt ?? state.lastSync,
            deliveredUnits: deliveredUnits?.units,
            state: state.sharedCopy().rawValue
        )
    }

    /// The state `init(adopting:localState:)` builds from, with this controller's own handle if `localState` holds one
    /// for the same base; `takeControl()` searches if not.
    static func adoptedState(from configuration: SharedDeviceConfiguration, localState: [String: Any]?) -> MedtrumPumpState? {
        let shared = MedtrumPumpState(rawValue: configuration.state)
        guard !shared.pumpSN.isEmpty else {
            return nil
        }

        return shared.adopted(handle: MedtrumPumpState.handle(in: localState, forPumpSN: shared.pumpSN))
    }

    /// This controller's handle for its base
    public var localState: [String: Any]? {
        state.localState
    }
}

extension MedtrumPumpState {
    /// This controller's CoreBluetooth handle for the base, with the base's serial number so it is never used for
    /// another one. Handles are per device, so the export never carries one.
    var localState: [String: Any]? {
        guard !pumpSN.isEmpty, let handle = peripheralIdentifier else {
            return nil
        }

        return ["pumpSN": pumpSN, "peripheralIdentifier": handle.uuidString]
    }

    /// The handle in `localState`, if it is for the base with `pumpSN`
    static func handle(in localState: [String: Any]?, forPumpSN pumpSN: Data) -> UUID? {
        guard let localState, localState["pumpSN"] as? Data == pumpSN else {
            return nil
        }

        return (localState["peripheralIdentifier"] as? String).flatMap(UUID.init(uuidString:))
    }

    /// The export: facts about the patch, none of this controller's relationship to it
    func sharedCopy() -> MedtrumPumpState {
        let shared = MedtrumPumpState(rawValue: rawValue)
        shared.peripheralIdentifier = nil
        shared.controlReleased = false
        shared.configuredByAnotherController = false
        shared.inFlightDosesInheritedAway = false
        shared.untrackedDeliveryIsForeign = false
        shared.expectsForeignRecords = false
        shared.otherControllerDetectedAt = nil
        return shared
    }

    /// Another controller's shared state as this one's: in-flight doses keep the exporter's identities (their start
    /// dates), and delivery this controller did not command is not booked
    func adopted(handle: UUID?) -> MedtrumPumpState {
        let state = MedtrumPumpState(rawValue: rawValue)
        state.peripheralIdentifier = handle
        state.controlReleased = false
        state.configuredByAnotherController = true
        state.inFlightDosesInheritedAway = false
        state.untrackedDeliveryIsForeign = true
        state.sharedPatchId = patchId
        state.expectsForeignRecords = true
        return state
    }

    static let deliveryPulseUnits = 0.05

    /// The patch has no delivered counter: what it has given since its first reservoir reading, which both controllers
    /// share through the export
    var deliveredUnits: (units: Double, at: Date)? {
        guard !patchSessionEnded, let initial = initialReservoir else {
            return nil
        }

        let pulses = (max(0, initial - reservoir) / Self.deliveryPulseUnits).rounded()
        return (pulses * Self.deliveryPulseUnits, reservoirReadAt ?? lastSync)
    }

    /// Copies of a bolus or temp basal still in flight now belong to the controller taking over
    func releaseControl() {
        controlReleased = true
        inFlightDosesInheritedAway = bolusDose != nil || basalDose.type == .tempBasal
    }

    /// Another controller ran the patch: book none of its delivery, and with `dropInFlight` drop the in-flight copies,
    /// which that controller booked
    func resolveAfterForeignControl(dropInFlight: Bool, at now: Date = .now) {
        bolusEnded()
        untrackedDeliveryIsForeign = true
        controlReleased = false
        inFlightDosesInheritedAway = false
        guard dropInFlight else {
            return
        }

        bolusDose = nil
        cancelingBolusSince = nil
        if basalDose.type == .tempBasal {
            // Not reported: the scheduled basal is the patch's own, and the next status says what it is running
            basalDose = UnfinalizedDose(basalRate: currentBaseBasalRate, insulinType: insulinType, startDate: now)
        }
    }
}

// MARK: - Exclusive control

extension MedtrumPumpManager: ExclusiveDeviceControl {
    public var isControlReleased: Bool {
        state.controlReleased
    }

    /// Stops bidding for the base's single connection; pairing and session token are kept. A write under way finishes
    /// first. Copies of a bolus or temp basal still in flight now belong to the controller taking over.
    public func releaseControl() {
        state.releaseControl()
        bluetooth.releaseForLoan()
        handoffLog.info("Control released, doses in flight handed over: \(state.inFlightDosesInheritedAway)")

        // A saved handle that never connected is wrong: drop it, so `localState` goes nil and the next adopt searches
        if let unproven = bluetooth.connectClock.adoptedHandleThatNeverConnected() {
            state.peripheralIdentifier = nil
            logDeviceCommunication("saved handle \(unproven) never connected - forgotten; the next adopt searches", type: .connection)
        }
        notifyStateDidChange()
    }

    /// Lifts a release, then connects: by the handle this device has, or by searching for the base's serial number.
    /// It connects with or without a release here: another controller can take the patch without this one releasing
    /// it (a watch's start without the phone). A take whose patch has not answered after `takeEscalateAfter` scans for
    /// it, until it answers or control is released; a take of a patch already connected has its answer.
    public func takeControl() {
        if state.controlReleased {
            bluetooth.connectClock.beginAttempt(adoptedHandle: nil)
            state.resolveAfterForeignControl(dropInFlight: state.inFlightDosesInheritedAway)
            handoffLog.info("Control taken back, delivery the patch reports is another controller's until it settles")
        }
        if state.otherControllerDetectedAt != nil {
            logDeviceCommunication("[trust] taking control again after another controller was detected", type: .connection)
            state.otherControllerDetectedAt = nil
        }
        // The first connection after a take meets the other controller's delivery before it
        state.expectsForeignRecords = state.isShared
        notifyStateDidChange()

        bluetooth.take(search: takeControlNeedsSearch)
        bluetooth.scheduleTakeEscalation(after: Self.takeEscalateAfter)
    }

    /// How long a take waits for the patch's answer before it scans for the base by serial number
    static let takeEscalateAfter: TimeInterval = 12

    public var isControlReady: Bool {
        #if targetEnvironment(simulator)
            // No radio: any paired base counts as ready
            return !state.pumpSN.isEmpty
        #else
            return bluetooth.isConnected
        #endif
    }

    var takeControlNeedsSearch: Bool {
        !state.pumpSN.isEmpty && state.peripheralIdentifier == nil
    }

    /// An adopter searches for the base unless `localState` holds this controller's handle for it
    public static func takeControlNeedsSearch(
        adopting configuration: SharedDeviceConfiguration,
        localState: [String: Any]?
    ) -> Bool {
        let shared = MedtrumPumpState(rawValue: configuration.state)
        guard !shared.pumpSN.isEmpty else {
            return false
        }

        return MedtrumPumpState.handle(in: localState, forPumpSN: shared.pumpSN) == nil
    }
}

// MARK: - Detecting another controller

extension MedtrumPumpState {
    /// Newest history records a connection reads, newest first
    static let otherControllerRecordsRead: UInt64 = 8

    /// This patch was handed over (exported or adopted): another controller may run it
    var isShared: Bool {
        !patchId.isEmpty && sharedPatchId == patchId
    }

    /// At a connection's first status: delivery the patch never starts by itself - a temp basal, a bolus - that began
    /// after this controller last heard the patch (`since`), when only another controller can have been connected. This
    /// controller's own commands are answered, which moves `since` past them. Alarms, suspends, a temp basal running
    /// out and daily totals the patch writes by itself prove nothing. The one connection a take or an adopt expects is
    /// skipped: the other controller's use before it. Patch times are compared in this device's time
    /// (`deviceTime`), within `patchClockSlack`.
    /// ponytail: a bolus whose record the patch writes only at its end, and that is still running here, goes unseen;
    /// the other controller's next temp basal or bolus shows it. Read the running bolus' record if that is too late.
    /// - Parameters:
    ///   - previousSequence: the newest history record this controller saw before this connection
    ///   - basal: what the patch runs, from this connection's first status
    ///   - readRecord: reads one history record over this connection
    /// - Returns: what shows another controller ran the patch, for the log
    func otherControllerEvidence(
        since: Date?,
        previousSequence: UInt64?,
        basal: BasalData?,
        readRecord: (UInt64) -> GetRecordPacketResponse?
    ) -> String? {
        let expected = expectsForeignRecords
        expectsForeignRecords = false
        guard isShared, !expected, let since else {
            return nil
        }

        let after = since.addingTimeInterval(patchClockSlack)
        if let basal, basal.type.isTempBasal(), deviceTime(basal.startTime) > after {
            return "a temp basal of \(basal.rate) U/h started \(deviceTime(basal.startTime)), " +
                "after this controller's last contact \(since)"
        }

        guard let previous = previousSequence, let latest = latestRecordSequence, latest > previous else {
            return nil
        }

        let oldest = max(previous + 1, latest - min(latest, Self.otherControllerRecordsRead - 1))
        for index in stride(from: latest, through: oldest, by: -1) {
            if let bolus = readRecord(index)?.bolus?.inDeviceTime(of: self), bolus.startedAt > after {
                return "a bolus of \(bolus.amount) U started \(bolus.startedAt) (record #\(index)), " +
                    "after this controller's last contact \(since)"
            }
        }
        return nil
    }
}

public extension MedtrumPumpManager {
    /// When another controller was found to have run the patch, as OmnipodKit's: nothing is sent until the host takes
    /// control again
    var otherControllerDetectedAt: Date? {
        state.otherControllerDetectedAt
    }
}

extension MedtrumPumpManager {
    /// Another controller ran the patch since this one last did: book none of its delivery, keep this controller's
    /// doses in flight (the other did not adopt them), and send nothing more until the host takes control again
    func standAside(because evidence: String) {
        state.resolveAfterForeignControl(dropInFlight: false)
        state.otherControllerDetectedAt = .now
        bluetooth.releaseForLoan()
        logDeviceCommunication(
            "[trust] another controller has used the patch: \(evidence) - sending nothing until control is taken again",
            type: .connection
        )
        notifyStateDidChange()
    }
}

// MARK: - Ending a failed patch

public extension MedtrumPumpManager {
    /// What the app shows for an inoperable patch, e.g. "Occlusion" or "Expired"
    var localizedInoperableDescription: String? {
        guard isInoperable else {
            return nil
        }

        return state.pumpState.description
    }

    /// A failed patch keeps alarming until it is deactivated, and only the controller holding it can do that
    var failedDeviceDeactivationTitle: String? {
        guard !state.patchSessionEnded, state.pumpState.isTerminated else {
            return nil
        }

        return String(
            localized: "Deactivate Patch",
            comment: "Action that deactivates a failed patch from the controller holding it"
        )
    }

    /// The patch settings' deactivation: stop the patch and end its session, booking its end here
    func deactivateFailedDevice() async throws {
        let result = await withCheckedContinuation { done in
            deactivatePatch { done.resume(returning: $0) }
        }
        if case let .failure(error) = result {
            throw error
        }
    }

    /// The controller that ended the patch booked its last delivery: this copy's in-flight doses are dropped as at a
    /// take-back, and the session ends without booking anything
    func forgetDeviceDeactivatedElsewhere() async {
        guard !state.patchSessionEnded, state.controlReleased || state.otherControllerDetectedAt != nil else {
            return
        }

        state.resolveAfterForeignControl(dropInFlight: state.inFlightDosesInheritedAway)
        state.otherControllerDetectedAt = nil
        logDeviceCommunication("[release] the patch was deactivated by another controller; forgotten here", type: .connection)
        endPatchSession(at: .now, statusIsCurrent: false, bookingDelivery: false)
        // As a deactivation here: the base's handle goes too, the next patch is set up in the foreground
        bluetooth.liftRelease()
        bluetooth.disconnect(force: true)
    }
}

// MARK: - Delivered-total odometer

extension MedtrumPumpManager: PumpDeliveryOdometer {
    public var deliveredUnits: (units: Double, at: Date)? {
        state.deliveredUnits
    }

    public var deliveryPulseUnits: Double { MedtrumPumpState.deliveryPulseUnits }

    /// A failed patch delivers nothing more, and refuses commands
    public var deliveredUnitsAreFinal: Bool {
        state.pumpState.isTerminated
    }

    /// From the patch's own status, so it includes a bolus another controller started
    public var bolusUnderWayEndsAt: Date? {
        guard let endsAt = state.reportedBolusEndsAt, endsAt > .now else {
            return nil
        }

        return endsAt
    }

    /// A bolus is running that this controller has no dose for: read the patch's newest history record, and if it is
    /// that bolus, time its end from the amount it records. Once per record; until then the end rolls 30 s ahead.
    func lookUpBolusRecord() {
        guard let sequence = state.latestRecordSequence, state.bolusRecordLookedUp != sequence else {
            return
        }

        state.bolusRecordLookedUp = sequence
        let patchId = state.patchId.toUInt64()

        // Off the queue the status arrived on: the response is delivered there
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.bluetooth.write(GetRecordPacket(recordIndex: sequence, patchId: patchId))
            guard case let .success(data) = result, let response = data as? GetRecordPacketResponse else {
                if case let .failure(error) = result {
                    handoffLog.warning("Bolus record #\(sequence) could not be read: \(error.errorDescription)")
                }
                return
            }

            let now = Date.now
            guard let record = response.bolus?.inDeviceTime(of: self.state),
                  record.canBeRunning(at: now, slack: self.state.patchClockSlack)
            else {
                // Shows whether the patch writes the record at the start of a bolus, or only at its end
                self.logDeviceCommunication(
                    "bolus record #\(sequence): type \(response.recordType), valid \(response.isValid), " +
                        "\(response.bolus.map { "\($0.amount) U from \($0.startedAt), \($0.delivered) U delivered" } ?? "no bolus")" +
                        " - not the bolus running, its end stays rolling",
                    type: .receive
                )
                return
            }

            self.logDeviceCommunication(
                "bolus record #\(sequence): \(record.amount) U from \(record.startedAt), \(record.delivered) U delivered - " +
                    "timing the bolus running from it",
                type: .receive
            )
            guard self.state.bolusDose == nil, self.state.reportedBolusEndsAt != nil else {
                return
            }

            self.state.bolusRecord = record
            self.state.reportedBolusEndsAt = max(now, record.endsAt(delivered: record.delivered, at: now))
        }
    }

    /// A real status read, bypassing the freshness shortcut in ensureCurrentPumpData
    public func refreshDeliveredUnits() async -> Bool {
        await withCheckedContinuation { done in
            syncPumpData { syncedAt in
                done.resume(returning: syncedAt != nil)
            }
        }
    }
}

// MARK: - Connect clock

/// CoreBluetooth's connect and disconnect edges, stamped as they happen, so a take's log can tell "connected late" from
/// "never connected". Observation only. One per `BluetoothManager`, so an adopt, release and re-adopt never reads
/// another manager's attempt.
final class ConnectClock {
    private let lock = NSLock()
    private var lastConnectAt: Date?
    private var lastDisconnectAt: Date?
    private var connectCount = 0
    private var trail: [String] = []
    private var startedAt: Date?
    private var adoptedHandle: String?

    /// When the current take began: at adopt, or at a take after a release
    var attemptStartedAt: Date? { lock.withLock { startedAt } }

    func beginAttempt(adoptedHandle: String?) {
        lock.withLock {
            lastConnectAt = nil
            lastDisconnectAt = nil
            connectCount = 0
            trail = []
            startedAt = .now
            self.adoptedHandle = adoptedHandle
        }
    }

    /// The handle this attempt's adopt attached from `localState`, if it never connected. Once per attempt; the caller
    /// drops it.
    func adoptedHandleThatNeverConnected() -> String? {
        lock.withLock {
            defer { adoptedHandle = nil }
            return connectCount == 0 ? adoptedHandle : nil
        }
    }

    func noteConnect() {
        note("+") {
            lastConnectAt = .now
            connectCount += 1
        }
    }

    func noteDisconnect(error: Error?) {
        note("-\(Self.describe(error))") { lastDisconnectAt = .now }
    }

    func noteFailToConnect(error: Error?) {
        note("x\(Self.describe(error))") {}
    }

    private func note(_ edge: String, _ update: () -> Void) {
        lock.withLock {
            update()
            trail.append(edge)
            if trail.count > 12 {
                trail.removeFirst()
            }
        }
    }

    /// CoreBluetooth's reason a link ended; nil means this process cancelled it
    private static func describe(_ error: Error?) -> String {
        guard let error = error as NSError? else {
            return "local"
        }

        return "\(error.domain)#\(error.code)"
    }

    /// One field for a log line, relative to the attempt's start
    func summary(since start: Date?) -> String {
        lock.withLock {
            guard let start else {
                return "cb: (no anchor)"
            }

            func rel(_ date: Date?) -> String {
                date.map { String(format: "+%.1fs", $0.timeIntervalSince(start)) } ?? "never"
            }
            let edges = trail.isEmpty ? "" : " · trail[\(trail.joined(separator: " "))]"
            return "cb: didConnect \(rel(lastConnectAt)) (n=\(connectCount)) · didDisconnect \(rel(lastDisconnectAt))\(edges)"
        }
    }
}
