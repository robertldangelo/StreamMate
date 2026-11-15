import AVFoundation
import CoreMedia
import Foundation

/// Encodes captured PCM audio to AAC-LC frames with ADTS headers.
final class AudioEncoder {
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var inputFormat: AVAudioFormat?
    private var anchor: CMTime?
    private var packetsOut: Int64 = 0
    private var framesIn: Int64 = 0
    private var sampleRate: Double = 48000
    private var channels: Int = 2
    private(set) var failed = false

    /// (ADTS frame, presentation time)
    var onFrame: ((Data, CMTime) -> Void)?
    var onError: ((String) -> Void)?

    func encode(_ sampleBuffer: CMSampleBuffer) {
        if failed { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
                      let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame),
                      let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
                else { return }
                self.process(pcm, format: format, pts: pts)
            }
        } catch {
            fail("audio buffer error: \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) {
        if failed { return }
        failed = true
        onError?(message)
    }

    private func setup(_ format: AVAudioFormat) -> Bool {
        sampleRate = format.sampleRate
        channels = Int(format.channelCount)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        guard let out = AVAudioFormat(settings: settings),
              let conv = AVAudioConverter(from: format, to: out) else {
            fail("could not create AAC encoder")
            return false
        }
        conv.bitRate = 160_000
        converter = conv
        outputFormat = out
        inputFormat = format
        return true
    }

    private func process(_ pcm: AVAudioPCMBuffer, format: AVAudioFormat, pts: CMTime) {
        if converter == nil || inputFormat != format {
            if !setup(format) { return }
            anchor = nil
            packetsOut = 0
            framesIn = 0
        }
        guard let conv = converter, let outFormat = outputFormat else { return }

        // Keep audio timestamps continuous, but re-anchor after a gap.
        let scale = CMTimeScale(sampleRate)
        if let a = anchor {
            let expected = CMTimeAdd(a, CMTime(value: framesIn, timescale: scale))
            let drift = CMTimeGetSeconds(CMTimeSubtract(pts, expected))
            if abs(drift) > 0.1 {
                anchor = CMTimeSubtract(pts, CMTime(value: packetsOut * 1024, timescale: scale))
                framesIn = packetsOut * 1024
            }
        } else {
            anchor = pts
        }
        framesIn += Int64(pcm.frameLength)

        var supplied = false
        while true {
            let out = AVAudioCompressedBuffer(format: outFormat, packetCapacity: 8, maximumPacketSize: max(conv.maximumOutputPacketSize, 2048))
            var error: NSError?
            let status = conv.convert(to: out, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return pcm
            }
            if status == .error {
                fail("AAC encode error: \(error?.localizedDescription ?? "unknown")")
                return
            }
            emit(out)
            if status != .haveData { break }
        }
    }

    private func emit(_ buffer: AVAudioCompressedBuffer) {
        let count = Int(buffer.packetCount)
        guard count > 0, let descriptions = buffer.packetDescriptions, let a = anchor else { return }
        let scale = CMTimeScale(sampleRate)
        for i in 0..<count {
            let d = descriptions[i]
            let size = Int(d.mDataByteSize)
            if size <= 0 { continue }
            var frame = adtsHeader(payloadSize: size)
            frame.append(Data(bytes: buffer.data.advanced(by: Int(d.mStartOffset)), count: size))
            let pts = CMTimeAdd(a, CMTime(value: packetsOut * 1024, timescale: scale))
            packetsOut += 1
            onFrame?(frame, pts)
        }
    }

    private func adtsHeader(payloadSize: Int) -> Data {
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000]
        let freqIndex = UInt8(rates.firstIndex(of: sampleRate) ?? 3)
        let ch = UInt8(channels)
        let full = payloadSize + 7
        var h = [UInt8](repeating: 0, count: 7)
        h[0] = 0xFF
        h[1] = 0xF1
        h[2] = (1 << 6) | (freqIndex << 2) | (ch >> 2)  // AAC-LC
        h[3] = ((ch & 3) << 6) | UInt8((full >> 11) & 0x03)
        h[4] = UInt8((full >> 3) & 0xFF)
        h[5] = UInt8((full & 0x07) << 5) | 0x1F
        h[6] = 0xFC
        return Data(h)
    }
}
