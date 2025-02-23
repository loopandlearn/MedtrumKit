import LoopKit
import LoopKitUI
import SwiftUI

extension MedtrumPumpManager: PumpManagerUI {
    public static func setupViewController(
        initialSettings settings: LoopKitUI.PumpManagerSetupSettings,
        bluetoothProvider _: any LoopKit.BluetoothProvider,
        colorPalette: LoopKitUI.LoopUIColorPalette,
        allowDebugFeatures: Bool,
        prefersToSkipUserInteraction _: Bool,
        allowedInsulinTypes: [LoopKit.InsulinType]
    ) -> LoopKitUI.SetupUIResult<any LoopKitUI.PumpManagerViewController, any LoopKitUI.PumpManagerUI> {
        let vc = MedtrumKitUICoordinator(
            colorPalette: colorPalette,
            pumpManagerSettings: settings,
            allowDebugFeatures: allowDebugFeatures,
            allowedInsulinTypes: allowedInsulinTypes
        )

        return .userInteractionRequired(vc)
    }

    // NOTE: iAPS support
    public static func setupViewController(
        initialSettings settings: LoopKitUI.PumpManagerSetupSettings,
        bluetoothProvider _: LoopKit.BluetoothProvider,
        colorPalette: LoopKitUI.LoopUIColorPalette,
        allowDebugFeatures: Bool,
        allowedInsulinTypes: [LoopKit.InsulinType]
    ) -> LoopKitUI.SetupUIResult<LoopKitUI.PumpManagerViewController, LoopKitUI.PumpManagerUI> {
        let vc = MedtrumKitUICoordinator(
            colorPalette: colorPalette,
            pumpManagerSettings: settings,
            allowDebugFeatures: allowDebugFeatures,
            allowedInsulinTypes: allowedInsulinTypes
        )

        return .userInteractionRequired(vc)
    }

    public func settingsViewController(
        bluetoothProvider _: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool,
        allowedInsulinTypes: [InsulinType]
    ) -> PumpManagerViewController {
        MedtrumKitUICoordinator(
            pumpManager: self,
            colorPalette: colorPalette,
            allowDebugFeatures: allowDebugFeatures,
            allowedInsulinTypes: allowedInsulinTypes
        )
    }

    public func deliveryUncertaintyRecoveryViewController(
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool
    ) -> (UIViewController & CompletionNotifying) {
        return MedtrumKitUICoordinator(pumpManager: self, colorPalette: colorPalette, allowDebugFeatures: allowDebugFeatures)
    }

    public func hudProvider(
        bluetoothProvider: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowedInsulinTypes: [InsulinType]
    ) -> HUDProvider? {
        MedtrumKitHUDProvider(
            pumpManager: self,
            bluetoothProvider: bluetoothProvider,
            colorPalette: colorPalette,
            allowedInsulinTypes: allowedInsulinTypes
        )
    }

    public static func createHUDView(rawValue _: [String: Any]) -> BaseHUDView? {
        nil
    }

    public static var onboardingImage: UIImage? {
        nil
    }

    public var smallImage: UIImage? {
        nil
    }

    public var pumpStatusHighlight: DeviceStatusHighlight? {
        nil
    }

    // Not needed
    public var pumpLifecycleProgress: DeviceLifecycleProgress? {
        nil
    }

    public var pumpStatusBadge: DeviceStatusBadge? {
        nil
    }
}
