import CoreBluetooth
import Foundation

// One 20-second experiment: register a controller-shaped GATT service, advertise,
// and scan for it on this same Mac. It never connects to physical peripherals.
final class Probe: NSObject, CBPeripheralManagerDelegate, CBCentralManagerDelegate {
    var peripheral: CBPeripheralManager!
    var central: CBCentralManager!
    var sightings = 0
    var subscriptions = 0
    let uuid = CBUUID(string: "FC82")
    override init() {
        super.init()
        peripheral = CBPeripheralManager(delegate: self, queue: nil)
        central = CBCentralManager(delegate: self, queue: nil)
    }
    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        print("peripheralState=\(p.state.rawValue)")
        guard p.state == .poweredOn else { return }
        let service = CBMutableService(type: uuid, primary: true)
        service.characteristics = [
            CBMutableCharacteristic(type: CBUUID(string: "00000002-19CA-4651-86E5-FA29DCDD09D1"), properties: [.notify], value: nil, permissions: []),
            CBMutableCharacteristic(type: CBUUID(string: "00000003-19CA-4651-86E5-FA29DCDD09D1"), properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeable]),
            CBMutableCharacteristic(type: CBUUID(string: "00000004-19CA-4651-86E5-FA29DCDD09D1"), properties: [.read, .indicate], value: nil, permissions: [.readable])
        ]
        p.add(service)
    }
    func peripheralManager(_ p: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        print("serviceAdded error=\(String(describing: error))")
        guard error == nil else { return }
        p.startAdvertising([
            CBAdvertisementDataLocalNameKey: "ZwiftShift BLE Probe",
            CBAdvertisementDataServiceUUIDsKey: [uuid],
            CBAdvertisementDataManufacturerDataKey: Data([0x4a, 0x09, 0x09])
        ])
    }
    func peripheralManagerDidStartAdvertising(_ p: CBPeripheralManager, error: Error?) {
        print("advertising=\(p.isAdvertising) error=\(String(describing: error))")
    }
    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        subscriptions += 1
        print("subscription=\(characteristic.uuid)")
    }
    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests { print("write=\(r.characteristic.uuid) bytes=\(r.value?.count ?? 0)"); p.respond(to: r, withResult: .success) }
    }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        print("centralState=\(c.state.rawValue)")
        if c.state == .poweredOn { c.scanForPeripherals(withServices: [uuid], options: nil) }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "unnamed"
        if name == "ZwiftShift BLE Probe" { sightings += 1 }
        print("scan name=\(name) self=\(name == "ZwiftShift BLE Probe")")
    }
}
let probe = Probe()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 20))
probe.central.stopScan()
probe.peripheral.stopAdvertising()
probe.peripheral.removeAllServices()
print("RESULT sameMacSightings=\(probe.sightings) subscriptions=\(probe.subscriptions)")
