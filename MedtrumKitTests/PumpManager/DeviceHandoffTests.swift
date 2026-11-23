import LoopKit
@testable import MedtrumKit
import XCTest

final class DeviceHandoffTests: XCTestCase {
    private let pumpSN = Data([0x28, 0xD8, 0x12, 0x4A])
    private let handle = UUID()

    private func activeState() -> MedtrumPumpState {
        let state = MedtrumPumpState(nil)
        state.isOnboarded = true
        state.pumpSN = pumpSN
        state.sessionToken = Data([1, 2, 3, 4])
        state.patchId = UInt64(256).toData(length: 4)
        state.pumpState = .active
        state.patchSessionEnded = false
        state.patchActivatedAt = Date.now.addingTimeInterval(-.hours(10))
        state.peripheralIdentifier = handle
        state.initialReservoir = 200
        state.reservoir = 187.35
        state.reservoirReadAt = Date.now
        return state
    }

    // MARK: Export and adopt

    func testExportLeavesOutTheHandleAndThisControllersFlags() throws {
        let manager = MedtrumPumpManager(state: activeState(), withBluetooth: false)
        manager.releaseControl()
        let export = manager.exportConfiguration()
        let shared = MedtrumPumpState(rawValue: export.state)

        XCTAssertEqual(export.managerIdentifier, "Medtrum")
        XCTAssertNil(shared.peripheralIdentifier)
        XCTAssertFalse(shared.controlReleased)
        XCTAssertEqual(shared.pumpSN, pumpSN)
        XCTAssertEqual(try XCTUnwrap(export.deliveredUnits), 12.65, accuracy: 0.001)
    }

    func testAdoptUsesThisDevicesHandleOnlyForTheSamePatch() throws {
        let export = MedtrumPumpManager(state: activeState(), withBluetooth: false).exportConfiguration()
        let own = UUID()

        let same = try XCTUnwrap(MedtrumPumpManager.adoptedState(
            from: export,
            localState: ["pumpSN": pumpSN, "peripheralIdentifier": own.uuidString]
        ))
        XCTAssertEqual(same.peripheralIdentifier, own)
        XCTAssertTrue(same.sharedWithAnotherController)
        XCTAssertNil(same.bolusDose)
        XCTAssertFalse(MedtrumPumpManager.takeControlNeedsSearch(
            adopting: export,
            localState: ["pumpSN": pumpSN, "peripheralIdentifier": own.uuidString]
        ))

        let other = try XCTUnwrap(MedtrumPumpManager.adoptedState(
            from: export,
            localState: ["pumpSN": Data([9, 9, 9, 9]), "peripheralIdentifier": own.uuidString]
        ))
        XCTAssertNil(other.peripheralIdentifier)
        XCTAssertTrue(MedtrumPumpManager.takeControlNeedsSearch(adopting: export, localState: nil))
    }

    func testAdoptRefusesAnEndedPatchOrAnotherPlugin() {
        let ended = activeState()
        ended.patchSessionEnded = true
        let endedExport = SharedDeviceConfiguration(managerIdentifier: "Medtrum", asOf: Date.now, state: ended.rawValue)
        XCTAssertNil(MedtrumPumpManager.adoptedState(from: endedExport, localState: nil))

        let other = SharedDeviceConfiguration(managerIdentifier: "Omni", asOf: Date.now, state: activeState().rawValue)
        XCTAssertNil(MedtrumPumpManager.adoptedState(from: other, localState: nil))
    }

    // MARK: Release and take

    func testReleaseIsPersistedAndRefusedDuringABolus() {
        let bolusing = activeState()
        bolusing.bolusDose = UnfinalizedDose(
            decisionId: nil, units: 2, duration: 60, activationType: .manualNoRecommendation, insulinType: nil
        )
        let busy = MedtrumPumpManager(state: bolusing, withBluetooth: false)
        busy.releaseControl()
        XCTAssertFalse(busy.isControlReleased)

        let manager = MedtrumPumpManager(state: activeState(), withBluetooth: false)
        manager.releaseControl()
        XCTAssertTrue(manager.isControlReleased)
        XCTAssertFalse(manager.isControlReady)
        XCTAssertTrue(MedtrumPumpState(rawValue: manager.rawState).controlReleased)
        XCTAssertEqual(manager.state.peripheralIdentifier, handle)
    }

    func testTakeAfterAReleaseStartsFresh() {
        let manager = MedtrumPumpManager(state: activeState(), withBluetooth: false)
        manager.releaseControl()
        manager.takeControl()

        XCTAssertFalse(manager.isControlReleased)
        XCTAssertEqual(manager.state.basalDose.type, .basal)
        XCTAssertNil(manager.state.bolusDose)
    }

    // MARK: Another controller

    func testARefusalSavedByTheEarlierBuildIsIgnored() {
        var raw = activeState().rawValue
        raw["refusesSessions"] = true
        raw["foreignSessionDetectedAt"] = Date.now
        let manager = MedtrumPumpManager(state: MedtrumPumpState(rawValue: raw), withBluetooth: false)

        XCTAssertFalse(manager.refusesSessions)
        XCTAssertNil(manager.foreignSessionDetectedAt)
        XCTAssertNil(manager.rawState["refusesSessions"])
    }

    private func sharedState(lastContact: Date) -> MedtrumPumpState {
        let state = activeState()
        state.sharedWithAnotherController = true
        state.lastContactAt = lastContact
        state.pumpTime = Date.now
        state.pumpTimeSyncedAt = Date.now
        return state
    }

    private func temp(startedAt: Date) -> BasalData {
        BasalData(type: .ABSOLUTE_TEMP, sequence: 5, patchId: 256, startTime: startedAt, rate: 0.8, delivery: 0)
    }

    private func bolusRecord(startedAt: Date) -> GetRecordPacketResponse {
        GetRecordPacketResponse(
            isValid: true, recordType: 1, sequence: 0,
            bolus: BolusRecord(startedAt: startedAt, amount: 2, delivered: 2)
        )
    }

    private let noRecords: (UInt64) -> GetRecordPacketResponse? = { _ in nil }

    func testATempBasalStartedAfterOurLastContactIsAnotherControllers() {
        let contact = Date.now.addingTimeInterval(-.minutes(10))
        let state = sharedState(lastContact: contact)

        XCTAssertNotNil(state.foreignDeliveryEvidence(
            since: contact, previousSequence: nil, basal: temp(startedAt: contact.addingTimeInterval(60)), readRecord: noRecords
        ))
    }

    func testOurOwnTempBasalReportedLateIsOurs() {
        // the 21 November false alarm: our temp began before the answer that moved our last contact
        let contact = Date.now.addingTimeInterval(-.minutes(1))
        let state = sharedState(lastContact: contact)

        XCTAssertNil(state.foreignDeliveryEvidence(
            since: contact, previousSequence: nil, basal: temp(startedAt: contact.addingTimeInterval(-1)), readRecord: noRecords
        ))
    }

    func testThePatchClockOffsetIsAllowedFor() {
        let contact = Date.now.addingTimeInterval(-.minutes(10))
        let state = sharedState(lastContact: contact)
        // the patch's clock runs 2 minutes ahead
        state.pumpTime = Date.now.addingTimeInterval(.minutes(2))

        XCTAssertNil(state.foreignDeliveryEvidence(
            since: contact, previousSequence: nil, basal: temp(startedAt: contact.addingTimeInterval(.minutes(2) - 1)),
            readRecord: noRecords
        ))
    }

    func testAnUnansweredCommandOfOursIsNotAnotherControllers() {
        let contact = Date.now.addingTimeInterval(-.minutes(10))
        let state = sharedState(lastContact: contact)
        let sentAt = contact.addingTimeInterval(20)
        state.unansweredDeliveryCommandAt = sentAt

        XCTAssertNil(state.foreignDeliveryEvidence(
            since: contact, previousSequence: nil, basal: temp(startedAt: sentAt.addingTimeInterval(2)), readRecord: noRecords
        ))
        XCTAssertNil(state.unansweredDeliveryCommandAt, "used up")
        // a later start is not that command
        state.unansweredDeliveryCommandAt = sentAt
        XCTAssertNotNil(state.foreignDeliveryEvidence(
            since: contact, previousSequence: nil, basal: temp(startedAt: sentAt.addingTimeInterval(.minutes(5))),
            readRecord: noRecords
        ))
    }

    func testTheConnectionAfterATakeOrAnAdoptIsNotChecked() {
        let contact = Date.now.addingTimeInterval(-.minutes(10))
        let state = sharedState(lastContact: contact)
        state.expectsForeignDelivery = true
        let foreign = temp(startedAt: contact.addingTimeInterval(60))

        XCTAssertNil(state.foreignDeliveryEvidence(since: contact, previousSequence: nil, basal: foreign, readRecord: noRecords))
        XCTAssertNotNil(state.foreignDeliveryEvidence(since: contact, previousSequence: nil, basal: foreign, readRecord: noRecords))
    }

    func testAPatchNeverSharedIsNotChecked() {
        let contact = Date.now.addingTimeInterval(-.minutes(10))
        let state = sharedState(lastContact: contact)
        state.sharedWithAnotherController = false

        XCTAssertNil(state.foreignDeliveryEvidence(
            since: contact, previousSequence: nil, basal: temp(startedAt: contact.addingTimeInterval(60)), readRecord: noRecords
        ))
    }

    func testABolusInTheNewHistoryRecordsIsFound() {
        let contact = Date.now.addingTimeInterval(-.minutes(10))
        let state = sharedState(lastContact: contact)
        state.latestRecordSequence = 20
        var read: [UInt64] = []

        let evidence = state.foreignDeliveryEvidence(since: contact, previousSequence: 17, basal: nil) { index in
            read.append(index)
            return index == 18 ? self.bolusRecord(startedAt: contact.addingTimeInterval(120)) : nil
        }
        XCTAssertNotNil(evidence)
        XCTAssertEqual(read, [20, 19, 18], "only the records new since our last connection, newest first")

        // ours, from before our last contact
        state.latestRecordSequence = 21
        XCTAssertNil(state.foreignDeliveryEvidence(since: contact, previousSequence: 20, basal: nil) { _ in
            self.bolusRecord(startedAt: contact.addingTimeInterval(-30))
        })
    }

    func testFoundDeliveryStopsThisControllerUntilALiftingTake() {
        let manager = MedtrumPumpManager(state: sharedState(lastContact: Date.now), withBluetooth: false)

        XCTAssertTrue(manager.foreignDeliveryFound("test"))
        XCTAssertTrue(manager.refusesSessions)
        XCTAssertNotNil(manager.foreignSessionDetectedAt)
        XCTAssertFalse(manager.isControlReady)
        XCTAssertTrue(MedtrumPumpState(rawValue: manager.rawState).refusesAfterForeignDelivery)

        manager.takeControl()
        XCTAssertTrue(manager.refusesSessions, "a plain take stays refused")

        manager.takeControlLiftingRefusal()
        XCTAssertFalse(manager.refusesSessions)
        XCTAssertNil(manager.foreignSessionDetectedAt)
        XCTAssertTrue(manager.state.expectsForeignDelivery)
    }

    func testWhileSupersedingFoundDeliveryIsOnlyReported() {
        let manager = MedtrumPumpManager(state: sharedState(lastContact: Date.now), withBluetooth: false)
        manager.takeControl(supersedingAnotherControllerUntil: Date.now.addingTimeInterval(.hours(1)))
        XCTAssertTrue(manager.state.expectsForeignDelivery)

        XCTAssertFalse(manager.foreignDeliveryFound("test"))
        XCTAssertFalse(manager.refusesSessions)
        XCTAssertNotNil(manager.foreignSessionDetectedAt)

        manager.stopSupersedingAnotherController()
        XCTAssertTrue(manager.foreignDeliveryFound("test"))
        XCTAssertTrue(manager.refusesSessions)
    }

    func testAnAdoptExpectsTheExportersDeliveryAndTheExportCarriesNoTrust() throws {
        let exporter = MedtrumPumpManager(state: sharedState(lastContact: Date.now), withBluetooth: false)
        exporter.state.foreignDeliveryDetectedAt = Date.now
        exporter.state.unansweredDeliveryCommandAt = Date.now
        let export = exporter.exportConfiguration()
        let shared = MedtrumPumpState(rawValue: export.state)
        XCTAssertNil(shared.lastContactAt)
        XCTAssertNil(shared.foreignDeliveryDetectedAt)
        XCTAssertNil(shared.unansweredDeliveryCommandAt)

        let adopted = try XCTUnwrap(MedtrumPumpManager.adoptedState(from: export, localState: nil))
        XCTAssertTrue(adopted.expectsForeignDelivery)
    }

    func testTheMarkEndsAtTheNextScheduleChange() {
        let state = activeState()
        state.basalSchedule = BasalSchedule(entries: [
            RepeatingScheduleValue(startTime: 0, value: 1.0),
            RepeatingScheduleValue(startTime: .hours(3), value: 0.8)
        ])
        let manager = MedtrumPumpManager(state: state, withBluetooth: false)
        let midnight = Calendar.current.startOfDay(for: Date.now)

        XCTAssertEqual(manager.markDurationNow(at: midnight.addingTimeInterval(.hours(1))), .minutes(30))
        XCTAssertEqual(manager.markDurationNow(at: midnight.addingTimeInterval(.hours(3) - .minutes(10) - 20)), .minutes(10))
        XCTAssertNil(manager.markDurationNow(at: midnight.addingTimeInterval(.hours(3) - .minutes(3))))
        XCTAssertEqual(manager.markDurationNow(at: midnight.addingTimeInterval(.hours(23) + .minutes(50))), .minutes(10))
    }

    func testAReleaseThatCameWithTheOldRefusalIsUndone() {
        var raw = activeState().rawValue
        raw["controlReleased"] = true
        raw["refusesSessions"] = true
        XCTAssertFalse(MedtrumPumpState(rawValue: raw).controlReleased)

        raw["refusesSessions"] = nil
        XCTAssertTrue(MedtrumPumpState(rawValue: raw).controlReleased, "a real hand-off stays released")
    }

    // MARK: Pump data

    func testFreshDataReportsTheLastSyncNotNil() {
        let state = activeState()
        state.lastSync = Date.now.addingTimeInterval(-30)
        let manager = MedtrumPumpManager(state: state, withBluetooth: false)
        let reported = expectation(description: "completion")
        manager.ensureCurrentPumpData { lastSync in
            XCTAssertEqual(lastSync, state.lastSync)
            reported.fulfill()
        }
        wait(for: [reported], timeout: 1)
    }

    // MARK: Odometer

    func testDeliveredUnitsAreTheReservoirUsedInWholePulses() throws {
        let manager = MedtrumPumpManager(state: activeState(), withBluetooth: false)
        let delivered = try XCTUnwrap(manager.deliveredUnits)
        XCTAssertEqual(delivered.units, 12.65, accuracy: 0.0001)
        XCTAssertEqual(manager.deliveryPulseUnits, 0.05)

        let unread = activeState()
        unread.reservoirReadAt = nil
        XCTAssertNil(MedtrumPumpManager(state: unread, withBluetooth: false).deliveredUnits)
    }

    func testAFaultedPatchsTotalIsFinal() {
        let state = activeState()
        state.pumpState = .occlusion
        XCTAssertTrue(MedtrumPumpManager(state: state, withBluetooth: false).deliveredUnitsAreFinal)
        XCTAssertFalse(MedtrumPumpManager(state: activeState(), withBluetooth: false).deliveredUnitsAreFinal)
    }
}
