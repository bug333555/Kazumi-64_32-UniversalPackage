## 新增支持
- 32位 ARM (armeabi-v7a) Android 设备
- Android 8.1 (SDK 27) 及以上老系统兼容
- 骁龙450 / MT6765 等老SOC实测通过
- 解锁特摄剧标签搜索（假面骑士、奥特曼等）

## 修改内容
- 32位 + 64位双ABI，按设备自动选择
- Android 11 及以下设备隐藏Vulkan选项，自动回退OpenGL
- arm64 注入兼容版 libmpv，修复由于过老的SOC不适配的兼容性问题而导致的白屏

## 运行要求
- 推荐 Android 8.1 (SDK 27) 及以上
- 2GB+ 运行内存

## 已知问题
过于老旧的部分华为或荣耀机型在使用本应用时，用于验证网站的验证码功能可能会无法使用，出现反复重复的验证情况，以及部分资源规则视频无法加载解析失败等，该问题需要更新华为的Huawei WebView到较新版本才能够解决，因此出现该状况的机型请使用那些不需要验证码的资源规则或者更新Huawei WebView

## 下载
前往 [Releases](https://github.com/bug333555/Kazumi-32-/releases) 下载最新 APK

## 更新说明
适配版不定时更新，跟随 Kazumi 上游主版本

## 问题反馈
遇到兼容性问题请提 Issue，附上：
- 设备型号（如 OPPO A5 PBAM00）
- Android 版本（设置 → 关于手机）以及Kazumi内的报错信息
- SOC 型号（可用 DevCheck 等 App 查看）
- 问题描述（白屏/闪退/视频无法播放等）
- 操作步骤（如何触发的问题）

## 鸣谢
- 原项目：[Predidit/Kazumi](https://github.com/Predidit/Kazumi)
- 弹幕服务：DanDanPlay API
- 图标：Yuquanaaa / [Pixiv](https://www.pixiv.net/artworks/116666979)
- 字体：Mi Sans by Xiaomi
