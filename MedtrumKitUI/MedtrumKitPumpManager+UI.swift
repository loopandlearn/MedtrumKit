//
//  MedtrumKitPumpManager+UI.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 20/02/2025.
//

import LoopKit
import LoopKitUI
import SwiftUI

extension MedtrumPumpManager : PumpManagerUI {    
    public static func setupViewController(initialSettings settings: LoopKitUI.PumpManagerSetupSettings, bluetoothProvider: LoopKit.BluetoothProvider, colorPalette: LoopKitUI.LoopUIColorPalette, allowDebugFeatures: Bool, allowedInsulinTypes: [LoopKit.InsulinType]) -> LoopKitUI.SetupUIResult<LoopKitUI.PumpManagerViewController, LoopKitUI.PumpManagerUI> {

        let vc = MedtrumKitUICoordinator(
            colorPalette: colorPalette,
            pumpManagerSettings: settings,
            allowDebugFeatures: allowDebugFeatures,
            allowedInsulinTypes: allowedInsulinTypes
        )
        
        return .userInteractionRequired(vc)
    }
    
    public func settingsViewController(bluetoothProvider: BluetoothProvider, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool, allowedInsulinTypes: [InsulinType]) -> PumpManagerViewController {
        
        return MedtrumKitUICoordinator(
            pumpManager: self,
            colorPalette: colorPalette,
            allowDebugFeatures: allowDebugFeatures,
            allowedInsulinTypes: allowedInsulinTypes
        )
    }
    
    public func deliveryUncertaintyRecoveryViewController(colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool) -> (UIViewController & CompletionNotifying) {
        return MedtrumKitUICoordinator(pumpManager: self, colorPalette: colorPalette, allowDebugFeatures: allowDebugFeatures)
   }
    
    public func hudProvider(bluetoothProvider: BluetoothProvider, colorPalette: LoopUIColorPalette, allowedInsulinTypes: [InsulinType]) -> HUDProvider? {
        return MedtrumKitHUDProvider(pumpManager: self, bluetoothProvider: bluetoothProvider, colorPalette: colorPalette, allowedInsulinTypes: allowedInsulinTypes)
    }
    
    public static func createHUDView(rawValue: [String : Any]) -> BaseHUDView? {
        return nil
    }
    
    public static var onboardingImage: UIImage? {
        return nil
    }
    
    public var smallImage: UIImage? {
        return nil
    }
    
    public var pumpStatusHighlight: DeviceStatusHighlight? {
        return nil
    }
    
    // Not needed
    public var pumpLifecycleProgress: DeviceLifecycleProgress? {
        return nil
    }
    
    public var pumpStatusBadge: DeviceStatusBadge? {
        return nil
    }
}
