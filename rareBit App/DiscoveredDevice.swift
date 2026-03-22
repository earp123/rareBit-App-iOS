//
//  DiscoveredDevice.swift
//  rareBit App
//
//  Created by Sam Rall on 12/23/25.
//

import Foundation
import CoreBluetooth

struct DiscoveredDevice: Identifiable, Hashable {
    let id: UUID
    let peripheral: CBPeripheral
    let advertisedName: String?
    let rssi: Int

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        lhs.id == rhs.id
    }
}
