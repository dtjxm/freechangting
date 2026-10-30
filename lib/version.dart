/// 应用版本号 —— **唯一事实源**。
///
/// 规则：必须与 `pubspec.yaml` 的 `version:` 版本名一致（`+` 后的 build 号除外）。
/// 关于页头部、关于页「版本信息」首行、`我的` 页脚都从这里取，避免各写一份而漂移。
/// 由 `test/version_guard_test.dart` 静态校验，不一致时测试会失败。
library;

const kAppVersion = 'v2.4.6';

/// 应用 build 号（versionCode）—— 与 `pubspec.yaml` 的 `version:` 里 `+` 后数字一致。
/// v2.2.5 应用内更新用它跟远端 version.json 的 versionCode 比对，判断是否有新版。
/// 发版时和 pubspec 一起改（version_guard_test.dart 不校验这个 int，但发布脚本会校验）。
///
/// v2.2.9 起固定用「高段位」build 号：v2.2.3~v2.2.6 的 split 包实际 versionCode
/// 是 2051~2054，v2.2.7/2.2.8 是 55/56。本轮取 2057，既高于 v2.2.6 的 2054，
/// 也高于 v2.2.7/2.2.8 的 55/56，三个旧版都能在应用内直接升级。后续版本请继续
/// 只增不减（例如 2.3.0+2058）。
const kVersionCode = 2066;
