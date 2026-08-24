
//
//  SMPuuids.swift
//  rareBit App
//
//  Created by Sam Rall on 12/23/25.
//

import Foundation
import CoreBluetooth

enum SmpUuids {
    static let service = CBUUID(string: "8D53DC1D-1DB7-4CD3-868B-8A527460AA84")
    static let characteristic = CBUUID(string: "DA2E7828-FBCE-4E01-AE9E-261174997C48")
}

enum cfgUuids {
    static let service = CBUUID(string: "23220001-38d5-4b7b-bad0-7dee1eee1b6d")
    static let cfg_characteristic = CBUUID(string: "23220002-38d5-4b7b-bad0-7dee1eee1b6d")
    static let fwv_characteristic = CBUUID(string: "23220003-38d5-4b7b-bad0-7dee1eee1b6d")
    /// Relay only, advertised while USB-docked. Write 0xA8 to reboot into the
    /// legacy-DFU bootloader (~500ms after the write response).
    static let dfu_trigger_characteristic = CBUUID(string: "23220004-38d5-4b7b-bad0-7dee1eee1b6d")
}

enum legacyDfuUuids {
    /// Nordic legacy DFU service, advertised by the Relay's OTAFIX bootloader.
    /// Scan for this — the bootloader's advertised name differs from the app name.
    static let service = CBUUID(string: "00001530-1212-EFDE-1523-785FEABCD123")
}
