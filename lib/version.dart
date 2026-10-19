/// 应用版本号 —— **唯一事实源**。
///
/// 规则：必须与 `pubspec.yaml` 的 `version:` 版本名一致（`+` 后的 build 号除外）。
/// 关于页头部、关于页「版本信息」首行、`我的` 页脚都从这里取，避免各写一份而漂移。
/// 由 `test/version_guard_test.dart` 静态校验，不一致时测试会失败。
library;

const kAppVersion = 'v2.2.9';

/// 应用 build 号（versionCode）—— 与 `pubspec.yaml` 的 `version:` 里 `+` 后数字一致。
/// v2.2.5 应用内更新用它跟远端 version.json 的 versionCode 比对，判断是否有新版。
/// 发版时和 pubspec 一起改（version_guard_test.dart 不校验这个 int，但发布脚本会校验）。
const kVersionCode = 57;
