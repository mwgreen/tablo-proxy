import Foundation

// MARK: - MPEG-TS Constants

let TS_PACKET_SIZE = 188
let TS_SYNC_BYTE: UInt8 = 0x47
let PAT_PID: UInt16 = 0x0000
let STREAM_TYPE_MPEG2_VIDEO: UInt8 = 0x02
let STREAM_TYPE_AAC_AUDIO: UInt8 = 0x0F
let STREAM_TYPE_AC3_AUDIO: UInt8 = 0x81

// MARK: - MPEG-2 Start Codes

let SEQUENCE_HEADER_CODE: UInt32 = 0x000001B3
let PICTURE_START_CODE: UInt32 = 0x00000100
let SEQUENCE_END_CODE: UInt32 = 0x000001B7
let EXTENSION_START_CODE: UInt32 = 0x000001B5

// MARK: - PES Packet

struct PESPacket {
    let pid: UInt16
    let streamType: UInt8
    let pts: Int64?      // in 90kHz units
    let dts: Int64?
    let data: Data       // elementary stream data
}

// MARK: - TS Demuxer

class TSDemuxer {
    var pmtPID: UInt16 = 0
    var videoPID: UInt16 = 0
    var audioPID: UInt16 = 0
    var videoStreamType: UInt8 = 0
    var audioStreamType: UInt8 = 0

    // PES accumulation buffers per PID
    private var pesBuffers: [UInt16: Data] = [:]
    private var pesStarted: [UInt16: Bool] = [:]

    // Callback for completed PES packets
    var onPESPacket: ((PESPacket) -> Void)?

    func demux(data: Data) {
        var offset = 0
        while offset + TS_PACKET_SIZE <= data.count {
            // Find sync byte
            if data[offset] != TS_SYNC_BYTE {
                offset += 1
                continue
            }

            let packet = data[offset..<offset + TS_PACKET_SIZE]
            parsePacket(packet)
            offset += TS_PACKET_SIZE
        }
    }

    // Flush any remaining PES data
    func flush() {
        for pid in [videoPID, audioPID] where pid != 0 {
            if let buf = pesBuffers[pid], !buf.isEmpty {
                emitPES(pid: pid, data: buf)
                pesBuffers[pid] = Data()
            }
        }
    }

    private func parsePacket(_ packet: Data) {
        let base = packet.startIndex

        let byte1 = packet[base + 1]
        let byte2 = packet[base + 2]
        let byte3 = packet[base + 3]

        let payloadUnitStart = (byte1 & 0x40) != 0
        let pid = UInt16(byte1 & 0x1F) << 8 | UInt16(byte2)
        let adaptationFieldControl = (byte3 & 0x30) >> 4
        //let continuityCounter = byte3 & 0x0F

        // Calculate payload offset
        var payloadOffset = base + 4
        if adaptationFieldControl == 0x02 || adaptationFieldControl == 0x03 {
            let adaptationLength = Int(packet[base + 4])
            payloadOffset = base + 5 + adaptationLength
        }

        // No payload
        if adaptationFieldControl == 0x02 {
            return
        }

        guard payloadOffset < base + TS_PACKET_SIZE else { return }
        let payload = packet[payloadOffset..<base + TS_PACKET_SIZE]

        // PAT
        if pid == PAT_PID {
            parsePAT(payload: payload, payloadUnitStart: payloadUnitStart)
            return
        }

        // PMT
        if pid == pmtPID && pmtPID != 0 {
            parsePMT(payload: payload, payloadUnitStart: payloadUnitStart)
            return
        }

        // Video or Audio PES
        if pid == videoPID || pid == audioPID {
            if payloadUnitStart {
                // Emit previous PES if we had one
                if let buf = pesBuffers[pid], !buf.isEmpty {
                    emitPES(pid: pid, data: buf)
                }
                pesBuffers[pid] = Data(payload)
                pesStarted[pid] = true
            } else if pesStarted[pid] == true {
                pesBuffers[pid]?.append(Data(payload))
            }
        }
    }

    private func parsePAT(payload: Data, payloadUnitStart: Bool) {
        var offset = payload.startIndex
        if payloadUnitStart {
            let pointerField = Int(payload[offset])
            offset += 1 + pointerField
        }

        guard offset + 8 <= payload.endIndex else { return }
        // Skip table_id(1), section_syntax(2), transport_stream_id(2), version(1), section_number(1), last_section(1)
        offset += 8

        // Each program entry: program_number(2) + PMT_PID(2)
        let sectionEnd = payload.endIndex - 4 // exclude CRC
        while offset + 4 <= sectionEnd {
            let programNumber = UInt16(payload[offset]) << 8 | UInt16(payload[offset + 1])
            let pmtPid = (UInt16(payload[offset + 2]) & 0x1F) << 8 | UInt16(payload[offset + 3])
            offset += 4

            if programNumber != 0 {
                pmtPID = pmtPid
                break
            }
        }
    }

    private func parsePMT(payload: Data, payloadUnitStart: Bool) {
        var offset = payload.startIndex
        if payloadUnitStart {
            let pointerField = Int(payload[offset])
            offset += 1 + pointerField
        }

        guard offset + 12 <= payload.endIndex else { return }

        // table_id(1) + section_length(2) + program_number(2) + version(1) + section_number(1) + last_section(1)
        let sectionLength = Int(payload[offset + 1] & 0x0F) << 8 | Int(payload[offset + 2])
        let sectionEnd = min(offset + 3 + sectionLength - 4, payload.endIndex) // exclude CRC
        offset += 8

        // PCR_PID(2) + program_info_length(2)
        guard offset + 4 <= payload.endIndex else { return }
        let programInfoLength = Int(payload[offset + 2] & 0x0F) << 8 | Int(payload[offset + 3])
        offset += 4 + programInfoLength

        // Stream entries
        while offset + 5 <= sectionEnd {
            let streamType = payload[offset]
            let elementaryPID = (UInt16(payload[offset + 1]) & 0x1F) << 8 | UInt16(payload[offset + 2])
            let esInfoLength = Int(payload[offset + 3] & 0x0F) << 8 | Int(payload[offset + 4])
            offset += 5 + esInfoLength

            if streamType == STREAM_TYPE_MPEG2_VIDEO && videoPID == 0 {
                videoPID = elementaryPID
                videoStreamType = streamType
            } else if (streamType == STREAM_TYPE_AAC_AUDIO || streamType == STREAM_TYPE_AC3_AUDIO) && audioPID == 0 {
                audioPID = elementaryPID
                audioStreamType = streamType
            }
        }
    }

    private func emitPES(pid: UInt16, data: Data) {
        guard data.count >= 9 else { return }

        // Verify PES start code: 0x000001
        guard data[data.startIndex] == 0x00 &&
              data[data.startIndex + 1] == 0x00 &&
              data[data.startIndex + 2] == 0x01 else { return }

        let flags = data[data.startIndex + 7]
        let headerLength = Int(data[data.startIndex + 8])
        let esDataStart = data.startIndex + 9 + headerLength

        guard esDataStart <= data.endIndex else { return }

        // Extract PTS
        var pts: Int64? = nil
        var dts: Int64? = nil

        let ptsDtsFlags = (flags >> 6) & 0x03
        if ptsDtsFlags >= 2 && data.startIndex + 14 <= data.endIndex {
            let r = data.startIndex + 9
            pts = Int64(data[r] & 0x0E) << 29 |
                  Int64(data[r + 1]) << 22 |
                  Int64(data[r + 2] & 0xFE) << 14 |
                  Int64(data[r + 3]) << 7 |
                  Int64(data[r + 4] >> 1)

            if ptsDtsFlags == 3 && data.startIndex + 19 <= data.endIndex {
                let d = data.startIndex + 14
                dts = Int64(data[d] & 0x0E) << 29 |
                      Int64(data[d + 1]) << 22 |
                      Int64(data[d + 2] & 0xFE) << 14 |
                      Int64(data[d + 3]) << 7 |
                      Int64(data[d + 4] >> 1)
            }
        }

        let streamType = pid == videoPID ? videoStreamType : audioStreamType
        let esData = Data(data[esDataStart..<data.endIndex])

        let packet = PESPacket(pid: pid, streamType: streamType, pts: pts, dts: dts, data: esData)
        onPESPacket?(packet)
    }
}

// MARK: - MPEG-2 Sequence Header Parser

struct MPEG2SequenceInfo {
    let width: Int
    let height: Int
    let frameRateCode: Int
    let fps: Double
}

func parseMPEG2SequenceHeader(data: Data) -> MPEG2SequenceInfo? {
    // Look for sequence header start code 0x000001B3
    var i = data.startIndex
    while i + 7 < data.endIndex {
        if data[i] == 0x00 && data[i+1] == 0x00 && data[i+2] == 0x01 && data[i+3] == 0xB3 {
            let b = i + 4
            let width = Int(data[b]) << 4 | Int(data[b+1] >> 4)
            let height = Int(data[b+1] & 0x0F) << 8 | Int(data[b+2])
            let frameRateCode = Int(data[b+3] & 0x0F)

            let fpsTable: [Int: Double] = [
                1: 24000.0/1001.0, 2: 24, 3: 25, 4: 30000.0/1001.0,
                5: 30, 6: 50, 7: 60000.0/1001.0, 8: 60
            ]

            return MPEG2SequenceInfo(
                width: width, height: height,
                frameRateCode: frameRateCode,
                fps: fpsTable[frameRateCode] ?? 30.0
            )
        }
        i += 1
    }
    return nil
}

// MARK: - MPEG-2 Frame Assembler

/// Accumulates MPEG-2 ES data and splits it into complete pictures.
/// Each picture includes any preceding sequence header.
class MPEG2FrameAssembler {
    private var buffer = Data()
    var onFrame: ((Data, Int64?) -> Void)?  // (frame ES data, PTS)
    private var currentPTS: Int64?

    func feed(esData: Data, pts: Int64?) {
        // On new PES with PTS, check if we have a pending frame to emit
        if let pts = pts, !buffer.isEmpty {
            // Emit what we have so far as a frame
            onFrame?(buffer, currentPTS)
            buffer = Data()
            currentPTS = pts
        } else if currentPTS == nil {
            currentPTS = pts
        }

        buffer.append(esData)
    }

    func flush() {
        if !buffer.isEmpty {
            onFrame?(buffer, currentPTS)
            buffer = Data()
            currentPTS = nil
        }
    }
}
