import UIKit
import AVFoundation
import VideoToolbox
import AudioToolbox

class FFmpegVTPlayerViewController: UIViewController {

    var urlString: String!

    private let displayLayer = AVSampleBufferDisplayLayer()

    // 三条线程：读包、视频解码、音频解码
    private let demuxQueue = DispatchQueue(label: "ffmpeg.demux.queue")
    private let videoDecodeQueue = DispatchQueue(label: "ffmpeg.video.decode.queue")
    private let audioDecodeQueue = DispatchQueue(label: "ffmpeg.audio.decode.queue")

    // Video
    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var videoStreamIndex: Int32 = -1
    private var videoStream: UnsafeMutablePointer<AVStream>?
    private var hwDeviceCtx: UnsafeMutablePointer<AVBufferRef>?
    private var swsCtx: OpaquePointer?

    // Audio
    private var audioCodecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var audioStreamIndex: Int32 = -1
    private var audioStream: UnsafeMutablePointer<AVStream>?
    private var swrCtx: OpaquePointer?
    private var audioQueue: AudioQueueRef?
    private var audioBuffers: [AudioQueueBufferRef?] = []
    private var audioDataLock = NSLock()
    private var audioPCMData = Data()

    // 音频主时钟
    private var audioClockLock = NSLock()
    private var audioPTSSec: Double = 0
    private var audioPTSWallTime: CFAbsoluteTime = 0
    private var audioClockReady = false

    // 无音频流时的 fallback
    private var playbackStartTime: CFAbsoluteTime = 0
    private var firstVideoPTSSec: Double = -1

    private var isPlaying = true
    private var threadsStarted = false

    // 线程退出信号
    private let demuxDone = DispatchSemaphore(value: 0)
    private let videoDone = DispatchSemaphore(value: 0)
    private let audioDone = DispatchSemaphore(value: 0)

    // Packet 队列（线程安全）
    private var videoPacketQueue = PacketQueue()
    private var audioPacketQueue = PacketQueue()

    // Audio 常量
    private let kAudioSampleRate: Float64 = 44100
    private let kAudioChannels: UInt32 = 2
    private let kAudioBufferSize: UInt32 = 4096
    private let kAudioBufferCount = 3
    private let kMaxPacketQueueSize = 128

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

// MARK: - Thread-safe Packet Queue
private class PacketQueue {
    private var packets: [UnsafeMutablePointer<AVPacket>] = []
    private let lock = NSCondition()
    private var finished = false

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return packets.count
    }

    func enqueue(_ packet: UnsafeMutablePointer<AVPacket>) {
        lock.lock()
        let clone = av_packet_alloc()!
        av_packet_ref(clone, packet)
        packets.append(clone)
        lock.signal()
        lock.unlock()
    }

    func dequeue() -> UnsafeMutablePointer<AVPacket>? {
        lock.lock()
        while packets.isEmpty && !finished {
            lock.wait()
        }
        if packets.isEmpty {
            lock.unlock()
            return nil
        }
        let pkt = packets.removeFirst()
        lock.unlock()
        return pkt
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.broadcast()
        lock.unlock()
    }

    func flush() {
        lock.lock()
        for pkt in packets {
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_free(&p)
        }
        packets.removeAll()
        lock.unlock()
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
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            print("❌ AVAudioSession setup failed: \(error)")
        }

        demuxQueue.async { [weak self] in
            guard let self else { return }
            self.openInput()
            self.setupAudioOutput()
            self.threadsStarted = true

            self.videoDecodeQueue.async { [weak self] in
                self?.videoDecodeLoop()
                self?.videoDone.signal()
            }
            self.audioDecodeQueue.async { [weak self] in
                self?.audioDecodeLoop()
                self?.audioDone.signal()
            }
            self.demuxLoop()
            self.demuxDone.signal()
        }
    }

    func stopPlay() {
        isPlaying = false
        videoPacketQueue.markFinished()
        audioPacketQueue.markFinished()

        // 等待所有线程退出（仅在线程已启动时）
        if threadsStarted {
            _ = demuxDone.wait(timeout: .now() + 3)
            _ = videoDone.wait(timeout: .now() + 3)
            _ = audioDone.wait(timeout: .now() + 3)
        }

        if #available(iOS 18.0, *) {
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true) {  }
        } else {
            displayLayer.flushAndRemoveImage()
        }

        if let aq = audioQueue {
            AudioQueueStop(aq, true)
            for buf in audioBuffers {
                if let b = buf { AudioQueueFreeBuffer(aq, b) }
            }
            AudioQueueDispose(aq, true)
            audioQueue = nil
        }

        videoPacketQueue.flush()
        audioPacketQueue.flush()

        if swrCtx != nil { swr_free(&self.swrCtx) }
        if let sws = swsCtx { sws_freeContext(sws); swsCtx = nil }
        if let _ = audioCodecCtx { avcodec_free_context(&self.audioCodecCtx) }
        if let _ = codecCtx { avcodec_free_context(&self.codecCtx) }
        if let _ = formatCtx { avformat_close_input(&self.formatCtx) }
        if let _ = hwDeviceCtx { av_buffer_unref(&self.hwDeviceCtx) }
        avformat_network_deinit()
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}

// MARK: - Audio Queue
private func audioQueueOutputCallback(
    inUserData: UnsafeMutableRawPointer?,
    inAQ: AudioQueueRef,
    inBuffer: AudioQueueBufferRef
) {
    guard let userData = inUserData else { return }
    let vc = Unmanaged<FFmpegVTPlayerViewController>.fromOpaque(userData).takeUnretainedValue()
    vc.fillAudioBuffer(inBuffer)
}

private extension FFmpegVTPlayerViewController {

    func setupAudioOutput() {
        guard audioStreamIndex >= 0 else { return }

        var format = AudioStreamBasicDescription(
            mSampleRate: kAudioSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: kAudioChannels, mBitsPerChannel: 16, mReserved: 0
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioQueueNewOutput(
            &format, audioQueueOutputCallback, selfPtr,
            CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, 0,
            &audioQueue
        )
        guard status == noErr, let aq = audioQueue else {
            print("❌ AudioQueue create failed: \(status)")
            return
        }

        audioBuffers = [AudioQueueBufferRef?](repeating: nil, count: kAudioBufferCount)
        for i in 0..<kAudioBufferCount {
            AudioQueueAllocateBuffer(aq, kAudioBufferSize, &audioBuffers[i])
            if let buf = audioBuffers[i] {
                buf.pointee.mAudioDataByteSize = 0
                fillAudioBuffer(buf)
            }
        }
        AudioQueueStart(aq, nil)
    }

    func fillAudioBuffer(_ buffer: AudioQueueBufferRef) {
        let needed = Int(kAudioBufferSize)
        var bytesConsumed = 0

        audioDataLock.lock()
        let available = min(needed, audioPCMData.count)
        if available > 0 {
            _ = audioPCMData.withUnsafeBytes { rawPtr in
                memcpy(buffer.pointee.mAudioData, rawPtr.baseAddress!, available)
            }
            buffer.pointee.mAudioDataByteSize = UInt32(available)
            audioPCMData.removeFirst(available)
            bytesConsumed = available
        } else {
            memset(buffer.pointee.mAudioData, 0, needed)
            buffer.pointee.mAudioDataByteSize = UInt32(needed)
        }
        audioDataLock.unlock()

        audioClockLock.lock()
        if bytesConsumed > 0 {
            let seconds = Double(bytesConsumed) / (Double(kAudioChannels) * 2.0) / kAudioSampleRate
            audioPTSSec += seconds
        }
        // 无论是否有数据消费，都刷新墙钟，防止静音期间时钟差值累积
        audioPTSWallTime = CFAbsoluteTimeGetCurrent()
        audioClockLock.unlock()

        if let aq = audioQueue {
            AudioQueueEnqueueBuffer(aq, buffer, 0, nil)
        }
    }

    func enqueueAudioPCM(_ data: Data) {
        // 背压：PCM 缓冲区超过 256KB 就等一下
        while isPlaying {
            audioDataLock.lock()
            let size = audioPCMData.count
            audioDataLock.unlock()
            if size < 256 * 1024 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        audioDataLock.lock()
        audioPCMData.append(data)
        audioDataLock.unlock()
    }

    func getAudioClockSec() -> Double {
        audioClockLock.lock()
        let clock = audioPTSSec + (CFAbsoluteTimeGetCurrent() - audioPTSWallTime)
        audioClockLock.unlock()
        return clock
    }
}

// MARK: - FFmpeg Open / Demux
private extension FFmpegVTPlayerViewController {

    func openInput() {
        avformat_network_init()

        let actualURL = resolveHLSVariantURL(urlString) ?? urlString!

        formatCtx = avformat_alloc_context()
        formatCtx!.pointee.probesize = 512_000
        formatCtx!.pointee.max_analyze_duration = 2_000_000

        var opts: OpaquePointer?
        av_dict_set(&opts, "timeout", "10000000", 0)
        av_dict_set(&opts, "rw_timeout", "10000000", 0)

        guard avformat_open_input(&formatCtx, actualURL, nil, &opts) >= 0 else {
            print("❌ open input failed"); av_dict_free(&opts); return
        }
        av_dict_free(&opts)

        guard avformat_find_stream_info(formatCtx, nil) >= 0 else {
            print("❌ find stream info failed"); return
        }

        print("ℹ️ nb_streams=\(formatCtx!.pointee.nb_streams)")

        // 找视频流和音频流
        for i in 0..<formatCtx!.pointee.nb_streams {
            let stream = formatCtx!.pointee.streams[Int(i)]!
            let codecType = stream.pointee.codecpar.pointee.codec_type
            if codecType == AVMEDIA_TYPE_VIDEO && videoStreamIndex < 0 {
                videoStreamIndex = Int32(i); videoStream = stream
            } else if codecType == AVMEDIA_TYPE_AUDIO && audioStreamIndex < 0 {
                audioStreamIndex = Int32(i); audioStream = stream
            }
        }

        print("ℹ️ video=\(videoStreamIndex), audio=\(audioStreamIndex)")

        // 视频解码器
        if let videoStream = videoStream {
            let codecId = videoStream.pointee.codecpar.pointee.codec_id
            guard let codec = avcodec_find_decoder(codecId) else { print("❌ no video decoder"); return }

            codecCtx = avcodec_alloc_context3(codec)
            guard let ctx = codecCtx,
                  avcodec_parameters_to_context(ctx, videoStream.pointee.codecpar) >= 0 else { return }

            if codecId == AV_CODEC_ID_H264 || codecId == AV_CODEC_ID_HEVC {
                var deviceCtx: UnsafeMutablePointer<AVBufferRef>?
                if av_hwdevice_ctx_create(&deviceCtx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0 {
                    hwDeviceCtx = deviceCtx
                    ctx.pointee.hw_device_ctx = av_buffer_ref(hwDeviceCtx)
                }
                ctx.pointee.get_format = { _, pixFmtsOpt in
                    guard let pixFmts = pixFmtsOpt else { return AV_PIX_FMT_NONE }
                    var p = pixFmts
                    while p.pointee != AV_PIX_FMT_NONE {
                        if p.pointee == AV_PIX_FMT_VIDEOTOOLBOX { return p.pointee }
                        p = p.advanced(by: 1)
                    }
                    return pixFmts.pointee
                }
            }
            guard avcodec_open2(ctx, codec, nil) >= 0 else { print("❌ open video codec failed"); return }
        }

        // 音频解码器
        if let audioStream = audioStream {
            let codecId = audioStream.pointee.codecpar.pointee.codec_id
            guard let codec = avcodec_find_decoder(codecId) else { return }
            audioCodecCtx = avcodec_alloc_context3(codec)
            guard let ctx = audioCodecCtx,
                  avcodec_parameters_to_context(ctx, audioStream.pointee.codecpar) >= 0,
                  avcodec_open2(ctx, codec, nil) >= 0 else { return }
            setupSwrContext(ctx)
        }
    }

    /// 解析 HLS master playlist，选择一个 variant 子 playlist URL
    /// 避免 FFmpeg 同时下载所有 variant
    func resolveHLSVariantURL(_ urlStr: String) -> String? {
        guard urlStr.lowercased().contains(".m3u8"),
              let url = URL(string: urlStr) else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        var playlistContent: String?
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data { playlistContent = String(data: data, encoding: .utf8) }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 10)

        guard let content = playlistContent else { return nil }
        guard content.contains("#EXT-X-STREAM-INF") else { return nil }

        var variants: [(bandwidth: Int, url: String)] = []
        let lines = content.components(separatedBy: .newlines)

        for (i, line) in lines.enumerated() {
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                var bandwidth = 0
                if let range = line.range(of: "BANDWIDTH=") {
                    let start = range.upperBound
                    let rest = line[start...]
                    let numStr = rest.prefix(while: { $0.isNumber })
                    bandwidth = Int(numStr) ?? 0
                }
                if i + 1 < lines.count {
                    let variantURL = lines[i + 1].trimmingCharacters(in: .whitespaces)
                    if !variantURL.isEmpty && !variantURL.hasPrefix("#") {
                        var resolvedURL: String
                        if variantURL.hasPrefix("http") {
                            resolvedURL = variantURL
                        } else {
                            let baseURL = url.deletingLastPathComponent()
                            resolvedURL = baseURL.appendingPathComponent(variantURL).absoluteString
                        }
                        variants.append((bandwidth: bandwidth, url: resolvedURL))
                    }
                }
            }
        }

        guard !variants.isEmpty else { return nil }

        // 按带宽排序，选中间偏下的 variant（兼顾画质和网络）
        variants.sort { $0.bandwidth < $1.bandwidth }
        let idx = max(0, variants.count / 3)
        let selected = variants[idx]

        print("ℹ️ HLS: \(variants.count) variants, selected bandwidth=\(selected.bandwidth), url=\(selected.url)")
        return selected.url
    }

    func setupSwrContext(_ actx: UnsafeMutablePointer<AVCodecContext>) {
        var outChLayout = AVChannelLayout()
        av_channel_layout_default(&outChLayout, Int32(kAudioChannels))
        var inChLayout = actx.pointee.ch_layout
        var swr: OpaquePointer?
        swr_alloc_set_opts2(&swr, &outChLayout, AV_SAMPLE_FMT_S16, Int32(kAudioSampleRate),
                            &inChLayout, actx.pointee.sample_fmt, actx.pointee.sample_rate, 0, nil)
        if let swr = swr, swr_init(swr) >= 0 { swrCtx = swr }
    }

    /// Demux 线程：读包并分发到视频/音频队列
    func demuxLoop() {
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        guard let pkt = packet else { return }
        var readCount = 0
        while isPlaying && av_read_frame(formatCtx, pkt) >= 0 {
            if pkt.pointee.stream_index == videoStreamIndex {
                videoPacketQueue.enqueue(pkt)
            } else if pkt.pointee.stream_index == audioStreamIndex {
                audioPacketQueue.enqueue(pkt)
            }
            av_packet_unref(pkt)
            readCount += 1
            if readCount % 100 == 0 {
                print("📦 demux: \(readCount) packets, vQ=\(videoPacketQueue.count) aQ=\(audioPacketQueue.count)")
            }
        }
        print("📦 demux ended after \(readCount) packets")
        videoPacketQueue.markFinished()
        audioPacketQueue.markFinished()
        av_packet_free(&packet)
    }
}

// MARK: - Video Decode Thread
private extension FFmpegVTPlayerViewController {

    func videoDecodeLoop() {
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard let frm = frame else { return }
        while let dequeuedPkt = videoPacketQueue.dequeue() {
            var pkt: UnsafeMutablePointer<AVPacket>? = dequeuedPkt
            guard let ctx = codecCtx, let vStream = videoStream else {
                av_packet_free(&pkt)
                continue
            }
            avcodec_send_packet(ctx, pkt)
            var frameCount = 0
            while avcodec_receive_frame(ctx, frm) == 0 {
                var pixelBuffer: CVPixelBuffer?

                if frm.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
                    guard let ptr = frm.pointee.data.3 else { continue }
                    pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(ptr).takeUnretainedValue()
                } else {
                    pixelBuffer = softDecodeToPixelBuffer(frame: frm, codecCtx: ctx)
                }
                guard let pb = pixelBuffer else { continue }

                let pts = frm.pointee.best_effort_timestamp
                let timeBase = vStream.pointee.time_base
                let ptsSec = (pts == Int64(bitPattern: 0x8000000000000000)) ? 0 : Double(pts) * av_q2d(timeBase)
                let presentationTime = CMTime(seconds: ptsSec, preferredTimescale: 600)

                frameCount += 1
                if frameCount % 90 == 1 {
                    let aClock = getAudioClockSec()
                    let aReady = audioClockReady
                    let pcmSize: Int = { self.audioDataLock.lock(); let s = self.audioPCMData.count; self.audioDataLock.unlock(); return s }()
                    print("🎬 vPTS=\(String(format: "%.3f", ptsSec)) aClock=\(String(format: "%.3f", aClock)) aReady=\(aReady) pcm=\(pcmSize) vQ=\(videoPacketQueue.count) aQ=\(audioPacketQueue.count)")
                }

                // 同步策略
                if audioClockReady {
                    // 检查音频是否断流（PCM 耗尽且音频时钟停滞）
                    let aClock = getAudioClockSec()
                    let delay = ptsSec - aClock

                    if delay > 0.005 && delay < 0.5 {
                        // 正常范围：视频超前音频，等一下
                        Thread.sleep(forTimeInterval: delay)
                    } else if delay >= 0.5 {
                        // 视频远超音频 → 音频可能断流了，不等，直接送显
                        // 不做任何等待
                    } else if delay < -0.1 {
                        // 视频落后音频，丢帧追赶
                        continue
                    }
                } else {
                    if firstVideoPTSSec < 0 {
                        firstVideoPTSSec = ptsSec
                        playbackStartTime = CFAbsoluteTimeGetCurrent()
                    }
                    let delay = (ptsSec - firstVideoPTSSec) - (CFAbsoluteTimeGetCurrent() - playbackStartTime)
                    if delay > 0.005 && delay < 2.0 {
                        Thread.sleep(forTimeInterval: delay)
                    }
                }

                enqueueSampleBuffer(pixelBuffer: pb, presentationTime: presentationTime)
            }
            av_packet_free(&pkt)
        }
        av_frame_free(&frame)
    }

    func enqueueSampleBuffer(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc)
        guard let desc = formatDesc else { return }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: presentationTime,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: desc,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer)

        if let sb = sampleBuffer {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if #available(iOS 18.0, *) {
                    if self.displayLayer.sampleBufferRenderer.isReadyForMoreMediaData {
                        self.displayLayer.sampleBufferRenderer.enqueue(sb)
                    }
                } else {
                    if self.displayLayer.isReadyForMoreMediaData {
                        self.displayLayer.enqueue(sb)
                    }
                }
            }
        }
    }

    func softDecodeToPixelBuffer(frame: UnsafeMutablePointer<AVFrame>,
                                  codecCtx: UnsafeMutablePointer<AVCodecContext>) -> CVPixelBuffer? {
        let w = Int(codecCtx.pointee.width), h = Int(codecCtx.pointee.height)
        if swsCtx == nil {
            swsCtx = sws_getContext(Int32(w), Int32(h), codecCtx.pointee.pix_fmt,
                                    Int32(w), Int32(h), AV_PIX_FMT_NV12, SWS_BILINEAR, nil, nil, nil)
        }
        guard let sws = swsCtx else { return nil }

        let bufY = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h)
        let bufUV = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h / 2)
        defer { bufY.deallocate(); bufUV.deallocate() }

        let dstData: [UnsafeMutablePointer<UInt8>?] = [bufY, bufUV, nil, nil]
        let dstLine: [Int32] = [Int32(w), Int32(w), 0, 0]
        let srcData: [UnsafePointer<UInt8>?] = [
            frame.pointee.data.0.map { UnsafePointer($0) },
            frame.pointee.data.1.map { UnsafePointer($0) },
            frame.pointee.data.2.map { UnsafePointer($0) },
            frame.pointee.data.3.map { UnsafePointer($0) }
        ]
        let srcLine: [Int32] = [frame.pointee.linesize.0, frame.pointee.linesize.1,
                                 frame.pointee.linesize.2, frame.pointee.linesize.3]
        sws_scale(sws, srcData, srcLine, 0, Int32(h), dstData, dstLine)

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs as CFDictionary, &pb)
        guard let pixelBuffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let yDest = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
           let uvDest = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            memcpy(yDest, bufY, w * h)
            memcpy(uvDest, bufUV, w * h / 2)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }
}

// MARK: - Audio Decode Thread
private extension FFmpegVTPlayerViewController {

    func audioDecodeLoop() {
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard let frm = frame else { return }
        while let dequeuedPkt = audioPacketQueue.dequeue() {
            var pkt: UnsafeMutablePointer<AVPacket>? = dequeuedPkt
            guard let ctx = audioCodecCtx, let swr = swrCtx, let aStream = audioStream else {
                av_packet_free(&pkt)
                continue
            }
            avcodec_send_packet(ctx, pkt)
            while avcodec_receive_frame(ctx, frm) == 0 {
                // 只在第一帧设置音频时钟基准，之后由 fillAudioBuffer 消费推进
                if !audioClockReady {
                    let pts = frm.pointee.best_effort_timestamp
                    let timeBase = aStream.pointee.time_base
                    if pts != Int64(bitPattern: 0x8000000000000000) {
                        let sec = Double(pts) * av_q2d(timeBase)
                        audioClockLock.lock()
                        audioPTSSec = sec
                        audioPTSWallTime = CFAbsoluteTimeGetCurrent()
                        audioClockReady = true
                        audioClockLock.unlock()
                    }
                }

                let outSamples = swr_get_out_samples(swr, frm.pointee.nb_samples)
                guard outSamples > 0 else { continue }

                let outBufSize = Int(outSamples) * Int(kAudioChannels) * 2
                let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: outBufSize)
                defer { outBuf.deallocate() }

                var outPtr: UnsafeMutablePointer<UInt8>? = outBuf
                let inPtr = UnsafeMutableRawPointer(frm.pointee.extended_data)!
                    .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                let converted = withUnsafeMutablePointer(to: &outPtr) { pp in
                    swr_convert(swr, pp, outSamples, inPtr, frm.pointee.nb_samples)
                }
                if converted > 0 {
                    let bytes = Int(converted) * Int(kAudioChannels) * 2
                    enqueueAudioPCM(Data(bytes: outBuf, count: bytes))
                }
            }
            av_packet_free(&pkt)
        }
        av_frame_free(&frame)
    }
}
