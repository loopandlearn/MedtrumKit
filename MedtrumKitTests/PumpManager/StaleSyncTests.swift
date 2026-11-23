@testable import MedtrumKit
import XCTest

final class StaleSyncTests: XCTestCase {
    private func makeState(latest: UInt64?) -> MedtrumPumpState {
        let state = MedtrumPumpState(nil)
        state.pumpState = .active
        state.patchSessionEnded = false
        state.patchId = UInt64(202).toData(length: 4)
        state.latestRecordSequence = latest
        return state
    }

    private func makeResponse(sequence: Double, patchId: Double = 202) -> SynchronizePacketResponse {
        var response = SynchronizePacketResponse(state: .active, activeAlarms: [])
        response.storage = StorageData(sequence: sequence, patchId: patchId)
        return response
    }

    // 2026-11-23 11:38: a sync written before the hand-off's mark, applied after it
    func testSyncBeforeAKnownRecordIsStale() {
        XCTAssertTrue(StateSyncer.answeredBeforeKnownRecord(syncResponse: makeResponse(sequence: 631), state: makeState(latest: 632)))
    }

    func testSyncAtOrAfterTheLatestRecordIsCurrent() {
        let state = makeState(latest: 632)
        XCTAssertFalse(StateSyncer.answeredBeforeKnownRecord(syncResponse: makeResponse(sequence: 632), state: state))
        XCTAssertFalse(StateSyncer.answeredBeforeKnownRecord(syncResponse: makeResponse(sequence: 640), state: state))
    }

    func testAnotherPatchOrNoSequenceIsNeverStale() {
        XCTAssertFalse(StateSyncer.answeredBeforeKnownRecord(
            syncResponse: makeResponse(sequence: 3, patchId: 203),
            state: makeState(latest: 632)
        ))
        XCTAssertFalse(StateSyncer.answeredBeforeKnownRecord(syncResponse: makeResponse(sequence: 3), state: makeState(latest: nil)))
        var noStorage = makeResponse(sequence: 3)
        noStorage.storage = nil
        XCTAssertFalse(StateSyncer.answeredBeforeKnownRecord(syncResponse: noStorage, state: makeState(latest: 632)))
    }
}
