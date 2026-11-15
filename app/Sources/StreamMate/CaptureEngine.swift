import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures a display or window, encodes it and feeds the stream server.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var video: VideoEncoder?
    private var audio: AudioEncoder?
    private var muxer: TSMuxer?
    private weak var server: StreamServer?

    private let sampleQueue = DispatchQueue(label: "streammate.video")
    private let audioQueue = DispatchQueue(label: "streammate.audio")
    private let muxQueue = DispatchQueue(label: "streammate.mux")

    private var timer: DispatchSourceTimer?
    private var lastBuffer: CVPixelBuffer?
    private var lastFrameAt = CMTime.zero

    private var base: CMTime?
    private var sawKeyframe = false
    private var lastVideoTS: UInt64 = 0

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?

    var onError: ((String) -> Void)?

    func start(filter: SCContentFilter, width: Int, height: Int, fps: Int, bitrate: Int,
               includeAudio: Bool, sourceRect: CGRect?, server: StreamServer) async throws {
        self.server = server
        guard let encoder = VideoEncoder(width: width, height: height, bitrate: bitrate, fps: fps) else {
            throw NSError(domain: "StreamMate", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not start the video encoder."])
        }
        let mux = TSMuxer(hasAudio: includeAudio)
        video = encoder
        muxer = mux
        base = nil
        sawKeyframe = false
        lastVideoTS = 0

        encoder.onFrame = { [weak self] data, pts, key in
            self?.muxQueue.async { self?.muxVideo(data, pts: pts, key: key) }
        }
        server.onNeedKeyframe = { [weak encoder] in
            encoder?.forceKeyframe()
        }

        if includeAudio {
            let a = AudioEncoder()
            a.onFrame = { [weak self] data, pts in
                self?.muxQueue.async { self?.muxAudio(data, pts: pts) }
            }
            a.onError = { [weak self] message in
                self?.onError?("Audio: \(message)")
            }
            audio = a
        } else {
            audio = nil
        }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.scalesToFit = true
        if let rect = sourceRect {
            config.sourceRect = rect
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 6
        config.backgroundColor = CGColor.black
        if includeAudio {
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if includeAudio {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await s.startCapture()
        stream = s

        // A still screen produces no new frames, so repeat the last one to keep the stream alive.
        let t = DispatchSource.makeTimerSource(queue: sampleQueue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.1)
        t.setEventHandler { [weak self] in
            guard let self = self, let pb = self.lastBuffer else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            if CMTimeGetSeconds(CMTimeSubtract(now, self.lastFrameAt)) > 0.09 {
                self.lastFrameAt = now
                self.video?.encode(pb, pts: now)
            }
        }
        t.resume()
        timer = t
    }

    func stop() async {
        timer?.cancel()
        timer = nil
        if let s = stream {
            try? await s.stopCapture()
        }
        stream = nil
        sampleQueue.sync {
            self.lastBuffer = nil
            self.pool = nil
            self.video?.invalidate()
            self.video = nil
        }
        audio = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[SCStreamFrameInfo.status] as? Int,
                  let status = SCFrameStatus(rawValue: raw), status == .complete,
                  let captured = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pb = centred(captured, info: attachments.first ?? [:])
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            lastBuffer = pb
            lastFrameAt = CMClockGetTime(CMClockGetHostTimeClock())
            video?.encode(pb, pts: pts)
        case .audio:
            audio?.encode(sampleBuffer)
        default:
            break
        }
    }

    // MARK: Centring

    /// ScreenCaptureKit puts content that is not 16:9 in the top-left corner of the frame.
    /// This redraws it scaled to fit and centred on a black 16:9 frame.
    private func centred(_ pb: CVPixelBuffer, info: [SCStreamFrameInfo: Any]) -> CVPixelBuffer {
        let bw = CGFloat(CVPixelBufferGetWidth(pb))
        let bh = CGFloat(CVPixelBufferGetHeight(pb))
        guard let dict = info[SCStreamFrameInfo.contentRect] as? NSDictionary,
              let raw = CGRect(dictionaryRepresentation: dict as CFDictionary),
              raw.width > 1, raw.height > 1 else { return pb }
        let scale = CGFloat((info[SCStreamFrameInfo.scaleFactor] as? NSNumber)?.doubleValue ?? 1)
        let bounds = CGRect(x: -1, y: -1, width: bw + 2, height: bh + 2)
        let scaled = CGRect(x: raw.minX * scale, y: raw.minY * scale, width: raw.width * scale, height: raw.height * scale)
        var content = raw
        if scale != 1, bounds.contains(scaled) { content = scaled }
        guard bounds.contains(content) else { return pb }
        content = content.intersection(CGRect(x: 0, y: 0, width: bw, height: bh))
        if content.width >= bw - 2 && content.height >= bh - 2 { return pb }  // already fills the frame

        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: Int(bw),
                kCVPixelBufferHeightKey as String: Int(bh),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &created)
            pool = created
        }
        guard let p = pool else { return pb }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, p, &made)
        guard let out = made else { return pb }

        // Core Image's origin is bottom-left; the content rectangle's is top-left.
        let crop = CGRect(x: content.minX, y: bh - content.maxY, width: content.width, height: content.height)
        let fit = min(bw / crop.width, bh / crop.height)
        let image = CIImage(cvPixelBuffer: pb)
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: fit, y: fit))
            .transformed(by: CGAffineTransform(translationX: (bw - crop.width * fit) / 2, y: (bh - crop.height * fit) / 2))
        let canvas = CGRect(x: 0, y: 0, width: bw, height: bh)
        let background = CIImage(color: CIColor.black).cropped(to: canvas)
        ciContext.render(image.composited(over: background).cropped(to: canvas), to: out)
        return out
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("Capture stopped: \(error.localizedDescription)")
    }

    // MARK: Muxing (muxQueue only)

    private func timestamp(_ t: CMTime) -> UInt64? {
        if base == nil { base = t }
        guard let b = base else { return nil }
        let seconds = CMTimeGetSeconds(CMTimeSubtract(t, b)) + 1.0
        if !seconds.isFinite || seconds < 0 { return nil }
        return UInt64(seconds * 90000)
    }

    private func muxVideo(_ data: Data, pts: CMTime, key: Bool) {
        guard let mux = muxer else { return }
        if !sawKeyframe {
            if !key { return }
            sawKeyframe = true
        }
        guard var ts = timestamp(pts) else { return }
        if ts <= lastVideoTS { ts = lastVideoTS + 1 }
        lastVideoTS = ts
        var out: [UInt8] = []
        if key { out = mux.tables() }
        out.append(contentsOf: mux.video(data, pts: ts, keyframe: key))
        server?.broadcast(out, startsWithKeyframe: key)
    }

    private func muxAudio(_ data: Data, pts: CMTime) {
        guard let mux = muxer, mux.hasAudio, sawKeyframe, let ts = timestamp(pts) else { return }
        server?.broadcast(mux.audio(data, pts: ts), startsWithKeyframe: false)
    }
}
