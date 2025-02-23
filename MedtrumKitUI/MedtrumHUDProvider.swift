import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

internal class MedtrumKitHUDProvider: NSObject, HUDProvider {
    private let pumpManager: MedtrumPumpManager

    private let bluetoothProvider: BluetoothProvider

    private let colorPalette: LoopUIColorPalette

    private let allowedInsulinTypes: [InsulinType]

    public init(
        pumpManager: MedtrumPumpManager,
        bluetoothProvider: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowedInsulinTypes: [InsulinType]
    ) {
        self.pumpManager = pumpManager
        self.bluetoothProvider = bluetoothProvider
        self.colorPalette = colorPalette
        self.allowedInsulinTypes = allowedInsulinTypes
        super.init()
    }

    func createHUDView() -> LoopKitUI.BaseHUDView? {
        nil
    }

    func didTapOnHUDView(_: LoopKitUI.BaseHUDView, allowDebugFeatures _: Bool) -> LoopKitUI.HUDTapAction? {
        nil
    }

    var hudViewRawState: HUDViewRawState {
        var rawValue: HUDProvider.HUDViewRawState = [:]
        return rawValue
    }

    var visible: Bool = false

    var managerIdentifier: String {
        pumpManager.managerIdentifier
    }
}
