//
//  RareBitFirmware.swift
//  rareBit App
//
//  Created by Sam Rall on 12/23/25.
//

import Foundation

enum RareBitDeviceType: String, CaseIterable {
    case proFlag = "rareBit PRO Flag"
    case proReceiver = "rareBit PRO Receiver"
    case relay = "rareBit Relay"
    case blink = "BLINK RED"
    case unknown

    static func from(advertisedName: String?) -> RareBitDeviceType {
        guard let name = advertisedName else { return .unknown }
        // exact names only (your requirement)
        if name == RareBitDeviceType.proFlag.rawValue { return .proFlag }
        if name == RareBitDeviceType.proReceiver.rawValue { return .proReceiver }
        if name == RareBitDeviceType.relay.rawValue { return .relay }
        if name == RareBitDeviceType.blink.rawValue {return .blink}
        return .unknown
    }

    var firmwareResource: (name: String, ext: String)? {
        switch self {
        case .proFlag: return ("PRO_FLAG_1v9", "bin")
        case .proReceiver: return ("PRO_RX_1v9", "bin")
        case .relay: return ("RELAY_2v0", "bin")
        case .blink: return ("BLUE_BLINK", "bin")
        case .unknown: return nil
        }
    }

    var displayName: String {
        switch self {
        case .proFlag: return "PRO Flag"
        case .proReceiver: return "PRO Receiver"
        case .relay: return "Relay"
        case .blink: return "BLINK RED"
        case .unknown: return "Unknown"
        }
    }
}
