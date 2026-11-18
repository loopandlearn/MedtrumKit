import LoopKit

public enum BasalState: Int {
    case active = 0
    case suspended = 1
    case tempBasal = 2
}

public enum BolusState: Int {
    case noBolus = 0
    case inProgress = 1
    case canceling = 2
}

public enum ExpiryMode: Int {
    case `default` = 1
    case extended = 2

    var lifespan: TimeInterval {
        switch self {
        case .default:
            return .hours(72)
        case .extended:
            return .hours(112)
        }
    }

    var gracePeriod: TimeInterval {
        .hours(8)
    }

    var timer: UInt8 {
        self == .default ? 1 : 0
    }
}

public struct PreviousPatch: Codable {
    public var patchId: Data
    public var lastStateRaw: UInt8
    public var lastSyncAt: Date
    public var battery: Double
    public var activatedAt: Date
    public var deactivatedAt: Date
    public var initialReservoirLevel: Double?
    public var reservoirLevel: Double?
}

public class MedtrumPumpState: RawRepresentable {
    public typealias RawValue = PumpManager.RawStateValue

    public required init(rawValue: RawValue) {
        isOnboarded = rawValue["isOnboarded"] as? Bool ?? false
        lastSync = rawValue["lastSync"] as? Date ?? Date.distantPast
        pumpSN = rawValue["pumpSN"] as? Data ?? Data()
        useSilentTones = rawValue["useSilentTones"] as? Bool ?? false
        controlReleased = rawValue["controlReleased"] as? Bool ?? false
        configuredByAnotherController = rawValue["configuredByAnotherController"] as? Bool ?? false
        inFlightDosesInheritedAway = rawValue["inFlightDosesInheritedAway"] as? Bool ?? false
        untrackedDeliveryIsForeign = rawValue["untrackedDeliveryIsForeign"] as? Bool ?? false
        sharedPatchId = rawValue["sharedPatchId"] as? Data
        expectsForeignRecords = rawValue["expectsForeignRecords"] as? Bool ?? false
        otherControllerDetectedAt = rawValue["otherControllerDetectedAt"] as? Date
        lastContactAt = rawValue["lastContactAt"] as? Date
        latestRecordSequence = rawValue["latestRecordSequence"] as? UInt64
        lowReservoirWarning = rawValue["lowReservoirWarning"] as? Double
        sessionToken = rawValue["sessionToken"] as? Data ?? Data()
        backupSessionToken = rawValue["backupSessionToken"] as? Data ?? Data()
        patchId = rawValue["patchId"] as? Data ?? Data()
        peripheralIdentifier = (rawValue["peripheralIdentifier"] as? String).flatMap { UUID(uuidString: $0) }
        patchActivatedAt = rawValue["patchActivatedAt"] as? Date ?? nil
        deviceType = rawValue["deviceType"] as? UInt8 ?? 0
        swVersion = rawValue["swVersion"] as? String ?? "0.0.0"
        pumpTime = rawValue["pumpTime"] as? Date ?? Date()
        pumpTimeSyncedAt = rawValue["pumpTimeSyncedAt"] as? Date ?? Date()
        maxHourlyInsulin = rawValue["maxHourlyInsulin"] as? Double ?? 20
        maxDailyInsulin = rawValue["maxDailyInsulin"] as? Double ?? 100
        initialReservoir = rawValue["initialReservoir"] as? Double
        reservoir = rawValue["reservoir"] as? Double ?? 0
        reservoirReadAt = rawValue["reservoirReadAt"] as? Date
        battery = rawValue["battery"] as? Double ?? 0
        notificationAfterActivation = rawValue["notificationAfterActivation"] as? TimeInterval ?? .hours(72)

        if let expiryModeRaw = rawValue["expiryMode"] as? ExpiryMode.RawValue {
            expiryMode = ExpiryMode(rawValue: expiryModeRaw) ?? .default
        } else if let expirationTimer = rawValue["expirationTimer"] as? UInt8 {
            expiryMode = expirationTimer == 1 ? .default : .extended
        } else {
            expiryMode = .default
        }

        if let previousPatchRaw = rawValue["previousPatch"] as? Data {
            do {
                previousPatch = try JSONDecoder().decode(PreviousPatch.self, from: previousPatchRaw)
            } catch {}
        }

        if let rawInsulinType = rawValue["insulinType"] as? InsulinType.RawValue {
            insulinType = InsulinType(rawValue: rawInsulinType)
        }

        if let pumpStateRaw = rawValue["pumpState"] as? PatchState.RawValue {
            pumpState = PatchState(rawValue: pumpStateRaw) ?? .none
        } else {
            pumpState = .none
        }

        // Not kept by earlier versions: then only a patch being set up has no session
        patchSessionEnded = rawValue["patchSessionEnded"] as? Bool ?? pumpState.isSetup

        if let rawBasalSchedule = rawValue["basalSchedule"] as? BasalSchedule.RawValue {
            basalSchedule = BasalSchedule(rawValue: rawBasalSchedule) ??
                BasalSchedule(entries: [LoopKit.RepeatingScheduleValue(startTime: 0, value: 0)])
        } else {
            basalSchedule = BasalSchedule(entries: [LoopKit.RepeatingScheduleValue(startTime: 0, value: 0)])
        }

        if let basalStateRaw = rawValue["basalState"] as? BasalState.RawValue {
            basalState = BasalState(rawValue: basalStateRaw) ?? .active
        } else {
            basalState = .active
        }

        if let alarmSettingRaw = rawValue["alarmSetting"] as? AlarmSettings.RawValue {
            alarmSetting = AlarmSettings(rawValue: alarmSettingRaw) ?? .BeepOnly
        } else {
            alarmSetting = .BeepOnly
        }

        if let rawDoseEntry = rawValue["bolusDose"] as? UnfinalizedDose.RawValue {
            bolusDose = UnfinalizedDose(rawValue: rawDoseEntry)
        } else {
            bolusDose = nil
        }

        if let rawDoseEntry = rawValue["basalDose"] as? UnfinalizedDose.RawValue {
            basalDose = UnfinalizedDose(rawValue: rawDoseEntry) ?? UnfinalizedDose
                .defaultBasalDose(basalSchedule: basalSchedule, insulineType: insulinType)
        } else {
            basalDose = UnfinalizedDose.defaultBasalDose(basalSchedule: basalSchedule, insulineType: insulinType)
        }
    }

    public init(_ basal: BasalRateSchedule?) {
        isOnboarded = false
        lastSync = Date.distantPast
        pumpSN = Data()
        useSilentTones = false
        lowReservoirWarning = nil
        bolusDose = nil
        sessionToken = Data()
        backupSessionToken = Data()
        patchId = Data()
        peripheralIdentifier = nil
        patchActivatedAt = nil
        deviceType = 0
        swVersion = "0.0.0"
        pumpTime = Date()
        pumpTimeSyncedAt = Date()
        pumpState = .none
        patchSessionEnded = true

        maxHourlyInsulin = 20
        maxDailyInsulin = 100
        reservoir = 0
        battery = 0
        basalState = .active
        alarmSetting = .BeepOnly
        expiryMode = .default
        notificationAfterActivation = .hours(72)
        previousPatch = nil

        if let basal = basal {
            basalSchedule = BasalSchedule(entries: basal.items)
        } else {
            basalSchedule = BasalSchedule(entries: [LoopKit.RepeatingScheduleValue(startTime: 0, value: 0)])
        }

        basalDose = UnfinalizedDose.defaultBasalDose(basalSchedule: basalSchedule, insulineType: insulinType)
    }

    public var rawValue: RawValue {
        var value: [String: Any] = [:]

        value["isOnboarded"] = isOnboarded
        value["lastSync"] = lastSync
        value["insulinType"] = insulinType?.rawValue
        value["lowReservoirWarning"] = lowReservoirWarning
        value["pumpSN"] = pumpSN
        value["sessionToken"] = sessionToken
        value["backupSessionToken"] = backupSessionToken
        value["patchId"] = patchId
        value["peripheralIdentifier"] = peripheralIdentifier?.uuidString
        value["patchActivatedAt"] = patchActivatedAt
        value["patchGracePeriodFrom"] = patchGracePeriodFrom
        value["patchExpiresAt"] = patchExpiresAt
        value["deviceType"] = deviceType
        value["swVersion"] = swVersion
        value["pumpTime"] = pumpTime
        value["pumpTimeSyncedAt"] = pumpTimeSyncedAt
        value["pumpState"] = pumpState.rawValue
        value["patchSessionEnded"] = patchSessionEnded
        value["maxHourlyInsulin"] = maxHourlyInsulin
        value["maxDailyInsulin"] = maxDailyInsulin
        value["basalSchedule"] = basalSchedule.rawValue
        value["initialReservoir"] = initialReservoir
        value["bolusDose"] = bolusDose?.rawValue
        value["basalDose"] = basalDose.rawValue
        value["reservoir"] = reservoir
        value["reservoirReadAt"] = reservoirReadAt
        value["battery"] = battery
        value["basalState"] = basalState.rawValue
        value["alarmSetting"] = alarmSetting.rawValue
        value["expiryMode"] = expiryMode.rawValue
        value["notificationAfterActivation"] = notificationAfterActivation
        value["useSilentTones"] = useSilentTones
        value["controlReleased"] = controlReleased
        value["configuredByAnotherController"] = configuredByAnotherController
        value["inFlightDosesInheritedAway"] = inFlightDosesInheritedAway
        value["untrackedDeliveryIsForeign"] = untrackedDeliveryIsForeign
        value["sharedPatchId"] = sharedPatchId
        value["expectsForeignRecords"] = expectsForeignRecords
        value["otherControllerDetectedAt"] = otherControllerDetectedAt
        value["lastContactAt"] = lastContactAt
        value["latestRecordSequence"] = latestRecordSequence

        if let previousPatch = previousPatch {
            do {
                value["previousPatch"] = try JSONEncoder().encode(previousPatch)
            } catch {}
        }

        return value
    }

    public var isOnboarded: Bool
    public var insulinType: InsulinType?
    public var lastSync: Date
    public var pumpSN: Data {
        didSet {
            guard pumpSN != oldValue else {
                return
            }

            // prevent ensureConnected from reconnecting straight back to the previous base
            peripheralIdentifier = nil
        }
    }

    public var lowReservoirWarning: Double?
    public var useSilentTones: Bool

    // Handing the patch to another controller (MedtrumPumpManager+DeviceHandoff)

    /// Control is released to another controller (ExclusiveDeviceControl). Persisted, so a relaunch does not take it
    /// back.
    public var controlReleased = false

    /// Built from another controller's export (DeviceConfigurationSharing): never held connected between commands, so
    /// that controller can take the patch back.
    public var configuredByAnotherController = false

    /// Control was released with a bolus or temp basal in flight. The other controller owns those records from then
    /// on, so taking control drops this controller's copies.
    public var inFlightDosesInheritedAway = false

    /// A bolus, temp basal or suspend the patch reports that this controller has no record of may be another
    /// controller's, so none is booked. Set on adopt and take-back; cleared once the patch shows neither, or this
    /// controller commands delivery itself.
    public var untrackedDeliveryIsForeign = false

    /// The patch this state was exported for or adopted from: only a patch handed over can be run by another controller
    /// (`isShared`)
    public var sharedPatchId: Data?

    /// The next connection's first status follows a take or an adopt: the other controller's delivery before it is
    /// expected, not evidence (`otherControllerEvidence`)
    public var expectsForeignRecords = false

    /// Another controller was found to have run the patch since this one last did: nothing is sent until the host takes
    /// control again. Unlike a release, the doses in flight stay this controller's.
    public var otherControllerDetectedAt: Date?

    /// When the patch last answered or notified this controller. Each command is answered, so the patch's records of
    /// this controller's own delivery start before it.
    public var lastContactAt: Date?

    /// The patch's newest history record, from its status
    var latestRecordSequence: UInt64?

    // Patch specific data
    public var sessionToken: Data
    public var backupSessionToken: Data
    public var patchId: Data

    /// The CoreBluetooth identifier of the pump base we are paired with - the base carries the
    /// radio, so this survives a patch change. iOS keeps it stable, which lets us get a
    /// `CBPeripheral` back with `retrievePeripherals(withIdentifiers:)` instead of scanning. That
    /// matters because scanning finds nothing while the app is in the background, whereas
    /// reconnecting to a known peripheral is honoured there.
    public var peripheralIdentifier: UUID?

    public var patchActivatedAt: Date?
    public var patchGracePeriodFrom: Date? {
        guard let activatedAt = patchActivatedAt else {
            return nil
        }

        return activatedAt.addingTimeInterval(expiryMode.lifespan)
    }

    public var patchExpiresAt: Date? {
        guard let activatedAt = patchActivatedAt else {
            return nil
        }

        return activatedAt.addingTimeInterval(expiryMode.lifespan + expiryMode.gracePeriod)
    }

    public var previousPatch: PreviousPatch?

    public var deviceType: UInt8
    public var swVersion: String

    public var pumpTime: Date
    public var pumpTimeSyncedAt: Date

    public var pumpState: PatchState
    /// No patch session is running: the last one ended, or none started yet
    public var patchSessionEnded: Bool
    public var initialReservoir: Double?
    public var reservoir: Double
    /// When the patch last reported `reservoir`: the delivered total's time (PumpDeliveryOdometer)
    public var reservoirReadAt: Date?
    public var battery: Double

    // Patch settings
    public var maxHourlyInsulin: Double
    public var maxDailyInsulin: Double
    public var alarmSetting: AlarmSettings
    public var expiryMode: ExpiryMode
    public var notificationAfterActivation: TimeInterval

    /// Resetting "cancelingBolusSince" to nil depends on `ensureConnected` calling the callback.
    /// `ensureConnected` orphans its completion in a few places.
    /// So instead of a boolean, we use a date, which "auto-expires" after this timeout.
    /// This timeout is longer than the 30s write timeout plus a reconnect.
    private static let cancelBolusTimeout: TimeInterval = .minutes(2)

    // **** THESE VALUES SHOULD NOT BE PERSISTED ****
    public var primeProgress: UInt8 = 0
    public var isConnected: Bool = false
    // if it was persisted, and we happen to restore a date - there will be nothing left to reset it to `nil`
    public var cancelingBolusSince: Date?
    /// When the bolus the patch reported at its last status ends, whoever started it (PumpDeliveryOdometer)
    public var reportedBolusEndsAt: Date?
    /// The history record of a bolus running that this controller has no dose for, once looked up
    var bolusRecord: BolusRecord?
    /// The history record last looked up for it, so each record is read once
    var bolusRecordLookedUp: UInt64?

    /// The patch shows no bolus running
    func bolusEnded() {
        reportedBolusEndsAt = nil
        bolusRecord = nil
        bolusRecordLookedUp = nil
    }
    // **** END ****

    public var bolusDose: UnfinalizedDose?

    private var isCancelingBolus: Bool {
        guard let since = cancelingBolusSince else {
            return false
        }

        return Date.now.timeIntervalSince(since) < MedtrumPumpState.cancelBolusTimeout
    }

    public var bolusState: BolusState {
        if isCancelingBolus {
            return .canceling
        }

        return bolusDose == nil ? .noBolus : .inProgress
    }

    // basalState is the basalState from the patch itself
    // Preventing acting on an out-dated basalDose
    public var basalState: BasalState
    public var basalDose: UnfinalizedDose
    public var basalSchedule: BasalSchedule

    public var basalDeliveryState: PumpManagerStatus.BasalDeliveryState {
        if pumpState.rawValue >= PatchState.occlusion.rawValue {
            return .pumpInoperable
        }

        switch basalDose.type {
        case .basal,
             .bolus,
             .resume:
            return .active(basalDose.startDate)
        case .suspend:
            return .suspended(basalDose.startDate)
        case .tempBasal:
            return .tempBasal(basalDose.toDoseEntry(isMutable: true))
        }
    }

    var bolusDeliveryState: PumpManagerStatus.BolusState {
        if isCancelingBolus {
            return .canceling
        }

        guard let dose = bolusDose?.toDoseEntry(isMutable: true) else {
            return .noBolus
        }

        return .inProgress(dose)
    }

    public var currentBaseBasalRate: Double {
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let nowTimeInterval = now.timeIntervalSince(startOfDay)

        return basalSchedule.entries.last(where: { $0.startTime <= nowTimeInterval })?.rate ?? 0
    }

    public var model: String {
        let type = Crypto.simpleDecrypt(Data(pumpSN.reversed())).toUInt64()

        if (126_000_000 ..< 126_999_999).contains(type) {
            return "MD0201"
        } else if (127_000_000 ..< 127_999_999).contains(type) {
            return "MD5201"
        } else if (128_000_000 ..< 128_999_999).contains(type) {
            return "MD8201"
        } else if (130_000_000 ..< 130_999_999).contains(type) {
            return "MD0202"
        } else if (131_000_000 ..< 131_999_999).contains(type) {
            return "MD5202"
        } else if (148_000_000 ..< 148_999_999).contains(type) {
            return "MD8301"
        } else {
            return "INVALID"
        }
    }

    public var pumpName: String {
        let model = self.model
        if model == "MD8301" {
            return "Medtrum Nano 300U"
        } else if model == "INVALID" {
            return "Medtrum Nano UNKNOWN"
        } else {
            return "Medtrum Nano 200U"
        }
    }

    /// How far the patch's clock is ahead of this device's, as the last GetTime measured it (`pumpTime` read at
    /// `pumpTimeSyncedAt`). The time warning below shows past 15 s, but nothing sets the patch's clock until the user
    /// does, so patch times are converted with this rather than trusted to that bound.
    var patchClockOffset: TimeInterval {
        pumpTime.timeIntervalSince(pumpTimeSyncedAt)
    }

    /// A patch time in this device's time
    func deviceTime(_ patchTime: Date) -> Date {
        patchTime.addingTimeInterval(-patchClockOffset)
    }

    /// What is left when a converted patch time is compared with this device's: the patch's whole seconds and the
    /// answer's latency, and drift since the measurement. GetTime is read every 30 min while connected; an older
    /// measurement, such as an adopter's copy of the exporter's, gets the wide slack.
    var patchClockSlack: TimeInterval {
        Date.now.timeIntervalSince(pumpTimeSyncedAt) < .hours(1) ? 5 : 60
    }

    func shouldShowTimeWarning() -> Bool {
        // Allow a 15 sec diff in time
        abs(pumpTimeSyncedAt.timeIntervalSince1970 - pumpTime.timeIntervalSince1970) > 15
    }

    public var debugDescription: String {
        [
            "## MedtrumPumpState - \(Date.now)",
            "* isOnboarded: \(isOnboarded)",
            "* lastSync: \(lastSync)",
            "* pumpState: \(pumpState.rawValue)",
            "* pumpSN: \(pumpSN.hexEncodedString())",
            "* pumpName: \(pumpName)",
            "* model: \(model)",
            "* swVersion: \(swVersion)",
            "* maxDailyInsulin: \(maxDailyInsulin)u",
            "* maxHourlyInsulin: \(maxHourlyInsulin)u",
            "* battery: \(battery)",
            "* pumpTime: \(pumpTime)",
            "* pumpTimeSyncedAt: \(pumpTimeSyncedAt)",
            "* insulinType: \(String(describing: insulinType))",
            "* reservoirLevel: \(reservoir)",
            "* lowReservoirWarning: \(String(describing: lowReservoirWarning))",
            "* bolusState: \(bolusState.rawValue)"
        ].joined(separator: "\n")
    }
}
