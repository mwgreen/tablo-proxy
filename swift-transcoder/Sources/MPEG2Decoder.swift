import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

class MPEG2Decoder {
    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    let width: Int
    let height: Int

    /// Called when a frame is decoded. (pixelBuffer, pts in 90kHz)
    var onDecodedFrame: ((CVPixelBuffer, Int64) -> Void)?

    init(width: Int, height: Int) throws {
        self.width = width
        self.height = height

        // Create format description for MPEG-2
        var fmt: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_MPEG2Video,
            width: Int32(width),
            height: Int32(height),
            extensions: nil,
            formatDescriptionOut: &fmt
        )
        guard status == noErr, let formatDesc = fmt else {
            throw NSError(domain: "MPEG2Decoder", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create format description: \(status)"])
        }
        self.formatDesc = formatDesc

        // Output pixel buffer attributes
        let bufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        // Decoder spec — MPEG-2 is software-only on Apple Silicon
        let decoderSpec: [CFString: Any] = [:]

        // Create callback
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, imageBuffer, pts, duration in
                guard let refcon = refcon else { return }
                let decoder = Unmanaged<MPEG2Decoder>.fromOpaque(refcon).takeUnretainedValue()
                guard status == noErr, let pixelBuffer = imageBuffer else { return }

                // Convert CMTime PTS to 90kHz
                let pts90k = pts.isValid ? Int64(pts.seconds * 90000) : 0
                decoder.onDecodedFrame?(pixelBuffer, pts90k)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var sess: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: formatDesc,
            decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: bufferAttrs as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &sess
        )

        guard createStatus == noErr, let session = sess else {
            throw NSError(domain: "MPEG2Decoder", code: Int(createStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create decoder session: \(createStatus)"])
        }
        self.session = session
    }

    /// Decode a complete MPEG-2 picture (raw ES data with start codes)
    func decode(frameData: Data, pts: Int64) {
        guard let session = session, let formatDesc = formatDesc else { return }

        // Create CMBlockBuffer from the raw ES data
        var blockBuffer: CMBlockBuffer?
        frameData.withUnsafeBytes { rawBuf in
            guard let baseAddress = rawBuf.baseAddress else { return }
            // We need a mutable copy for CMBlockBuffer
            let mutable = UnsafeMutableRawPointer(mutating: baseAddress)
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: mutable,
                blockLength: frameData.count,
                blockAllocator: kCFAllocatorNull,  // don't free — data owns it
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: frameData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }

        guard let block = blockBuffer else { return }

        // Create CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 90000),
            presentationTimeStamp: CMTime(value: CMTimeValue(pts), timescale: 90000),
            decodeTimeStamp: .invalid
        )

        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard let sample = sampleBuffer else { return }

        // Decode — synchronous
        let decodeFlags = VTDecodeFrameFlags._EnableAsynchronousDecompression
        var infoFlags = VTDecodeInfoFlags()

        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: decodeFlags,
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
    }

    func flush() {
        if let session = session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
    }

    deinit {
        if let session = session {
            VTDecompressionSessionInvalidate(session)
        }
    }
}
