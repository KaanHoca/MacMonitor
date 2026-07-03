// FanHelper — Standalone CLI tool for SMC fan control
// Compiled separately and run with admin privileges via osascript.
// Usage: FanHelper boost <target_rpm> <duration_seconds>
//        FanHelper auto

import IOKit
import Foundation

// MARK: - SMC Data Structures

struct SMCKeyData {
    struct vers_t {
        var major: UInt8 = 0; var minor: UInt8 = 0
        var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0
    }
    struct pLimitData {
        var version: UInt16 = 0; var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0
    }
    struct keyInfo_t {
        var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0
    }
    var key: UInt32 = 0
    var vers = vers_t(); var pLimitData = pLimitData(); var keyInfo = keyInfo_t()
    var padding: UInt16 = 0; var result: UInt8 = 0; var status: UInt8 = 0
    var data8: UInt8 = 0; var data32: UInt32 = 0
    var bytes: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) =
               (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

// MARK: - SMC Helpers

func fourCC(_ s: String) -> UInt32 {
    var r: UInt32 = 0
    for c in s.utf8 { r = (r << 8) | UInt32(c) }
    return r
}

var conn: io_connect_t = 0

func openSMC() -> Bool {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
    guard svc != 0 else { return false }
    let kr = IOServiceOpen(svc, mach_task_self_, 0, &conn)
    IOObjectRelease(svc)
    return kr == kIOReturnSuccess
}

func getKeyInfo(_ key: String) -> (dataSize: UInt32, dataType: UInt32)? {
    var inData = SMCKeyData()
    var outData = SMCKeyData()
    inData.key = fourCC(key)
    inData.data8 = 9 // kSMCGetKeyInfo
    var sz = MemoryLayout<SMCKeyData>.size
    let kr = IOConnectCallStructMethod(conn, 2, &inData, sz, &outData, &sz)
    guard kr == kIOReturnSuccess, outData.keyInfo.dataSize > 0 else { return nil }
    return (outData.keyInfo.dataSize, outData.keyInfo.dataType)
}

func readSMCByte(_ key: String) -> UInt8? {
    guard let info = getKeyInfo(key) else { return nil }
    var inRead = SMCKeyData()
    var outRead = SMCKeyData()
    inRead.key = fourCC(key)
    inRead.keyInfo.dataSize = info.dataSize
    inRead.data8 = 5 // kSMCReadKey
    var sz = MemoryLayout<SMCKeyData>.size
    let kr = IOConnectCallStructMethod(conn, 2, &inRead, sz, &outRead, &sz)
    guard kr == kIOReturnSuccess else { return nil }
    return outRead.bytes.0
}

func readSMCUInt16(_ key: String) -> UInt16? {
    guard let info = getKeyInfo(key) else { return nil }
    var inRead = SMCKeyData()
    var outRead = SMCKeyData()
    inRead.key = fourCC(key)
    inRead.keyInfo.dataSize = info.dataSize
    inRead.data8 = 5
    var sz = MemoryLayout<SMCKeyData>.size
    let kr = IOConnectCallStructMethod(conn, 2, &inRead, sz, &outRead, &sz)
    guard kr == kIOReturnSuccess else { return nil }
    return (UInt16(outRead.bytes.0) << 8) | UInt16(outRead.bytes.1)
}

func writeSMCRaw(_ key: String, bytes: [UInt8]) -> Bool {
    guard let info = getKeyInfo(key) else { return false }
    var inW = SMCKeyData()
    var outW = SMCKeyData()
    inW.key = fourCC(key)
    inW.keyInfo.dataSize = info.dataSize
    inW.data8 = 6 // kSMCWriteKey

    // Copy bytes into the tuple
    withUnsafeMutablePointer(to: &inW.bytes) { ptr in
        ptr.withMemoryRebound(to: UInt8.self, capacity: 32) { dest in
            for (i, b) in bytes.prefix(Int(info.dataSize)).enumerated() {
                dest[i] = b
            }
        }
    }

    var sz = MemoryLayout<SMCKeyData>.size
    let kr = IOConnectCallStructMethod(conn, 2, &inW, sz, &outW, &sz)
    return kr == kIOReturnSuccess
}

func writeFloat(_ key: String, value: Float32) -> Bool {
    var f = value
    let bytes = withUnsafeBytes(of: &f) { Array($0) }
    return writeSMCRaw(key, bytes: bytes)
}

func writeFpe2(_ key: String, value: UInt16) -> Bool {
    let encoded = value << 2
    return writeSMCRaw(key, bytes: [UInt8(encoded >> 8), UInt8(encoded & 0xFF)])
}

func writeByte(_ key: String, value: UInt8) -> Bool {
    return writeSMCRaw(key, bytes: [value])
}

// MARK: - Architecture Detection

func isAppleSilicon() -> Bool {
    var sysinfo = utsname()
    uname(&sysinfo)
    let machine = withUnsafePointer(to: &sysinfo.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
            String(cString: $0)
        }
    }
    return machine.hasPrefix("arm64")
}

// MARK: - Fan Control

func setForcedBit(_ fanIndex: Int, forced: Bool) -> Bool {
    let key = "FS! "
    guard let current = readSMCUInt16(key) else { return false }
    var bits = current
    if forced {
        bits |= UInt16(1 << fanIndex)
    } else {
        bits &= ~UInt16(1 << fanIndex)
    }
    return writeSMCRaw(key, bytes: [UInt8(bits >> 8), UInt8(bits & 0xFF)])
}

func boostFans(targetRPM: Int, duration: Int) {
    guard let countByte = readSMCByte("FNum") else {
        fputs("Error: Cannot read fan count\n", stderr)
        exit(1)
    }
    let fanCount = Int(countByte)
    guard fanCount > 0 else {
        fputs("Error: No fans found\n", stderr)
        exit(1)
    }

    let appleSilicon = isAppleSilicon()

    // Set fans to target RPM
    for i in 0..<fanCount {
        if appleSilicon {
            // Apple Silicon: set force bit, then write target
            _ = setForcedBit(i, forced: true)
            _ = writeFloat("F\(i)Tg", value: Float32(targetRPM))
        } else {
            // Intel: set manual mode, then write target as fpe2
            _ = writeByte("F\(i)Md", value: 1)
            _ = writeFpe2("F\(i)Tg", value: UInt16(targetRPM))
        }
    }

    // Wait for the boost duration
    Thread.sleep(forTimeInterval: Double(duration))

    // Revert to auto mode
    for i in 0..<fanCount {
        if appleSilicon {
            _ = setForcedBit(i, forced: false)
        } else {
            _ = writeByte("F\(i)Md", value: 0)
        }
    }
}

func revertFans() {
    guard let countByte = readSMCByte("FNum") else { return }
    let fanCount = Int(countByte)
    let appleSilicon = isAppleSilicon()

    for i in 0..<fanCount {
        if appleSilicon {
            _ = setForcedBit(i, forced: false)
        } else {
            _ = writeByte("F\(i)Md", value: 0)
        }
    }
}

// MARK: - Main

guard openSMC() else {
    fputs("Error: Cannot open AppleSMC\n", stderr)
    exit(1)
}

let args = CommandLine.arguments

if args.count >= 3 && args[1] == "boost" {
    let targetRPM = Int(args[2]) ?? 5000
    let duration = args.count >= 4 ? (Int(args[3]) ?? 30) : 30
    boostFans(targetRPM: targetRPM, duration: duration)
} else if args.count >= 2 && args[1] == "auto" {
    revertFans()
} else {
    fputs("Usage: FanHelper boost <target_rpm> [duration_seconds]\n", stderr)
    fputs("       FanHelper auto\n", stderr)
    exit(1)
}

IOServiceClose(conn)
