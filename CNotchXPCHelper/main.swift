//
//  main.swift
//  CNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation
import Security

class ServiceDelegate: NSObject, NSXPCListenerDelegate {

    // Reject connections from anything not signed by the same developer
    // team as this helper. This service is scoped to a private per-app XPC
    // domain rather than the global launchd namespace, which already makes
    // it hard for an unrelated process to reach, but that scoping isn't a
    // substitute for an explicit check here.
    private static let codeSigningRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"655RB6729T\""

    /// This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard Self.isAuthorized(newConnection) else {
            newConnection.invalidate()
            return false
        }

        // Configure the connection.
        // First, set the interface that the exported object implements.
        newConnection.exportedInterface = NSXPCInterface(with: (any CNotchXPCHelperProtocol).self)

        // Next, set the object that the connection exports. All messages sent on the connection to this service will be sent to the exported object to handle. The connection retains the exported object.
        let exportedObject = CNotchXPCHelper()
        newConnection.exportedObject = exportedObject

        // Resuming the connection allows the system to deliver more incoming messages.
        newConnection.resume()

        // Returning true from this method tells the system that you have accepted this connection. If you want to reject the connection for some reason, call invalidate() on the connection and return false.
        return true
    }

    private static func isAuthorized(_ connection: NSXPCConnection) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: connection.processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(codeSigningRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else {
            return false
        }

        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

// Create the delegate for the service.
let delegate = ServiceDelegate()

// Set up the one NSXPCListener for this service. It will handle all incoming connections.
let listener = NSXPCListener.service()
listener.delegate = delegate

// Resuming the serviceListener starts this service. This method does not return.
listener.resume()
