// SPDX-License-Identifier: GPL-3.0-or-later
// 用系统硬解码（AVSampleBufferDisplayLayer）显示远端 H.264 画面，A9/iOS 15 可用。
import Foundation
import UIKit
import AVFoundation
import CoreMedia

final class RemoteScreenRenderer {

    let layer = AVSampleBufferDisplayLayer()
    private var formatDescription: CMVideoFormatDescription?
    private var waitingForKeyframe = true
    private(set) var videoSize = CGSize.zero

    var onNeedsKeyframe: (() -> Void)?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
    }

    /// 用主机 `format` 消息里的 base64 avcC 建立解码格式。
    func configure(descriptionBase64: String, width: Int, height: Int) -> Bool {
        guard let avcC = Data(base64Encoded: descriptionBase64), let (sps, pps) = Self.parseAVCC(avcC) else {
            return false
        }
        // 空参数集会拿到 nil 指针，之前直接强解包，格式异常就崩。
        guard !sps.isEmpty, !pps.isEmpty else { return false }
        var description: CMVideoFormatDescription?
        var sizes = [sps.count, pps.count]
        let status: OSStatus = sps.withUnsafeBytes { spsRaw -> OSStatus in
            guard let spsBase = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return pps.withUnsafeBytes { ppsRaw -> OSStatus in
                guard let ppsBase = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                var pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                return pointers.withUnsafeMutableBufferPointer { buffer -> OSStatus in
                    guard let base = buffer.baseAddress else { return -1 }
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 2,
                        parameterSetPointers: base, parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4, formatDescriptionOut: &description)
                }
            }
        }
        guard status == noErr, let description else { return false }
        layer.flushAndRemoveImage()
        formatDescription = description
        videoSize = CGSize(width: width, height: height)
        waitingForKeyframe = true
        return true
    }

    /// 送入一帧 AVCC 样本（长度前缀 NAL）。解码器重启后只接受关键帧。
    @discardableResult
    func enqueue(avcc data: Data, timestampUs: UInt64, keyframe: Bool) -> Bool {
        guard let format = formatDescription, !data.isEmpty else { return false }
        if waitingForKeyframe {
            guard keyframe else { return false }
            waitingForKeyframe = false
        }
        if layer.status == .failed { flushAndAskForKeyframe(); return false }

        let count = data.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
            let block else { return false }
        var destination: UnsafeMutablePointer<Int8>?
        var available = 0
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &available,
            totalLengthOut: nil, dataPointerOut: &destination) == kCMBlockBufferNoErr,
            let destination, available >= count else { return false }
        data.copyBytes(to: UnsafeMutableRawBufferPointer(start: destination, count: count), count: count)

        let timing = CMSampleTimingInfo(duration: CMTimeMake(value: 1500, timescale: 90_000),
            presentationTimeStamp: CMTimeMake(value: Int64(timestampUs), timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        guard let sample = try? CMSampleBuffer(dataBuffer: block, formatDescription: format,
            numSamples: 1, sampleTimings: [timing], sampleSizes: [count]) else { return false }
        layer.enqueue(sample)
        return true
    }

    func flushAndAskForKeyframe() {
        layer.flushAndRemoveImage()
        waitingForKeyframe = true
        onNeedsKeyframe?()
    }

    func reset() {
        layer.flushAndRemoveImage()
        formatDescription = nil
        videoSize = .zero
        waitingForKeyframe = true
    }

    /// avcC → 带起始码的 SPS/PPS。
    private static func parseAVCC(_ avcC: Data) -> (Data, Data)? {
        let bytes = [UInt8](avcC)
        guard bytes.count >= 8, bytes[0] == 1 else { return nil }
        var offset = 5
        let spsCount = Int(bytes[offset] & 0x1f); offset += 1
        guard spsCount >= 1, offset + 2 <= bytes.count else { return nil }
        let spsLength = Int(bytes[offset]) << 8 | Int(bytes[offset + 1]); offset += 2
        guard offset + spsLength <= bytes.count else { return nil }
        var sps = Array(bytes[offset..<(offset + spsLength)]); offset += spsLength
        guard offset + 3 <= bytes.count else { return nil }
        let ppsCount = Int(bytes[offset]); offset += 1
        guard ppsCount >= 1 else { return nil }
        let ppsLength = Int(bytes[offset]) << 8 | Int(bytes[offset + 1]); offset += 2
        guard offset + ppsLength <= bytes.count else { return nil }
        var pps = Array(bytes[offset..<(offset + ppsLength)])
        sps.insert(contentsOf: [0, 0, 0, 1], at: 0)
        pps.insert(contentsOf: [0, 0, 0, 1], at: 0)
        return (Data(sps), Data(pps))
    }
}
