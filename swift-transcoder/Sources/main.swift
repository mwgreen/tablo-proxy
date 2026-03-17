import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import UniformTypeIdentifiers

// MARK: - CLI

guard CommandLine.arguments.count >= 3 else {
    fputs("Usage: hls-transcode <source-hls-url> <output-dir> [bitrate] [segment-duration] [offset] [--live]\n", stderr)
    exit(1)
}

let sourceURLString = CommandLine.arguments[1]
let outputDirPath = CommandLine.arguments[2]
let bitrate = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]) ?? 4_000_000 : 4_000_000
let segmentDuration = CommandLine.arguments.count > 4 ? Double(CommandLine.arguments[4]) ?? 4.0 : 4.0
let startOffset = CommandLine.arguments.count > 5 ? Double(CommandLine.arguments[5]) ?? 0 : 0
let isLive = CommandLine.arguments.contains("--live")

guard let sourceURL = URL(string: sourceURLString) else {
    fputs("Invalid source URL\n", stderr)
    exit(1)
}

let outputDir = URL(fileURLWithPath: outputDirPath)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

// MARK: - HLS Playlist Helpers

struct HLSSegmentInfo {
    let uri: String
    let duration: Double
    let byteRangeLength: Int?
    let byteRangeOffset: Int?
}

func parseMediaPlaylist(data: Data) -> [HLSSegmentInfo] {
    let text = String(data: data, encoding: .utf8) ?? ""
    let lines = text.components(separatedBy: "\n")
    var segments: [HLSSegmentInfo] = []
    var nextDuration: Double = 0
    var nextByteLength: Int? = nil
    var nextByteOffset: Int? = nil
    var runningOffset = 0

    for line in lines {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("#EXTINF:") {
            nextDuration = Double(t.dropFirst(8).components(separatedBy: ",").first ?? "0") ?? 0
        } else if t.hasPrefix("#EXT-X-BYTERANGE:") {
            let parts = t.dropFirst(17).components(separatedBy: "@")
            nextByteLength = Int(parts[0])
            if parts.count > 1 { nextByteOffset = Int(parts[1]); runningOffset = nextByteOffset! }
            else { nextByteOffset = runningOffset }
            if let len = nextByteLength { runningOffset = (nextByteOffset ?? 0) + len }
        } else if !t.isEmpty && !t.hasPrefix("#") {
            segments.append(HLSSegmentInfo(uri: t, duration: nextDuration,
                byteRangeLength: nextByteLength, byteRangeOffset: nextByteOffset))
            nextDuration = 0; nextByteLength = nil; nextByteOffset = nil
        }
    }
    return segments
}

func resolveMediaPlaylistURL(masterURL: URL) async throws -> URL {
    let (data, _) = try await URLSession.shared.data(from: masterURL)
    let text = String(data: data, encoding: .utf8) ?? ""
    guard text.contains("#EXT-X-STREAM-INF") else { return masterURL }
    let lines = text.components(separatedBy: "\n")
    for (i, line) in lines.enumerated() {
        if line.contains("#EXT-X-STREAM-INF"), i + 1 < lines.count {
            let uri = lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            return resolveURI(uri, baseURL: masterURL)
        }
    }
    return masterURL
}

func resolveURI(_ uri: String, baseURL: URL) -> URL {
    if uri.hasPrefix("http") { return URL(string: uri)! }
    if uri.hasPrefix("/") {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let parts = uri.components(separatedBy: "?")
        c.path = parts[0]
        if parts.count > 1 { c.query = parts[1] }
        return c.url!
    }
    return baseURL.deletingLastPathComponent().appendingPathComponent(uri)
}

func downloadSegmentData(baseURL: URL, segment: HLSSegmentInfo) async throws -> Data {
    let segURL = resolveURI(segment.uri, baseURL: baseURL)
    var request = URLRequest(url: segURL)
    if let length = segment.byteRangeLength, let offset = segment.byteRangeOffset {
        request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
    }
    let (data, _) = try await URLSession.shared.data(for: request)
    return data
}

// MARK: - Segment Writer (fMP4 HLS output)

class SegmentWriter: NSObject, AVAssetWriterDelegate {
    let outputDir: URL
    let targetDuration: Double
    var isLive: Bool
    var segmentIndex = 0
    var playlistEntries: [(filename: String, duration: Double)] = []
    var initWritten = false

    init(outputDir: URL, targetDuration: Double, isLive: Bool = true) {
        self.outputDir = outputDir
        self.targetDuration = targetDuration
        self.isLive = isLive
    }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        switch segmentType {
        case .initialization:
            if !initWritten {
                try! segmentData.write(to: outputDir.appendingPathComponent("init.mp4"))
                initWritten = true
                fputs("[gpu] Wrote init.mp4 (\(segmentData.count) bytes)\n", stderr)
            }
        case .separable:
            var duration = targetDuration
            if let report = segmentReport, let tr = report.trackReports.first {
                duration = tr.duration.seconds
            }
            guard duration > 0.1 && segmentData.count > 500 else { return }
            let filename = "seg\(segmentIndex).m4s"
            try! segmentData.write(to: outputDir.appendingPathComponent(filename))
            playlistEntries.append((filename: filename, duration: duration))
            segmentIndex += 1
            writePlaylist(finished: false)
            fputs("[gpu] seg\(segmentIndex - 1) (\(segmentData.count / 1024)KB, \(String(format: "%.2f", duration))s)\n", stderr)
        @unknown default: break
        }
    }

    func writePlaylist(finished: Bool) {
        var m3u8 = "#EXTM3U\n#EXT-X-VERSION:7\n"
        let maxDur = playlistEntries.map(\.duration).max() ?? targetDuration
        m3u8 += "#EXT-X-TARGETDURATION:\(Int(ceil(maxDur)))\n"
        m3u8 += "#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        m3u8 += "#EXT-X-PLAYLIST-TYPE:EVENT\n"
        m3u8 += "#EXT-X-MAP:URI=\"init.mp4\"\n"
        for e in playlistEntries {
            m3u8 += "#EXTINF:\(String(format: "%.6f", e.duration)),\n\(e.filename)\n"
        }
        if finished { m3u8 += "#EXT-X-ENDLIST\n" }
        try! m3u8.write(to: outputDir.appendingPathComponent("stream.m3u8"), atomically: true, encoding: .utf8)
    }
}

// MARK: - Main Pipeline

fputs("[gpu] Source: \(sourceURLString)\n", stderr)
fputs("[gpu] Output: \(outputDirPath)\n", stderr)

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }

// Resolve master → media playlist
fputs("[gpu] Fetching playlist...\n", stderr)
let mediaPlaylistURL = try await resolveMediaPlaylistURL(masterURL: sourceURL)
if mediaPlaylistURL != sourceURL {
    fputs("[gpu] Media playlist: \(mediaPlaylistURL)\n", stderr)
}

// Fetch playlist and skip to live edge
let (initPlData, _) = try await URLSession.shared.data(from: mediaPlaylistURL)
let allSegments = parseMediaPlaylist(data: initPlData)
fputs("[gpu] \(allSegments.count) segments in playlist\n", stderr)
guard !allSegments.isEmpty else { fputs("[gpu] No segments\n", stderr); exit(1) }

// Determine starting segment
var liveStartIndex = 0
if isLive {
    // Live: start near the live edge so playback is immediate.
    // Rewind buffer grows naturally as the stream continues.
    liveStartIndex = max(0, allSegments.count - 5)
    fputs("[gpu] LIVE: starting from segment \(liveStartIndex) (near live edge)\n", stderr)
} else if startOffset > 0 {
    // Recording with offset: skip to the right position
    var accumulated = 0.0
    for (i, seg) in allSegments.enumerated() {
        if accumulated >= startOffset { liveStartIndex = i; break }
        accumulated += seg.duration
    }
    fputs("[gpu] RECORDING: starting from segment \(liveStartIndex) (offset \(String(format: "%.1f", startOffset))s)\n", stderr)
} else {
    fputs("[gpu] RECORDING: starting from beginning\n", stderr)
}

// Download just 2 segments to probe video properties
var initialData = Data()
let probeEnd = min(liveStartIndex + 2, allSegments.count)
for i in liveStartIndex..<probeEnd {
    initialData.append(try await downloadSegmentData(baseURL: mediaPlaylistURL, segment: allSegments[i]))
}
fputs("[gpu] Probe: \(initialData.count / 1024)KB (\(probeEnd - liveStartIndex) segments)\n", stderr)

// Demux to find video properties
let demuxer = TSDemuxer()
var firstVideoES: Data? = nil
var sequenceInfo: MPEG2SequenceInfo? = nil

demuxer.onPESPacket = { pes in
    if pes.streamType == STREAM_TYPE_MPEG2_VIDEO && firstVideoES == nil {
        firstVideoES = pes.data
        sequenceInfo = parseMPEG2SequenceHeader(data: pes.data)
    }
}
demuxer.demux(data: initialData)
demuxer.flush()

guard let seqInfo = sequenceInfo else {
    fputs("[gpu] Could not find MPEG-2 sequence header\n", stderr)
    exit(1)
}
fputs("[gpu] Video: \(seqInfo.width)x\(seqInfo.height) @ \(String(format: "%.2f", seqInfo.fps))fps\n", stderr)
fputs("[gpu] Video PID: 0x\(String(demuxer.videoPID, radix: 16)) type=\(demuxer.videoStreamType), Audio PID: 0x\(String(demuxer.audioPID, radix: 16)) type=\(demuxer.audioStreamType)\n", stderr)

// Set up MPEG-2 decoder (VTDecompressionSession)
let decoder = try MPEG2Decoder(width: seqInfo.width, height: seqInfo.height)
fputs("[gpu] MPEG-2 decoder created\n", stderr)

// Set up H.264 encoder (AVAssetWriter)
let segWriter = SegmentWriter(outputDir: outputDir, targetDuration: segmentDuration, isLive: isLive)

let writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
writer.outputFileTypeProfile = .mpeg4AppleHLS
writer.preferredOutputSegmentInterval = CMTime(seconds: segmentDuration, preferredTimescale: 600)
writer.initialSegmentStartTime = .zero
writer.delegate = segWriter

// Output at 30fps for faster encoding — OTA TV is typically 30fps source
let outputFPS = min(seqInfo.fps, 30.0)
let frameSkip = Int(round(seqInfo.fps / outputFPS))  // e.g., skip every other frame for 60→30
fputs("[gpu] Output: \(outputFPS)fps (skip \(frameSkip - 1) of every \(frameSkip) frames)\n", stderr)

let videoSettings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: seqInfo.width, AVVideoHeightKey: seqInfo.height,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitrate,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
        AVVideoMaxKeyFrameIntervalKey: Int(outputFPS * Double(segmentDuration)),
        AVVideoExpectedSourceFrameRateKey: outputFPS,
        "RealTime" as String: true,
        "AllowFrameReordering" as String: false,
    ]
]
let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
videoInput.expectsMediaDataInRealTime = true
writer.add(videoInput)

let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)

// Audio input — add upfront, AAC encode
let audioSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatMPEG4AAC,
    AVEncoderBitRateKey: 128_000,
    AVSampleRateKey: 48_000,
    AVNumberOfChannelsKey: 2,
]
let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
audioInput.expectsMediaDataInRealTime = true
writer.add(audioInput)

let tmpDir = outputDir.appendingPathComponent(".tmp")
try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
let audioTranscoder = AudioTranscoder(tempDir: tmpDir)

// Audio is appended to the writer when flushBatch() fires (after each segment).
var totalAudioDrained = 0
audioTranscoder.onAudioSample = { sample in
    if audioInput.isReadyForMoreMediaData {
        audioInput.append(sample)
        totalAudioDrained += 1
    }
}
func drainAudio() {
    audioTranscoder.flushBatch()
}

let writeOK = writer.startWriting()
fputs("[gpu] startWriting: \(writeOK), status: \(writer.status.rawValue), error: \(writer.error?.localizedDescription ?? "none")\n", stderr)
writer.startSession(atSourceTime: .zero)

// Frame queue for thread-safe handoff from decoder callback → writer
struct DecodedFrame {
    let pixelBuffer: CVPixelBuffer
    let pts90k: Int64
}
var frameQueue: [DecodedFrame] = []
let queueLock = NSLock()

var frameCount: Int64 = 0
var basePTS: Int64? = nil
var lastInputPTS: Int64 = 0
var lastOutputPTS: Int64 = 0
var lastWrittenCMPTS = CMTime.zero

decoder.onDecodedFrame = { pixelBuffer, pts90k in
    queueLock.lock()
    frameQueue.append(DecodedFrame(pixelBuffer: pixelBuffer, pts90k: pts90k))
    queueLock.unlock()
}

// Drain frame queue into writer (call from main thread)
// Sort by PTS to handle B-frame reordering
// Interleaves audio draining to keep the writer balanced — AVAssetWriter
// in HLS mode expects both audio and video to arrive together.
func drainFrames() {
    queueLock.lock()
    let allFrames = frameQueue.sorted { $0.pts90k < $1.pts90k }
    frameQueue = []
    queueLock.unlock()

    // Drop frames for fps reduction AFTER PTS sort so spacing stays even
    let frames: [DecodedFrame]
    if frameSkip > 1 {
        frames = allFrames.enumerated().compactMap { $0.offset % frameSkip == 0 ? $0.element : nil }
    } else {
        frames = allFrames
    }

    for (idx, frame) in frames.enumerated() {
        if frameCount == 0 {
            let w = CVPixelBufferGetWidth(frame.pixelBuffer)
            let h = CVPixelBufferGetHeight(frame.pixelBuffer)
            fputs("[gpu] First frame: \(w)x\(h)\n", stderr)
        }

        // Drain audio every ~30 video frames (~0.5s) to keep writer balanced
        if idx % 30 == 0 {
            drainAudio()
        }

        lastInputPTS = frame.pts90k

        let relativePTS = frame.pts90k - basePTS!
        lastOutputPTS = relativePTS
        let cmPTS = CMTime(value: CMTimeValue(relativePTS), timescale: 90000)

        // Wait for writer to be ready, bail if writer has failed
        var waitCount = 0
        while !videoInput.isReadyForMoreMediaData {
            if writer.status == .failed {
                fputs("[gpu] Writer failed: \(writer.error?.localizedDescription ?? "?")\n", stderr)
                return
            }
            drainAudio()
            waitCount += 1
            if waitCount > 2000 { // 2 seconds
                break
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        // Skip non-monotonic frames (B-frame reorder artifacts across drain batches)
        if CMTimeCompare(cmPTS, lastWrittenCMPTS) <= 0 {
            continue
        }
        guard videoInput.isReadyForMoreMediaData else { continue }
        let ok = adaptor.append(frame.pixelBuffer, withPresentationTime: cmPTS)
        if ok {
            lastWrittenCMPTS = cmPTS
        } else {
            fputs("[gpu] Append failed at frame \(frameCount) pts=\(cmPTS.seconds)s lastWritten=\(lastWrittenCMPTS.seconds)s. Writer: \(writer.status.rawValue), error: \(writer.error?.localizedDescription ?? "?")\n", stderr)
            break  // Writer is dead, stop trying
        }
        frameCount += 1
        if frameCount % 300 == 0 {
            fputs("[gpu] \(frameCount) frames (\(String(format: "%.1f", cmPTS.seconds))s)\n", stderr)
        }
    }
}

// Connect demuxer → frame assembler → decoder
let assembler = MPEG2FrameAssembler()
assembler.onFrame = { frameData, pts in
    decoder.decode(frameData: frameData, pts: pts ?? 0)
}

// Reset demuxer for continuous processing (reuse PIDs already discovered)
let demuxer2 = TSDemuxer()
demuxer2.pmtPID = demuxer.pmtPID
demuxer2.videoPID = demuxer.videoPID
demuxer2.audioPID = demuxer.audioPID
demuxer2.videoStreamType = demuxer.videoStreamType
demuxer2.audioStreamType = demuxer.audioStreamType

demuxer2.onPESPacket = { pes in
    // Set basePTS from the first PES with a valid PTS (audio or video)
    if basePTS == nil, let pts = pes.pts, pts > 0 {
        basePTS = pts
        lastInputPTS = pts
        fputs("[gpu] basePTS set from first PES: \(pts) (\(Double(pts)/90000.0)s)\n", stderr)
    }

    if pes.streamType == STREAM_TYPE_MPEG2_VIDEO {
        assembler.feed(esData: pes.data, pts: pes.pts)
    } else if pes.pid == demuxer2.audioPID {
        if let pts = pes.pts {
            audioTranscoder.lastPTS = pts
        }
        guard audioTranscoder.lastPTS > 0 else { return }
        if audioTranscoder.totalFramesDecoded < 5 {
            let frames = AC3AudioDecoder.findSyncFrames(in: pes.data)
            fputs("[audio] PES: \(pes.data.count) bytes, \(frames.count) AC3 frames, pts=\(pes.pts ?? -1)\n", stderr)
        }
        audioTranscoder.decodePES(data: pes.data, pts: audioTranscoder.lastPTS, basePTS: basePTS ?? 0)
        // Note: decodePES() advances lastPTS internally after processing all frames
    }
}

// Don't process initial data separately — the main loop will handle everything
// Only mark segments BEFORE liveStartIndex as known (skip them)
var knownKeys = Set<String>()
for i in 0..<liveStartIndex {
    let seg = allSegments[i]
    knownKeys.insert("\(seg.uri):\(seg.byteRangeOffset ?? 0):\(seg.byteRangeLength ?? 0)")
}

fputs("[gpu] Entering \(isLive ? "live" : "recording") loop...\n", stderr)

if isLive {
    // Live: poll for new segments. Rewind buffer grows as the stream continues.
    while true {
        do {
            let (plData, _) = try await URLSession.shared.data(from: mediaPlaylistURL)
            let currentSegments = parseMediaPlaylist(data: plData)

            for seg in currentSegments {
                let key = "\(seg.uri):\(seg.byteRangeOffset ?? 0):\(seg.byteRangeLength ?? 0)"
                if knownKeys.contains(key) { continue }
                knownKeys.insert(key)
                let data = try await downloadSegmentData(baseURL: mediaPlaylistURL, segment: seg)
                demuxer2.demux(data: data)
                demuxer2.flush()
                decoder.flush()
                drainFrames()
                drainAudio()
            }
        } catch {
            fputs("[gpu] Poll error: \(error.localizedDescription)\n", stderr)
        }

        try await Task.sleep(nanoseconds: 250_000_000)
    }
} else {
    // Recording: download and transcode everything as fast as possible
    // Re-fetch playlist to get all segments (it may have grown)
    let (plData, _) = try await URLSession.shared.data(from: mediaPlaylistURL)
    let recSegments = parseMediaPlaylist(data: plData)
    fputs("[gpu] Recording: \(recSegments.count) total segments to process\n", stderr)

    // Download segments in concurrent batches for speed, then demux+drain sequentially.
    // Flush audio every few segments to keep writer interleaved.
    let batchSize = 16  // concurrent downloads per batch
    let flushInterval = 4  // flush audio/video every N segments
    var processed = 0
    var segIndex = 0
    let totalSegs = recSegments.count
    let startTime = Date()

    while segIndex < totalSegs {
        // Download a batch of segments concurrently
        let batchEnd = min(segIndex + batchSize, totalSegs)
        var downloadTasks: [(index: Int, task: Task<Data?, Error>)] = []
        for i in segIndex..<batchEnd {
            let seg = recSegments[i]
            let key = "\(seg.uri):\(seg.byteRangeOffset ?? 0):\(seg.byteRangeLength ?? 0)"
            if knownKeys.contains(key) { continue }
            knownKeys.insert(key)
            let baseURL = mediaPlaylistURL
            downloadTasks.append((i, Task { try await downloadSegmentData(baseURL: baseURL, segment: seg) }))
        }

        // Process downloaded segments in order
        for (_, task) in downloadTasks {
            guard let data = try await task.value else { continue }
            demuxer2.demux(data: data)
            processed += 1

            if processed % flushInterval == 0 {
                demuxer2.flush()
                decoder.flush()
                drainFrames()
                drainAudio()
            }
        }

        // Flush any remaining after each batch
        demuxer2.flush()
        decoder.flush()
        drainFrames()
        drainAudio()

        segIndex = batchEnd

        // Progress line
        let elapsed = Date().timeIntervalSince(startTime)
        let pct = Double(processed) / Double(totalSegs) * 100
        let segsPerSec = elapsed > 0 ? Double(processed) / elapsed : 0
        let remaining = segsPerSec > 0 ? Double(totalSegs - processed) / segsPerSec : 0
        let outSecs = Double(segWriter.segmentIndex) * segmentDuration
        fputs("\r[gpu] \(processed)/\(totalSegs) segs (\(String(format: "%.0f", pct))%) | \(segWriter.segmentIndex) output segs (\(String(format: "%.0f", outSecs))s) | \(String(format: "%.1f", segsPerSec)) seg/s | ETA \(String(format: "%.0f", remaining))s   ", stderr)
    }
    fputs("\n", stderr)

    // Final flush
    demuxer2.flush()
    assembler.flush()
    decoder.flush()
    drainFrames()
    drainAudio()
    segWriter.writePlaylist(finished: true)
    fputs("[gpu] Recording complete: \(frameCount) frames, \(segWriter.segmentIndex) output segments\n", stderr)

    // Keep running so the server can serve the files
    while true {
        try await Task.sleep(nanoseconds: 5_000_000_000)
    }
}
