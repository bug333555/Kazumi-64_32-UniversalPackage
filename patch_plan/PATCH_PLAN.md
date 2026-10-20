# Kazumi 2.3.9 老设备兼容试验包计划

## 目标

生成一个只用于本地检查的 Kazumi 2.3.9 试验 APK：

1. 以 upstream tag `2.3.9`（提交 `025dcb5c2f62db881382c72f191d08b49a9feb41`）为功能基线。
2. 恢复已验证的 2.2.0 播放器详情页布局：播放器下方紧凑线路选择、三列选集卡片、原有选集/评论布局。只恢复展示层，保留 2.3.9 的播放器控制器、下载和网络代码所需接口。
3. 修复上游 Issue #2734 的 XPath 选集 Cookie/UA 传播缺口：选集请求只在同站或同注册域名时携带插件 Cookie，并由请求执行器使用同一个插件 User-Agent；跨站 URL 不携带 Cookie。
4. 两个 Android ABI 都替换为已验证的自研 v1.1.5/API21 `libmpv.so` 与 `libmediakitandroidhelper.so`，不使用上游 v1.3/新原生库。试验 APK 必须同时包含 `arm64-v8a` 和 `armeabi-v7a`。
5. 使用同签名、递增版本号和新包元数据生成可安装试验包；不上传 GitHub、不修改现有发行版、不安装到用户手机。

## 证据与输入

- 已验证原生归档：`C:\bug335\Kazumi_compat_backups\20261017-v115-api21-2687\Kazumi-v115-api21-2687-validated-20261017.zip`，SHA-256 `6c1ddbaaef8f70259a621bf950c9a80454eeb42d1966b13bffa791addac069b8`。
- 归档中的 ARM64 `libmpv.so` SHA-256 `087ec82b44ef8628b6d40c9bf9366bed568681aeb006704488b8760caaa02be0`。
- 归档中的 ARMv7 `libmpv.so` SHA-256 `6fe82d0619cfb3afc5781626939cafdbacf6e12640b790c797e652c020d80a22`。
- 归档中的 ARM64 helper SHA-256 `a6862031015e390aa8a64536411132cf4df6a5a9dcf782f0d68b995380a1cccb`。
- 归档中的 ARMv7 helper SHA-256 `698ce761945a3bdaf6ffe690e715fc510bc30a3571c5ac6768a734847232d5cc`。
- 2.2.0 页面基线来自 fork tag `origin-v2.3.3` 的 `lib/pages/video/video_page.dart`、`video_controller.dart` 和生成文件；该 tag 的 APK 发布标签虽为 v2.3.3，源码 version 仍为 2.2.0+20200。
- #2734 的当前上游代码仍在 `XPathRuleStrategy.prepareChapterRequest` 返回默认 `includeCookies: false`；Issue 当前为 open。

## 计划修改文件

- `lib/pages/video/video_page.dart`：恢复 2.2.0 紧凑详情页展示层。
- `lib/pages/video/video_controller.dart` 与 `.g.dart`：保留与旧页面兼容的全屏/侧栏状态和当前播放器生命周期实现；不回退 HLS 播放器逻辑。
- `lib/services/plugin/xpath_rule_strategy.dart`：增加同站 Cookie 请求标记，使用 `RuleExecutionConfig.baseUrl` 进行安全边界判断。
- `lib/services/plugin/rule_engine.dart` / `rule_engine_models.dart`：仅在需要时补充同站判断或测试 seam，避免跨站 Cookie 泄露；保持执行器 Cookie 与 UA 成对发送。
- `pubspec.yaml`：版本保持 2.3.9，试验 build number 递增；不得降低 Android minSdk。
- `tools/`、本计划和验证报告：记录双 ABI 替换、签名、API 级别和页面静态检查。

## 原生替换与验证

从归档读取四个 `.so`，写入 APK 对应 ABI 目录；对每个成员在替换前后计算 SHA-256。使用 `aapt` 检查包名、版本、minSdk、ABIs，使用 `zipalign` 和 `apksigner` 检查 APK。要求 APK 同时包含 `lib/arm64-v8a/` 与 `lib/armeabi-v7a/` 的 mpv/helper 四个文件，并验证两个 libmpv ELF 的 API 21 兼容性。

## 风险与回滚

- 上游 2.3.9 的 Flutter/media-kit 依赖可能要求新的本地工具链；本地试验只允许在当前工作树调整构建环境，不改变用户全局工具配置。
- 2.2.0 页面与 2.3.9 控制器之间若出现字段/生成代码不匹配，优先补充兼容适配，不把整个 2.3.9 控制器回退到更早版本。
- #2734 的同站判断必须拒绝任意第三方 chapter URL；如果缺少可安全判断的 base host，保持不携带 Cookie。
- 试验失败时只删除本工作树的构建中间物；保留原工作树、归档、签名材料和既有发行版。

本机只有 Flutter 3.44.1，因此试验分支暂时把 Flutter SDK 约束改为 `>=3.44.1 <4.0.0`；应用版本仍为 2.3.9。该构建环境差异会记录在报告中，不代表上游正式构建约束已被修改。

## 验收门槛

1. `flutter test` 和 `flutter analyze` 通过，或记录明确的环境阻塞。
2. 静态检查证明旧页面使用紧凑线路/三列选集布局，未引用 2.3.9 的新选集侧栏作为主页面。
3. #2734 单元测试证明同站 XPath chapter 请求带 Cookie 与匹配 UA，跨站请求不带 Cookie。
4. APK 静态检查证明 package/version/signature/zipalign、双 ABI 和四个自研 native hash 正确。
5. 输出本地试验 APK 与报告，等待用户检查页面样式；不推送、不发布、不安装手机。
