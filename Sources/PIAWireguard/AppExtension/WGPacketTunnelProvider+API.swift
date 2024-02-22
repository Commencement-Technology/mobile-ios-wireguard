//
//  WGPacketTunnelProvider+API.swift
//  PIAWireguard
//  
//  Created by Jose Antonio Blaya Garcia on 27/02/2020.
//  Copyright © 2020 Private Internet Access, Inc.
//
//  This file is part of the Private Internet Access iOS Client.
//
//  The Private Internet Access iOS Client is free software: you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your option) any later version.
//
//  The Private Internet Access iOS Client is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
//  or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
//  details.
//
//  You should have received a copy of the GNU General Public License along with the Private
//  Internet Access iOS Client.  If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import Network
import NetworkExtension
import os.log
import __PIAWireGuardNative
import Alamofire
import TweetNacl

extension WGPacketTunnelProvider: URLSessionDelegate {
    
    func addPublicKeyToServer(serverAddress: String,
                              withCompletionHandler startTunnelCompletionHandler: @escaping (Error?) -> Void) {

        guard let piaToken = self.providerConfiguration[PIAWireguardConfiguration.Keys.token] as? String else {
            let msg = "WGPacketTunnel: pia auth token not found"
            self.stopTunnel(withMessage: msg)
            return
        }
                
        //Generate private key
        let keys = try! NaclBox.keyPair()
        wgPublicKey = keys.publicKey
        wgPrivateKey = keys.secretKey
        
        let baseUrl = WGClientEndpoint.addKey(serverAddress: serverAddress,
                                              port: PIAWireguardConstants.remotePort).url
        
        let params = [PIAWireguardConstants.API.publicKeyParameter: wgPublicKey.base64EncodedString(),
                      PIAWireguardConstants.API.authTokenParameter: piaToken]

        _ = session?.request(baseUrl, method: .get, parameters: params, encoding: URLEncoding.default).response { (response) in
            if let error = response.error {
                let msg = "WGPacketTunnel: request resulted in a error: \(error.localizedDescription)"
                self.stopTunnel(withMessage: msg)
            } else if let data = response.data {
                self.parse(data, withCompletionHandler: startTunnelCompletionHandler)
            } else {
                let msg = "WGPacketTunnel: no data to parse. Response code was: \(String(describing: response.response?.statusCode))"
                self.stopTunnel(withMessage: msg)
            }
        }

    }
    
    func addPublicKeyToServerIp(serverAddress: String,
                              withCompletionHandler startTunnelCompletionHandler: @escaping (Error?) -> Void) {

        guard let piaToken = self.providerConfiguration[PIAWireguardConfiguration.Keys.token] as? String else {
            let msg = "WGPacketTunnel: pia auth token not found"
            self.stopTunnel(withMessage: msg)
            return
        }

        //Generate private key
        let keys = try! NaclBox.keyPair()
        wgPublicKey = keys.publicKey
        wgPrivateKey = keys.secretKey

        
        let url = URL(string: "https://\(serverAddress):1337/addKey?pubkey=\(wgPublicKey.base64EncodedString().addingPercentEncoding(withAllowedCharacters:.rfc3986Unreserved)!)&pt=\(piaToken)")!

        let sessionConfig = URLSessionConfiguration.default
        let session = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)

        let task = session.dataTask(with: url) {(data, response, error) in
            guard let data = data else { return }
            self.parse(data, withCompletionHandler: startTunnelCompletionHandler)

        }

        task.resume()
    }
    
    private var tunnelFileDescriptor: Int32? {
        var ctlInfo = ctl_info()
        withUnsafeMutablePointer(to: &ctlInfo.ctl_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) {
                _ = strcpy($0, "com.apple.net.utun_control")
            }
        }
        for fd: Int32 in 0...1024 {
            var addr = sockaddr_ctl()
            var ret: Int32 = -1
            var len = socklen_t(MemoryLayout.size(ofValue: addr))
            withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    ret = getpeername(fd, $0, &len)
                }
            }
            if ret != 0 || addr.sc_family != AF_SYSTEM {
                continue
            }
            if ctlInfo.ctl_id == 0 {
                ret = ioctl(fd, CTLIOCGINFO, &ctlInfo)
                if ret != 0 {
                    continue
                }
            }
            if addr.sc_id == ctlInfo.ctl_id {
                return fd
            }
        }
        return nil
    }


    
    private func parse(_ data: Data,
                       withCompletionHandler startTunnelCompletionHandler: @escaping (Error?) -> Void) {
        
        guard let dnsServers = self.providerConfiguration[PIAWireguardConfiguration.Keys.dnsServers] as? [String] else {
            let msg = "WGPacketTunnel: dnsServer not found"
            self.stopTunnel(withMessage: msg)
            return
        }
        guard let ping = self.providerConfiguration[PIAWireguardConfiguration.Keys.ping] as? String else {
            let msg = "WGPacketTunnel: ping server not found"
            self.stopTunnel(withMessage: msg)
            return
        }
        
        let packetSize = self.providerConfiguration[PIAWireguardConfiguration.Keys.packetSize] as? Int ?? PIAWireguardConstants.mtu
        
        if let serverResponse = try? JSONDecoder().decode(WGServerResponse.self, from: data) {
            
            self.serverIPAddress = serverResponse.server_ip
            guard !self.serverIPAddress.isEmpty else {
                let msg = "WGPacketTunnel: Remote address not found"
                self.stopTunnel(withMessage: msg)
                return
            }
            
            wg_log(.info, staticMessage: "Configuring network settings")
            
            self.setTunnelNetworkSettings(self.generateNetworkSettings(withDnsServer: dnsServers,
                                                                       packetSize: packetSize,
                                                                       andServerResponse: serverResponse)) { (error) in
                                                                        if let error = error {
                                                                            wg_log(.info, staticMessage: "WGPacketTunnel: could not set network settings")
                                                                            wg_log(.error, message: error.localizedDescription)
                                                                            self.stopTunnel(with: .configurationFailed, completionHandler: {})
                                                                        } else {
                                                                            
                                                                            self.networkMonitor = NWPathMonitor()
                                                                            self.networkMonitor!.pathUpdateHandler = self.pathUpdate
                                                                            self.networkMonitor!.start(queue: DispatchQueue(label: "NetworkMonitor"))
                                                                            
                                                                            
                                                                            let fileDescriptor = self.tunnelFileDescriptor ?? -1
                                                                            if fileDescriptor < 0 {
                                                                                let msg = "WGPacketTunnel: could not determine file descriptor"
                                                                                self.stopTunnel(withMessage: msg)
                                                                                return
                                                                            }
                                                                            
                                                                            var ifnameSize = socklen_t(IFNAMSIZ)
                                                                            let ifnamePtr = UnsafeMutablePointer<CChar>.allocate(capacity: Int(ifnameSize))
                                                                            ifnamePtr.initialize(repeating: 0, count: Int(ifnameSize))
                                                                            if getsockopt(fileDescriptor, 2 /* SYSPROTO_CONTROL */, 2 /* UTUN_OPT_IFNAME */, ifnamePtr, &ifnameSize) == 0 {
                                                                                self.ifname = String(cString: ifnamePtr)
                                                                            }
                                                                            ifnamePtr.deallocate()
                                                                            wg_log(.info, message: "Tunnel interface is \(self.ifname ?? "unknown")")
                                                                            
                                                                            self.pinger = SwiftyPing(host: ping, configuration: PingConfiguration(interval: self.pingInterval, with: 5), queue: DispatchQueue.global())
                                                                            
                                                                            let wgConfig = self.uapiConfiguration(serverResponse: serverResponse)
                                                                            let handle = wgTurnOn(wgConfig, fileDescriptor)
                                                                    
                                                                            if handle < 0 {
                                                                                wg_log(.info, staticMessage: "WGPacketTunnel: could not start backend")
                                                                                startTunnelCompletionHandler(PacketTunnelProviderError.couldNotStartBackend)
                                                                                return
                                                                            }
                                                                            
                                                                            self.handle = handle
                                                                            self.updateSettings()
                                                                            self.configureNetworkActivityListener()
                                                                            
                                                                            startTunnelCompletionHandler(nil)
                                                                            
                                                                        }
            }
            
        } else {
            let msg = "WGPacketTunnel: unable to parse data: \(String(data: data, encoding: .utf8) ?? data.description) ourKey: \(self.wgPublicKey.base64EncodedString())"
            self.stopTunnel(withMessage: msg)
        }
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {

        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {

            guard let cn = self.providerConfiguration[PIAWireguardConfiguration.Keys.cn] as? String else {
                let msg = "WGPacketTunnel: cn not found"
                self.stopTunnel(withMessage: msg)
                return
            }

            //SERVER TRUST SETTINGS
            guard let serverTrust = challenge.protectionSpace.serverTrust else {
                let msg = "WGPacketTunnel: serverTrust not found"
                self.stopTunnel(withMessage: msg)
                return
            }

            //GET SERVER CERTIFICATE
            var chain: [SecCertificate]
            if #available(iOS 15.0, *) {
                guard let unwrappedChain = SecTrustCopyCertificateChain(serverTrust) else {
                    return
                }
                chain = unwrappedChain as! [SecCertificate]
            } else {
                guard let unwrappedCert = SecTrustGetCertificateAtIndex(serverTrust, 0) else {
                    return
                }
                chain = [unwrappedCert]
            }

//            var serverCommonName: CFString!
//            SecCertificateCopyCommonName(serverCertificate!, &serverCommonName)
//            //TODO Compare this value with the CN from the region response
//
//            if serverCommonName as String != cn {
//                completionHandler(.cancelAuthenticationChallenge, nil)
//                self.stopTunnel(withMessage: "WGPacketTunnel: cn not valid")
//                return
//            }

#if SWIFT_PACKAGE
            let bundle = Bundle.module
#else
            let bundle = Bundle(for: WGPacketTunnelProvider.self)
#endif
            let paths = Set([".der"].map { fileExtension in
                bundle.paths(forResourcesOfType: fileExtension, inDirectory: nil)
            }.joined())

            let path = paths.first!
            let certificateData = try? Data(contentsOf: URL(fileURLWithPath: path)) as CFData
            let anchor = SecCertificateCreateWithData(nil, certificateData!)

            //ARRAY OF CA CERTIFICATES
            let anchorArray = [anchor] as CFArray

            //SET DEFAULT SSL POLICY
            let policy = SecPolicyCreateBasicX509()
            var trust: SecTrust!

            //Creates a trust management object based on certificates and policies
            let trustCreation = SecTrustCreateWithCertificates(chain as CFArray, policy, &trust)
            if trustCreation != errSecSuccess {
                completionHandler(.cancelAuthenticationChallenge, nil)
                self.stopTunnel(withMessage: "WGPacketTunnel: trustCreation not valid")
            }

            //SET CA and SET TRUST OBJECT BETWEEN THE CA AND THE TRUST OBJECT FROM THE SERVER CERTIFICATE
            let trustAnchor = SecTrustSetAnchorCertificates(trust, anchorArray)
            if trustAnchor != errSecSuccess {
                completionHandler(.cancelAuthenticationChallenge, nil)
                self.stopTunnel(withMessage: "WGPacketTunnel: trustAnchor not valid")
            }

            DispatchQueue.global().async {
                if SecTrustEvaluateWithError(trust, nil) {
                    completionHandler(.useCredential, URLCredential(trust: serverTrust))
                } else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    self.stopTunnel(withMessage: "WGPacketTunnel: Error during the certificate validation")
                }
            }

        } else {
            challenge.sender!.cancel(challenge)
            completionHandler(.cancelAuthenticationChallenge, nil)
            self.stopTunnel(withMessage: "WGPacketTunnel: request error")
        }

    }
}
