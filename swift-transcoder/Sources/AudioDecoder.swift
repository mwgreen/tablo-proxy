import Foundation
import AudioToolbox
import CoreMedia

/// Decodes AC3 (Dolby Digital) sync frames to PCM CMSampleBuffers using batch decoding.
/// Feeds multiple AC3 frames through a single AudioConverterFillComplexBuffer call so
/// the decoder maintains overlap state between frames — this eliminates the buzzy/gravelly
/// artifacts caused by per-frame reset. Only the first ~256 samples of each batch have
/// priming artifacts (inaudible over a full batch).
class AC3AudioDecoder {
    private var converter: AudioConverterRef?
    private var packetDesc = AudioStreamPacketDescription()
    private var configuredInputChannels: UInt32 = 0

    // Batch decode state — used by the input callback
    private var batchBasePointer: UnsafeRawPointer?
    private var batchPacketDescs: [AudioStreamPacketDescription] = []
    private var batchFrameIndex = 0

    let sampleRate: Float64
    let outputChannels: UInt32

    init(sampleRate: Float64 = 48000, outputChannels: UInt32 = 2) {
        self.sampleRate = sampleRate
        self.outputChannels = outputChannels
    }

    deinit { if let c = converter { AudioConverterDispose(c) } }

    private func ensureConverter(inputChannels: UInt32) -> Bool {
        if converter != nil && configuredInputChannels == inputChannels { return true }
        if let c = converter { AudioConverterDispose(c); converter = nil }

        var inputFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatAC3, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1536, mBytesPerFrame: 0,
            mChannelsPerFrame: inputChannels, mBitsPerChannel: 0, mReserved: 0
        )
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: outputChannels * 4, mFramesPerPacket: 1,
            mBytesPerFrame: outputChannels * 4,
            mChannelsPerFrame: outputChannels, mBitsPerChannel: 32, mReserved: 0
        )

        let status = AudioConverterNew(&inputFormat, &outputFormat, &converter)
        guard status == noErr else {
            fputs("[ac3] AudioConverterNew failed: \(status) (input=\(inputChannels)ch → output=\(outputChannels)ch)\n", stderr)
            return false
        }
        configuredInputChannels = inputChannels
        fputs("[ac3] Converter created: \(inputChannels)ch AC3 → \(outputChannels)ch PCM\n", stderr)
        return true
    }

    /// Decode a batch of AC3 frames in a single AudioConverterFillComplexBuffer call.
    /// Returns one CMSampleBuffer containing all decoded PCM with the given PTS.
    func decodeBatch(frames: [Data], pts: CMTime) -> CMSampleBuffer? {
        guard !frames.isEmpty else { return nil }
        guard let first = frames.first, first.count >= 7,
              first[first.startIndex] == 0x0B, first[first.startIndex + 1] == 0x77 else { return nil }

        let inputCh = Self.parseInputChannels(frame: first)
        guard ensureConverter(inputChannels: inputCh) else { return nil }

        // Reset once per batch — clears end-of-stream state from previous batch.
        // Priming delay only affects first ~256 samples of the batch (inaudible).
        AudioConverterReset(converter!)

        // Concatenate all frames into one contiguous buffer with packet descriptions
        var combined = Data()
        var descs: [AudioStreamPacketDescription] = []
        for frame in frames {
            descs.append(AudioStreamPacketDescription(
                mStartOffset: Int64(combined.count),
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(frame.count)
            ))
            combined.append(frame)
        }

        batchPacketDescs = descs
        batchFrameIndex = 0

        let bytesPerSample = Int(outputChannels * 4)
        let totalExpectedSamples = UInt32(frames.count * 1536)
        let maxPCMBytes = Int(totalExpectedSamples) * bytesPerSample
        var outputData = Data(count: maxPCMBytes)
        var numOutputPackets = totalExpectedSamples

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: outputChannels,
                                  mDataByteSize: UInt32(maxPCMBytes), mData: nil)
        )

        let status: OSStatus = combined.withUnsafeBytes { rawBuf -> OSStatus in
            self.batchBasePointer = rawBuf.baseAddress
            return outputData.withUnsafeMutableBytes { outBuf -> OSStatus in
                bufferList.mBuffers.mData = outBuf.baseAddress
                return AudioConverterFillComplexBuffer(
                    self.converter!, Self.batchInputProc,
                    Unmanaged.passUnretained(self).toOpaque(),
                    &numOutputPackets, &bufferList, nil
                )
            }
        }
        batchBasePointer = nil

        if status != noErr {
            fputs("[ac3] batch decode failed: status=\(status) frames=\(frames.count)\n", stderr)
            return nil
        }

        let actualBytes = Int(bufferList.mBuffers.mDataByteSize)
        guard actualBytes > 0 else { return nil }

        // Pad output to exactly N*1536 samples so duration matches PTS spacing.
        // outputData is zero-initialized, so trailing bytes are silence.
        // Without padding, the ~288-sample priming loss per batch causes audio
        // to drift ahead of video (~3s per 10 minutes).
        let expectedSamples = frames.count * 1536
        let expectedBytes = expectedSamples * bytesPerSample
        let useBytes = min(expectedBytes, maxPCMBytes)
        let useSamples = useBytes / bytesPerSample

        return makeSampleBuffer(pcmData: outputData.prefix(useBytes),
                                numSamples: useSamples, pts: pts)
    }

    private func makeSampleBuffer(pcmData: Data, numSamples: Int, pts: CMTime) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: outputChannels * 4, mFramesPerPacket: 1,
            mBytesPerFrame: outputChannels * 4,
            mChannelsPerFrame: outputChannels, mBitsPerChannel: 32, mReserved: 0
        )
        var fmtDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &fmtDesc) == noErr, let fmt = fmtDesc else { return nil }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil,
            blockLength: pcmData.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: pcmData.count,
            flags: 0, blockBufferOut: &block) == noErr, let blk = block else { return nil }

        _ = pcmData.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blk,
                offsetIntoDestination: 0, dataLength: pcmData.count)
        }

        var sampleBuf: CMSampleBuffer?
        let duration = CMTime(value: Int64(numSamples), timescale: CMTimeScale(sampleRate))
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = Int(outputChannels * 4)

        guard CMSampleBufferCreate(allocator: nil, dataBuffer: blk, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
            sampleCount: numSamples, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuf) == noErr else { return nil }
        return sampleBuf
    }

    // Batch input callback — feeds AC3 frames sequentially from the concatenated buffer.
    private static let batchInputProc: AudioConverterComplexInputDataProc = {
        (_, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
        guard let ud = inUserData else { ioNumberDataPackets.pointee = 0; return -50 }
        let d = Unmanaged<AC3AudioDecoder>.fromOpaque(ud).takeUnretainedValue()

        guard d.batchFrameIndex < d.batchPacketDescs.count,
              let basePtr = d.batchBasePointer else {
            ioNumberDataPackets.pointee = 0
            return noErr  // all frames consumed
        }

        let desc = d.batchPacketDescs[d.batchFrameIndex]
        let ptr = basePtr.advanced(by: Int(desc.mStartOffset))

        ioNumberDataPackets.pointee = 1
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = d.configuredInputChannels
        ioData.pointee.mBuffers.mDataByteSize = desc.mDataByteSize
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: ptr)

        if let outDesc = outDataPacketDescription {
            // mStartOffset must be 0 — the data pointer already points to this frame
            d.packetDesc = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0,
                mDataByteSize: desc.mDataByteSize)
            withUnsafeMutablePointer(to: &d.packetDesc) { outDesc.pointee = $0 }
        }

        d.batchFrameIndex += 1
        return noErr
    }

    // MARK: - AC3 Header Parsing

    static func parseInputChannels(frame: Data) -> UInt32 {
        guard frame.count >= 7 else { return 2 }
        let d0 = frame.startIndex
        let acmod = (frame[d0 + 6] >> 5) & 0x07
        let acmodChannels: [UInt8: UInt32] = [0:2, 1:1, 2:2, 3:3, 4:3, 5:4, 6:4, 7:5]
        var ch = acmodChannels[acmod] ?? 2
        var bitPos = 3
        if (acmod & 0x01) != 0 && acmod != 1 { bitPos += 2 }
        if (acmod & 0x04) != 0 { bitPos += 2 }
        if acmod == 2 { bitPos += 2 }
        let lfeByte = d0 + 6 + (bitPos / 8)
        let lfeBit = 7 - (bitPos % 8)
        if lfeByte < frame.endIndex {
            if (frame[lfeByte] >> lfeBit) & 0x01 == 1 { ch += 1 }
        }
        return ch
    }

    static func findSyncFrames(in data: Data) -> [(offset: Int, length: Int)] {
        var frames: [(Int, Int)] = []
        var i = data.startIndex
        while i < data.endIndex - 6 {
            guard data[i] == 0x0B && data[i+1] == 0x77 else { i += 1; continue }
            let fscod = (data[i+4] >> 6) & 0x03
            let frmsizecod = data[i+4] & 0x3F
            guard fscod < 3, frmsizecod < 38 else { i += 1; continue }
            let sz = frameSize(fscod: fscod, code: frmsizecod)
            guard sz > 0, i + sz <= data.endIndex else { i += 1; continue }
            frames.append((i - data.startIndex, sz))
            i += sz
        }
        return frames
    }

    private static func frameSize(fscod: UInt8, code: UInt8) -> Int {
        let t48: [Int] = [64,64,80,80,96,96,112,112,128,128,160,160,192,192,224,224,
            256,256,320,320,384,384,448,448,512,512,640,640,768,768,
            896,896,1024,1024,1152,1152,1280,1280]
        let t44: [Int] = [69,70,87,88,104,105,121,122,139,140,174,175,208,209,243,244,
            278,279,348,349,417,418,487,488,557,558,696,697,835,836,
            975,976,1114,1115,1253,1254,1393,1394]
        let t32: [Int] = [96,96,120,120,144,144,168,168,192,192,240,240,288,288,336,336,
            384,384,480,480,576,576,672,672,768,768,960,960,1152,1152,
            1344,1344,1536,1536,1728,1728,1920,1920]
        let idx = Int(code)
        switch fscod {
        case 0: return t48[idx] * 2
        case 1: return t44[idx] * 2
        case 2: return t32[idx] * 2
        default: return 0
        }
    }
}

/// Accumulates AC3 frames from PES packets and batch-decodes them.
/// Uses source PTS directly (relative to basePTS) — same clock as video.
class AudioTranscoder {
    private var ac3Decoder: AC3AudioDecoder?
    var onAudioSample: ((CMSampleBuffer) -> Void)?
    let tempDir: URL

    // Accumulated frames waiting for batch decode
    private var pendingFrames: [Data] = []
    private var pendingPTS: CMTime = .zero  // PTS of first pending frame

    init(tempDir: URL) {
        self.tempDir = tempDir
        ac3Decoder = AC3AudioDecoder()
        fputs("[audio] AC3 decoder created (batch mode)\n", stderr)
    }

    var totalFramesDecoded = 0
    var lastPTS: Int64 = 0

    /// Accumulate AC3 frames from a PES packet. Call flushBatch() to decode.
    func decodePES(data: Data, pts: Int64, basePTS: Int64) {
        let frames = AC3AudioDecoder.findSyncFrames(in: data)
        if totalFramesDecoded == 0 && pendingFrames.isEmpty {
            fputs("[audio] First PES: \(data.count) bytes, \(frames.count) sync frames, pts=\(pts), basePTS=\(basePTS)\n", stderr)
            if let first = frames.first, first.offset + 7 < data.count {
                let d0 = data.startIndex + first.offset
                let inputCh = AC3AudioDecoder.parseInputChannels(frame: data[d0..<d0+first.length])
                let acmod = (data[d0+6] >> 5) & 0x07
                fputs("[audio] AC3: acmod=\(acmod) channels=\(inputCh) frameSize=\(first.length)\n", stderr)
            }
        }
        for (i, frame) in frames.enumerated() {
            let frameData = data[frame.offset..<(frame.offset + frame.length)]
            let framePTS90k = pts + Int64(i) * 2880
            guard framePTS90k >= basePTS else { continue }

            let relativeSeconds = Double(framePTS90k - basePTS) / 90000.0
            let cmPTS = CMTime(seconds: relativeSeconds, preferredTimescale: 48000)

            if pendingFrames.isEmpty {
                pendingPTS = cmPTS
            }
            pendingFrames.append(Data(frameData))
        }
        if !frames.isEmpty {
            lastPTS = pts + Int64(frames.count) * 2880
        }
    }

    /// Batch-decode all accumulated frames and emit CMSampleBuffers via onAudioSample.
    func flushBatch() {
        guard let decoder = ac3Decoder, !pendingFrames.isEmpty else { return }

        if let sample = decoder.decodeBatch(frames: pendingFrames, pts: pendingPTS) {
            let n = CMSampleBufferGetNumSamples(sample)
            if totalFramesDecoded < 5 {
                fputs("[audio] Batch: \(pendingFrames.count) frames → \(n) PCM samples, pts=\(String(format: "%.3f", pendingPTS.seconds))s\n", stderr)
            }
            onAudioSample?(sample)
            totalFramesDecoded += pendingFrames.count
        }
        pendingFrames.removeAll()
    }

    func flush(basePTS: Int64) { flushBatch() }
}
