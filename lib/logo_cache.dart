/// 台标本地缓存（v2.2.7 优化，不升版本）
///
/// 为什么不用 NetImage 直连：
///   ① 每次进页面/滚动都要重新请求几百个图床，弱网下长时间空白；
///   ② 同一批台标的图片是静态的，重复下载纯属浪费；
///   ③ 不少图床对移动端 UA/Referer 敏感，偶发 403。
///
/// 策略：首次联网取到 → 写入应用私有目录 `live_logo/<md5>.img`；之后一律从本地读，
/// 列表滚动零网络请求、秒出。文件名取 URL 的 md5，天然去重与长期有效。
///
/// v2.2.7 修复（缺陷 6）：支持**随包内置台标**。资产里的 logo 有三态：
///   · `''`                   → 无台标，界面走「首字色块」占位；
///   · `asset:cctv1.png`      → 随包资源（`assets/logos/cctv/cctv1.png`），**不发网络请求**；
///   · `asset:tv/abcd12.png`  → 随包资源（`assets/logos/tv/abcd12.png`，复用 PC 版台标库）；
///   · `http(s)://…`          → 网络台标，走本地缓存（下载一次，之后离线可用）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class LogoCache {
  LogoCache._(this._dir);

  /// 随包内置台标的引用前缀（资产层写入 `asset:<文件名>`）
  static const String assetScheme = 'asset:';

  /// 内置台标目录（pubspec.yaml 里已声明整个 `assets/logos/`）
  static const String bundledDir = 'assets/logos/cctv/';

  /// 内置台标根目录：`asset:tv/xxx.png` → `assets/logos/tv/xxx.png`
  static const String bundledRoot = 'assets/logos/';

  /// 是否是随包内置台标（形如 `asset:cctv1.png` / `asset:tv/xxx.png`）
  static bool isBundled(String logo) =>
      logo.startsWith(assetScheme) && logo.length > assetScheme.length;

  /// 内置台标 → Flutter 资源路径
  ///
  /// · `asset:cctv1.png`      → `assets/logos/cctv/cctv1.png`（央视 19 张）
  /// · `asset:tv/abcd12.png`  → `assets/logos/tv/abcd12.png`（复用 PC 版台标库）
  static String? bundledPath(String logo) {
    if (!isBundled(logo)) return null;
    final rel = logo.substring(assetScheme.length);
    return rel.contains('/') ? '$bundledRoot$rel' : '$bundledDir$rel';
  }

  final Directory _dir;
  static LogoCache? _inst;
  static Directory? _pendingDir;

  static LogoCache get instance => _inst ??= LogoCache._(_pendingDir!);

  /// 初始化目录（app 启动时调用一次）
  static Future<void> init() async {
    if (_inst != null) return;
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory('${base.path}${Platform.pathSeparator}live_logo');
      if (!d.existsSync()) d.createSync(recursive: true);
      _pendingDir = d;
      _inst = LogoCache._(d);
    } catch (e) {
      // 极端情况下退回临时目录，保证功能不崩
      final d = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}live_logo',
      );
      if (!d.existsSync()) d.createSync(recursive: true);
      _pendingDir = d;
      _inst = LogoCache._(d);
    }
  }

  /// 文件名 = URL 的稳定摘要（不引 crypto 依赖，纯 Dart 实现）
  File _file(String url) =>
      File('${_dir.path}${Platform.pathSeparator}${_hash(url)}.img');

  static String _hash(String s) {
    var h1 = 0x811c9dc5, h2 = 0x01000193;
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      h1 = (h1 ^ c) & 0xFFFFFFFF;
      h1 = (h1 * 16777619) & 0xFFFFFFFF;
      h2 = (h2 + c * (i + 7)) & 0xFFFFFFFF;
      h2 = ((h2 << 5) | (h2 >> 27)) & 0xFFFFFFFF;
    }
    return '${h1.toRadixString(16).padLeft(8, '0')}${h2.toRadixString(16).padLeft(8, '0')}';
  }

  /// 本地已有则直接返回 FileImage（Widget 会自动监听文件变化并刷新）
  ImageProvider? local(String url) {
    if (url.isEmpty) return null;
    if (isBundled(url)) return null; // 随包台标不走下载链路
    final f = _file(url);
    if (f.existsSync() && f.lengthSync() > 0) return FileImage(f);
    unawaited(_download(url));
    return null;
  }

  /// 统一的台标取图入口（列表页/播放页都走它）
  ///
  /// 优先级：随包内置 → 本地缓存（命中即返） → 触发网络下载（本次返回 null，落到占位）
  ImageProvider? provider(String logo) {
    if (logo.isEmpty) return null;
    final bundled = bundledPath(logo);
    if (bundled != null) return AssetImage(bundled);
    return local(logo);
  }

  /// 预热：把一页用到的台标先抓下来
  void prefetch(Iterable<String> urls) {
    var n = 0;
    for (final u in urls) {
      if (u.isEmpty || isBundled(u)) continue; // 内置台标无需预热
      final f = _file(u);
      if (!f.existsSync()) {
        unawaited(_download(u));
        if (++n >= 60) break; // 单批上限，避免一次性打满连接
      }
    }
  }

  Future<void> _download(String url) async {
    if (isBundled(url)) return; // 兜底：绝不把 asset: 当网络地址去下载
    final f = _file(url);
    if (f.existsSync() && f.lengthSync() > 0) return;
    try {
      final resp = await http
          .get(
            Uri.parse(url),
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
        await f.writeAsBytes(resp.bodyBytes, flush: true);
      }
    } catch (_) {
      // 取不到就保持占位，下次滚动到再试
    }
  }

  /// fire-and-forget
  static void unawaited(Future<void> f) {}
}
