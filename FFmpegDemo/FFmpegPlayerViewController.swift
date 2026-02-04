import UIKit
import AVFoundation
import CoreVideo

class FFmpegPlayerViewController: UIViewController {

    // 用于显示视频
    var displayLayer: AVSampleBufferDisplayLayer!

    // 音频播放
    var audioEngine: AVAudioEngine!
    var audioPlayerNode: AVAudioPlayerNode!
    var audioFormat: AVAudioFormat!

    // m3u8 链接
    let urlString = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black
        setupDisplayLayer()
        setupAudioEngine()

        // 异步播放
        DispatchQueue.global(qos: .userInitiated).async {
            self.playM3U8()
        }
    }

    func setupDisplayLayer() {
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = view.bounds
        view.layer.addSublayer(displayLayer)
    }

    func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        audioPlayerNode = AVAudioPlayerNode()
        audioEngine.attach(audioPlayerNode)

        let sampleRate: Double = 44100
        let channels: AVAudioChannelCount = 2
        audioFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)
        audioEngine.connect(audioPlayerNode, to: audioEngine.mainMixerNode, format: audioFormat)

        try? audioEngine.start()
        audioPlayerNode.play()
    }

    func playM3U8() {
        avformat_network_init()
        defer { avformat_network_deinit() }

        guard let urlC = strdup(urlString) else { return }
        var fmtCtx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard avformat_open_input(&fmtCtx, urlC, nil, nil) >= 0,
              avformat_find_stream_info(fmtCtx, nil) >= 0 else {
            print("Failed to open m3u8")
            return
        }

        // 找视频和音频流
        var videoStreamIndex: Int32 = -1
        var audioStreamIndex: Int32 = -1
        for i in 0..<fmtCtx!.pointee.nb_streams {
            let st = fmtCtx!.pointee.streams[Int(i)]!
            switch st.pointee.codecpar.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                videoStreamIndex = i
            case AVMEDIA_TYPE_AUDIO:
                audioStreamIndex = i
            default: break
            }
        }

        // 视频解码器
        let videoCodecPar = fmtCtx!.pointee.streams[Int(videoStreamIndex)]!.pointee.codecpar
        guard let videoCodec = avcodec_find_decoder(videoCodecPar.pointee.codec_id) else { return }
        let videoCodecCtx = avcodec_alloc_context3(videoCodec)
        avcodec_parameters_to_context(videoCodecCtx, videoCodecPar)
        avcodec_open2(videoCodecCtx, videoCodec, nil)

        // 音频解码器
        let audioCodecPar = fmtCtx!.pointee.streams[Int(audioStreamIndex)]!.pointee.codecpar
        guard let audioCodec = avcodec_find_decoder(audioCodecPar.pointee.codec_id) else { return }
        let audioCodecCtx = avcodec_alloc_context3(audioCodec)
        avcodec_parameters_to_context(audioCodecCtx, audioCodecPar)
        avcodec_open2(audioCodecCtx, audioCodec, nil)

        // 帧和包
        let frame = av_frame_alloc()
        let pkt = av_packet_alloc()

        // 视频缩放上下文 RGBA
        var swsCtx: OpaquePointer? = sws_getContext(
            videoCodecCtx!.pointee.width,
            videoCodecCtx!.pointee.height,
            videoCodecCtx!.pointee.pix_fmt,
            videoCodecCtx!.pointee.width,
            videoCodecCtx!.pointee.height,
            AV_PIX_FMT_RGBA,
            SWS_BILINEAR,
            nil, nil, nil)

        let videoWidth = Int(videoCodecCtx!.pointee.width)
        let videoHeight = Int(videoCodecCtx!.pointee.height)
        let bufferSize = av_image_get_buffer_size(AV_PIX_FMT_RGBA, Int32(videoWidth), Int32(videoHeight), 1)
        let videoBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(bufferSize))
        var dstData: [UnsafeMutablePointer<UInt8>?] = [videoBuffer, nil, nil, nil]
        var dstLinesize: [Int32] = [Int32(videoWidth * 4), 0, 0, 0]

        while av_read_frame(fmtCtx, pkt) >= 0 {
            if pkt!.pointee.stream_index == videoStreamIndex {
                avcodec_send_packet(videoCodecCtx, pkt)
                while avcodec_receive_frame(videoCodecCtx, frame) == 0 {
                    sws_scale(swsCtx,
                              frame!.pointee.data,
                              frame!.pointee.linesize,
                              0,
                              videoCodecCtx!.pointee.height,
                              &dstData,
                              &dstLinesize)

                    // 显示视频
                    DispatchQueue.main.async {
                        // TODO: 这里可以用 CVPixelBuffer + CMSampleBuffer + displayLayer
                        // 简化示意：你可以封装 dstData 为 CVPixelBuffer 并 append 到 displayLayer
                    }
                }
            } else if pkt!.pointee.stream_index == audioStreamIndex {
                avcodec_send_packet(audioCodecCtx, pkt)
                while avcodec_receive_frame(audioCodecCtx, frame) == 0 {
                    // 这里拿 PCM 数据
                    let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frame!.pointee.nb_samples))!
                    pcmBuffer.frameLength = pcmBuffer.frameCapacity
                    // 将 frame!.pointee.data[0] 复制到 pcmBuffer.floatChannelData
                    // 省略细节，实际需要 swr_convert 转码为 float32
                    // 然后播放
                    // audioPlayerNode.scheduleBuffer(pcmBuffer)
                }
            }
            av_packet_unref(pkt)
        }

        // 清理
        av_frame_free(&frame)
        av_packet_free(&pkt)
        sws_freeContext(swsCtx)
        avcodec_free_context(&videoCodecCtx)
        avcodec_free_context(&audioCodecCtx)
        avformat_close_input(&fmtCtx)
    }
}
