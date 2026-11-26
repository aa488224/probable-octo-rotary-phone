import Foundation
import AVFoundation
import CoreMedia

/// Decodes an H.264 (AVCC length-prefixed) byte stream using the system hardware decoder
/// via AVSampleBufferDisplayLayer. Works on iOS 15 / A9 (iPhone 6s Plus).
final class H264Renderer {

    let layer = AVSampleBufferDisplayLayer()
    private var formatDescription: CMVideoFormatDescription?
    private var waitingForKeyframe = true
    private var size = CGSize(width: 0, height: 0)

    /// Feed the `description` field from CarWithin's `format` message (base64 avcC).
    /// Returns false if the description could not be parsed.
    func configure(descriptionBase64: String, width: Int, height: Int) -> Bool {
        guard let avcC = Data(base64Encoded: descriptionBase64) else { return false }
        guard let (sps, pps) = H264Renderer.parseAVCC(avcC) else { return false }

        var desc: CMVideoFormatDescription?
        var sizes = [sps.count, pps.count]
        let status: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                var pointers: [UnsafePointer<UInt8>] = [
                    spsRaw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                ]
                return pointers.withUnsafeMutableBufferPointer { ptrs in
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: ptrs.baseAddress!,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &desc
                    )
                }
            }
        }
        guard status == noErr, let format = desc else { return false }

        layer.flushAndRemoveImage()
        formatDescription = format
        size = CGSize(width: width, height: height)
        waitingForKeyframe = true
        return true
    }

    /// Enqueue one AVCC sample. `data` is the bytes after the 9-byte CarWithin packet header.
    /// `timestampUs` is the big-endian microsecond timestamp from the packet.
    /// Returns true if the sample was submitted.
    func enqueue(avcc data: Data, timestampUs: UInt64, keyframe: Bool) -> Bool {
        guard let format = formatDescription else { return false }

        if waitingForKeyframe {
            if !keyframe { return false }
            waitingForKeyframe = false
        }

        let timing = CMSampleTimingInfo(
            duration: CMTimeMake(value: 1500, timescale: 90000),
            presentationTimeStamp: CMTimeMake(value: Int64(timestampUs), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )

        let count = data.count

        // Let CoreMedia allocate and COPY the bytes. AVSampleBufferDisplayLayer
        // decodes asynchronously, so handing it a pointer we free here would
        // cause corruption; the copy keeps the sample valid until decoding ends.
        var block: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: count,
            flags: 0,
            blockBufferOut: &block
        )
        guard blockStatus == kCMBlockBufferNoErr, let bb = block else { return false }

        // Ask CoreMedia for its own buffer, then copy our bytes into it. This way
        // the block buffer owns the memory and stays valid through async decode.
        var dest: UnsafeMutablePointer<Int8>?
        var available = 0
        let ptrStatus = CMBlockBufferGetDataPointer(
            bb, offset: 0, lengthAtOffsetOut: &available,
            totalLengthOut: nil, dataPointerOut: &dest
        )
        guard ptrStatus == kCMBlockBufferNoErr, let p = dest, available >= count else { return false }
        data.copyBytes(to: UnsafeMutableRawBufferPointer(start: p, count: count), count: count)

        let sample: CMSampleBuffer?
        do {
            sample = try CMSampleBuffer(
                dataBuffer: bb,
                formatDescription: format,
                numSamples: 1,
                sampleTimings: [timing],
                sampleSizes: [count]
            )
        } catch {
            return false
        }
        guard let s = sample else { return false }

        if layer.status == .failed {
            layer.flushAndRemoveImage()
        }
        layer.enqueue(s)
        return true
    }

    func reset() {
        layer.flushAndRemoveImage()
        formatDescription = nil
        waitingForKeyframe = true
    }

    /// Parse avcC -> (SPS including start code, PPS including start code)
    private static func parseAVCC(_ avcC: Data) -> (Data, Data)? {
        let b = [UInt8](avcC)
        guard b.count >= 7, b[0] == 1 else { return nil }
        var offset = 5
        let spsCount = Int(b[offset] & 0x1F); offset += 1
        guard spsCount >= 1 else { return nil }
        guard offset + 2 <= b.count else { return nil }
        let spsLen = Int(b[offset]) << 8 | Int(b[offset + 1]); offset += 2
        guard offset + spsLen <= b.count else { return nil }
        var sps = [UInt8](b[offset..<(offset + spsLen)]); offset += spsLen

        guard offset + 1 <= b.count else { return nil }
        let ppsCount = Int(b[offset]); offset += 1
        guard ppsCount >= 1, offset + 2 <= b.count else { return nil }
        let ppsLen = Int(b[offset]) << 8 | Int(b[offset + 1]); offset += 2
        guard offset + ppsLen <= b.count else { return nil }
        var pps = [UInt8](b[offset..<(offset + ppsLen)])

        sps.insert(contentsOf: [0, 0, 0, 1], at: 0)
        pps.insert(contentsOf: [0, 0, 0, 1], at: 0)
        return (Data(sps), Data(pps))
    }
}
