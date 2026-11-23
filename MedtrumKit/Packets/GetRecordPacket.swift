/// A normal bolus as the patch's history records it
struct BolusRecord: Equatable {
    let startedAt: Date
    let amount: Double
    let delivered: Double
}

struct GetRecordPacketResponse {
    let isValid: Bool
    let recordType: UInt8
    let sequence: UInt64
    /// Only for a normal bolus record
    let bolus: BolusRecord?
}

/// One record of the patch's history, by its sequence number. Layout from AndroidAPS' Medtrum driver
/// (GetRecordPacket.kt), as @EJM0 ports it in EJM0/MedtrumKit 326eaa4 (loopandlearn/MedtrumKit#6).
class GetRecordPacket: MedtrumBasePacket, MedtrumBasePacketProtocol {
    typealias T = GetRecordPacketResponse

    static let validHeader: UInt8 = 170
    static let bolusRecordTypes: Set<UInt8> = [1, 65]
    static let normalBolus: UInt8 = 1

    let commandType: UInt8 = CommandType.GET_RECORD
    let mimimumDataSize: Int = 18

    let recordIndex: UInt64
    let patchId: UInt64

    init(recordIndex: UInt64, patchId: UInt64) {
        self.recordIndex = recordIndex
        self.patchId = patchId
    }

    /**
     * byte 0-1: record index
     * byte 2-3: patch id
     */
    func getRequestBytes() -> Data {
        recordIndex.toData(length: 2) + patchId.toData(length: 2)
    }

    /**
     * byte 6: header (170 when valid)
     * byte 8: record type (1 or 65: bolus)
     * byte 16-17: record sequence
     * Bolus record, from byte 18:
     * byte 18: bolus type (low nibble, 1 = normal) and wizard (high nibble)
     * byte 22-25: start time, Medtrum seconds
     * byte 26-27: normal amount, divided by 0.05
     * byte 28-29: normal delivered, divided by 0.05
     */
    func parseResponse() -> GetRecordPacketResponse {
        let isValid = totalData[6] == Self.validHeader
        let recordType = totalData[8]
        var bolus: BolusRecord?
        if isValid, Self.bolusRecordTypes.contains(recordType), totalData.count >= 30,
           totalData[18] & 0x0F == Self.normalBolus
        {
            bolus = BolusRecord(
                startedAt: Date.fromMedtrumSeconds(totalData.subdata(in: 22 ..< 26).toUInt64()),
                amount: totalData.subdata(in: 26 ..< 28).toDouble() * 0.05,
                delivered: totalData.subdata(in: 28 ..< 30).toDouble() * 0.05
            )
        }

        return GetRecordPacketResponse(
            isValid: isValid,
            recordType: recordType,
            sequence: totalData.subdata(in: 16 ..< 18).toUInt64(),
            bolus: bolus
        )
    }
}
