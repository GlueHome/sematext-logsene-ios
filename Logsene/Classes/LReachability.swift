/*
 Copyright (c) 2014, Ashley Mills
 All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:

 1. Redistributions of source code must retain the above copyright notice, this
 list of conditions and the following disclaimer.

 2. Redistributions in binary form must reproduce the above copyright notice,
 this list of conditions and the following disclaimer in the documentation
 and/or other materials provided with the distribution.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 POSSIBILITY OF SUCH DAMAGE.
 */

// Reachability.swift version 2.2beta2

import SystemConfiguration
import Foundation

enum ReachabilityError: Error {
    case FailedToCreateWithAddress(sockaddr_in)
    case FailedToCreateWithHostname(String)
    case UnableToSetCallback
    case UnableToSetDispatchQueue
}

let ReachabilityChangedNotification = NSNotification.Name(rawValue: "ReachabilityChangedNotification")

func callback(reachability: SCNetworkReachability, flags: SCNetworkReachabilityFlags, info: UnsafeMutableRawPointer?) {
    guard let info = info else { return }
    let reachability = Unmanaged<LReachability>.fromOpaque(UnsafeRawPointer(info)).takeUnretainedValue()

    DispatchQueue.main.async {
        reachability.reachabilityChanged(flags)
    }
}


class LReachability: NSObject {

    internal typealias NetworkReachable = (LReachability) -> ()
    internal typealias NetworkUnreachable = (LReachability) -> ()

    internal enum NetworkStatus: CustomStringConvertible {

        case NotReachable, ReachableViaWiFi, ReachableViaWWAN

        internal var description: String {
            switch self {
            case .ReachableViaWWAN:
                return "Cellular"
            case .ReachableViaWiFi:
                return "WiFi"
            case .NotReachable:
                return "No Connection"
            }
        }
    }

    // MARK: - *** internal properties ***
    internal var whenReachable: NetworkReachable?
    internal var whenUnreachable: NetworkUnreachable?
    internal var reachableOnWWAN: Bool
    internal var notificationCenter = NotificationCenter.default

    internal var currentReachabilityStatus: NetworkStatus {
        if isReachable() {
            if isReachableViaWiFi() {
                return .ReachableViaWiFi
            }
            if isRunningOnDevice {
                return .ReachableViaWWAN
            }
        }
        return .NotReachable
    }

    internal var currentReachabilityString: String {
        return "\(currentReachabilityStatus)"
    }

    private var previousFlags: SCNetworkReachabilityFlags?

    // MARK: - *** Initialisation methods ***

    required internal init(reachabilityRef: SCNetworkReachability) {
        reachableOnWWAN = true
        self.reachabilityRef = reachabilityRef
    }

    internal convenience init(hostname: String) throws {

        guard
            let nodename = (hostname as NSString).utf8String,
            let ref = SCNetworkReachabilityCreateWithName(nil, nodename)
        else {
            throw ReachabilityError.FailedToCreateWithHostname(hostname)
        }

        self.init(reachabilityRef: ref)
    }

    internal class func reachabilityForInternetConnection() throws -> LReachability {

        var zeroAddress = sockaddr_in()
        zeroAddress.sin_len = UInt8(MemoryLayout.size(ofValue: zeroAddress))
        zeroAddress.sin_family = sa_family_t(AF_INET)

        guard let ref = withUnsafePointer(to: &zeroAddress, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1, {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            })
        }) else { throw ReachabilityError.FailedToCreateWithAddress(zeroAddress) }

        return LReachability(reachabilityRef: ref)
    }

    internal class func reachabilityForLocalWiFi() throws -> LReachability {

        var localWifiAddress: sockaddr_in = sockaddr_in(sin_len: __uint8_t(0), sin_family: sa_family_t(0), sin_port: in_port_t(0), sin_addr: in_addr(s_addr: 0), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        localWifiAddress.sin_len = UInt8(MemoryLayout.size(ofValue: localWifiAddress))
        localWifiAddress.sin_family = sa_family_t(AF_INET)

        // IN_LINKLOCALNETNUM is defined in <netinet/in.h> as 169.254.0.0
        let address: UInt32 = 0xA9FE0000
        localWifiAddress.sin_addr.s_addr = in_addr_t(address.bigEndian)

        guard let ref = withUnsafePointer(to: &localWifiAddress, {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1, {
            SCNetworkReachabilityCreateWithAddress(nil, $0)
          })
        }) else { throw ReachabilityError.FailedToCreateWithAddress(localWifiAddress) }

        return LReachability(reachabilityRef: ref)
    }

    // MARK: - *** Notifier methods ***
    internal func startNotifier() throws {

        guard !notifierRunning else { return }

        var context = SCNetworkReachabilityContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        if !SCNetworkReachabilitySetCallback(reachabilityRef!, callback, &context) {
            stopNotifier()
            throw ReachabilityError.UnableToSetCallback
        }

        if !SCNetworkReachabilitySetDispatchQueue(reachabilityRef!, reachabilitySerialQueue) {
            stopNotifier()
            throw ReachabilityError.UnableToSetDispatchQueue
        }

        // Perform an intial check
        reachabilitySerialQueue.async {
            let flags = self.reachabilityFlags
            self.reachabilityChanged(flags)
        }

        notifierRunning = true
    }

    internal func stopNotifier() {
        defer { notifierRunning = false }
        guard let reachabilityRef = reachabilityRef else { return }

        SCNetworkReachabilitySetCallback(reachabilityRef, nil, nil)
        SCNetworkReachabilitySetDispatchQueue(reachabilityRef, nil)
    }

    // MARK: - *** Connection test methods ***
    internal func isReachable() -> Bool {
        let flags = reachabilityFlags
        return isReachableWithFlags(flags)
    }

    internal func isReachableViaWWAN() -> Bool {

        let flags = reachabilityFlags

        // Check we're not on the simulator, we're REACHABLE and check we're on WWAN
        return isRunningOnDevice && isReachable(flags) && isOnWWAN(flags)
    }

    internal func isReachableViaWiFi() -> Bool {

        let flags = reachabilityFlags

        // Check we're reachable
        if !isReachable(flags) {
            return false
        }

        // Must be on WiFi if reachable but not on an iOS device (i.e. simulator)
        if !isRunningOnDevice {
            return true
        }

        // Check we're NOT on WWAN
        return !isOnWWAN(flags)
    }

    // MARK: - *** Private methods ***
    private var isRunningOnDevice: Bool = {
        #if targetEnvironment(simulator) && os(iOS)
            return false
        #else
            return true
        #endif
    }()

    private var notifierRunning = false
    private var reachabilityRef: SCNetworkReachability?
    private let reachabilitySerialQueue = DispatchQueue(label: "uk.co.ashleymills.reachability")

    internal func reachabilityChanged(_ flags: SCNetworkReachabilityFlags) {

        guard previousFlags != flags else { return }

        if isReachableWithFlags(flags) {
            if let block = whenReachable {
                block(self)
            }
        } else {
            if let block = whenUnreachable {
                block(self)
            }
        }

        notificationCenter.post(name: ReachabilityChangedNotification, object:self)

        previousFlags = flags
    }

    private func isReachableWithFlags(_ flags: SCNetworkReachabilityFlags) -> Bool {

        if !isReachable(flags) {
            return false
        }

        if isConnectionRequiredOrTransient(flags) {
            return false
        }

        if isRunningOnDevice {
            if isOnWWAN(flags) && !reachableOnWWAN {
                // We don't want to connect when on 3G.
                return false
            }
        }

        return true
    }

    // WWAN may be available, but not active until a connection has been established.
    // WiFi may require a connection for VPN on Demand.
    private func isConnectionRequired() -> Bool {
        return connectionRequired()
    }

    private func connectionRequired() -> Bool {
        let flags = reachabilityFlags
        return isConnectionRequired(flags)
    }

    // Dynamic, on demand connection?
    private func isConnectionOnDemand() -> Bool {
        let flags = reachabilityFlags
        return isConnectionRequired(flags) && isConnectionOnTrafficOrDemand(flags)
    }

    // Is user intervention required?
    private func isInterventionRequired() -> Bool {
        let flags = reachabilityFlags
        return isConnectionRequired(flags) && isInterventionRequired(flags)
    }

    private func isOnWWAN(_ flags: SCNetworkReachabilityFlags) -> Bool {
        #if os(iOS)
            return flags.contains(.isWWAN)
        #else
            return false
        #endif
    }
    private func isReachable(_ flags: SCNetworkReachabilityFlags) -> Bool {
        return flags.contains(.reachable)
    }
    private func isConnectionRequired(_ flags: SCNetworkReachabilityFlags) -> Bool {
        return flags.contains(.connectionRequired)
    }
    private func isInterventionRequired(_ flags: SCNetworkReachabilityFlags) -> Bool {
        return flags.contains(.interventionRequired)
    }
    private func isConnectionOnTraffic(_ flags: SCNetworkReachabilityFlags) -> Bool {
        return flags.contains(.connectionOnTraffic)
    }
    private func isConnectionOnDemand(_ flags: SCNetworkReachabilityFlags) -> Bool {
        return flags.contains(.connectionOnDemand)
    }
    func isConnectionOnTrafficOrDemand(_ flags: SCNetworkReachabilityFlags) -> Bool {
        return !flags.intersection([.connectionOnTraffic, .connectionOnDemand]).isEmpty
    }
    private func isTransientConnection(_ flags: SCNetworkReachabilityFlags) -> Bool {
        return flags.contains(.transientConnection)
    }
    private func isLocalAddress(_ flags: SCNetworkReachabilityFlags) -> Bool {
        return flags.contains(.isLocalAddress)
    }
    private func isDirect(_ flags: SCNetworkReachabilityFlags) -> Bool {
        return flags.contains(.isDirect)
    }
    private func isConnectionRequiredOrTransient(_ flags: SCNetworkReachabilityFlags) -> Bool {
        let testcase:SCNetworkReachabilityFlags = [.connectionRequired, .transientConnection]
        return flags.intersection(testcase) == testcase
    }

    private var reachabilityFlags: SCNetworkReachabilityFlags {

        guard let reachabilityRef = reachabilityRef else { return SCNetworkReachabilityFlags() }

        var flags = SCNetworkReachabilityFlags()
        let gotFlags = withUnsafeMutablePointer(to: &flags) {
            SCNetworkReachabilityGetFlags(reachabilityRef, $0)
        }

        if gotFlags {
            return flags
        } else {
            return SCNetworkReachabilityFlags()
        }
    }

    override internal var description: String {

        var W: String
        if isRunningOnDevice {
            W = isOnWWAN(reachabilityFlags) ? "W" : "-"
        } else {
            W = "X"
        }
        let R = isReachable(reachabilityFlags) ? "R" : "-"
        let c = isConnectionRequired(reachabilityFlags) ? "c" : "-"
        let t = isTransientConnection(reachabilityFlags) ? "t" : "-"
        let i = isInterventionRequired(reachabilityFlags) ? "i" : "-"
        let C = isConnectionOnTraffic(reachabilityFlags) ? "C" : "-"
        let D = isConnectionOnDemand(reachabilityFlags) ? "D" : "-"
        let l = isLocalAddress(reachabilityFlags) ? "l" : "-"
        let d = isDirect(reachabilityFlags) ? "d" : "-"

        return "\(W)\(R) \(c)\(t)\(i)\(C)\(D)\(l)\(d)"
    }

    deinit {
        stopNotifier()

        reachabilityRef = nil
        whenReachable = nil
        whenUnreachable = nil
    }
}
