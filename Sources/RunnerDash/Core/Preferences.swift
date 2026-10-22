import Foundation

enum Pref {
    static let notifyFailed = "notifyJobFailed"
    static let notifySucceeded = "notifyJobSucceeded"
    static let notifyOffline = "notifyRunnerOffline"
    static let notifyDisk = "notifyDiskLow"
    static let diskAlertGB = "diskAlertGB"
    static let dataCapGB = "monthlyDataCapGB"
    static let keepAwake = "keepAwakeDuringJobs"
    static let autoClean = "autoCleanWhenDiskLow"
    static let autoCleanGB = "autoCleanBelowGB"
    static let autoCleanDerivedData = "autoCleanDerivedData"
    static let batteryPause = "pauseOnLowBattery"
    static let batteryPercent = "pauseBelowBatteryPercent"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            notifyFailed: true, notifySucceeded: false, notifyOffline: true, notifyDisk: true, diskAlertGB: 15,
            dataCapGB: 0, keepAwake: true, autoClean: false, autoCleanGB: 15, autoCleanDerivedData: false,
            batteryPause: false, batteryPercent: 30,
        ])
    }
}
