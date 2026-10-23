import CoreBluetooth
import Observation
import UIKit

/// Watches the phone's Bluetooth state so problems show up before a recording, not during one.
/// Never scans; it only listens for state changes.
@Observable @MainActor
final class BluetoothMonitor: NSObject {
    private(set) var status: BluetoothStatus = .unknown
    @ObservationIgnored private var manager: CBCentralManager?

    /// Pass `watching: false` where there is no Bluetooth (Simulator, tests, previews).
    init(watching: Bool) {
        super.init()
        guard watching else { status = .ready; return }
        manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    fileprivate func update(_ state: CBManagerState) {
        status = switch state {
        case .poweredOn: .ready
        case .poweredOff: .poweredOff
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        case .resetting: .resetting
        default: .unknown
        }
    }
}

extension BluetoothMonitor: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in self.update(state) }
    }
}
