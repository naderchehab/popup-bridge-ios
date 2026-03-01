enum PopupBridgeAnalytics {

    static let started = "popup-bridge:started"
    static let succeeded = "popup-bridge:succeeded"
    static let failed = "popup-bridge:failed"
    static let canceled = "popup-bridge:canceled"

    // App Switch events
    static let appDetected = "popup-bridge:app-switch:app-detected"
    static let appLaunched = "popup-bridge:app-switch:app-launched"
    static let appLaunchFailed = "popup-bridge:app-switch:app-launch-failed"
    static let appSwitchReturned = "popup-bridge:app-switch:returned"
}

