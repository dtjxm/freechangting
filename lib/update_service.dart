/// 应用内更新服务（v2.2.5 新增，对标隔壁「免费畅听」的 update.js）。
///
/// 机制（无推送、打开时自检）：
///   ① App 冷启动拉一次远端 version.json，比对 [kVersionCode]，有新版才提示；
///   ② 用户点「立即更新」→ 下载 APK 到 App 专属目录 → flutter_app_installer 调系统安装器覆盖安装；
///   ③ 点「稍后」记住这个版本，下次启动不再打扰（手动检查仍会提示）。
///
/// 版本清单托管（2026-10-15 定稿，与免费畅听同一套）：GitHub 公开仓库 + ghproxy 国内加速镜像。
/// ⚠️ jsDelivr 国内四条线路已被墙、EdgeOne 免费域名 3 小时过期 —— 均已弃用。
/// ⚠️ ghproxy.net / gh-proxy.com 是公益镜像，哪天失效改 [kManifestMirrors] / [kApkMirrors]
///     数组换一个前缀即可，其它逻辑不用动。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_app_installer/flutter_app_installer.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'version.dart';

/// GitHub raw 基址 —— 复用免费畅听同一个仓库（dtjxm/freechangting），
/// 用独立文件名 `dysj-*` 与音乐软件的 `version.json` / `app-release.apk` 区分。
/// （token 是 fine-grained、只授权了这个仓库，建不了新仓库，故复用。）
const String _rawBase = 'https://raw.githubusercontent.com/dtjxm/freechangting/main';

/// v2.2.7 起 APK 体积超 100MB（base64 后），走 GitHub Contents API 推不上去，
/// 改上传到 GitHub Release 附件（固定文件名 dysj-release.apk）。
/// v2.2.8 起用 release 的 `latest` 直链，以后每次发版只换附件，App 不再需要改这里。
/// 国内直连 github.com 不稳，故仍走 ghfast.top 等镜像代理（实测可跟随 latest 重定向）。
const String _apkReleaseUrl =
    'https://github.com/dtjxm/freechangting/releases/latest/download/dysj-release.apk';

/// 清单地址候选 —— 逐个尝试，哪个通返回哪个（第三方镜像可能偶尔抽风）。
/// ⚠️ 与免费畅听同款踩坑结论：ghfast.top 实测 App 端 fetch 最稳（返回合法 JSON）；
/// ghproxy.net 浏览器能开、curl 也通，但 App fetch 拉 raw 会返回 HTML 错误页导致 jsonDecode 崩溃。
/// 故 ghfast.top 排第一，其余作回退。
const List<String> kManifestMirrors = [
  'https://ghfast.top/$_rawBase/dysj-version.json',
  'https://ghproxy.net/$_rawBase/dysj-version.json',
  'https://gh-proxy.com/$_rawBase/dysj-version.json',
  '$_rawBase/dysj-version.json',
];

/// APK 下载地址候选 —— 下载时逐个尝试，哪个通用哪个。
/// v2.2.7 起指向 GitHub Release 附件（raw 上的 dysj-release.apk 已停更、仍是旧的 v2.2.6）。
const List<String> kApkMirrors = [
  'https://ghfast.top/$_apkReleaseUrl',
  'https://ghproxy.net/$_apkReleaseUrl',
  'https://gh-proxy.com/$_apkReleaseUrl',
  _apkReleaseUrl,
];

/// 「稍后」版本记录的 shared_preferences key
const String _kSkipVersion = 'dysj_skip_update_version';

class UpdateInfo {
  final int versionCode;
  final String versionName;
  final String url;
  final int size;
  final String md5;
  final String note;
  final bool force;

  UpdateInfo.fromJson(Map<String, dynamic> j)
      : versionCode = (j['versionCode'] as num?)?.toInt() ?? 0,
        versionName = (j['versionName'] as String?) ?? '',
        url = (j['url'] as String?) ?? '',
        size = (j['size'] as num?)?.toInt() ?? 0,
        md5 = (j['md5'] as String?) ?? '',
        note = (j['note'] as String?) ?? '',
        force = (j['force'] as bool?) ?? false;

  bool get valid =>
      versionCode > 0 && url.isNotEmpty && url.startsWith('http');
}

enum CheckResult { latest, available, skipped, error }

class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  bool _busy = false;

  /// 拉远端版本清单 —— 多镜像逐个尝试，哪个通返回哪个。超时 8 秒/个，带时间戳绕缓存。
  Future<UpdateInfo?> fetchManifest({int timeoutMs = 8000}) async {
    for (final url in kManifestMirrors) {
      try {
        final sep = url.contains('?') ? '&' : '?';
        final res = await http
            .get(Uri.parse('$url${sep}_=${DateTime.now().millisecondsSinceEpoch}'))
            .timeout(Duration(milliseconds: timeoutMs));
        if (res.statusCode != 200) continue;
        final j = jsonDecode(utf8.decode(res.bodyBytes));
        if (j is! Map<String, dynamic>) continue;
        final info = UpdateInfo.fromJson(j);
        if (info.valid) return info;
      } catch (_) {
        // 继续试下一个镜像
      }
    }
    return null;
  }

  /// 是否比本机新
  bool isNewer(UpdateInfo? m) =>
      m != null && m.valid && m.versionCode > kVersionCode;

  /// 记录「稍后不再提醒」的版本
  Future<void> setSkipped(int versionCode) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kSkipVersion, versionCode);
  }

  Future<int> get skippedVersion async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kSkipVersion) ?? 0;
  }

  /// 检查更新。
  /// [silent] = true 时（启动静默），拉不到 / 已最新 / 已点过稍后 都完全不出声。
  /// 返回结果供调用方决定是否弹窗。
  Future<(CheckResult, UpdateInfo?)> check({bool silent = false}) async {
    final m = await fetchManifest();
    if (!isNewer(m)) return (CheckResult.latest, m);
    if (silent && await skippedVersion >= m!.versionCode) {
      return (CheckResult.skipped, m);
    }
    return (CheckResult.available, m);
  }

  /// 下载 APK，返回本地路径。带进度回调 [onProgress]（0~1）。
  /// 多镜像逐个尝试：哪个能下完（size 对得上）就用哪个，全失败才抛错。
  ///
  /// v2.2.6 修复版①：下载目录必须用 **外部专属目录**（getExternalStorageDirectory
  /// = /storage/emulated/0/Android/data/<包>/files，被 file_paths.xml 的
  /// external-files-path 覆盖）。之前用 getApplicationDocumentsDirectory
  /// = /data/data/<包>/app_flutter，FileProvider 的 files-path 不覆盖它，
  /// 安装时报 "Failed to find configured root that contains ..." 崩溃。
  ///
  /// v2.2.6 修复版②：若本地已有下载完整 APK（大小与清单一致），直接复用不重新下载。
  Future<String> download(UpdateInfo info,
      {void Function(double)? onProgress}) async {
    final dir = await _apkDir();
    final file = File('${dir.path}/update_${info.versionName}.apk');
    // 已有完整缓存 → 直接用（对标音乐软件：下载完成后重复点不再重下）
    final cached = await _validCached(file, info);
    if (cached != null) {
      if (onProgress != null) onProgress(1.0);
      return cached;
    }
    // APK 下载候选：镜像数组优先，info.url 兜底（清单里写的原始地址）
    final candidates = <String>[
      ...kApkMirrors,
      if (info.url.isNotEmpty && !kApkMirrors.contains(info.url)) info.url,
    ];
    String? lastErr;
    for (final url in candidates) {
      final client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(url));
        final resp = await client.send(req).timeout(const Duration(minutes: 5));
        if (resp.statusCode != 200) {
          throw Exception('HTTP ${resp.statusCode}');
        }
        final total = resp.contentLength ?? info.size;
        // 下载到临时文件，完整后改名——避免半截文件被当成「已下载缓存」
        final tmp = File('${file.path}.part');
        final sink = tmp.openWrite();
        var loaded = 0;
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          loaded += chunk.length;
          if (total > 0 && onProgress != null) {
            onProgress(loaded / total);
          }
        }
        await sink.close();
        // 校验大小：拿到的大小与清单里的对不上（镜像吐了缓存/半截）就换下一个
        if (info.size > 0 && loaded != info.size) {
          throw Exception('大小不符：期望 ${info.size}，实得 $loaded');
        }
        if (await file.exists()) await file.delete();
        await tmp.rename(file.path);
        return file.path;
      } catch (e) {
        lastErr = '$e';
        // 清掉半截文件，换下一个镜像
        try {
          final tmp = File('${file.path}.part');
          if (await tmp.exists()) await tmp.delete();
          if (await file.exists()) await file.delete();
        } catch (_) {}
      } finally {
        client.close();
      }
    }
    throw Exception('所有下载地址均失败${lastErr == null ? '' : '：$lastErr'}');
  }

  /// APK 下载目录：外部专属目录（被 file_paths.xml 的 external-files-path 覆盖，
  /// FileProvider 才能授权给系统安装器）。取不到外部存储时回退内部 files 目录。
  Future<Directory> _apkDir() async {
    final ext = await getExternalStorageDirectory(); // /storage/emulated/0/Android/data/<pkg>/files
    if (ext != null) return ext;
    return getApplicationDocumentsDirectory(); // 兜底（极少数设备）
  }

  /// 本地是否已有下载完整的 APK 缓存（大小与清单一致）。有则返回路径，无则 null。
  Future<String?> _validCached(File file, UpdateInfo info) async {
    try {
      if (!await file.exists()) return null;
      final len = await file.length();
      if (info.size > 0 && len == info.size) return file.path;
      // 大小对不上（旧半截/脏文件）→ 清掉
      await file.delete();
    } catch (_) {}
    return null;
  }

  /// 是否已有可安装的下载缓存（供 UI 判断显示「立即安装」还是「立即更新」）。
  Future<String?> cachedApkPath(UpdateInfo info) async {
    final dir = await _apkDir();
    return _validCached(File('${dir.path}/update_${info.versionName}.apk'), info);
  }

  /// 调系统安装器覆盖安装。成功（系统安装页弹出）返回 true。
  Future<bool> install(String path) async {
    final installer = FlutterAppInstaller();
    await installer.installApk(filePath: path);
    return true;
  }

  /// 一键：下载 + 安装（带进度回调）。防重入。
  Future<bool> downloadAndInstall(UpdateInfo info,
      {void Function(double)? onProgress}) async {
    if (_busy) return false;
    _busy = true;
    try {
      final path = await download(info, onProgress: onProgress);
      if (onProgress != null) onProgress(1.0);
      return await install(path);
    } finally {
      _busy = false;
    }
  }

  /// 格式化字节大小（对标音乐软件 fmtSize）
  static String fmtSize(int n) {
    if (n <= 0) return '';
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).round()} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
