# 第三方代码声明

本应用包含以下以 Apache License 2.0 授权的第三方代码。完整许可证文本见
[`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt)。

## HTV（HTWMedia/HTV）

- 仓库：https://github.com/HTWMedia/HTV
- 许可证：Apache License 2.0
- 使用范围：`lib/source_health_store.dart`（通用存储）、`lib/live_source_health.dart`
  与 `lib/vod_source_health.dart`（两个业务封装）
- 对应原文件：`lib/common/utils/source_health.dart`

本项目的 `lib/source_health_store.dart` 改编自上述文件，直播/点播两个封装类
（`live_source_health.dart`、`vod_source_health.dart`）为本项目独立实现。主要修改：

1. 直接使用 `shared_preferences` 读写，移除原项目的 `PrefsUtil` / `LoggerUtil` 依赖；
2. 存储键由调用方注入（`live_source_health_v1` / `vod_source_health_v1`），
   避免与原应用的数据互相干扰；
3. 排序对象由 URL 字符串泛化为任意条目（直播线路用 URL，点播片源用 id），
   保留权重相同时的稳定顺序；
4. 增加可注入时钟（`SourceHealthStore.now`），便于单元测试覆盖冷却与过期逻辑；
5. 保留原实现的冷却档位（10 分钟 / 1 小时 / 6 小时 / 12 小时 / 24 小时）、
   7 天过期与 2000 条上限策略。

除上述文件外，本项目的其余代码均为独立实现。`lib/live_stall_detector.dart`
的起播后卡死检测在设计上参考了 HTV 的播放器看门狗思路，但为本项目重新实现，
未复制其源代码。GitHub 上的 FongMi/TV 与 Kazumi 项目仅用于架构与交互设计参考，
未复制其源代码（两者均为 GPL-3.0）。
