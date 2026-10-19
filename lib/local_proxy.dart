import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import 'hls_purify.dart';

/// 本地「清单净化」代理（电影世界 · 手机版）
///
/// ## 它做什么
///
/// 在 App 内起一个只监听 127.0.0.1 的 HTTP 服务，播放列表请求先打到它：
///
/// ```
/// ExoPlayer ──► http://127.0.0.1:<port>/adfilter.m3u8?u=<原地址>
///                    │
///                    ├─ 代理 GET 源站拿回 m3u8 文本（仅此一次请求）
///                    ├─ [HlsPurifier] 删除广告分片并改写清单
///                    └─ 返回改写后的清单
///                          │
/// ExoPlayer ◄──────────────┘
///   随后按清单里的「绝对地址」直连源站拉分片 —— 不经过本代理
/// ```
///
/// v2.2.0 修复：仅当原地址是 m3u8 时才包装；代理地址路径以 `.m3u8` 结尾，
/// 否则 ExoPlayer 会按扩展名把清单误判为渐进式媒体而无法播放（详见 [isHlsUrl]）。
///
/// ## 它刻意不做什么（重要）
///
/// **绝不转发 TS 分片数据。** 净化后的清单里，分片 URI 已被改写成源站绝对地址，
/// 后续分片由 ExoPlayer 直连源站。所以这里的数据吞吐量始终只有「一份清单」的大小
/// （通常几十 KB），既不翻倍流量，也不额外耗电。
/// —— TV 版 `RemoteServer.java` 的注释亦明确要求这一条：
///    「分片 URI 一律改写为绝对地址（代理返回的清单，其相对路径会被播放器按代理地址解析）」
///
/// ## 失败行为
///
/// 任何一步出错、或判据不足未能净化，都 **307 临时重定向回原地址** 直连播放。
/// 用 307 而非 301，是为了避免被播放器永久缓存而绕过净化。
class AdFilterProxy {
  AdFilterProxy._();
  static final AdFilterProxy instance = AdFilterProxy._();

  static const String _kUa =
      'Mozilla/5.0 (Linux; Android 13) Chrome/126.0';
  static const Duration _kTimeout = Duration(seconds: 15);

  HttpServer? _server;
  final http.Client _client = http.Client();

  /// 总开关。关掉后所有请求直接 307 回原地址（等同于没接这一层）。
  bool enabled = true;

  bool get running => _server != null;
  int get port => _server?.port ?? 0;

  /// 拉上游清单时的 User-Agent（部分源对 UA 敏感）
  String userAgent = _kUa;

  /// 启动本地服务。重复调用只会绑定一次。
  Future<void> start() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server!.listen(
        _handle,
        onError: (Object e) => _log('本地服务异常: $e'),
      );
      _log('本地净化服务已启动 127.0.0.1:${_server!.port}');
    } catch (e) {
      _server = null;
      _log('本地净化服务启动失败（去广告将不生效）: $e');
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
    }
  }

  /// v2.2.0 修复（全量点播失败的根因）：判断播放地址是否为 HLS（m3u8）清单。
  ///
  /// **为什么必须区分**：`VideoPlayerController.networkUrl` 默认不带 formatHint，
  /// 安卓端 `video_player_android` 在 formatHint 为空时会把
  /// `StreamingFormat` 置为 `UNKNOWN`（见 `VideoPlayerPlugin#videoAssetWithOptions`），
  /// 随后交给 ExoPlayer 的 `DefaultMediaSourceFactory` **按 URI 路径后缀**推断媒体类型。
  /// 若把 m3u8 包成路径不带 `.m3u8` 的地址（原实现是 `/adfilter?u=…`），
  /// ExoPlayer 会把它当「渐进式（progressive）」媒体去解析，报
  /// `None of the available extractors could read the stream` → 直接播不出来。
  /// 非 m3u8（如 mp4 直链）本来就不需要净化，直连最稳。
  static bool isHlsUrl(String url) {
    url = url.trim(); // v2.2.2（E2）：先去掉首尾空白，再判空/判后缀
    if (url.isEmpty) return false;
    // 去掉 query / fragment 后看路径后缀，兼容大写与带签名参数的地址
    var path = url;
    final q = path.indexOf('?');
    if (q >= 0) path = path.substring(0, q);
    final h = path.indexOf('#');
    if (h >= 0) path = path.substring(0, h);
    return path.toLowerCase().endsWith('.m3u8');
  }

  /// 把真实播放地址包装成本地代理地址。
  ///
  /// 若服务没起来（真机权限等原因）、或地址不是 m3u8，**原样返回** ——
  /// 保证最坏情况下仍能正常播放。
  ///
  /// v2.2.0 修复：① 只对 m3u8 地址包装（mp4 等直链与 v2.1.1 行为完全一致，不绕代理）；
  /// ② 代理地址路径以 `.m3u8` 结尾，让 ExoPlayer 仍能按后缀识别为 HLS 清单。
  /// v2.2.2（E1）：把「拼代理 URL」这一步抽成静态纯函数，便于纯单测护栏断言
  /// 路径必带 `.m3u8` 后缀（v2.2.0 全量点播播不出的根因就是代理路径缺该后缀）。
  /// 注意：仍按传入的**原始地址**包装，行为不变。
  static String buildProxyUrl(int port, String absoluteUrl) =>
      'http://127.0.0.1:$port/adfilter.m3u8?u=${base64Url.encode(utf8.encode(absoluteUrl))}';

  String proxyUrl(String absoluteUrl) {
    if (!enabled || _server == null) return absoluteUrl;
    if (!isHlsUrl(absoluteUrl)) return absoluteUrl;
    // 路径写死 `/adfilter.m3u8`（而非 `/adfilter`）；_handle 不校验路径，兼容无碍。
    return buildProxyUrl(_server!.port, absoluteUrl);
  }

  Future<void> _handle(HttpRequest req) async {
    HttpResponse resp = req.response;
    try {
      final target = _targetOf(req);
      if (target == null) {
        resp
          ..statusCode = HttpStatus.badRequest
          ..write('missing target');
        await resp.close();
        return;
      }
      await _serve(resp, target);
    } catch (e) {
      _log('处理异常: $e');
      try {
        final t = _targetOf(req);
        if (t != null) {
          resp
            ..statusCode = HttpStatus.temporaryRedirect
            ..headers.set(HttpHeaders.locationHeader, t);
          await resp.close();
          return;
        }
      } catch (_) {}
      try {
        resp.statusCode = HttpStatus.internalServerError;
        await resp.close();
      } catch (_) {}
    }
  }

  String? _targetOf(HttpRequest req) {
    final u = req.uri.queryParameters['u'];
    if (u == null || u.isEmpty) return null;
    try {
      // base64Url 的 padding 在 query 传递中可能被丢掉，补回来再解
      var s = u.replaceAll(' ', '+');
      while (s.length % 4 != 0) {
        s = '$s=';
      }
      return utf8.decode(base64Url.decode(s));
    } catch (_) {
      return null;
    }
  }

  Future<void> _serve(HttpResponse resp, String target) async {
    // 总开关关闭 → 直接回源
    if (!enabled) {
      await _redirect(resp, target, '开关关闭');
      return;
    }

    final http.Response upstream;
    try {
      upstream = await _client
          .get(Uri.parse(target), headers: {'User-Agent': userAgent})
          .timeout(_kTimeout);
    } catch (e) {
      await _redirect(resp, target, '清单获取失败: $e');
      return;
    }
    if (upstream.statusCode != 200) {
      await _redirect(resp, target, '源站返回 ${upstream.statusCode}');
      return;
    }

    final body = utf8.decode(upstream.bodyBytes, allowMalformed: true);
    if (!body.contains('#EXTM3U')) {
      // 不是 m3u8（例如 mp4 直链），原样透传，避免多绕一层
      await _redirect(resp, target, '非 m3u8');
      return;
    }

    final String outBody;
    if (HlsPurifier.isMasterPlaylist(body)) {
      // 主清单：把每个码率变体再包一层代理，选中后子清单仍会来净化
      final Uri parent = Uri.parse(target);
      outBody = HlsPurifier.rewriteMaster(
        body,
        parent.hasScheme ? parent.toString() : 'https://$target',
        (abs) => proxyUrl(abs),
      );
      _log('改写主清单 host=${parent.host}');
    } else {
      final purified = HlsPurifier.purifyMedia(body, target);
      if (purified == null) {
        // 判不准 / 命中红线 → 把播放权交还原地址（不用 301，避免被永久缓存）
        await _redirect(resp, target, '净化放弃');
        return;
      }
      outBody = purified;
      _log('净化返回清单 host=${Uri.parse(target).host} '
          '字节=${utf8.encode(outBody).length}');
    }

    resp
      ..statusCode = HttpStatus.ok
      ..headers.contentType =
          ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8')
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..write(outBody);
    await resp.close();
  }

  Future<void> _redirect(HttpResponse resp, String target, String why) async {
    _log('307 直连 原因=$why host=${Uri.tryParse(target)?.host}');
    resp
      ..statusCode = HttpStatus.temporaryRedirect
      ..headers.set(HttpHeaders.locationHeader, target);
    await resp.close();
  }

  void _log(String msg) {
    debugPrint('[adproxy] $msg');
    HlsPurifier.onLog?.call(msg);
  }
}
