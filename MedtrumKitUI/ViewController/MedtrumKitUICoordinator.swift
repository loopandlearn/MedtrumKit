//
//  MedtrumKitUICoordinator.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 20/02/2025.
//

import Combine
import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

class MedtrumKitUICoordinator: UINavigationController, PumpManagerOnboarding, CompletionNotifying, UINavigationControllerDelegate {
    private let colorPalette: LoopUIColorPalette

    private var pumpManager: MedtrumPumpManager?

    private var allowedInsulinTypes: [InsulinType]

    private var allowDebugFeatures: Bool

    init(
        pumpManager: MedtrumPumpManager? = nil,
        colorPalette: LoopUIColorPalette,
        pumpManagerSettings: PumpManagerSetupSettings? = nil,
        allowDebugFeatures: Bool,
        allowedInsulinTypes: [InsulinType] = []
    )
    {
        if let pumpManager = pumpManager {
            self.pumpManager = pumpManager
        }

        self.colorPalette = colorPalette

        self.allowDebugFeatures = allowDebugFeatures

        self.allowedInsulinTypes = allowedInsulinTypes

        super.init(navigationBarClass: UINavigationBar.self, toolbarClass: UIToolbar.self)
        }
    
    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    var pumpManagerOnboardingDelegate: (any LoopKitUI.PumpManagerOnboardingDelegate)?
    
    var completionDelegate: (any LoopKitUI.CompletionDelegate)?
    
    
}
