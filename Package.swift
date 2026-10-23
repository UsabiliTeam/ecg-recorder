// swift-tools-version:5.9
// Mac-only test harness: compiles the Foundation-only logic of the app (the same files the iOS target uses)
// so it can be tested with `swift test` in seconds, with no simulator. The app itself is built from
// ECGRecorder.xcodeproj (project.yml). UI, Bluetooth and Live Activity code are not part of this package.
import PackageDescription

let package = Package(
    name: "ECGRecorderLogic",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ECGRecorder",
            path: "ECGRecorder",
            sources: [
                "Core/CSV.swift", "Core/ChartData.swift", "Core/ConnectionAdvisor.swift", "Core/Format.swift",
                "Core/Models.swift", "Core/Validation.swift",
                "Devices/Sensor.swift", "Devices/SimulatedSensor.swift",
                "Metrics/Metrics.swift", "Metrics/Artifacts.swift", "Metrics/SignalQuality.swift",
                "Recording/LiveBuffer.swift", "Recording/RowWriter.swift", "Recording/SessionEngine.swift",
                "Storage/AppPaths.swift", "Storage/SessionIndex.swift",
                "Time/NTPClient.swift", "State/Roster.swift", "State/DeviceProviders.swift", "UI/Palette.swift",
            ]),
        .testTarget(
            name: "ECGRecorderTests",
            dependencies: ["ECGRecorder"],
            path: "ECGRecorderTests"),
    ],
    swiftLanguageVersions: [.v5])
