import Foundation
import MultipeerConnectivity
import Network
import CoreBluetooth


// MARK: - Transport Protocol

protocol ChatTransport {
    var onMessageReceived: ((String, String) -> Void)? { get set }
    func start()
    func sendMessage(_ text: String, completion: @escaping (Bool) -> Void)
}


class BluetoothManager: NSObject, ChatTransport {
    private var peripheralManager: CBPeripheralManager!
    private var centralManager: CBCentralManager!
    private var chatCharacteristic: CBMutableCharacteristic!
    private var subscribedCentrals: [CBCentral] = []
    private var discoveredPeripherals: [CBPeripheral] = []
    private var chatCharacteristics: [CBPeripheral: CBCharacteristic] = [:]

    private let serviceUUID = CBUUID(string: "C0DE1000-FEED-FEED-FEED-C0DEC0FFEE01")
    private let chatCharacteristicUUID = CBUUID(string: "C0DE1001-FEED-FEED-FEED-C0DEC0FFEE01")

    var onMessageReceived: ((String, String) -> Void)?

    override init() {
        super.init()
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func start() {
        // Both central and peripheral will begin once state updates to poweredOn
    }

    func sendMessage(_ text: String, completion: @escaping (Bool) -> Void) {
        guard let data = text.data(using: .utf8) else {
            completion(false)
            return
        }

        var sent = false

        // Send as peripheral
        if !subscribedCentrals.isEmpty {
            let success = peripheralManager.updateValue(data, for: chatCharacteristic, onSubscribedCentrals: nil)
            sent = sent || success
        }

        // Send as central
        var centralSuccess = false
        for (peripheral, characteristic) in chatCharacteristics {
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
            centralSuccess = true
        }

        sent = sent || centralSuccess
        completion(sent)
    }

}

// MARK: - Peripheral Role

extension BluetoothManager: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }

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
            CBAdvertisementDataLocalNameKey: "BluetoothChat"
        ])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        subscribedCentrals.append(central)
    }
}

// MARK: - Central Role

extension BluetoothManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        centralManager.scanForPeripherals(withServices: [serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if !discoveredPeripherals.contains(peripheral) {
            discoveredPeripherals.append(peripheral)
            peripheral.delegate = self
            centralManager.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
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
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let data = characteristic.value,
           let text = String(data: data, encoding: .utf8) {
            onMessageReceived?(peripheral.name ?? "BluetoothPeer", text)
        }
    }
}


// MARK: - Multipeer Manager (Apple Devices)

class MultipeerManager: NSObject, ChatTransport {
    private let peerID: MCPeerID
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser!
    private var browser: MCNearbyServiceBrowser!

    var onMessageReceived: ((String, String) -> Void)?

    override init() {
        let name = Host.current().localizedName ?? UUID().uuidString
        self.peerID = MCPeerID(displayName: name)

        super.init()

        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self

        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: "chat-service")
        advertiser.delegate = self

        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: "chat-service")
        browser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        print("[Multipeer] Multipeer communication started as \(peerID.displayName)")
    }

    func sendMessage(_ text: String, completion: @escaping (Bool) -> Void) {
        guard !session.connectedPeers.isEmpty else {
            completion(false)
            return
        }
        if let data = text.data(using: .utf8) {
            do {
                try session.send(data, toPeers: session.connectedPeers, with: .reliable)
                completion(true)
            } catch {
                print("[Multipeer] Error sending: \(error)")
                completion(false)
            }
        } else {
            completion(false)
        }
    }
}

extension MultipeerManager: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        print("[Multipeer] Peer \(peerID.displayName) state changed: \(state.rawValue)")
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if let text = String(data: data, encoding: .utf8) {
            onMessageReceived?(peerID.displayName, text)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String : String]?) {
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {}
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {}
}

// MARK: - WiFiDirectManager (Non-Apple)

class WiFiDirectManager: ChatTransport {
    var onMessageReceived: ((String, String) -> Void)?
    private var server: NWListener?
    private var connection: NWConnection?

    func start() {
        // Start a server to listen for incoming messages
        let parameters = NWParameters.tcp
        server = try? NWListener(using: parameters, on: 8080)
        server?.newConnectionHandler = { [weak self] connection in
            self?.connection = connection
            connection.start(queue: .global())
            connection.receiveMessage { data, _, _, _ in
                if let data = data, let text = String(data: data, encoding: .utf8) {
                    self?.onMessageReceived?("WiFiPeer", text)
                }
            }
        }
        server?.start(queue: .global())
        print("[WifiDirect] Starting Wi-Fi Direct communication (simulated with sockets on iOS/macOS)")
    }

    func sendMessage(_ text: String, completion: @escaping (Bool) -> Void) {
        guard let connection = connection else {
            completion(false)
            return
        }

        let data = text.data(using: .utf8)
        connection.send(content: data, completion: .contentProcessed({ error in
            if let error = error {
                print("[WifiDirect] Error sending message: \(error)")
                completion(false)
            }
            else {
                completion(true)
            }
        }))
    }
}

// MARK: - Protocol Selector

class CrossPlatformTransportManager: ChatTransport {
    private var transports: [ChatTransport] = []

    var onMessageReceived: ((String, String) -> Void)? {
        didSet {
            for i in transports.indices {
                transports[i].onMessageReceived = onMessageReceived
            }
        }
    }

    init() {
        let wifiTransport = WiFiDirectManager()
        let multiTransport = MultipeerManager()
        let bluetoothTransport = BluetoothManager()
        transports.append(wifiTransport)
        transports.append(multiTransport)
        transports.append(bluetoothTransport)
    }

    func start() {
        transports.forEach { $0.start() }
    }

    func sendMessage(_ text: String) {
        sendMessage(text) { success in
            if !success {
                print("[TransportManager] Failed to send message on all transports.")
            }
        }
    }

    func sendMessage(_ text: String, completion: @escaping (Bool) -> Void) {
        trySend(index: 0, text: text, completion: completion)
    }

    private func trySend(index: Int, text: String, completion: @escaping (Bool) -> Void) {
        guard index < transports.count else {
            completion(false)
            return
        }

        transports[index].sendMessage(text) { success in
            if success {
                print("[TransportManager] Message sent via \(type(of: self.transports[index]))")
                completion(true)
            } else {
                self.trySend(index: index + 1, text: text, completion: completion)
            }
        }
    }
}


// MARK: - CLI Usage

let transportManager = CrossPlatformTransportManager()
transportManager.onMessageReceived = { sender, message in
    print("\(sender): \(message)\n> ", terminator: "")
}
transportManager.start()

DispatchQueue.global(qos: .userInitiated).async {
    while true {
        print("> ", terminator: "")
        if let line = readLine(), !line.isEmpty {
            transportManager.sendMessage(line)
        }
    }
}

RunLoop.main.run()
