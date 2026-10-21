# Kazumi 2.3.9 紧凑来源页与播放兼容候选

日期：2026-10-21

这是首轮试验包的后续修正版。首轮只恢复了播放器内的选集面板，遗漏了截图对应的播放来源页；同时把 API21/v1.1.5 原生库与 2.3.9 media_kit 组合混用了，导致无法加载进度条和播放的风险没有被消除。

## 修正内容

- `SourceSheetView` 改为 2.2.0 的来源页布局：横向来源标签、状态圆点、来源结果卡片、底部别名/手动检索入口和浏览器按钮；保留 2.3.9 的搜索、验证码和播放回调逻辑。
- media_kit、media_kit_video、`media_kit_libs_video` 及 Android native glue 统一锁定到已验证的 2.2.0 ref：`652cfc765a43792be8bec429ea72296d5d96fb7d`。
- 当 `VideoSourceFormat` 仍为 `auto` 时，根据已解析 URL 的 `.m3u8/.m3u` 后缀重新设置 `demuxer-lavf-format=hls`，恢复旧设备 HLS 播放路径。
- 新增 HLS URL 回归测试，并纳入 Actions focused test 命令。

## 构建与验证

- 分支提交：`229cedbd`。
- GitHub Actions：<https://github.com/bug333555/Kazumi-64_32-UniversalPackage/actions/runs/39519164021>。
- Flutter 依赖、两个 focused tests、静态分析、universal APK、native 替换、zipalign 和签名均通过。
- APK：`com.predidit.kazumi`，`2.3.9/20309`，minSdk `24`，包含 `arm64-v8a`、`armeabi-v7a`、`x86_64`。
- 文件大小：`70,276,345` bytes。
- SHA-256：`eaeb7e370ec17446b6fed66000626fa45af8f887f073ef35063b877533caf445`。
- v2/v3 试验签名证书 SHA-256：`6dabd549abc4ec7b37faab60030260dfc332001b3866e397e6e71d220bd19d60`。

四个自有 ARM 库在最终 APK 中仍与已验证归档一致：

| APK entry | SHA-256 |
| --- | --- |
| `lib/arm64-v8a/libmpv.so` | `087ec82b44ef8628b6d40c9bf9366bed568681aeb006704488b8760caaa02be0` |
| `lib/arm64-v8a/libmediakitandroidhelper.so` | `a6862031015e390aa8a64536411132cf4df6a5a9dcf782f0d68b995380a1cccb` |
| `lib/armeabi-v7a/libmpv.so` | `6fe82d0619cfb3afc5781626939cafdbacf6e12640b790c797e652c020d80a22` |
| `lib/armeabi-v7a/libmediakitandroidhelper.so` | `698ce761945a3bdaf6ffe690e715fc510bc30a3571c5ac6768a734847232d5cc` |

试验包：[Kazumi-2.3.9-ui-compat-trial.apk](../dist/run-39519164021/Kazumi-2.3.9-ui-compat-trial.apk)。它仍使用一次性测试签名，不能覆盖已有正式签名安装；实体骁龙 450/Android 8.1 的 logcat 和实际播放验证尚未完成。
