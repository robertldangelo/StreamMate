import CoreMedia
import Foundation
import VideoToolbox

/// Hardware H.264 encoder. Emits one Annex B access unit per frame.
final class VideoEncoder {
    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var wantKeyframe = true

    /// (access unit in Annex B, presentation time, is keyframe)
    var onFrame: ((Data, CMTime, Bool) -> Void)?

    init?(width: Int, height: Int, bitrate: Int, fps: Int) {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created)
        guard status == noErr, let s = created else { return nil }
        session = s
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 2))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2))
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    func forceKeyframe() {
        lock.lock()
        wantKeyframe = true
        lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let s = session else { return }
        lock.lock()
        let key = wantKeyframe
        wantKeyframe = false
        lock.unlock()
        var props: CFDictionary?
        if key {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(
            s,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: CMTime.invalid,
            frameProperties: props,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sb = sampleBuffer, let self = self else { return }
            self.handle(sb)
        }
    }

    func invalidate() {
        if let s = session {
            VTCompressionSessionInvalidate(s)
        }
        session = nil
    }

    private func handle(_ sb: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sb),
              let format = CMSampleBufferGetFormatDescription(sb) else { return }

        var isKey = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let first = arr.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }

        let length = CMBlockBufferGetDataLength(block)
        guard length > 4 else { return }
        var avcc = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &avcc) == noErr else { return }

        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        var out = Data(capacity: length + 128)
        out.append(contentsOf: startCode)
        out.append(contentsOf: [0x09, 0xF0])  // access unit delimiter

        if isKey {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if st == noErr, let p = ptr, size > 0 {
                    out.append(contentsOf: startCode)
                    out.append(p, count: size)
                }
            }
        }

        // Convert length-prefixed NAL units to Annex B.
        var offset = 0
        while offset + 4 <= length {
            let n = (Int(avcc[offset]) << 24) | (Int(avcc[offset + 1]) << 16)
                | (Int(avcc[offset + 2]) << 8) | Int(avcc[offset + 3])
            offset += 4
            if n <= 0 || offset + n > length { break }
            out.append(contentsOf: startCode)
            out.append(contentsOf: avcc[offset..<(offset + n)])
            offset += n
        }

        onFrame?(out, CMSampleBufferGetPresentationTimeStamp(sb), isKey)
    }
}
