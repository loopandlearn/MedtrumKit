import HealthKit
import LoopKit
import os.log

public class MedtrumPumpManager: DeviceManager {
    public static let pluginIdentifier = "Medtrum"
    public let localizedTitle = LocalizedString("Medtrum", comment: "Generic title of the Medtrum pump manager")
     public let managerIdentifier: String = "MedtrumKit"
    public var rawState: RawStateValue
    private let log = MedtrumLogger(category: "MedtrumPumpManager")
    public let pumpDelegate = WeakSynchronizedDelegate<PumpManagerDelegate>()
    
    public required init?(rawState: RawStateValue) {
        return nil
    }
    
    public var isOnboarded: Bool {
        false
    }
    
    public static var onboardingMaximumBasalScheduleEntryCount: Int {
        48
    }
    
    public static var onboardingSupportedBasalRates: [Double] {
        // 0.05 units for rates between 0.00-25U/hr
        // 0 U/hr is a supported scheduled basal rate
        (1 ... 500).map { Double($0) / 20 }
    }

    public static var onboardingSupportedBolusVolumes: [Double] {
        // 0.05 units for rates between 0.05-30U
        // 0 is not a supported bolus volume
        (1 ... 600).map { Double($0) / 20 }
    }
    
    public static var onboardingSupportedMaximumBolusVolumes: [Double] {
        MedtrumPumpManager.onboardingSupportedBolusVolumes
    }
    
    public var delegateQueue: DispatchQueue! {
        get {
            pumpDelegate.queue
        }
        set {
            pumpDelegate.queue = newValue
        }
    }
    
    public var supportedBasalRates: [Double] {
        MedtrumPumpManager.onboardingSupportedBasalRates
    }
    
    public var supportedBolusVolumes: [Double] {
        MedtrumPumpManager.onboardingSupportedBolusVolumes
    }
    
    public var supportedMaximumBolusVolumes: [Double] {
        MedtrumPumpManager.onboardingSupportedBolusVolumes
    }
    
    public var maximumBasalScheduleEntryCount: Int {
        MedtrumPumpManager.onboardingMaximumBasalScheduleEntryCount
    }
    
    public var minimumBasalScheduleEntryDuration: TimeInterval {
        // One per hour
        TimeInterval(60 * 60)
    }
    
    public var debugDescription: String
    
    
    public func acknowledgeAlert(alertIdentifier: LoopKit.Alert.AlertIdentifier, completion: @escaping ((any Error)?) -> Void) {
        completion(nil)
    }
    
    public func getSoundBaseURL() -> URL? {
        nil
    }
    
    public func getSounds() -> [LoopKit.Alert.Sound] {
        []
    }
    
    public var pumpManagerDelegate: LoopKit.PumpManagerDelegate? {
        get {
            pumpDelegate.delegate
        }
        set {
            pumpDelegate.delegate = newValue
        }
    }
    
    private func device() -> HKDevice {
        HKDevice(
            name: "NONE",
            manufacturer: "Medtrum",
            model: "NONE",
            hardwareVersion: "NONE",
            firmwareVersion: "NONE",
            softwareVersion: "",
            localIdentifier: "NONE",
            udiDeviceIdentifier: nil
        )
    }
}

extension MedtrumPumpManager {
    
    public var pumpRecordsBasalProfileStartEvents: Bool {
        false
    }
    
    public var pumpReservoirCapacity: Double {
        0
    }
    
    public var lastSync: Date? {
        nil
    }
    
    public var status: LoopKit.PumpManagerStatus {
        PumpManagerStatus(
            timeZone: TimeZone.current,
            device: device(),
            pumpBatteryChargeRemaining: 0,
            basalDeliveryState: .none,
            bolusState: LoopKit.PumpManagerStatus.BolusState.noBolus,
            insulinType: nil
        )
    }
    
    public func addStatusObserver(_ observer: any LoopKit.PumpManagerStatusObserver, queue: DispatchQueue) {}
    
    public func removeStatusObserver(_ observer: any LoopKit.PumpManagerStatusObserver) {}
    
    public func ensureCurrentPumpData(completion: ((Date?) -> Void)?) {
        completion?(nil)
    }
    
    public func setMustProvideBLEHeartbeat(_ mustProvideBLEHeartbeat: Bool) {}
    
    public func createBolusProgressReporter(reportingOn dispatchQueue: DispatchQueue) -> (any LoopKit.DoseProgressReporter)? {
        nil
    }
    
    public func estimatedDuration(toBolus units: Double) -> TimeInterval {
        TimeInterval(0)
    }
    
    public func enactBolus(units: Double, activationType: LoopKit.BolusActivationType, completion: @escaping (LoopKit.PumpManagerError?) -> Void) {
        completion(.communication(nil))
    }
    
    public func cancelBolus(completion: @escaping (LoopKit.PumpManagerResult<LoopKit.DoseEntry?>) -> Void) {
        completion(.failure(.deviceState(nil)))
    }
    
    public func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval, completion: @escaping (LoopKit.PumpManagerError?) -> Void) {
        completion(.deviceState(nil))
    }
    
    public func suspendDelivery(completion: @escaping ((any Error)?) -> Void) {
        completion(NSError(domain: "NOT IMPLEMENTED", code: -1))
    }
    
    public func resumeDelivery(completion: @escaping ((any Error)?) -> Void) {
        completion(NSError(domain: "NOT IMPLEMENTED", code: -1))
    }
    
    public func syncBasalRateSchedule(items scheduleItems: [LoopKit.RepeatingScheduleValue<Double>], completion: @escaping (Result<LoopKit.BasalRateSchedule, any Error>) -> Void) {
        completion(.failure(NSError(domain: "NOT IMPLEMENTED", code: -1)))
    }
    
    public func syncDeliveryLimits(limits deliveryLimits: LoopKit.DeliveryLimits, completion: @escaping (Result<LoopKit.DeliveryLimits, any Error>) -> Void) {
        completion(.failure(NSError(domain: "NOT IMPLEMENTED", code: -1)))
    }
}

