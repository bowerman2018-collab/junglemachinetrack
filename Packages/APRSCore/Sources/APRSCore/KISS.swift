import Foundation

/// KISS TNC framing (the format most Bluetooth TNCs use to hand AX.25 frames to an app).
public enum KISS {
    public static let fend: UInt8 = 0xC0
    public static let fesc: UInt8 = 0xDB
    public static let tfend: UInt8 = 0xDC
    public static let tfesc: UInt8 = 0xDD

    /// Wraps an AX.25 frame as a KISS data frame on port 0.
    public static func encode(_ frame: [UInt8], port: UInt8 = 0) -> [UInt8] {
        var out: [UInt8] = [fend, (port & 0x0F) << 4]
        for b in frame {
            switch b {
            case fend: out += [fesc, tfend]
            case fesc: out += [fesc, tfesc]
            default: out.append(b)
            }
        }
        out.append(fend)
        return out
    }
}

/// Reassembles KISS frames from a byte stream that may arrive in arbitrary chunks.
public struct KISSDecoder {
    private var buffer: [UInt8] = []
    private var inFrame = false
    private var escaping = false

    public init() {}

    /// Feeds bytes and returns the payload of every complete data frame (command 0 on any port).
    public mutating func feed(_ bytes: [UInt8]) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        for b in bytes {
            if b == KISS.fend {
                if inFrame, let command = buffer.first, command & 0x0F == 0, buffer.count > 1 {
                    frames.append(Array(buffer.dropFirst()))
                }
                buffer.removeAll(keepingCapacity: true)
                inFrame = true
                escaping = false
                continue
            }
            guard inFrame else { continue }
            if escaping {
                escaping = false
                switch b {
                case KISS.tfend: buffer.append(KISS.fend)
                case KISS.tfesc: buffer.append(KISS.fesc)
                default: buffer.append(b)
                }
            } else if b == KISS.fesc {
                escaping = true
            } else {
                buffer.append(b)
            }
            if buffer.count > 2048 {
                // Runaway frame; drop it and wait for the next FEND.
                buffer.removeAll()
                inFrame = false
            }
        }
        return frames
    }
}
