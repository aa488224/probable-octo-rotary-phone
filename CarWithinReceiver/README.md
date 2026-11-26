# CarWithinReceiver

一个跑在 iOS 15 设备（如 iPhone 6s Plus）上的原生接收端 App，把 CarWithin 主手机上的 CarPlay 画面显示出来。

**为什么需要它**：CarWithin 官方接收页要 `MediaSource` / `WebCodecs`（iOS 16.4 / 17.1+ 才有），6s Plus 的 iOS 15 播不了。这个 App 用系统 `AVSampleBufferDisplayLayer` 硬解 H.264，绕开浏览器那套 API——它只是个"解码显示器"，不跑 CarPlay 会话，所以能装到 iOS 15。

## 原理

```
主 iPhone (iOS 16+, CarWithin)  --WebSocket /stream-->  6s Plus (本 App)
                                                          │
                                          decoder:"webcodecs" 握手
                                          收 1 字节关键帧标志 +
                                          8 字节微秒时间戳 + AVCC NALU
                                                          │
                                          AVSampleBufferDisplayLayer 硬解显示
```

关键点：握手时声明 `decoder:"webcodecs"` + `h265:false`，服务端就发裸 AVCC H.264 帧且强制 H.264（A9 没有 HEVC 硬解）。触控通过 `{"type":"touches"}` 回传。

## 一、有 Mac：直接编译安装

1. 把整个 `CarWithinReceiver` 文件夹拷到 Mac。
2. 双击 `CarWithinReceiver.xcodeproj` 用 Xcode 打开。
3. 选 Target → Signing & Capabilities → Team 选你自己的 Apple ID（免费个人开发者即可）。
   - 把 **Bundle Identifier** 改成你自己的唯一值（如 `com.你的名字.cwr`）。
4. 手机（6s Plus）用数据线连上，选它为运行目标。
5. 点 ▶ Run，Xcode 会签名并装到手机上。
6. 手机上：设置 → 通用 → VPN与设备管理 → 信任你的开发者证书。

免费 Apple ID 签名装的应用 **7 天过期**，到期需重签重装。

## 二、没 Mac：GitHub 云端编译出 IPA

工程里已带 `.github/workflows/build.yml`：

1. 在 GitHub 新建一个仓库，把 `CarWithinReceiver` 整个文件夹传上去（含隐藏的 `.github` 目录）。
2. 仓库 → Actions → 找到 "Build CarWithinReceiver IPA" → Run workflow。
3. 跑完后在 Artifacts 下载 `CarWithinReceiver-unsigned.ipa`（未签名）。
4. 用你的签名工具（牛逼助手等）签名后安装到 6s Plus。

> 云端编译的是未签名 IPA，必须自己签名才能装。

## 三、使用

1. 主 iPhone 装 CarWithin，正常启动 CarPlay，设「当前输出 = 浏览器」，打开「局域网接收页」。
2. 记下 App 显示的地址，如 `http://192.168.1.23:9888`。
3. 6s Plus 连**同一个 Wi-Fi**，打开本 App。
4. 输入框填 `192.168.1.23:9888`（只要 IP 和端口，去掉 `http://`），点 **Connect**。
5. 状态变绿、出现画面即成功。横屏使用，点屏幕可回传触控操作 CarPlay。
6. 顶部控制栏可以点视频区隐藏/显示。

### 局域网要求

- 主 iPhone 必须**连进** Wi-Fi（不能自己开热点）。
- 开 Wi-Fi 的可以是路由器 / 电脑 / 另一台有卡手机；6s Plus 没卡也能连 Wi-Fi。
- 6s Plus 和主 iPhone 必须同网段、能互访。

## 四、常见问题

- **一直 "waiting for video"**：主手机 CarPlay 没启动，或两台不在同一 Wi-Fi，或 IP 填错。
- **连上但黑屏**：主手机画面设置改成 H.264、480/720、30 FPS，然后重启 CarPlay；本 App 会请求关键帧。
- **提示 Cannot parse video format**：服务端发的 avcC 格式异常，确认 CarWithin 是 1.0.x 版本。
- **画面很卡**：让 6s Plus 靠近路由器，或主手机降到 480/30fps。

## 五、代码结构

| 文件 | 作用 |
|---|---|
| `AppDelegate.swift` | 入口 |
| `ViewController.swift` | 地址输入、状态、视频视图、触控回传 |
| `WSClient.swift` | WebSocket 握手、心跳、收帧、触控发送 |
| `H264Renderer.swift` | 解析 avcC → SPS/PPS，AVCC 帧喂给系统硬解码铺满屏幕 |

部署目标 iOS 15.0，纯 UIKit，无第三方依赖。

## 六、局限

- 只收视频 + 触控；声音走主 iPhone 或其蓝牙，本 App 不出声。
- 依赖 CarWithin 的私有协议，作者改版后可能需要同步调整协议解析。
- 仅供个人在自有设备上使用；CarWithin 本体为 AGPL-3.0，本 App 是独立实现的接收端。
