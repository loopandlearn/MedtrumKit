//
//  HostAppState.swift
//  MedtrumKit
//
//  Single seam for host-app lifecycle state. The BLE stack needs to know whether the app is
//  frontmost (see BluetoothManager.shouldHoldConnection), but watchOS has no UIApplication —
//  keeping the platform split here means BluetoothManager itself stays platform-neutral.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
#if os(watchOS)
import WatchKit
#else
import UIKit
#endif

/// Host application lifecycle, abstracted away from UIKit/WatchKit.
enum HostAppState {

    /// True when the host app is frontmost and active. Read this on the main thread.
    static var isActive: Bool {
        #if os(watchOS)
        return WKApplication.shared().applicationState == .active
        #else
        return UIApplication.shared.applicationState == .active
        #endif
    }

    static var didBecomeActiveNotification: Notification.Name {
        #if os(watchOS)
        return WKApplication.didBecomeActiveNotification
        #else
        return UIApplication.didBecomeActiveNotification
        #endif
    }

    static var didEnterBackgroundNotification: Notification.Name {
        #if os(watchOS)
        return WKApplication.didEnterBackgroundNotification
        #else
        return UIApplication.didEnterBackgroundNotification
        #endif
    }
}
