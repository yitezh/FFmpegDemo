import UIKit
import AVFoundation
import VideoToolbox
import AudioToolbox

/// FFmpeg + VideoToolbox 硬解 + AudioQueue 音频播放的视频播放器
///
/// 整体架构：三线程模型
/// ┌─────────────┐     ┌──────────────────┐     ┌─────────────────────────┐
/// │  demuxQueue  │────▶│ videoPacketQueue  │────▶│   videoDecodeQueue      │
/// │  (读包线程)   │     └──────────────────┘     │  (视频解码 + 同步 + 送显) │
/// │              │     ┌──────────────────┐     └─────────────────────────┘
/// │              │────▶│ audioPacketQueue  │────▶┌─────────────────────────┐
/// └─────────────┘     └──────────────────┘     │   audioDecodeQueue      │
///                                               │  (音频解码 + 重采样)     │
///                                               └──────────┬──────────────┘
///                                                          ▼
///                                               ┌─────────────────────────┐
///                                               │   AudioQueue 回调       │
///                                               │  (消费 PCM + 推进时钟)   │
///                                               └─────────────────────────┘
///
/// 音视频同步策略：以音频时钟为主时钟
/// - 音频解码第一帧时设置时钟基准（audioPTSSec）
/// - AudioQueue 回调每消费一段 PCM 数据，按采样数推进 audioPTSSec
/// - 视频帧根据自身 PTS 与音频时钟的差值决定：等待 / 立即送显 / 丢帧
/// - 音频断流时（delay >= 0.5s）视频不等待，直接送显
/// - 无音频流时 fallback 到墙钟同步
///
/// HLS 处理：
/// - 自动解析 master playlist，选择最低码率 variant，避免 FFmpeg 同时下载所有 variant
/// - 预缓冲 + 缓冲状态机，网络不稳定时暂停等数据，攒够再恢复播放
class FFmpegVTPlayerViewController: UIViewController {

    /// 外部传入的视频 URL（支持 HLS m3u8、HTTP mp4 等）
    var urlString: String!

    /// 视频渲染层，利用系统 GPU 渲染管线显示 CMSampleBuffer
    private let displayLayer = AVSampleBufferDisplayLayer()

    // MARK: - 三条工作线程
    private let demuxQueue = DispatchQueue(label: "ffmpeg.demux.queue")       // 读包（demux）
    private let videoDecodeQueue = DispatchQueue(label: "ffmpeg.video.decode.queue") // 视频解码
    private let audioDecodeQueue = DispatchQueue(label: "ffmpeg.audio.decode.queue") // 音频解码

    // MARK: - FFmpeg 视频相关
    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?  // 封装格式上下文（管理输入流）
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?    // 视频解码器上下文
    private var videoStreamIndex: Int32 = -1                       // 视频流在 formatCtx 中的索引
    private var videoStream: UnsafeMutablePointer<AVStream>?       // 视频流指针（用于获取 time_base）
    private var hwDeviceCtx: UnsafeMutablePointer<AVBufferRef>?    // VideoToolbox 硬件设备上下文
    private var swsCtx: OpaquePointer?                             // 软解时的像素格式转换上下文（YUV→NV12）

    // MARK: - FFmpeg 音频相关
    private var audioCodecCtx: UnsafeMutablePointer<AVCodecContext>?  // 音频解码器上下文
    private var audioStreamIndex: Int32 = -1                         // 音频流索引
    private var audioStream: UnsafeMutablePointer<AVStream>?         // 音频流指针
    private var swrCtx: OpaquePointer?                               // 音频重采样上下文（原始格式→S16/44100/stereo）

    // MARK: - AudioQueue 播放
    private var audioQueue: AudioQueueRef?                // AudioQueue 实例
    private var audioBuffers: [AudioQueueBufferRef?] = [] // AudioQueue 的循环缓冲区（3个）
    private var audioDataLock = NSLock()                   // 保护 audioPCMData 的锁
    private var audioPCMData = Data()                      // PCM 数据缓冲区，音频解码线程写入，AudioQueue 回调消费

    // MARK: - 音频主时钟（Audio Master Clock）
    /// 音视频同步的核心：以音频实际播放进度作为时间基准
    /// - audioPTSSec: 当前音频播放到的时间点（秒），由 AudioQueue 回调推进
    /// - audioPTSWallTime: 上次更新 audioPTSSec 时的墙钟时间
    /// - getAudioClockSec() = audioPTSSec + (当前墙钟 - audioPTSWallTime)，实现亚帧精度插值
    private var audioClockLock = NSLock()
    private var audioPTSSec: Double = 0
    private var audioPTSWallTime: CFAbsoluteTime = 0
    private var audioClockReady = false  // 音频时钟是否已初始化（第一帧音频解码后设为 true）

    // MARK: - 无音频流时的墙钟 fallback
    private var playbackStartTime: CFAbsoluteTime = 0  // 第一帧视频送显时的墙钟
    private var firstVideoPTSSec: Double = -1           // 第一帧视频的 PTS（秒）

    // MARK: - 播放状态
    private var isPlaying = true          // 控制所有循环退出
    private var threadsStarted = false    // 标记工作线程是否已启动（stopPlay 用）
    private var isBuffering = false       // 缓冲状态机：true 时暂停播放等数据

    // MARK: - 线程退出信号（stopPlay 等待所有线程安全退出后再释放资源）
    private let demuxDone = DispatchSemaphore(value: 0)
    private let videoDone = DispatchSemaphore(value: 0)
    private let audioDone = DispatchSemaphore(value: 0)

    // MARK: - 线程安全的 Packet 队列
    /// demux 线程写入，视频/音频解码线程消费
    /// 内部用 NSCondition 实现阻塞等待，队列空时 dequeue 会阻塞直到有数据或 markFinished
    private var videoPacketQueue = PacketQueue()
    private var audioPacketQueue = PacketQueue()

    // MARK: - 音频输出参数
    private let kAudioSampleRate: Float64 = 44100  // 输出采样率
    private let kAudioChannels: UInt32 = 2         // 输出声道数（stereo）
    private let kAudioBufferSize: UInt32 = 4096    // 每个 AudioQueue buffer 的字节数
    private let kAudioBufferCount = 3              // AudioQueue buffer 数量（三缓冲）
    private let kMaxPacketQueueSize = 128           // Packet 队列最大容量

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupLayer()
        startPlay()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopPlay()
    }
}

// MARK: - 线程安全的 Packet 队列
/// 生产者-消费者模型：demux 线程 enqueue，解码线程 dequeue
/// 使用 NSCondition 实现阻塞等待，避免忙轮询
private class PacketQueue {
    private var packets: [UnsafeMutablePointer<AVPacket>] = []
    private let lock = NSCondition()
    private var finished = false  // 标记生产者已结束，不会再有新数据

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return packets.count
    }

    /// 入队：clone 一份 packet（因为 demux 线程会 unref 原始 packet）
    func enqueue(_ packet: UnsafeMutablePointer<AVPacket>) {
        lock.lock()
        let clone = av_packet_alloc()!
        av_packet_ref(clone, packet)
        packets.append(clone)
        lock.signal()  // 唤醒等待中的 dequeue
        lock.unlock()
    }

    /// 出队：队列空时阻塞等待，直到有数据或 markFinished
    /// 返回 nil 表示队列已结束，消费者应退出循环
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

    /// 标记生产者已结束，唤醒所有等待的消费者
    func markFinished() {
        lock.lock()
        finished = true
        lock.broadcast()
        lock.unlock()
    }

    /// 清空队列并释放所有 packet 内存
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

// MARK: - 渲染层设置
private extension FFmpegVTPlayerViewController {
    func setupLayer() {
        displayLayer.frame = view.bounds
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(displayLayer)
    }
}

// MARK: - 播放控制
private extension FFmpegVTPlayerViewController {

    /// 启动播放流程
    /// 1. 主线程配置 AVAudioSession（必须在主线程）
    /// 2. demux 线程：打开输入 → 设置音频输出 → 预缓冲 → 启动视频/音频解码线程 → 进入 demux 循环
    func startPlay() {
        // AVAudioSession 必须在主线程配置，否则 AudioQueue 会报 err=-19431
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

            // 预缓冲：先读一批数据到队列，避免开播就断流
            self.prebuffer()

            // 启动视频解码线程
            self.videoDecodeQueue.async { [weak self] in
                self?.videoDecodeLoop()
                self?.videoDone.signal()
            }
            // 启动音频解码线程
            self.audioDecodeQueue.async { [weak self] in
                self?.audioDecodeLoop()
                self?.audioDone.signal()
            }
            // 当前线程继续做 demux（持续读包分发）
            self.demuxLoop()
            self.demuxDone.signal()
        }
    }

    /// 停止播放并释放所有资源
    /// 关键：必须等待所有工作线程退出后再释放 FFmpeg 资源，否则会 EXC_BAD_ACCESS
    func stopPlay() {
        // 1. 通知所有循环退出
        isPlaying = false
        videoPacketQueue.markFinished()
        audioPacketQueue.markFinished()

        // 2. 等待三个工作线程安全退出（最多等 3 秒，防止死锁）
        if threadsStarted {
            _ = demuxDone.wait(timeout: .now() + 3)
            _ = videoDone.wait(timeout: .now() + 3)
            _ = audioDone.wait(timeout: .now() + 3)
        }

        // 3. 清理渲染层
        if #available(iOS 18.0, *) {
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true) {  }
        } else {
            displayLayer.flushAndRemoveImage()
        }

        // 4. 停止并释放 AudioQueue
        if let aq = audioQueue {
            AudioQueueStop(aq, true)
            for buf in audioBuffers {
                if let b = buf { AudioQueueFreeBuffer(aq, b) }
            }
            AudioQueueDispose(aq, true)
            audioQueue = nil
        }

        // 5. 清空 packet 队列
        videoPacketQueue.flush()
        audioPacketQueue.flush()

        // 6. 释放 FFmpeg 资源（顺序重要：先释放编解码器，再释放格式上下文）
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

// MARK: - AudioQueue 回调与音频输出

/// AudioQueue 的 C 回调函数（不能是实例方法）
/// 当一个 buffer 播放完毕后被系统调用，需要填充新数据并重新入队
private func audioQueueOutputCallback(
    inUserData: UnsafeMutableRawPointer?,
    inAQ: AudioQueueRef,
    inBuffer: AudioQueueBufferRef
) {
    guard let userData = inUserData else { return }
    // 通过 Unmanaged 指针恢复 VC 实例（setupAudioOutput 时传入的 selfPtr）
    let vc = Unmanaged<FFmpegVTPlayerViewController>.fromOpaque(userData).takeUnretainedValue()
    vc.fillAudioBuffer(inBuffer)
}

private extension FFmpegVTPlayerViewController {

    /// 创建 AudioQueue 并启动音频播放
    /// 输出格式：S16 interleaved / 44100Hz / stereo（4 bytes per frame）
    /// 回调绑定到主线程 RunLoop，确保回调能正常触发
    func setupAudioOutput() {
        guard audioStreamIndex >= 0 else { return }

        // S16 interleaved: 2 channels × 16bit = 4 bytes per frame
        var format = AudioStreamBasicDescription(
            mSampleRate: kAudioSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: kAudioChannels, mBitsPerChannel: 16, mReserved: 0
        )

        // 传递 self 指针给回调函数（passUnretained 不增加引用计数）
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioQueueNewOutput(
            &format, audioQueueOutputCallback, selfPtr,
            CFRunLoopGetMain(),                      // 回调在主线程 RunLoop 上触发
            CFRunLoopMode.commonModes.rawValue,      // 滚动时也能触发
            0,
            &audioQueue
        )
        guard status == noErr, let aq = audioQueue else {
            print("❌ AudioQueue create failed: \(status)")
            return
        }

        // 分配 3 个循环 buffer，初始填充静音并入队
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

    /// 填充 AudioQueue buffer
    /// 这是音频时钟推进的核心位置：
    /// - 有 PCM 数据时：拷贝数据到 buffer，按消费的采样数推进 audioPTSSec
    /// - 无 PCM 数据时：填充静音，只刷新 audioPTSWallTime（防止时钟差值累积导致跳变）
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
            // 无数据时填静音，防止 AudioQueue 饥饿报错
            memset(buffer.pointee.mAudioData, 0, needed)
            buffer.pointee.mAudioDataByteSize = UInt32(needed)
        }
        audioDataLock.unlock()

        // 更新音频时钟
        audioClockLock.lock()
        if bytesConsumed > 0 {
            // 消费了 bytesConsumed 字节 = bytesConsumed / (2channels × 2bytes) 个采样
            let seconds = Double(bytesConsumed) / (Double(kAudioChannels) * 2.0) / kAudioSampleRate
            audioPTSSec += seconds
        }
        // 关键：无论是否有数据，都刷新墙钟时间
        // 否则静音期间 getAudioClockSec() = audioPTSSec + (很大的墙钟差) → 时钟暴涨
        audioPTSWallTime = CFAbsoluteTimeGetCurrent()
        audioClockLock.unlock()

        if let aq = audioQueue {
            AudioQueueEnqueueBuffer(aq, buffer, 0, nil)
        }
    }

    /// 将解码后的 PCM 数据写入缓冲区
    /// 带背压控制：缓冲区超过 256KB 时阻塞等待，防止内存无限增长
    func enqueueAudioPCM(_ data: Data) {
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

    /// 获取当前音频时钟（秒）
    /// 通过墙钟插值实现亚帧精度：audioPTSSec 是上次 fillAudioBuffer 时的值，
    /// 加上自那以后经过的墙钟时间，得到"现在"的音频播放位置
    func getAudioClockSec() -> Double {
        audioClockLock.lock()
        let clock = audioPTSSec + (CFAbsoluteTimeGetCurrent() - audioPTSWallTime)
        audioClockLock.unlock()
        return clock
    }
}

// MARK: - FFmpeg 打开输入 / Demux / 预缓冲
private extension FFmpegVTPlayerViewController {

    /// 打开输入流并初始化视频/音频解码器
    /// 流程：
    /// 1. 如果是 HLS master playlist，先解析选择一个 variant 子 playlist
    /// 2. avformat_open_input 打开输入
    /// 3. avformat_find_stream_info 探测流信息
    /// 4. 遍历 streams 找到视频流和音频流
    /// 5. 初始化视频解码器（优先 VideoToolbox 硬解，不支持时软解）
    /// 6. 初始化音频解码器 + SwrContext 重采样
    func openInput() {
        avformat_network_init()

        // HLS 优化：解析 master playlist，选择单个 variant，避免 FFmpeg 同时下载所有 variant
        let actualURL = resolveHLSVariantURL(urlString) ?? urlString!

        formatCtx = avformat_alloc_context()
        // 限制探测参数，加速 HLS 打开（默认值太大会导致等待很久）
        formatCtx!.pointee.probesize = 512_000           // 最多探测 512KB 数据
        formatCtx!.pointee.max_analyze_duration = 2_000_000 // 最多分析 2 秒

        var opts: OpaquePointer?
        av_dict_set(&opts, "timeout", "10000000", 0)      // TCP 连接超时 10 秒（微秒）
        av_dict_set(&opts, "rw_timeout", "10000000", 0)    // 读写超时 10 秒

        guard avformat_open_input(&formatCtx, actualURL, nil, &opts) >= 0 else {
            print("❌ open input failed"); av_dict_free(&opts); return
        }
        av_dict_free(&opts)

        guard avformat_find_stream_info(formatCtx, nil) >= 0 else {
            print("❌ find stream info failed"); return
        }

        print("ℹ️ nb_streams=\(formatCtx!.pointee.nb_streams)")

        // 遍历所有 stream，找第一个视频流和第一个音频流
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

        // ---- 视频解码器初始化 ----
        if let videoStream = videoStream {
            let codecId = videoStream.pointee.codecpar.pointee.codec_id
            // 根据流的 codec_id 自动查找解码器（不硬编码 H.264，兼容所有编码格式）
            guard let codec = avcodec_find_decoder(codecId) else { print("❌ no video decoder"); return }

            codecCtx = avcodec_alloc_context3(codec)
            guard let ctx = codecCtx,
                  avcodec_parameters_to_context(ctx, videoStream.pointee.codecpar) >= 0 else { return }

            // VideoToolbox 硬解仅支持 H.264 和 H.265
            if codecId == AV_CODEC_ID_H264 || codecId == AV_CODEC_ID_HEVC {
                var deviceCtx: UnsafeMutablePointer<AVBufferRef>?
                if av_hwdevice_ctx_create(&deviceCtx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0 {
                    hwDeviceCtx = deviceCtx
                    ctx.pointee.hw_device_ctx = av_buffer_ref(hwDeviceCtx)
                }
                // get_format 回调：告诉 FFmpeg 优先选择 VideoToolbox 像素格式
                ctx.pointee.get_format = { _, pixFmtsOpt in
                    guard let pixFmts = pixFmtsOpt else { return AV_PIX_FMT_NONE }
                    var p = pixFmts
                    while p.pointee != AV_PIX_FMT_NONE {
                        if p.pointee == AV_PIX_FMT_VIDEOTOOLBOX { return p.pointee }
                        p = p.advanced(by: 1)
                    }
                    return pixFmts.pointee  // fallback 到第一个支持的格式（软解）
                }
            }
            guard avcodec_open2(ctx, codec, nil) >= 0 else { print("❌ open video codec failed"); return }
        }

        // ---- 音频解码器初始化 ----
        if let audioStream = audioStream {
            let codecId = audioStream.pointee.codecpar.pointee.codec_id
            guard let codec = avcodec_find_decoder(codecId) else { return }
            audioCodecCtx = avcodec_alloc_context3(codec)
            guard let ctx = audioCodecCtx,
                  avcodec_parameters_to_context(ctx, audioStream.pointee.codecpar) >= 0,
                  avcodec_open2(ctx, codec, nil) >= 0 else { return }
            // 设置重采样：将音频原始格式转换为 S16/44100/stereo
            setupSwrContext(ctx)
        }
    }

    /// 解析 HLS master playlist，选择一个 variant 子 playlist URL
    /// 目的：FFmpeg 打开 master playlist 时会同时下载所有 variant 的 TS 分片，
    /// 导致带宽浪费和大量超时。手动选择一个 variant 后直接传子 playlist URL 给 FFmpeg，
    /// 它就只会下载这一路。
    func resolveHLSVariantURL(_ urlStr: String) -> String? {
        guard urlStr.lowercased().contains(".m3u8"),
              let url = URL(string: urlStr) else { return nil }

        // 同步下载 master playlist 文本
        let semaphore = DispatchSemaphore(value: 0)
        var playlistContent: String?
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data { playlistContent = String(data: data, encoding: .utf8) }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 10)

        guard let content = playlistContent else { return nil }
        // 如果没有 #EXT-X-STREAM-INF，说明不是 master playlist，直接用原 URL
        guard content.contains("#EXT-X-STREAM-INF") else { return nil }

        // 解析所有 variant 的带宽和 URL
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
                            // 相对路径转绝对路径
                            let baseURL = url.deletingLastPathComponent()
                            resolvedURL = baseURL.appendingPathComponent(variantURL).absoluteString
                        }
                        variants.append((bandwidth: bandwidth, url: resolvedURL))
                    }
                }
            }
        }

        guard !variants.isEmpty else { return nil }

        // 选最低码率，优先保证流畅（移动网络/跨境场景）
        variants.sort { $0.bandwidth < $1.bandwidth }
        let selected = variants[0]

        print("ℹ️ HLS: \(variants.count) variants, selected bandwidth=\(selected.bandwidth), url=\(selected.url)")
        return selected.url
    }

    /// 配置音频重采样上下文
    /// 将音频流的原始格式（可能是 float/planar/各种采样率）统一转换为 S16/44100/stereo
    func setupSwrContext(_ actx: UnsafeMutablePointer<AVCodecContext>) {
        var outChLayout = AVChannelLayout()
        av_channel_layout_default(&outChLayout, Int32(kAudioChannels))
        var inChLayout = actx.pointee.ch_layout
        var swr: OpaquePointer?
        swr_alloc_set_opts2(&swr, &outChLayout, AV_SAMPLE_FMT_S16, Int32(kAudioSampleRate),
                            &inChLayout, actx.pointee.sample_fmt, actx.pointee.sample_rate, 0, nil)
        if let swr = swr, swr_init(swr) >= 0 { swrCtx = swr }
    }

    /// Demux 线程主循环：持续从输入流读取 packet，按 stream_index 分发到对应队列
    /// av_read_frame 是阻塞调用，HLS 场景下会等待 TS 分片下载完成
    func demuxLoop() {
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        guard let pkt = packet else { return }
        while isPlaying && av_read_frame(formatCtx, pkt) >= 0 {
            if pkt.pointee.stream_index == videoStreamIndex {
                videoPacketQueue.enqueue(pkt)
            } else if pkt.pointee.stream_index == audioStreamIndex {
                audioPacketQueue.enqueue(pkt)
            }
            av_packet_unref(pkt)
        }
        // 读完或出错，通知消费者队列已结束
        videoPacketQueue.markFinished()
        audioPacketQueue.markFinished()
        av_packet_free(&packet)
    }

    /// 预缓冲：开始播放前先读取一批 packet 到队列
    /// 避免开播就断流导致卡顿，类似浏览器的 "buffering..." 阶段
    func prebuffer() {
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        guard let pkt = packet else { return }
        let targetPackets = 120  // 目标缓冲约 4 秒的视频数据
        var count = 0
        while isPlaying && count < targetPackets && av_read_frame(formatCtx, pkt) >= 0 {
            if pkt.pointee.stream_index == videoStreamIndex {
                videoPacketQueue.enqueue(pkt)
                count += 1
            } else if pkt.pointee.stream_index == audioStreamIndex {
                audioPacketQueue.enqueue(pkt)
            }
            av_packet_unref(pkt)
        }
        av_packet_free(&packet)
        print("ℹ️ prebuffered \(count) video packets, vQ=\(videoPacketQueue.count) aQ=\(audioPacketQueue.count)")
    }
}

// MARK: - 视频解码线程
private extension FFmpegVTPlayerViewController {

    /// 视频解码主循环
    /// 职责：从 videoPacketQueue 取包 → 解码 → 音视频同步 → 送显
    ///
    /// 缓冲状态机：
    /// - 正常播放 → 队列低于 3 个 → 进入缓冲（暂停播放，等数据）
    /// - 缓冲中 → 队列恢复到 30 个 → 恢复播放（重置时间基准）
    ///
    /// 同步策略：
    /// - 有音频时钟：delay = vPTS - audioClock
    ///   - delay > 3ms 且 < 500ms → usleep 等待
    ///   - delay >= 500ms → 音频断流，不等待直接送显
    ///   - delay < -50ms → 视频落后，丢帧追赶
    /// - 无音频时钟：用墙钟 fallback
    func videoDecodeLoop() {
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard let frm = frame else { return }
        var frameCount = 0

        // 缓冲状态机阈值
        let bufferLowThreshold = 3     // 低于此值进入缓冲
        let bufferHighThreshold = 30   // 高于此值恢复播放

        while let dequeuedPkt = videoPacketQueue.dequeue() {
            var pkt: UnsafeMutablePointer<AVPacket>? = dequeuedPkt
            guard let ctx = codecCtx, let vStream = videoStream else {
                av_packet_free(&pkt)
                continue
            }
            avcodec_send_packet(ctx, pkt)
            while avcodec_receive_frame(ctx, frm) == 0 {
                // ---- 获取 CVPixelBuffer ----
                var pixelBuffer: CVPixelBuffer?

                if frm.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
                    // 硬解路径：VideoToolbox 解码后直接输出 CVPixelBuffer（在 data.3 中）
                    guard let ptr = frm.pointee.data.3 else { continue }
                    pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(ptr).takeUnretainedValue()
                } else {
                    // 软解路径：YUV 数据通过 sws_scale 转 NV12，再拷贝到 CVPixelBuffer
                    pixelBuffer = softDecodeToPixelBuffer(frame: frm, codecCtx: ctx)
                }
                guard let pb = pixelBuffer else { continue }

                // ---- 计算帧的显示时间 ----
                let pts = frm.pointee.best_effort_timestamp
                let timeBase = vStream.pointee.time_base
                let ptsSec = (pts == Int64(bitPattern: 0x8000000000000000)) ? 0 : Double(pts) * av_q2d(timeBase)
                let presentationTime = CMTime(seconds: ptsSec, preferredTimescale: 600)

                frameCount += 1

                // ---- 缓冲状态机 ----
                let vqCount = videoPacketQueue.count
                if !isBuffering && vqCount < bufferLowThreshold {
                    // 数据不足，进入缓冲状态
                    isBuffering = true
                    // 重置音频时钟，恢复后重新建立同步基准
                    audioClockLock.lock()
                    audioClockReady = false
                    audioClockLock.unlock()
                    firstVideoPTSSec = -1
                }
                if isBuffering {
                    // 等待队列积累到足够数据
                    while isPlaying && videoPacketQueue.count < bufferHighThreshold {
                        usleep(10_000) // 10ms
                    }
                    // 恢复播放，重置时间基准避免时钟跳变
                    isBuffering = false
                    firstVideoPTSSec = ptsSec
                    playbackStartTime = CFAbsoluteTimeGetCurrent()
                }

                // ---- 音视频同步 ----
                if audioClockReady {
                    let aClock = getAudioClockSec()
                    let delay = ptsSec - aClock

                    if delay > 0.003 && delay < 0.5 {
                        // 视频超前音频：等待（usleep 精度优于 Thread.sleep）
                        usleep(UInt32(delay * 1_000_000))
                    } else if delay < -0.05 {
                        // 视频落后音频超过 50ms：丢帧追赶
                        continue
                    }
                    // delay >= 0.5：音频断流，不等待直接送显
                } else {
                    // 音频时钟未就绪（无音频流或缓冲恢复后）：用墙钟同步
                    if firstVideoPTSSec < 0 {
                        firstVideoPTSSec = ptsSec
                        playbackStartTime = CFAbsoluteTimeGetCurrent()
                    }
                    let delay = (ptsSec - firstVideoPTSSec) - (CFAbsoluteTimeGetCurrent() - playbackStartTime)
                    if delay > 0.003 && delay < 2.0 {
                        usleep(UInt32(delay * 1_000_000))
                    }
                }

                // ---- 送显 ----
                enqueueSampleBuffer(pixelBuffer: pb, presentationTime: presentationTime)
            }
            av_packet_free(&pkt)
        }
        av_frame_free(&frame)
    }

    /// 将 CVPixelBuffer 包装成 CMSampleBuffer 并送入 displayLayer 渲染
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

    /// 软解 fallback：将 FFmpeg 解码的 YUV 帧转换为 CVPixelBuffer
    /// 流程：sws_scale(YUV→NV12) → CVPixelBufferCreate → memcpy 拷贝 Y/UV 平面
    func softDecodeToPixelBuffer(frame: UnsafeMutablePointer<AVFrame>,
                                  codecCtx: UnsafeMutablePointer<AVCodecContext>) -> CVPixelBuffer? {
        let w = Int(codecCtx.pointee.width), h = Int(codecCtx.pointee.height)

        // 懒初始化 SwsContext（整个播放过程只创建一次）
        if swsCtx == nil {
            swsCtx = sws_getContext(Int32(w), Int32(h), codecCtx.pointee.pix_fmt,
                                    Int32(w), Int32(h), AV_PIX_FMT_NV12, SWS_BILINEAR, nil, nil, nil)
        }
        guard let sws = swsCtx else { return nil }

        // 分配 NV12 输出 buffer（Y 平面 + UV 交错平面）
        let bufY = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h)
        let bufUV = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h / 2)
        defer { bufY.deallocate(); bufUV.deallocate() }

        let dstData: [UnsafeMutablePointer<UInt8>?] = [bufY, bufUV, nil, nil]
        let dstLine: [Int32] = [Int32(w), Int32(w), 0, 0]

        // FFmpeg frame 的 data 是 tuple，需要转成数组
        let srcData: [UnsafePointer<UInt8>?] = [
            frame.pointee.data.0.map { UnsafePointer($0) },
            frame.pointee.data.1.map { UnsafePointer($0) },
            frame.pointee.data.2.map { UnsafePointer($0) },
            frame.pointee.data.3.map { UnsafePointer($0) }
        ]
        let srcLine: [Int32] = [frame.pointee.linesize.0, frame.pointee.linesize.1,
                                 frame.pointee.linesize.2, frame.pointee.linesize.3]
        sws_scale(sws, srcData, srcLine, 0, Int32(h), dstData, dstLine)

        // 创建 CVPixelBuffer 并拷贝 NV12 数据
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

// MARK: - 音频解码线程
private extension FFmpegVTPlayerViewController {

    /// 音频解码主循环
    /// 职责：从 audioPacketQueue 取包 → 解码 → SwrContext 重采样 → 写入 PCM 缓冲区
    ///
    /// 音频时钟初始化：
    /// - 只在第一帧设置 audioPTSSec 基准值（用帧的 PTS）
    /// - 之后完全由 fillAudioBuffer 的消费速率推进时钟
    /// - 不能每帧都重置，否则解码速度快于播放速度时时钟会跳变
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
                // 只在第一帧（audioClockReady == false）时设置时钟基准
                // 之后由 AudioQueue 回调的 fillAudioBuffer 按消费速率推进
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

                // 计算重采样后的输出采样数
                let outSamples = swr_get_out_samples(swr, frm.pointee.nb_samples)
                guard outSamples > 0 else { continue }

                // 分配输出 buffer：S16 stereo = 2 channels × 2 bytes per sample
                let outBufSize = Int(outSamples) * Int(kAudioChannels) * 2
                let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: outBufSize)
                defer { outBuf.deallocate() }

                // swr_convert：将解码后的音频帧重采样为 S16/44100/stereo
                // 输入指针类型转换：extended_data 是 UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>
                // swr_convert 需要 UnsafeMutablePointer<UnsafePointer<UInt8>?>，通过 assumingMemoryBound 转换
                var outPtr: UnsafeMutablePointer<UInt8>? = outBuf
                let inPtr = UnsafeMutableRawPointer(frm.pointee.extended_data)!
                    .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                let converted = withUnsafeMutablePointer(to: &outPtr) { pp in
                    swr_convert(swr, pp, outSamples, inPtr, frm.pointee.nb_samples)
                }
                if converted > 0 {
                    let bytes = Int(converted) * Int(kAudioChannels) * 2
                    // 写入 PCM 缓冲区，带背压控制（超过 256KB 会阻塞等待）
                    enqueueAudioPCM(Data(bytes: outBuf, count: bytes))
                }
            }
            av_packet_free(&pkt)
        }
        av_frame_free(&frame)
    }
}
