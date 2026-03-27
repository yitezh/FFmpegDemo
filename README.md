# FFmpegDemo

演示 FFmpeg 在 iOS 项目中的集成与使用，包含三种不同的视频播放方案。

## 项目结构

```
FFmpegDemo/
├── ViewController.swift                          # 主界面，输入 URL 选择播放方式
├── FFmpegPlayerViewController.swift              # 方案一：FFmpeg + UIImageView
├── FFmpegSampleBufferPlayerViewController.swift  # 方案二：FFmpeg + AVSampleBufferDisplayLayer
├── FFmpegVTPlayerViewController.swift            # 方案三：FFmpeg + VideoToolbox 硬解 + 音频播放
├── FFmpegDemo-Bridging-Header.h                  # Bridging Header
└── FFmpeg-iOS/                                   # FFmpeg 静态库及头文件
    ├── include/                                  # libavcodec, libavformat, libavutil, libswscale, libswresample
    └── lib/                                      # .a 静态库
```

## 三种播放方案

### 方案一：FFmpeg + UIImageView

`FFmpegPlayerViewController`

- FFmpeg 软解码 → `sws_scale` 转 RGBA → `CGImage` → `UIImage` → `UIImageView` 显示
- 实现最简单，适合学习 FFmpeg 基本流程
- 缺点：性能差，视频大时容易 OOM，无帧率控制，无音频

### 方案二：FFmpeg + AVSampleBufferDisplayLayer

`FFmpegSampleBufferPlayerViewController`

- FFmpeg 软解码 → `sws_scale` 转 NV12 → `CVPixelBuffer` → `CMSampleBuffer` → `AVSampleBufferDisplayLayer` 渲染
- 利用系统渲染管线，性能优于方案一
- 缺点：仍为软解码，无音频

### 方案三：FFmpeg + VideoToolbox + 音视频同步

`FFmpegVTPlayerViewController`

- VideoToolbox 硬件解码（H.264/H.265），不支持时自动回退软解
- `libswresample` 音频重采样 → `AudioQueue` 播放
- 音频主时钟同步，视频帧根据音频播放进度控制显示时机
- 三线程架构：demux 线程 / 视频解码线程 / 音频解码线程
- HLS 自动解析 master playlist，选择合适的 variant
- 预缓冲 + 缓冲状态机，网络不稳定时自动暂停等待数据

## 依赖

- FFmpeg 静态库（已包含在 `FFmpeg-iOS/` 目录）
  - libavformat
  - libavcodec
  - libavutil
  - libswscale
  - libswresample
