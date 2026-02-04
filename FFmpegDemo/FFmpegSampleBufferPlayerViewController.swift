//
//  FFmpegSampleBufferPlayerViewController.swift
//  FFmpegDemo
//
//  Created by yite on 2026/2/4.
//


import UIKit
import AVFoundation

//使用displayLayer显示画面，性能会更高一些
class FFmpegSampleBufferPlayerViewController: UIViewController {

    var urlString: String!

    private let displayLayer = AVSampleBufferDisplayLayer()
    private let decodeQueue = DispatchQueue(label: "ffmpeg.decode.queue")

    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var videoStream: UnsafeMutablePointer<AVStream>?
    private var videoStreamIndex: Int32 = -1

    private var swsCtx: OpaquePointer?

    private var lastPTS: CMTime = .zero

    // FFmpeg 宏
    private let AV_NOPTS_VALUE = Int64(bitPattern: 0x8000000000000000)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupLayer()
        startPlay()
    }

    deinit {
        stopPlay()
    }
}

// MARK: - Layer Setup
private extension FFmpegSampleBufferPlayerViewController {
    func setupLayer() {
        displayLayer.frame = view.bounds
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(displayLayer)
    }
}

// MARK: - Play Control
private extension FFmpegSampleBufferPlayerViewController {

    func startPlay() {
        decodeQueue.async { [weak self] in
            self?.openInput()
            self?.decodeLoop()
        }
    }

    func stopPlay() {
        displayLayer.flushAndRemoveImage()

        if let _ = codecCtx {
            avcodec_free_context(&codecCtx)
        }
        if let _ = formatCtx {
            avformat_close_input(&formatCtx)
        }
        if let swsCtx = swsCtx {
            sws_freeContext(swsCtx)
        }
        avformat_network_deinit()
    }
}

// MARK: - FFmpeg Core
private extension FFmpegSampleBufferPlayerViewController {

    func openInput() {
        avformat_network_init()
        formatCtx = avformat_alloc_context()
        guard let formatCtx = formatCtx,
              avformat_open_input(&self.formatCtx, urlString, nil, nil) >= 0,
              avformat_find_stream_info(formatCtx, nil) >= 0 else {
            print("❌ open input failed")
            return
        }

        for i in 0..<formatCtx.pointee.nb_streams {
            guard let stream = formatCtx.pointee.streams[Int(i)] else { continue }
            if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                videoStreamIndex = Int32(i)
                videoStream = stream
                break
            }
        }

        guard let videoStream = videoStream else {
            print("❌ no video stream")
            return
        }

        guard let codecPar = videoStream.pointee.codecpar,
              let codec = avcodec_find_decoder(codecPar.pointee.codec_id) else { return }

        codecCtx = avcodec_alloc_context3(codec)
        guard let codecCtx = codecCtx,
              avcodec_parameters_to_context(codecCtx, codecPar) >= 0,
              avcodec_open2(codecCtx, codec, nil) >= 0 else {
            print("❌ open codec failed")
            return
        }

        // sws context: YUV420P -> NV12
        swsCtx = sws_getContext(
            codecCtx.pointee.width,
            codecCtx.pointee.height,
            codecCtx.pointee.pix_fmt,
            codecCtx.pointee.width,
            codecCtx.pointee.height,
            AV_PIX_FMT_NV12,
            SWS_BILINEAR,
            nil, nil, nil
        )
        if swsCtx == nil {
            print("❌ sws_getContext failed")
        }
    }

    func decodeLoop() {
        guard let codecCtx = codecCtx, let videoStream = videoStream, let swsCtx = swsCtx else { return }

        // Optional 指针
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard let packetUnwrapped = packet, let frameUnwrapped = frame else { return }

        let width = codecCtx.pointee.width
        let height = codecCtx.pointee.height

        // ✅ 正确分配 Y/UV 两个平面
        let ySize = width * height
        let uvSize = width * height / 2
        let bufferY = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(ySize))
        let bufferUV = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(uvSize))
        var dstData: [UnsafeMutablePointer<UInt8>?] = [bufferY, bufferUV, nil, nil]
        var dstLinesize: [Int32] = [Int32(width), Int32(width), 0, 0] // NV12 UV 每行 width 字节

        while av_read_frame(formatCtx, packetUnwrapped) >= 0 {
            if packetUnwrapped.pointee.stream_index == videoStreamIndex {
                avcodec_send_packet(codecCtx, packetUnwrapped)
                while avcodec_receive_frame(codecCtx, frameUnwrapped) == 0 {

                    let srcData: [UnsafePointer<UInt8>?] = [
                        frameUnwrapped.pointee.data.0.map { UnsafePointer($0) },
                        frameUnwrapped.pointee.data.1.map { UnsafePointer($0) },
                        frameUnwrapped.pointee.data.2.map { UnsafePointer($0) },
                        frameUnwrapped.pointee.data.3.map { UnsafePointer($0) },
                        frameUnwrapped.pointee.data.4.map { UnsafePointer($0) },
                        frameUnwrapped.pointee.data.5.map { UnsafePointer($0) },
                        frameUnwrapped.pointee.data.6.map { UnsafePointer($0) },
                        frameUnwrapped.pointee.data.7.map { UnsafePointer($0) }
                    ]

                    let srcLinesize: [Int32] = [
                        frameUnwrapped.pointee.linesize.0,
                        frameUnwrapped.pointee.linesize.1,
                        frameUnwrapped.pointee.linesize.2,
                        frameUnwrapped.pointee.linesize.3,
                        frameUnwrapped.pointee.linesize.4,
                        frameUnwrapped.pointee.linesize.5,
                        frameUnwrapped.pointee.linesize.6,
                        frameUnwrapped.pointee.linesize.7
                    ]

                    sws_scale(
                        swsCtx,
                        srcData,
                        srcLinesize,
                        0,
                        Int32(height),
                        dstData,
                        dstLinesize
                    )

                    guard let pixelBuffer = createPixelBuffer(width: Int(width), height: Int(height)) else { continue }
                    copyNV12ToPixelBuffer(dstData: dstData, dstLinesize: dstLinesize, pixelBuffer: pixelBuffer)

                    guard let formatDesc = createFormatDesc(pixelBuffer),
                          let sampleBuffer = createSampleBuffer(pixelBuffer: pixelBuffer,
                                                                formatDesc: formatDesc,
                                                                frame: frameUnwrapped,
                                                                stream: videoStream) else { continue }

                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if self.displayLayer.isReadyForMoreMediaData {
                            self.displayLayer.enqueue(sampleBuffer)
                        }
                    }
                }
            }
            av_packet_unref(packetUnwrapped)
        }

        // ✅ 释放 buffer 和 FFmpeg 资源
        bufferY.deallocate()
        bufferUV.deallocate()
        av_frame_free(&frame)
        av_packet_free(&packet)
    }

}

// MARK: - PixelBuffer & SampleBuffer
private extension FFmpegSampleBufferPlayerViewController {

    func createPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            attrs as CFDictionary, &buffer)
        return buffer
    }

    func copyNV12ToPixelBuffer(dstData: [UnsafeMutablePointer<UInt8>?], dstLinesize: [Int32], pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])

        guard let yDest = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvDest = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            return
        }

        let height = CVPixelBufferGetHeight(pixelBuffer)
        let uvHeight = height / 2

        // 拷贝 Y plane
        memcpy(yDest, dstData[0]!, Int(dstLinesize[0] * Int32(height)))
        // 拷贝 UV plane
        memcpy(uvDest, dstData[1]!, Int(dstLinesize[1] * Int32(uvHeight)))

        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }


    func createFormatDesc(_ pixelBuffer: CVPixelBuffer) -> CMVideoFormatDescription? {
        var desc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &desc
        )
        return desc
    }

    func createSampleBuffer(pixelBuffer: CVPixelBuffer, formatDesc: CMVideoFormatDescription, frame: UnsafeMutablePointer<AVFrame>, stream: UnsafeMutablePointer<AVStream>) -> CMSampleBuffer? {

        var pts = frame.pointee.best_effort_timestamp
        if pts == AV_NOPTS_VALUE { pts = 0 }

        let seconds = Double(pts) * av_q2d(stream.pointee.time_base)
        var time = CMTime(seconds: seconds, preferredTimescale: 600)

        if time <= lastPTS { time = lastPTS + CMTime(value: 1, timescale: 600) }
        lastPTS = time

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer
    }
}
