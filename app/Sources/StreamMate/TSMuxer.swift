import Foundation

/// Minimal MPEG-TS muxer: one H.264 video stream and an optional AAC (ADTS) audio stream.
/// Not thread-safe: call from a single queue.
final class TSMuxer {
    static let videoPID: UInt16 = 0x100
    static let audioPID: UInt16 = 0x101
    static let pmtPID: UInt16 = 0x1000

    let hasAudio: Bool
    private var counters: [UInt16: UInt8] = [:]

    init(hasAudio: Bool) {
        self.hasAudio = hasAudio
    }

    private func nextCC(_ pid: UInt16) -> UInt8 {
        let v = counters[pid] ?? 0
        counters[pid] = (v &+ 1) & 0x0F
        return v
    }

    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i) << 24
            for _ in 0..<8 {
                c = (c & 0x8000_0000) != 0 ? (c << 1) ^ 0x04C1_1DB7 : (c << 1)
            }
            table[i] = c
        }
        return table
    }()

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c = (c << 8) ^ crcTable[Int(((c >> 24) ^ UInt32(b)) & 0xFF)]
        }
        return c
    }

    private func psiPacket(pid: UInt16, section: [UInt8]) -> [UInt8] {
        var s = section
        let crc = TSMuxer.crc32(s)
        s.append(UInt8((crc >> 24) & 0xFF))
        s.append(UInt8((crc >> 16) & 0xFF))
        s.append(UInt8((crc >> 8) & 0xFF))
        s.append(UInt8(crc & 0xFF))
        var p: [UInt8] = [0x47, 0x40 | UInt8(pid >> 8), UInt8(pid & 0xFF), 0x10 | nextCC(pid), 0x00]
        p.append(contentsOf: s)
        if p.count < 188 {
            p.append(contentsOf: [UInt8](repeating: 0xFF, count: 188 - p.count))
        }
        return p
    }

    /// PAT + PMT, to be sent before every keyframe.
    func tables() -> [UInt8] {
        let pmt = TSMuxer.pmtPID
        let v = TSMuxer.videoPID
        let a = TSMuxer.audioPID
        let pat = psiPacket(pid: 0, section: [
            0x00, 0xB0, 13, 0x00, 0x01, 0xC1, 0x00, 0x00,
            0x00, 0x01, 0xE0 | UInt8(pmt >> 8), UInt8(pmt & 0xFF),
        ])
        var streams: [UInt8] = [0x1B, 0xE0 | UInt8(v >> 8), UInt8(v & 0xFF), 0xF0, 0x00]
        if hasAudio {
            streams.append(contentsOf: [0x0F, 0xE0 | UInt8(a >> 8), UInt8(a & 0xFF), 0xF0, 0x00])
        }
        var section: [UInt8] = [
            0x02, 0xB0, UInt8(9 + streams.count + 4), 0x00, 0x01, 0xC1, 0x00, 0x00,
            0xE0 | UInt8(v >> 8), UInt8(v & 0xFF), 0xF0, 0x00,
        ]
        section.append(contentsOf: streams)
        return pat + psiPacket(pid: pmt, section: section)
    }

    func video(_ accessUnit: Data, pts: UInt64, keyframe: Bool) -> [UInt8] {
        let pcr = pts > 18000 ? pts - 18000 : 0
        return pes(pid: TSMuxer.videoPID, streamID: 0xE0, pts: pts, payload: accessUnit, pcr: pcr, keyframe: keyframe)
    }

    func audio(_ adtsFrame: Data, pts: UInt64) -> [UInt8] {
        return pes(pid: TSMuxer.audioPID, streamID: 0xC0, pts: pts, payload: adtsFrame, pcr: nil, keyframe: false)
    }

    private func pes(pid: UInt16, streamID: UInt8, pts: UInt64, payload: Data, pcr: UInt64?, keyframe: Bool) -> [UInt8] {
        let n = payload.count + 8
        let sized = streamID != 0xE0 && n <= 65535
        var data: [UInt8] = []
        data.reserveCapacity(payload.count + 14)
        data.append(contentsOf: [
            0x00, 0x00, 0x01, streamID,
            sized ? UInt8((n >> 8) & 0xFF) : 0, sized ? UInt8(n & 0xFF) : 0,
            0x80, 0x80, 0x05,
            0x21 | UInt8((pts >> 29) & 0x0E),
            UInt8((pts >> 22) & 0xFF),
            0x01 | UInt8((pts >> 14) & 0xFE),
            UInt8((pts >> 7) & 0xFF),
            0x01 | UInt8((pts << 1) & 0xFE),
        ])
        data.append(contentsOf: payload)

        let total = data.count
        var out: [UInt8] = []
        out.reserveCapacity((total / 184 + 2) * 188)
        var offset = 0
        var first = true
        while offset < total {
            var af: [UInt8] = []
            var afLen = 0
            if first, let pcr = pcr {
                af = [
                    keyframe ? 0x50 : 0x10,
                    UInt8((pcr >> 25) & 0xFF), UInt8((pcr >> 17) & 0xFF),
                    UInt8((pcr >> 9) & 0xFF), UInt8((pcr >> 1) & 0xFF),
                    UInt8((pcr & 1) << 7) | 0x7E, 0x00,
                ]
                afLen = af.count + 1
            } else if first && keyframe {
                af = [0x40]
                afLen = 2
            }
            var space = 184 - afLen
            let remaining = total - offset
            if remaining < space {
                let pad = space - remaining
                if afLen == 0 {
                    if pad == 1 {
                        af = []
                        afLen = 1
                    } else {
                        af = [0x00] + [UInt8](repeating: 0xFF, count: pad - 2)
                        afLen = pad
                    }
                } else {
                    af.append(contentsOf: [UInt8](repeating: 0xFF, count: pad))
                    afLen += pad
                }
                space = remaining
            }
            out.append(0x47)
            out.append((first ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1F))
            out.append(UInt8(pid & 0xFF))
            out.append((afLen > 0 ? 0x30 : 0x10) | nextCC(pid))
            if afLen > 0 {
                out.append(UInt8(afLen - 1))
                out.append(contentsOf: af)
            }
            out.append(contentsOf: data[offset..<(offset + space)])
            offset += space
            first = false
        }
        return out
    }
}
