import UIKit
import AVFoundation
import VideoToolbox

class FFmpegVTPlayerViewController: UIViewController {

    var urlString: String!

    private let displayLayer = AVSampleBufferDisplayLayer()
    private let decodeQueue = DispatchQueue(label: "ffmpeg.decode.queue")

    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var videoStreamIndex: Int32 = -1
    private var videoStream: UnsafeMutablePointer<AVStream>?
    private var hwDeviceCtx: UnsafeMutablePointer<AVBufferRef>?

    // 播放起始时间
    private var playbackStartTime: CFAbsoluteTime = 0
    private var firstPTS: CMTime = .zero

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
private extension FFmpegVTPlayerViewController {
    func setupLayer() {
        displayLayer.frame = view.bounds
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(displayLayer)
    }
}

// MARK: - Play Control
private extension FFmpegVTPlayerViewController {

    func startPlay() {
        decodeQueue.async { [weak self] in
            self?.openInput()
            self?.decodeLoop()
        }
    }

    func stopPlay() {
        displayLayer.flushAndRemoveImage()

        if let codecCtx = codecCtx {
            avcodec_free_context(&self.codecCtx)
        }
        if let formatCtx = formatCtx {
            avformat_close_input(&self.formatCtx)
        }
        if let hwDeviceCtx = hwDeviceCtx {
            av_buffer_unref(&self.hwDeviceCtx)
        }

        avformat_network_deinit()
    }
}

// MARK: - FFmpeg + VideoToolbox
private extension FFmpegVTPlayerViewController {

    func openInput() {
        avformat_network_init()
        formatCtx = avformat_alloc_context()

        guard avformat_open_input(&formatCtx, urlString, nil, nil) >= 0,
              avformat_find_stream_info(formatCtx, nil) >= 0 else {
            print("❌ open input failed")
            return
        }

        // 找视频流
        for i in 0..<formatCtx!.pointee.nb_streams {
            let stream = formatCtx!.pointee.streams[Int(i)]!
            if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                videoStreamIndex = Int32(i)
                videoStream = stream
                break
            }
        }
        guard let videoStream = videoStream else { return }

        // 找 H.264 decoder
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_H264) else {
            print("❌ cannot find H.264 decoder")
            return
        }

        codecCtx = avcodec_alloc_context3(codec)
        guard let codecCtx = codecCtx,
              avcodec_parameters_to_context(codecCtx, videoStream.pointee.codecpar) >= 0 else {
            print("❌ failed to setup codec context")
            return
        }

        // 创建 VideoToolbox 硬解设备
        var deviceCtx: UnsafeMutablePointer<AVBufferRef>?
        if av_hwdevice_ctx_create(&deviceCtx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0 {
            hwDeviceCtx = deviceCtx
            codecCtx.pointee.hw_device_ctx = av_buffer_ref(hwDeviceCtx)
        } else {
            print("⚠️ VideoToolbox hwdevice create failed, will use software decode")
        }

        // 硬解选择回调
        codecCtx.pointee.get_format = { ctx, pixFmtsOpt in
            guard let pixFmts = pixFmtsOpt else { return AV_PIX_FMT_NONE }
            var p = pixFmts
            while p.pointee != AV_PIX_FMT_NONE {
                if p.pointee == AV_PIX_FMT_VIDEOTOOLBOX {
                    return p.pointee
                }
                p = p.advanced(by: 1)
            }
            return pixFmts.pointee
        }

        guard avcodec_open2(codecCtx, codec, nil) >= 0 else {
            print("❌ open codec failed")
            return
        }
    }

    func decodeLoop() {
        guard let codecCtx = codecCtx,
              let videoStream = videoStream else { return }

        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard let packetUnwrapped = packet, let frameUnwrapped = frame else { return }

        while av_read_frame(formatCtx, packetUnwrapped) >= 0 {
            if packetUnwrapped.pointee.stream_index == videoStreamIndex {
                avcodec_send_packet(codecCtx, packetUnwrapped)
                while avcodec_receive_frame(codecCtx, frameUnwrapped) == 0 {

                    guard frameUnwrapped.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue,
                          let cvPixelBufferPtr = frameUnwrapped.pointee.data.3 else { continue }

                    let cvPixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(cvPixelBufferPtr).takeUnretainedValue()

                    // 使用帧的 PTS
                    let pts = frameUnwrapped.pointee.best_effort_timestamp
                    let timeBase = videoStream.pointee.time_base
                    let ptsSec = (pts == Int64(bitPattern: 0x8000000000000000)) ? 0 : Double(pts) * av_q2d(timeBase)
                    let presentationTime = CMTime(seconds: ptsSec, preferredTimescale: 600)

                    // 记录第一帧的 PTS，作为时间基准
                    if firstPTS == .zero {
                        firstPTS = presentationTime
                        playbackStartTime = CFAbsoluteTimeGetCurrent()
                    }

                    // 计算延迟显示
                    let elapsed = CFAbsoluteTimeGetCurrent() - playbackStartTime
                    let delay = CMTimeGetSeconds(presentationTime - firstPTS) - elapsed
                    if delay > 0 {
                        Thread.sleep(forTimeInterval: delay)
                    }

                    // CMSampleBuffer
                    var formatDesc: CMVideoFormatDescription?
                    CMVideoFormatDescriptionCreateForImageBuffer(
                        allocator: kCFAllocatorDefault,
                        imageBuffer: cvPixelBuffer,
                        formatDescriptionOut: &formatDesc
                    )
                    guard let desc = formatDesc else { continue }

                    var timing = CMSampleTimingInfo(duration: .invalid,
                                                    presentationTimeStamp: presentationTime,
                                                    decodeTimeStamp: .invalid)
                    var sampleBuffer: CMSampleBuffer?
                    CMSampleBufferCreateForImageBuffer(
                        allocator: kCFAllocatorDefault,
                        imageBuffer: cvPixelBuffer,
                        dataReady: true,
                        makeDataReadyCallback: nil,
                        refcon: nil,
                        formatDescription: desc,
                        sampleTiming: &timing,
                        sampleBufferOut: &sampleBuffer
                    )

                    if let sb = sampleBuffer {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            if self.displayLayer.isReadyForMoreMediaData {
                                self.displayLayer.enqueue(sb)
                            }
                        }
                    }
                }
            }
            av_packet_unref(packetUnwrapped)
        }

        av_frame_free(&frame)
        av_packet_free(&packet)
    }
}
