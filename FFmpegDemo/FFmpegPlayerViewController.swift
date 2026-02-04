import UIKit
import AVFoundation

// 你需要确保 Bridging-Header 已经引入 FFmpeg：
/*
 #include "libavformat/avformat.h"
 #include "libavcodec/avcodec.h"
 #include "libswscale/swscale.h"
 #include "libavutil/imgutils.h"
*/

class FFmpegPlayerViewController: UIViewController {
    
    var urlString: String!
    var displayView: UIImageView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        displayView = UIImageView(frame: view.bounds)
        displayView.contentMode = .scaleAspectFit
        view.addSubview(displayView)
        
        DispatchQueue.global().async {
            self.playM3U8(urlString: self.urlString)
        }
    }
    
    func playM3U8(urlString: String) {
        avformat_network_init()
        defer { avformat_network_deinit() }
        
        // 打开输入
        var fmtCtx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard avformat_open_input(&fmtCtx, urlString, nil, nil) >= 0 else {
            print("Cannot open input")
            return
        }
        guard avformat_find_stream_info(fmtCtx, nil) >= 0 else {
            print("Cannot find stream info")
            return
        }
        
        // 找视频流
        var videoStreamIndex: Int32 = -1
        for i in 0..<fmtCtx!.pointee.nb_streams {
            guard let stream = fmtCtx!.pointee.streams[Int(i)],
                  let codecpar = stream.pointee.codecpar else { continue }
            if codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                videoStreamIndex = Int32(i)
                break
            }
        }
        guard videoStreamIndex >= 0 else {
            print("No video stream")
            return
        }
        
        // 视频解码器
        guard let videoStream = fmtCtx!.pointee.streams[Int(videoStreamIndex)],
              let videoCodecPar = videoStream.pointee.codecpar else { return }
        let codecID = videoCodecPar.pointee.codec_id
        guard let videoCodec = avcodec_find_decoder(codecID) else { return }
        
        var videoCodecCtx = avcodec_alloc_context3(videoCodec)
        avcodec_parameters_to_context(videoCodecCtx, videoCodecPar)
        avcodec_open2(videoCodecCtx, videoCodec, nil)
        
        // sws scale
        let videoWidth = Int(videoCodecCtx!.pointee.width)
        let videoHeight = Int(videoCodecCtx!.pointee.height)
        let swsCtx = sws_getContext(videoCodecCtx!.pointee.width,
                                    videoCodecCtx!.pointee.height,
                                    videoCodecCtx!.pointee.pix_fmt,
                                    videoCodecCtx!.pointee.width,
                                    videoCodecCtx!.pointee.height,
                                    AV_PIX_FMT_RGBA,
                                    SWS_BILINEAR,
                                    nil, nil, nil)
        
        let bufferSize = av_image_get_buffer_size(AV_PIX_FMT_RGBA, Int32(videoWidth), Int32(videoHeight), 1)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(bufferSize))
        var dstData: [UnsafeMutablePointer<UInt8>?] = [buffer, nil, nil, nil]
        var dstLinesize: [Int32] = [Int32(videoWidth * 4), 0, 0, 0]
        
        var frame = av_frame_alloc()
        var packet = av_packet_alloc()
        
        while av_read_frame(fmtCtx, packet) >= 0 {
            if packet!.pointee.stream_index == videoStreamIndex {
                avcodec_send_packet(videoCodecCtx, packet)
                while avcodec_receive_frame(videoCodecCtx, frame) == 0 {
                    // frame data tuple -> array
                    var srcData: [UnsafePointer<UInt8>?] = [
                        frame!.pointee.data.0.map { UnsafePointer($0) },
                        frame!.pointee.data.1.map { UnsafePointer($0) },
                        frame!.pointee.data.2.map { UnsafePointer($0) },
                        frame!.pointee.data.3.map { UnsafePointer($0) },
                        frame!.pointee.data.4.map { UnsafePointer($0) },
                        frame!.pointee.data.5.map { UnsafePointer($0) },
                        frame!.pointee.data.6.map { UnsafePointer($0) },
                        frame!.pointee.data.7.map { UnsafePointer($0) }
                    ]

                    var srcLinesize: [Int32] = [
                        frame!.pointee.linesize.0, frame!.pointee.linesize.1, frame!.pointee.linesize.2, frame!.pointee.linesize.3,
                        frame!.pointee.linesize.4, frame!.pointee.linesize.5, frame!.pointee.linesize.6, frame!.pointee.linesize.7
                    ]
                    
                    sws_scale(swsCtx,
                              srcData,
                              srcLinesize,
                              0,
                              videoCodecCtx!.pointee.height,
                              dstData,
                              dstLinesize)
                    
                    // RGBA -> UIImage
                    let colorSpace = CGColorSpaceCreateDeviceRGB()
                    if let context = CGContext(data: buffer,
                                               width: videoWidth,
                                               height: videoHeight,
                                               bitsPerComponent: 8,
                                               bytesPerRow: Int(dstLinesize[0]),
                                               space: colorSpace,
                                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                       let cgImage = context.makeImage() {
                        let image = UIImage(cgImage: cgImage)
                        DispatchQueue.main.async {
                            self.displayView.image = image
                        }
                    }
                }
            }
            av_packet_unref(packet)
        }
        
        // 释放资源
        av_frame_free(&frame)
        av_packet_free(&packet)
        sws_freeContext(swsCtx)
        avcodec_free_context(&videoCodecCtx)
        avformat_close_input(&fmtCtx)
        buffer.deallocate()
    }
}
