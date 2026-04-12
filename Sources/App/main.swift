import SwiftUI
import AppKit
import Logging
import Common
import HDRUI
import Capture
import MetalEngine
import Network

@main
struct HDRAnalyzerProApp: App {
    @StateObject private var sharedState = SharedAppState()

    init() {
        // F-003: Enable file logging (PROJECT_INTEGRITY_REPORT). Uses Application Support so it works regardless of CWD.
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let logDir = appSupport.appendingPathComponent("HDRImageAnalyzerPro/logs", isDirectory: true)
            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let logFile = logDir.appendingPathComponent("app.log")
            HDRLogger.setLogFile(url: logFile)
        }
        HDRLogger.info(category: "App", "HDR Image Analyzer Pro starting")
        NetworkService.setWebServerHandler(WebUIServer.requestHandler())
        if NetworkService.startWebServer(port: 8765) {
            HDRLogger.info(category: "App", "Web UI: http://localhost:8765/")
        }
    }
    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(sharedState)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 960, height: 720)
        WindowGroup("Scopes", id: "scopes") {
            ScopesOnSecondDisplayView()
                .environmentObject(sharedState)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 960, height: 720)
        .windowResizability(.contentSize)
        WindowGroup("Help", id: "help") {
            HelpWindowView()
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 560, height: 520)
        .windowResizability(.contentSize)
        Settings {
            PreferencesView()
                .preferredColorScheme(.dark)
        }
        .commands {
            // Remove default New item
            CommandGroup(replacing: .newItem) { }

            // MARK: - File (UI-006: shortcuts from AppShortcuts registry)
            CommandMenu("File") {
                Button("Presets...") {
                    NotificationCenter.default.post(name: AppMenuNotifications.openPresets, object: nil)
                }
                .keyboardShortcut(AppShortcuts.shortcut(for: .openPresets))
                Divider()
                Button("Export...") {
                    NotificationCenter.default.post(name: AppMenuNotifications.export, object: nil)
                }
                .keyboardShortcut(AppShortcuts.shortcut(for: .export))
                Divider()
                Button("Screenshot (Display)") {
                    NotificationCenter.default.post(name: AppMenuNotifications.takeScreenshot, object: nil)
                }
                .keyboardShortcut(AppShortcuts.shortcut(for: .takeScreenshot))
                Button("Screenshot (Scope)") {
                    NotificationCenter.default.post(name: AppMenuNotifications.takeScopeScreenshot, object: nil)
                }
                .keyboardShortcut(AppShortcuts.shortcut(for: .takeScopeScreenshot))
                Button("Copy Screenshot to Clipboard") {
                    NotificationCenter.default.post(name: AppMenuNotifications.copyScreenshotToPasteboard, object: nil)
                }
                .keyboardShortcut(AppShortcuts.shortcut(for: .copyScreenshotToPasteboard))
                Divider()
                Button("Start timed screenshot (QC-009)") {
                    NotificationCenter.default.post(name: AppMenuNotifications.startTimedScreenshot, object: nil)
                }
                Button("Stop timed screenshot") {
                    NotificationCenter.default.post(name: AppMenuNotifications.stopTimedScreenshot, object: nil)
                }
            }

            // MARK: - View
            CommandMenu("View") {
                Button("Layout") {
                    NotificationCenter.default.post(name: AppMenuNotifications.viewLayout, object: nil)
                }
                Divider()
                Button("Enter Full Screen") {
                    NSApp.mainWindow?.toggleFullScreen(nil)
                }
                .keyboardShortcut(AppShortcuts.shortcut(for: .enterFullScreen))
                Divider()
                Button("Zoom In") {
                    NotificationCenter.default.post(name: AppMenuNotifications.viewZoomIn, object: nil)
                }
                .keyboardShortcut(AppShortcuts.shortcut(for: .zoomIn))
                Button("Zoom Out") {
                    NotificationCenter.default.post(name: AppMenuNotifications.viewZoomOut, object: nil)
                }
                .keyboardShortcut(AppShortcuts.shortcut(for: .zoomOut))
                Button("Actual Size") {
                    NotificationCenter.default.post(name: AppMenuNotifications.viewActualSize, object: nil)
                }
                .keyboardShortcut(AppShortcuts.shortcut(for: .actualSize))
            }

            // MARK: - Input
            CommandMenu("Input") {
                Button("Device...") {
                    NotificationCenter.default.post(name: AppMenuNotifications.openDevicePicker, object: nil)
                }
                .keyboardShortcut(AppShortcuts.shortcut(for: .openDevicePicker))
                Button("Format...") {
                    NotificationCenter.default.post(name: AppMenuNotifications.openFormatPicker, object: nil)
                }
                .keyboardShortcut(AppShortcuts.shortcut(for: .openFormatPicker))
            }

            // MARK: - Analysis (UI-008: colorspace menus using CS-004; UI-006: shortcuts)
            CommandMenu("Analysis") {
                Button("Scope Type") {
                    NotificationCenter.default.post(name: AppMenuNotifications.openScopeType, object: nil)
                }
                .keyboardShortcut(AppShortcuts.shortcut(for: .scopeType))
                Menu("Analysis Space") {
                    ForEach(GamutSpace.allCases, id: \.self) { space in
                        Button {
                            var config = AppConfig.current
                            config.analysisGamutSpace = space
                            AppConfig.save(config)
                        } label: {
                            if AppConfig.current.analysisGamutSpace == space {
                                Label(space.displayName, systemImage: "checkmark")
                            } else {
                                Text(space.displayName)
                            }
                        }
                    }
                }
            }

            // MARK: - Display (UI-008: Display Space using CS-004)
            CommandMenu("Display") {
                Menu("Display Space") {
                    ForEach(GamutSpace.allCases, id: \.self) { space in
                        Button {
                            var config = AppConfig.current
                            config.displayGamutSpace = space
                            AppConfig.save(config)
                        } label: {
                            if AppConfig.current.displayGamutSpace == space {
                                Label(space.displayName, systemImage: "checkmark")
                            } else {
                                Text(space.displayName)
                            }
                        }
                    }
                }
                Button("Display Options...") {
                    NotificationCenter.default.post(name: AppMenuNotifications.openDisplayOptions, object: nil)
                }
                .keyboardShortcut(AppShortcuts.shortcut(for: .displayOptions))
            }

            // MARK: - Window (UI-013: scopes on display 2)
            CommandGroup(after: .windowArrangement) {
                Button("Show Scopes on Second Display") {
                    NotificationCenter.default.post(name: AppMenuNotifications.showScopesOnSecondDisplay, object: nil)
                }
                .keyboardShortcut("2", modifiers: [.command, .option])
                Button("Bring All to Front") {
                    NSApp.arrangeInFront(nil)
                }
            }

            // MARK: - Help (INT-010: user documentation / Help system)
            CommandMenu("Help") {
                Button("HDR Image Analyzer Pro Help") {
                    NotificationCenter.default.post(name: AppMenuNotifications.openHelp, object: nil)
                }
                    .keyboardShortcut(AppShortcuts.shortcut(for: .help))
                Divider()
                Button("About HDR Image Analyzer Pro") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
        }
    }
}
