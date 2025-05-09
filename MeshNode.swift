import Foundation
import CoreBluetooth

let serviceUUID = CBUUID(string: "C0DE1000-FEED-FEED-FEED-C0DEC0FFEE01")
let chatCharacteristicUUID = CBUUID(string: "C0DE1001-FEED-FEED-FEED-C0DEC0FFEE01")

class BluetoothChatNode: NSObject {
    // Peripheral mode
    private var peripheralManager: CBPeripheralManager!
    private var chatCharacteristic: CBMutableCharacteristic!
    private var subscribedCentrals: [CBCentral] = []
    
    // Central mode
    private var centralManager: CBCentralManager!
    private var discoveredPeripherals: [CBPeripheral] = []
    private var chatCharacteristics: [CBPeripheral: CBCharacteristic] = [:]
    
    override init() {
        super.init()
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func sendMessage(_ text: String) {
        let data = text.data(using: .utf8)!
        peripheralManager.updateValue(data, for: chatCharacteristic, onSubscribedCentrals: nil)
    }
}

// MARK: - Peripheral Manager

extension BluetoothChatNode: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            print("Peripheral not ready")
            return
        }

        chatCharacteristic = CBMutableCharacteristic(
            type: chatCharacteristicUUID,
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )
        
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [chatCharacteristic]
        peripheralManager.add(service)

        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey: "BTChat"
        ])
        
        print("🟣 Advertising chat service")
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        subscribedCentrals.append(central)
        print("🔗 Central subscribed: \(central)")
    }
}

// MARK: - Central Manager

extension BluetoothChatNode: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            print("Central not ready")
            return
        }
        
        centralManager.scanForPeripherals(withServices: [serviceUUID])
        print("🔍 Scanning for peripherals...")
    }
    
    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        if !discoveredPeripherals.contains(peripheral) {
            discoveredPeripherals.append(peripheral)
            peripheral.delegate = self
            centralManager.connect(peripheral, options: nil)
            print("🔌 Connecting to \(peripheral.name ?? "peer")")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("✅ Connected to \(peripheral.name ?? "peer")")
        peripheral.discoverServices([serviceUUID])
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics([chatCharacteristicUUID], for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics where characteristic.uuid == chatCharacteristicUUID {
            chatCharacteristics[peripheral] = characteristic
            peripheral.setNotifyValue(true, for: characteristic)
            print("📬 Subscribed to messages from \(peripheral.name ?? "peer")")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let data = characteristic.value,
           let message = String(data: data, encoding: .utf8) {
            print("\n🔵 \(peripheral.name ?? "Peer"): \(message)\n> ", terminator: "")
        }
    }
}

// MARK: - CLI Loop

let node = BluetoothChatNode()

DispatchQueue.global(qos: .userInitiated).async {
    while true {
        print("> ", terminator: "")
        if let line = readLine(), !line.isEmpty {
            node.sendMessage(line)
        }
    }
}

RunLoop.main.run()
