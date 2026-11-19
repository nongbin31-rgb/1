# 清阅在线漫画 (KedaOnlineReader)

纯原生 iOS / iPadOS（Swift + SwiftUI，iOS 16+）在线漫画阅读器。  
以**在线图源**为架构基底，内置完整的 **Anime4K v4（Metal 多 Pass 实时超分）** 与 **Waifu2x（CoreML 端侧 2x 超分）** 双引擎管线，支持在 Windows 环境下通过 GitHub Actions 自动编译打包未签名 `.ipa` 并在真机自签安装。

---

## 核心特性

1. **纯在线图源基底**
   - 统一 `MangaSourceProtocol` 抽象，内置：
     - **内置在线演示源**：含低清 JPEG 压缩线稿/彩漫测试页（640×960）以及真实 HTTPS 在线图片流，装上即可零配置实测超分效果。
     - **通用 JSON 在线源**：只需填入你的 REST API `Base URL` 及可选 `Authorization` / `Referer` 请求头，即可对接自建图源服务。
2. **双引擎经典超分管线（接入官方开源上游）**
   - **Anime4K v4（Metal 实时）**：基于 [imxieyi/Anime4KMetal](https://github.com/imxieyi/Anime4KMetal) 与 [bloc97/Anime4K](https://github.com/bloc97/Anime4K)
     - 完整支持 6 大经典多 Pass 管线预设：`AAFast`、`BBFast`、`CAFast`、`AAHQ`、`BBHQ`、`CAHQ`
     - 支持 `Anime4K_Thin_HQ`（细化线稿）与 `Anime4K_Darken_HQ`（加深线稿）末端附加滤镜
     - 内置最大边 `≤ 2500px` 显存防爆门控、`CIColorControls` sRGB 标准化与 `rgba8Unorm` 共享纹理读回
   - **Waifu2x（CoreML 深度）**：基于 [imxieyi/waifu2x-ios](https://github.com/imxieyi/waifu2x-ios)
     - 完整支持 10 组 2x 放大预设（漫画 `anime_*` 与照片 `photo_*` 各 5 档：无降噪 + 降噪 0~3）
     - 内置 `200px ~ 2500px` 双向尺寸安全拦截、`CGContext` 强制位图预解码避坑以及 `actor` 串行防 OOM 调度
3. **沉浸式阅读器与双轨拟真翻页引擎**
   - **双轨独立翻页流水线**：
     - **仿真书本卷页 (`PageEffect_Curling`)**：基于硬件加速 3D 网格折叠与安全排队状态机，杜绝连续手势重入崩溃，支持日漫 (RTL) 反向翻页、书脊中缝立体渐变阴影与 Taptic 微触觉/翻页音效联动。
     - **阻尼磁吸分页 (`PageEffect_SnapPage`)**：基于重写 `targetContentOffset` 物理吸附对齐算法，彻底解决单页放大漫游时的手势冲突，停靠自然顺滑。
     - **零延迟模式 (`PageEffect_Instant`)**：消除切页动画，毫秒级即时刷新，专为高刷与纯净阅读设计。
   - 支持条漫无限滚动（已内置视口外位图内存自动回收机制，杜绝长篇 OOM 闪退）。
   - 顶部实时显示分辨率变化与超分耗时（如 `Anime4K · 640×960 → 1280×1920 · 65ms`）。
   - 内置**左右分屏拖动对比滑块**（左侧原图 1x vs 右侧超分 2x），支持放大细看线条重建效果。

---

## Windows 零 Mac 硬件编译与自签安装教程

### 第一步：推送代码到 GitHub 仓库
1. 在 GitHub 上新建一个**私有仓库**（Private Repository）。
2. 在 Windows 的 PowerShell 中进入 `KedaOnlineReader` 目录并推送代码：
   ```powershell
   cd e:\App\Keda\KedaOnlineReader
   git init -b main
   git add .
   git commit -m "init iOS online manga reader with Anime4K and Waifu2x"
   git remote add origin https://github.com/<你的用户名>/<你的仓库名>.git
   git push -u origin main
   ```

### 第二步：云端自动编译出 `.ipa`
1. 打开 GitHub 仓库页面的 **Actions** 标签页，可以看到 `Build Unsigned iOS IPA` 正在运行（约 4~6 分钟）。
2. 构建完成后，点击进入该次构建记录，在底部 **Artifacts** 中下载 `KedaOnlineReader-unsigned-ipa.zip`，解压得到 `KedaOnlineReader-unsigned.ipa`。

### 第三步：在 Windows 上自签安装到 iPhone / iPad
任选其一即可：
- **方式 1：Sideloadly（最简单）**
  1. Windows 安装 iTunes（官网非微软商店版）与 [Sideloadly](https://sideloadly.io/)。
  2. 数据线连接 iPhone/iPad，把 `KedaOnlineReader-unsigned.ipa` 拖入 Sideloadly，登录你的 Apple ID 点击 **Start**。
  3. 安装完成后在手机进入 `设置 -> 通用 -> VPN 与设备管理` 信任证书，并在 `设置 -> 隐私与安全性` 开启「开发者模式」。
- **方式 2：SideStore / AltStore（支持 Wi-Fi 自动续签）**
  - 首次通过 Windows 的 AltServer 安装 SideStore 后，后续可直接在手机内用 Wi-Fi 导入并每 7 天自动续签，无需再连电脑。

---

## 本地 macOS 编译说明（若后续切到 Mac）
```bash
brew install xcodegen
bash scripts/fetch_vendor.sh
xcodegen generate
open KedaOnlineReader.xcodeproj
```

## 开源组件许可
- `imxieyi/waifu2x-ios` — MIT License
- `imxieyi/Anime4KMetal` — Apache License 2.0
- `bloc97/Anime4K` — MIT License
