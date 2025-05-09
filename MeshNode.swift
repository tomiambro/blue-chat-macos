import Foundation
import MultipeerConnectivity
import Network

// MARK: - Transport Protocol

protocol ChatTransport {
    var onMessageReceived: ((String, String) -> Void)? { get set }
    func start()
    func sendMessage(_ text: String)
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

    func sendMessage(_ text: String) {
        guard !session.connectedPeers.isEmpty else { return }
        if let data = text.data(using: .utf8) {
            do {
                try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            } catch {
                print("[Multipeer] Error sending message: \(error)")
            }
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

    func sendMessage(_ text: String) {
        guard let connection = connection else {
            print("[WifiDirect] No connection available.")
            return
        }
        let data = text.data(using: .utf8)
        connection.send(content: data, completion: .contentProcessed({ error in
            if let error = error {
                print("[WifiDirect] Error sending message: \(error)")
            }
        }))
    }
}

// MARK: - Protocol Selector

class CrossPlatformTransportManager: ChatTransport {
    private var transports: [ChatTransport] = []
    var onMessageReceived: ((String, String) -> Void)? {
        didSet {
            // Use for-in loop to modify the property
            for (var transport) in transports {
                transport.onMessageReceived = onMessageReceived
            }
        }
    }

    init() {
        let wifiTransport = WiFiDirectManager()
        let multiTransport = MultipeerManager()
        transports.append(wifiTransport)
        transports.append(multiTransport)
    }

    func start() {
        transports.forEach { $0.start() }
    }

    func sendMessage(_ text: String) {
        transports.forEach { $0.sendMessage(text) }
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
