import ServiceManagement
import SwiftUI

struct OpenAtLoginToggle: View {
    @State private var on = SMAppService.mainApp.status == .enabled
    var body: some View {
        Toggle("Open at login", isOn: $on)
            .help("Usage is only recorded while this app is running. Turn this on so tracking survives restarts.")
            .onChange(of: on) { _, value in
                guard value != (SMAppService.mainApp.status == .enabled) else { return }
                try? value ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                on = SMAppService.mainApp.status == .enabled  // reflect what macOS actually accepted
            }
    }
}

struct SettingsView: View {
    @AppStorage(Pref.notifyFailed) private var notifyFailed = true
    @AppStorage(Pref.notifySucceeded) private var notifySucceeded = false
    @AppStorage(Pref.notifyOffline) private var notifyOffline = true
    @AppStorage(Pref.notifyDisk) private var notifyDisk = true
    @AppStorage(Pref.diskAlertGB) private var diskAlertGB = 15
    @AppStorage(Pref.dataCapGB) private var dataCapGB = 0
    @AppStorage(Pref.keepAwake) private var keepAwake = true
    @AppStorage(Pref.autoClean) private var autoClean = false
    @AppStorage(Pref.autoCleanGB) private var autoCleanGB = 15
    @AppStorage(Pref.autoCleanDerivedData) private var autoCleanDerivedData = false
    @AppStorage(Pref.batteryPause) private var batteryPause = false
    @AppStorage(Pref.batteryPercent) private var batteryPercent = 30
    @State private var testResult: String?
    @EnvironmentObject var updater: AppUpdater

    var body: some View {
        Form {
            Section("Notify me when") {
                Toggle("A job fails", isOn: $notifyFailed)
                Toggle("A job succeeds", isOn: $notifySucceeded)
                Toggle("A runner goes offline on its own", isOn: $notifyOffline)
                Toggle("Free disk space is low", isOn: $notifyDisk)
                Stepper("Below \(diskAlertGB) GB free", value: $diskAlertGB, in: 5...200, step: 5).disabled(!notifyDisk).padding(.leading, 20)
                LabeledContent("Monthly data cap") {
                    HStack {
                        TextField("", value: $dataCapGB, format: .number).frame(width: 70).multilineTextAlignment(.trailing)
                        Text("GB")
                    }
                }
                .help("Alerts at 80% and 100% of this much data per month on this Mac. 0 turns it off.")
            }
            Section {
                Toggle("Keep the Mac awake while a job is running", isOn: $keepAwake)
            } header: {
                Text("Sleep")
            } footer: {
                Text("Prevents idle sleep only. Closing the lid on battery still sleeps the Mac and takes the runners offline.").foregroundStyle(.secondary)
            }
            Section {
                Toggle("Clean idle runners' workspaces when disk space is low", isOn: $autoClean)
                Stepper("Below \(autoCleanGB) GB free", value: $autoCleanGB, in: 5...200, step: 5).disabled(!autoClean).padding(.leading, 20)
                Toggle("Also clear Xcode DerivedData", isOn: $autoCleanDerivedData).disabled(!autoClean).padding(.leading, 20)
            } header: {
                Text("Automatic cleanup")
            } footer: {
                Text("Runs at most once an hour and never touches a runner that's running a job. The tool cache is kept.").foregroundStyle(.secondary)
            }
            Section {
                Toggle("Pause runners on low battery", isOn: $batteryPause)
                Stepper("Below \(batteryPercent)%", value: $batteryPercent, in: 10...90, step: 5).disabled(!batteryPause).padding(.leading, 20)
            } header: {
                Text("Battery")
            } footer: {
                Text("Idle runners are stopped and start again when you plug in. A job that's already running is allowed to finish.").foregroundStyle(.secondary)
            }
            Section("General") {
                OpenAtLoginToggle()
                LabeledContent("Notifications") {
                    Button("Send test notification") {
                        postTestNotification { ok in DispatchQueue.main.async { testResult = ok ? "Sent" : "Turned off in System Settings › Notifications" } }
                    }
                }
                if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary) }
                LabeledContent("Menu bar icon") {
                    Button("Preview build animation") { requestMenuIconPreview() }
                }
                LabeledContent("Version \(appVersion ?? "?")") {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize()
    }
}
