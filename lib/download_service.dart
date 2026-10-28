/// v1.6.0 下载引擎：
/// - m3u8 分段流：解析清单（选最高码率变体）→ 剔除片头贴片广告分段 →
///   串行任务队列 + 单集内 6 路分段并发下载 → ffmpeg concat 合并 mp4
/// - mp4 直链：流式下载
/// - 存储：MediaStore 写入 Movies/电影世界/片名/第X集.mp4（系统媒体库可见）
/// - 断点续传：分段落盘应用缓存目录并持久化任务状态，启动自动续传
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:permission_handler/permission_handler.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';

import 'hls_purify.dart';

import 'api.dart';
import 'models.dart';

const String _kUa = 'Mozilla/5.0 (Linux; Android 13) Chrome/126.0';

// ---------- v1.9.9（代码审查 3.4）持久化字段安全转换 ----------
// 旧版本持久化的 JSON 字段可能出现类型漂移（int 存成 String/double 等），
// 直接 `as int` 会让整批下载任务加载失败；统一走兼容转换。
int _jsonInt(dynamic v, [int def = 0]) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v) ?? def;
  return def;
}

double _jsonDouble(dynamic v, [double def = 0]) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? def;
  return def;
}

String _jsonStr(dynamic v, [String def = '']) {
  if (v is String) return v;
  if (v == null) return def;
  return '$v';
}

bool _jsonBool(dynamic v, [bool def = false]) => v is bool ? v : def;

/// 与 MainActivity.kt 对接的原生存储通道：
/// saveToMovies → MediaStore 写入 Movies/电影世界/片名/第X集.mp4
/// deleteSaved  → 按 content:// URI 或路径删除
const MethodChannel _storageChannel = MethodChannel('movie_world/storage');

/// v1.9.8 前台服务通道：下载期间通知栏常驻，防锁屏/切后台被系统冻结断网
const MethodChannel _fgChannel = MethodChannel('movie_world/fg');

/// 下载任务状态：等待 / 下载中 / 合并中 / 已暂停 / 已完成 / 失败
class DownloadTask {
  final String id; // sourceId|vodId|groupIndex|epIndex
  final String movieName;
  final int epIndex;
  final String epName;
  // v1.6.1：以下字段在自动换线路/换片源兜底时可变
  int sourceId;
  String sourceName;
  String vodId;
  int groupIndex;
  String groupName;
  String url;
  String state; // waiting/running/merging/paused/done/failed
  double progress; // 0..1（按分段数）
  String? savedPath; // 完成后的媒体库路径（file:// 或 content://）
  String? error;
  List<String> segments; // 解析后的分段 URL（已剔除片头广告）
  bool hls; // true=分段流 / false=mp4 直链
  bool parsed; // 清单是否已解析（续传时直接用已有分段）
  int attempts; // v1.6.1 自动换线路/换片源已尝试次数
  int bytesDone; // v1.6.1 已下载字节
  int bytesTotal; // v1.6.1 预估总字节（0=未知）
  double speedBps; // v1.6.1 实时速度（字节/秒）
  int elapsedSec; // v1.6.1 已用时长（秒，累计）
  int etaSec; // v1.6.1 预计剩余（秒）
  String subcat; // v1.9.8 软件二级分类（如「动作片」，展示用）
  int doneAt; // v1.9.8 完成时间（epoch 毫秒，0=未知/旧任务）
  // v2.1 AES-128 加密 HLS（靳老师 2026-09-24：加密视频改为可下载）
  // v2.1.1 升级为「按分段多密钥」：密钥可轮换、加密/未加密分段可混排
  List<String> encKeyUrls; // 去重后的密钥地址（空列表=未加密）
  List<String> encKeyIvs; // 与 encKeyUrls 对齐：清单指定 IV（''=按媒体序号取）
  List<int> segKeys; // 每个分段用第几把钥匙（-1=该分段未加密）；未加密时空
  int encSeq; // 首个分段对应的媒体序号（IV 未指定时用）
  bool get hasEncryption => encKeyUrls.isNotEmpty;

  DownloadTask({
    required this.id,
    required this.sourceId,
    required this.sourceName,
    required this.vodId,
    required this.movieName,
    required this.groupIndex,
    required this.groupName,
    required this.epIndex,
    required this.epName,
    required this.url,
    this.state = 'waiting',
    this.progress = 0,
    this.savedPath,
    this.error,
    this.segments = const [],
    this.hls = true,
    this.parsed = false,
    this.attempts = 0,
    this.bytesDone = 0,
    this.bytesTotal = 0,
    this.speedBps = 0,
    this.elapsedSec = 0,
    this.etaSec = 0,
    this.subcat = '',
    this.doneAt = 0,
    this.encKeyUrls = const [],
    this.encKeyIvs = const [],
    this.segKeys = const [],
    this.encSeq = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'sourceId': sourceId,
        'sourceName': sourceName,
        'vodId': vodId,
        'movieName': movieName,
        'groupIndex': groupIndex,
        'groupName': groupName,
        'epIndex': epIndex,
        'epName': epName,
        'url': url,
        'state': state,
        'progress': progress,
        'savedPath': savedPath,
        'error': error,
        'segments': segments,
        'hls': hls,
        'parsed': parsed,
        'attempts': attempts,
        'bytesDone': bytesDone,
        'bytesTotal': bytesTotal,
        'speedBps': speedBps,
        'etaSec': etaSec,
        'elapsedSec': elapsedSec,
        'subcat': subcat,
        'doneAt': doneAt,
        'encKeyUrls': encKeyUrls,
        'encKeyIvs': encKeyIvs,
        'segKeys': segKeys,
        'encSeq': encSeq,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> j) => DownloadTask(
        id: _jsonStr(j['id']),
        sourceId: _jsonInt(j['sourceId']),
        sourceName: _jsonStr(j['sourceName']),
        vodId: _jsonStr(j['vodId']),
        movieName: _jsonStr(j['movieName']),
        groupIndex: _jsonInt(j['groupIndex']),
        groupName: _jsonStr(j['groupName']),
        epIndex: _jsonInt(j['epIndex']),
        epName: _jsonStr(j['epName']),
        url: _jsonStr(j['url']),
        state: _jsonStr(j['state'], 'waiting'),
        progress: _jsonDouble(j['progress']),
        savedPath: j['savedPath'] is String ? j['savedPath'] as String : null,
        error: j['error'] is String ? j['error'] as String : null,
        segments: ((j['segments'] ?? const []) as List)
            .whereType<String>() // v2.2.2：非 String 元素跳过，不再整条抛错
            .toList(),
        hls: _jsonBool(j['hls'], true),
        parsed: _jsonBool(j['parsed']),
        attempts: _jsonInt(j['attempts']),
        bytesDone: _jsonInt(j['bytesDone']),
        bytesTotal: _jsonInt(j['bytesTotal']),
        // v1.9.9（代码审查 3.4）：补齐 speedBps/etaSec 的恢复，兼容旧数据缺字段
        speedBps: _jsonDouble(j['speedBps']),
        etaSec: _jsonInt(j['etaSec']),
        elapsedSec: _jsonInt(j['elapsedSec']),
        subcat: _jsonStr(j['subcat']),
        doneAt: _jsonInt(j['doneAt']),
        // v2.1.1 旧持久化数据兼容：v2.1 是单密钥字段（encKeyUrl/encIvHex），
        // v2.1.1 之前则完全没有加密字段 → 都缺省为「未加密」
        encKeyUrls: _decodeKeyUrls(j),
        encKeyIvs: _decodeKeyIvs(j),
        segKeys: _decodeSegKeys(j),
        encSeq: _jsonInt(j['encSeq']),
      );

  /// v2.1 → v2.1.1 兼容：旧单密钥字段转成「全部分段共用一把钥匙」
  static List<String> _decodeKeyUrls(Map<String, dynamic> j) {
    final v = ((j['encKeyUrls'] ?? const []) as List).map((e) => '$e').toList();
    if (v.isNotEmpty) return v;
    final old = _jsonStr(j['encKeyUrl']);
    return old.isEmpty ? const [] : [old];
  }

  static List<String> _decodeKeyIvs(Map<String, dynamic> j) {
    final v = ((j['encKeyIvs'] ?? const []) as List).map((e) => '$e').toList();
    if (v.isNotEmpty) return v;
    final old = _jsonStr(j['encKeyUrl']);
    return old.isEmpty ? const [] : [_jsonStr(j['encIvHex'])];
  }

  static List<int> _decodeSegKeys(Map<String, dynamic> j) {
    final v = ((j['segKeys'] ?? const []) as List)
        .whereType<num>() // v2.2.2：非 num 元素跳过，不再整条抛错
        .map((e) => e.toInt())
        .toList();
    if (v.isNotEmpty) return v;
    final old = _jsonStr(j['encKeyUrl']);
    if (old.isEmpty) return const [];
    final n = ((j['segments'] ?? const []) as List).length;
    return List<int>.filled(n, 0);
  }
}

/// v2.1 HLS AES-128 加密信息（靳老师 2026-09-24：加密视频改为可下载）
/// 常见片源的加密就是标准 AES-128-CBC + PKCS7，密钥就在清单的 KEY 标签里，
/// 手机自己就能解开（和在线播放时 ExoPlayer 做的事一样），并非真正的版权保护。
/// v2.1.1 升级：密钥可轮换（一部片子多把钥匙）、加密/未加密分段可混排——
/// 每个分段记录自己用第几把钥匙（靳老师实测 v2.1 仍有「加密方式不支持」的片源）。
/// 只有 SAMPLE-AES 等非 AES-128 方式仍不支持（极罕见），明确报错并走自动换线路。
class HlsKeyEntry {
  final String url; // 密钥的绝对地址
  final String ivHex; // 该把钥匙在清单里指定的 IV（''=按分段媒体序号取 IV）
  const HlsKeyEntry(this.url, this.ivHex);
}

/// 清单解析结果：去重后的钥匙表 + 每个分段用第几把
class HlsKeyPlan {
  final int seqBase; // 清单 MEDIA-SEQUENCE（首个分段的媒体序号基数）
  final List<HlsKeyEntry> keys; // 去重后的钥匙（空=未加密）
  final List<int> segKeyIdx; // 与清单分段一一对应：钥匙下标，-1=该分段未加密
  const HlsKeyPlan(this.seqBase, this.keys, this.segKeyIdx);

  bool get hasEncryption => keys.isNotEmpty;

  /// 从媒体清单解析「分段 → 密钥」计划。纯函数，可单测。
  /// SAMPLE-AES / AES-128 未给密钥地址 → 抛异常（明确「不支持」而不是装没看见）。
  static HlsKeyPlan parse(String text, Uri playlistUrl) {
    var seq = 0;
    final seqM = RegExp(r'#EXT-X-MEDIA-SEQUENCE:(\d+)').firstMatch(text);
    if (seqM != null) seq = int.tryParse(seqM.group(1)!) ?? 0;

    final keys = <HlsKeyEntry>[];
    final idx = <int>[];
    // 逐行跟踪「当前 KEY」：HLS 语义是 KEY 标签只影响其后直到下一个 KEY 的分段
    String? curMethod;
    String? curUri;
    String? curIv;
    for (final raw in text.split(RegExp(r'[\r\n]+'))) {
      final l = raw.trim();
      if (l.isEmpty) continue;
      if (l.startsWith('#EXT-X-KEY:')) {
        final attrs = l.substring(11);
        curMethod =
            RegExp(r'METHOD=([A-Za-z0-9-]+)').firstMatch(attrs)?.group(1) ??
                'NONE';
        curUri = RegExp(r'URI="([^"]+)"').firstMatch(attrs)?.group(1);
        curIv =
            RegExp(r'IV=0[xX]([0-9a-fA-F]+)').firstMatch(attrs)?.group(1);
        continue;
      }
      if (l.startsWith('#')) continue;
      if (curMethod == 'AES-128') {
        if (curUri == null || curUri.isEmpty) {
          throw '该视频为加密流但未提供密钥地址，暂不支持下载';
        }
        final entry = HlsKeyEntry(
            playlistUrl.resolve(curUri).toString(), (curIv ?? '').toLowerCase());
        var k = keys.indexWhere((e) => e.url == entry.url && e.ivHex == entry.ivHex);
        if (k < 0) {
          k = keys.length;
          keys.add(entry);
        }
        idx.add(k);
      } else {
        if (curMethod != null && curMethod != 'NONE') {
          throw '该视频加密方式（$curMethod）暂不支持下载';
        }
        idx.add(-1);
      }
    }
    return HlsKeyPlan(seq, keys, idx);
  }
}

/// HLS 标准：清单未指定 IV 时，分段 IV = 该分段媒体序号的
/// 64 位大端十六进制（左补零到 16 字符）。纯函数，可单测。
String hlsIvForSeq(int seq) => seq.toRadixString(16).padLeft(16, '0');

/// v2.0 并发统计快照：每个任务独立一份（旧版是单例共享字段，多任务并行时
/// 会互相覆盖速度与剩余时间；改为 per-task 快照 + 单一全局节拍器）
class _TaskStat {
  int lastBytes;
  DateTime lastTick;
  _TaskStat(this.lastBytes) : lastTick = DateTime.now();
}

class DownloadService extends ChangeNotifier {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

  static const _kStore = 'downloads_v1';
  static const int _segConcurrency = 6;
  static const int _segRetry = 3;

  // ---------- v2.0 同时下载数量（按「集」算，靳老师 2026-09-24） ----------
  static const _kMaxConcurrent = 'dysj_max_concurrent';
  static const int kDefaultMaxConcurrent = 3;
  static const int kMaxConcurrentLimit = 10;
  int _maxConcurrent = kDefaultMaxConcurrent;

  /// 同时下载的任务数上限（单位：集 —— 一集即一个任务）
  int get maxConcurrent => _maxConcurrent;

  Future<void> setMaxConcurrent(int n) async {
    final v = n.clamp(1, kMaxConcurrentLimit);
    if (v == _maxConcurrent) return;
    _maxConcurrent = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kMaxConcurrent, v);
    } catch (_) {}
    notifyListeners();
    pump(); // 调大后立即多开几路
  }

  Future<void> _loadMaxConcurrent() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _maxConcurrent = (prefs.getInt(_kMaxConcurrent) ?? kDefaultMaxConcurrent)
          .clamp(1, kMaxConcurrentLimit);
    } catch (_) {}
  }

  // ---------- v2.0 找回影片补二级分类（靳老师 2026-09-24）----------
  // 从媒体库恢复的任务是本地层凭空重建的，媒体库里没有「类型」信息，必须补：
  // - 方案 A 自动补：联网用片名精确匹配取回分类，静默 + 限流 + 同名只查一次
  // - 方案 B 手动兜底：没命中的显示「未分类」，用户点一下从固定分类清单里选
  // 两条路都写进「片名 → 分类」记忆表，同片名下次找回直接命中，不再联网。
  static const _kMovieSubcat = 'dysj_movie_subcat';
  final Map<String, String> _subcatMemory = {};
  final Set<String> _subcatLookup = {}; // 本次会话已联网查过的片名
  bool _fillingSubcat = false;

  Future<void> _loadSubcatMemory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kMovieSubcat);
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw);
      if (m is Map) {
        _subcatMemory
          ..clear()
          ..addAll(m.map((k, v) => MapEntry('$k', '$v')));
      }
    } catch (_) {}
  }

  void _saveSubcatMemory() {
    () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kMovieSubcat, jsonEncode(_subcatMemory));
      } catch (_) {}
    }();
  }

  /// 给同片名的全部任务补分类（方案 A 自动 / 方案 B 手动共用）；
  /// [remember] 为真时写进记忆表，下次同片名找回直接用
  void setSubcatForMovie(String movieName, String subcat,
      {bool remember = true}) {
    var n = 0;
    for (final t in tasks) {
      if (t.movieName == movieName) {
        t.subcat = subcat;
        n++;
      }
    }
    if (remember && subcat.isNotEmpty) {
      _subcatMemory[movieName] = subcat;
      _saveSubcatMemory();
    }
    if (n > 0) {
      _persist();
      _notify();
    }
  }

  /// 方案 A：联网补分类。静默（失败不打扰用户）、限流（每部间隔 300ms、单次最多 20 部），
  /// 同名只查一次；一旦用户把任务删光就提前收手，不再浪费流量。
  Future<void> _autoFillSubcat(List<String> names) async {
    if (_fillingSubcat) return;
    _fillingSubcat = true;
    try {
      final todo = names
          .where((n) => n.isNotEmpty && !_subcatLookup.contains(n))
          .take(20)
          .toList();
      for (final name in todo) {
        if (!tasks.any((t) => t.movieName == name)) break; // 用户已删 → 收手
        _subcatLookup.add(name);
        String? got;
        try {
          got = await _lookupSubcat(name);
        } catch (_) {}
        if (got != null && got.isNotEmpty) {
          setSubcatForMovie(name, got);
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    } finally {
      _fillingSubcat = false;
    }
  }

  /// 用片名在最快的 1~2 个片源里精确匹配，取回 typeName（软件二级分类）
  Future<String?> _lookupSubcat(String name) async {
    final api = MacApi.instance;
    // v2.2.10（C1）：defaultSource 就是 sources.first，原写法会重复查同一源
    final cands = api.activeSources.take(3).toList();
    for (final s in cands) {
      if (s.url.isEmpty) continue;
      try {
        final items =
            await api.search(s, name).timeout(const Duration(seconds: 12));
        for (final e in items) {
          if (e.name.trim() == name.trim() && e.typeName.isNotEmpty) {
            return e.typeName;
          }
        }
      } catch (_) {}
    }
    return null;
  }

  final http.Client _client = http.Client();
  final List<DownloadTask> tasks = [];
  bool _pumping = false;
  bool _inited = false;
  bool _initing = false; // v2.2.2（D5）：初始化进行中标志 —— 防止并发重复初始化

  DownloadTask? taskOf(int sourceId, String vodId, int epIndex) {
    for (final t in tasks) {
      if (t.sourceId == sourceId && t.vodId == vodId && t.epIndex == epIndex) {
        return t;
      }
    }
    return null;
  }

  /// 真正的批量入队：每集一条任务（已存在且未失败的任务跳过）
  Future<int> addTasks(List<DownloadTask> newTasks) async {
    var added = 0;
    for (final t in newTasks) {
      final exist = tasks.where((x) => x.id == t.id).firstOrNull;
      if (exist != null && exist.state != 'failed') continue;
      tasks.removeWhere((x) => x.id == t.id);
      tasks.insert(0, t);
      added++;
    }
    _persistNow();
    notifyListeners();
    pump();
    return added;
  }

  /// App 启动初始化：读取持久化任务，中断的任务自动恢复为等待并续传
  Future<void> init() async {
    if (_inited || _initing) return;
    _initing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kStore);
      if (raw != null && raw.isNotEmpty) {
        final rawList = jsonDecode(raw);
        if (rawList is List) {
          // v2.2.2（A2）：逐条容错 —— 一条坏数据不再让整个下载列表消失；
          // 坏记录跳过、好记录保留（对齐 store.dart 的 _oneFavorite/_oneHistory 写法）
          for (final e in rawList) {
            try {
              final t = DownloadTask.fromJson(e as Map<String, dynamic>);
              // 上次退出时正在下载/合并 → 自动恢复为等待（分段已保留，续传）
              if (t.state == 'running' || t.state == 'merging') {
                t.state = 'waiting';
              }
              tasks.add(t);
            } catch (_) {/* 单条损坏 → 跳过，不影响其余任务 */}
          }
        }
      }
      _inited = true; // v2.2.2（D5）：仅在成功初始化后置位；失败保持 false，下次还能重试
    } catch (_) {
      _initing = false;
      return; // 读取失败 → 不置 _inited，下次重试
    }
    _initing = false;
    // v1.9.8：取消启动自动扫描找回（靳老师 2026-09-23）——已下载视频由下载管理页
    // 的「找回视频」手动按钮按需恢复，不再每次启动自动扫描
    await _loadMaxConcurrent(); // v2.0 并发数量设置
    await _loadSubcatMemory(); // v2.0 找回影片的分类记忆
    pump();
  }

  /// v1.9.5 媒体库扫描恢复：原生层查询 MediaStore 中 Movies/电影世界/ 下全部视频，
  /// 按「片名/集名」重建任务；文件已被系统删除的不会出现在查询结果里，自动跳过。
  /// 返回本次恢复的任务数。
  /// v1.9.7 最近一次扫描找回的视频数（0=没找回；启动提示/手动找回反馈用）
  int lastRestoreCount = 0;

  /// [requestPermission] 手动「找回视频」时传 true：会请求媒体可见权限；
  /// 启动自动恢复传 false：不弹权限框（本应用下载的文件无需权限即可见）
  Future<int> restoreFromLibrary({bool requestPermission = false}) async {
    if (!Platform.isAndroid) return 0;
    try {
      final sdk = await _storageChannel.invokeMethod<int>('sdkInt') ?? 0;
      // v1.9.6：Android 7~9 查询 MediaStore 必须有存储权限，拿不到就放弃
      if (sdk < 29) {
        var st = await Permission.storage.status;
        if (!st.isGranted) st = await Permission.storage.request();
        if (!st.isGranted) return 0;
      } else if (requestPermission) {
        // v1.9.7：Android 13+ 看其他应用创建的视频需要 READ_MEDIA_VIDEO，
        // 10~12 需要 READ_EXTERNAL_STORAGE；本应用自己下载的文件无需权限，
        // 用户拒绝也不阻断扫描（自有文件仍然可见）
        try {
          if (sdk >= 33) {
            var st = await Permission.videos.status;
            if (!st.isGranted) st = await Permission.videos.request();
          } else {
            var st = await Permission.storage.status;
            if (!st.isGranted) st = await Permission.storage.request();
          }
        } catch (_) {}
      }
    } catch (_) {}
    try {
      final raw = await _storageChannel.invokeMethod<List<dynamic>>('scanSaved');
      if (raw == null) return 0;
      var added = 0;
      final needSubcat = <String>[]; // v2.0 待补分类的片名
      for (final e in raw) {
        if (e is! Map) continue;
        final movie = '${e['movie'] ?? ''}'.trim();
        final name = '${e['name'] ?? ''}'.trim();
        final uri = '${e['uri'] ?? ''}'.trim();
        if (movie.isEmpty || name.isEmpty || uri.isEmpty) continue;
        final ep = name.toLowerCase().endsWith('.mp4')
            ? name.substring(0, name.length - 4)
            : name;
        // 同片名同集名的完成任务已存在 → 不重复恢复
        // v1.9.6 修复：不限状态去重 —— 同片同集正在下载中也不重复恢复旧文件
        final dup = tasks.any((t) =>
            t.movieName == movie &&
            (t.epName == ep || t.epName.isEmpty));
        if (dup) continue;
        if (tasks.any((t) => t.savedPath == uri)) continue;
        final epM = RegExp(r'第\s*(\d+)\s*集').firstMatch(ep);
        // v2.0 分类记忆命中则直接填上，没命中记下来待联网补
        final knownSub = _subcatMemory[movie] ?? '';
        if (knownSub.isEmpty && !needSubcat.contains(movie)) {
          needSubcat.add(movie);
        }
        tasks.add(DownloadTask(
          id: 'local|$movie|$ep',
          sourceId: -1,
          sourceName: '本地恢复',
          vodId: movie,
          movieName: movie,
          groupIndex: 0,
          groupName: '媒体库',
          epIndex: epM != null ? (int.tryParse(epM.group(1)!) ?? 1) - 1 : 0,
          epName: ep,
          url: uri,
          state: 'done',
          progress: 1,
          savedPath: uri,
          subcat: knownSub,
        ));
        added++;
      }
      lastRestoreCount = added;
      if (added > 0) {
        _persistNow();
        notifyListeners();
        // v2.0 方案 A：后台静默联网补分类（不阻塞找回结果返回）
        if (needSubcat.isNotEmpty) unawaited(_autoFillSubcat(needSubcat));
      }
      return added;
    } catch (_) {
      lastRestoreCount = 0;
      return 0;
    }
  }

  Timer? _persistTimer;

  /// 真正的落盘：把当前任务列表快照写入本地。
  Future<void> _persistWrite() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kStore, jsonEncode(tasks.map((t) => t.toJson()).toList()));
    } catch (_) {}
  }

  /// v2.2.2（B2）防抖落盘：500ms 内的多次调用合并为一次（定时器触发时写最新快照）。
  /// 高频调用（下载中每 10 个分段一次）不再反复全量写盘；定时器一定会触发，不丢写。
  void _persist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 500), () {
      _persistTimer = null;
      _persistWrite();
    });
  }

  /// v2.2.2（B2）立即落盘：取消防抖定时器并直写最新快照 ——
  /// 供 delete / 恢复 等「改完必须立刻持久化」的场景使用。
  void _persistNow() {
    _persistTimer?.cancel();
    _persistTimer = null;
    _persistWrite();
  }

  void _notify() => notifyListeners();

  // ---------- v1.9.8 前台服务：锁屏/切后台下载不断 ----------

  DateTime _lastFgUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  bool _fgAskedNotifPerm = false;

  Future<void> _fgStart() async {
    if (!Platform.isAndroid) return;
    if (!_fgAskedNotifPerm) {
      _fgAskedNotifPerm = true;
      try {
        var st = await Permission.notification.status;
        if (!st.isGranted) await Permission.notification.request();
      } catch (_) {}
    }
    try {
      await _fgChannel.invokeMethod('start');
    } catch (_) {}
  }

  void _fgStop() {
    try {
      // v2.0：invokeMethod 的失败是**异步**抛出的，同步 try/catch 接不住 →
      // 用 ignore() 兜住（测试环境/通道未注册时不再冒未捕获异常）
      _fgChannel.invokeMethod('stop').ignore();
    } catch (_) {}
  }

  /// 通知栏进度文本更新（2 秒节流）
  /// v2.0 并发：单任务显示片名+进度；多任务显示「N 个任务同时下载（平均 X%）」
  void _fgUpdateAll() {
    final now = DateTime.now();
    if (now.difference(_lastFgUpdate).inMilliseconds < 2000) return;
    final act = tasks
        .where((t) => t.state == 'running' || t.state == 'merging')
        .toList();
    if (act.isEmpty) return;
    _lastFgUpdate = now;
    String text;
    if (act.length == 1) {
      final t = act.first;
      text = t.state == 'merging'
          ? '「${t.movieName}」合并保存中'
          : '「${t.movieName}」下载 ${(t.progress * 100).toStringAsFixed(0)}%';
    } else {
      final avg =
          act.fold<double>(0, (a, t) => a + t.progress) / act.length;
      text = '${act.length} 个任务同时下载（平均 ${(avg * 100).toStringAsFixed(0)}%）';
    }
    try {
      _fgChannel.invokeMethod('update', {'text': text}).ignore();
    } catch (_) {}
  }

  /// v2.0 下载完成通知（点击可打开 App 并跳转下载管理页）
  void _notifyDone(DownloadTask t) {
    if (!Platform.isAndroid) return;
    try {
      _fgChannel
          .invokeMethod('done', {
            'movie': t.movieName,
            'ep': t.epName.isEmpty ? '第${t.epIndex + 1}集' : t.epName,
          })
          .ignore();
    } catch (_) {}
  }

  bool get _hasActive {
    for (final t in tasks) {
      if (t.state == 'waiting' ||
          t.state == 'running' ||
          t.state == 'merging') {
        return true;
      }
    }
    return false;
  }

  /// 占用并发槽位的任务数（下载中 + 合并中）
  int get _activeCount => tasks
      .where((t) => t.state == 'running' || t.state == 'merging')
      .length;

  /// v2.0 并发泵（按「集」算）：同时最多跑 maxConcurrent 个任务，谁结束就补位。
  /// 失败自动换线路的任务会回到 waiting，被下一轮补位逻辑重新捞起。
  Future<void> pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      if (_hasActive) await _fgStart();
      while (_activeCount < _maxConcurrent) {
        final next = tasks.where((t) => t.state == 'waiting').firstOrNull;
        if (next == null) break;
        unawaited(_launch(next));
      }
    } finally {
      _pumping = false;
    }
    // v1.9.8：队列空了就撤掉前台通知
    if (!_hasActive) _fgStop();
  }

  /// 启动单个任务；结束后释放槽位并立刻补位下一个等待任务
  Future<void> _launch(DownloadTask t) async {
    try {
      await _run(t);
    } catch (_) {
      // _run 内部已有兜底（标记 failed），此处仅防意外抛出
    } finally {
      _stats.remove(t.id);
      if (!_hasActive) _fgStop();
      pump();
    }
  }

  Directory _taskDir(Directory cache, DownloadTask t) {
    final dirName = t.id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
    // v2.2.10 修复 P0：换线路（attempts 递增）后使用独立分段目录，
    // 否则续传会把上一条线路的 seg_*.ts 当成「已下载」复用，成片花屏/错位。
    final epoch = t.attempts > 0 ? '_a${t.attempts}' : '';
    return Directory('${cache.path}/dl/$dirName$epoch');
  }

  /// v2.0 实时统计：per-task 字节/时间快照 + 单一全局节拍器（每秒一拍），
  /// 多任务并行时各任务的速度与剩余时间互不干扰
  final Map<String, _TaskStat> _stats = {};
  Timer? _ticker;

  void _startStats(DownloadTask t) {
    _stats[t.id] = _TaskStat(t.bytesDone);
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  /// 全局节拍：刷新所有活跃任务的 已用时长 / 速度 / 预计剩余
  void _tick() {
    final act = tasks
        .where((t) => t.state == 'running' || t.state == 'merging')
        .toList();
    if (act.isEmpty) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    for (final t in act) {
      final st = _stats[t.id] ??= _TaskStat(t.bytesDone);
      t.elapsedSec++;
      final now = DateTime.now();
      final dt = now.difference(st.lastTick).inMilliseconds;
      if (dt >= 800) {
        t.speedBps = (t.bytesDone - st.lastBytes) * 1000 / dt;
        st.lastBytes = t.bytesDone;
        st.lastTick = now;
      }
      if (t.state == 'running' &&
          t.bytesDone > 0 &&
          t.progress > 0.02 &&
          t.speedBps > 0) {
        // 分段流总大小未知 → 用已下比例反推
        t.bytesTotal = (t.bytesDone / t.progress).round();
        t.etaSec = ((t.bytesTotal - t.bytesDone) / t.speedBps).round();
      } else if (t.state != 'running') {
        t.etaSec = 0;
        t.speedBps = 0;
      }
    }
    _fgUpdateAll(); // v1.9.8 通知栏进度
    _notify();
  }

  Future<void> _run(DownloadTask t) async {
    if (t.state != 'waiting') return; // v2.0 并发下防重复启动/已删除任务
    t.state = 'running';
    t.error = null;
    _startStats(t);
    _notify();
    try {
      final cache = await getTemporaryDirectory();
      final dir = _taskDir(cache, t);
      await dir.create(recursive: true);

      // v1.6.1 续传时按已有分段文件恢复已下载字节
      if (t.hls && t.parsed) {
        var bytes = 0;
        for (final f in dir.listSync()) {
          if (f is File && f.path.endsWith('.ts')) bytes += await f.length();
        }
        t.bytesDone = bytes;
      }

      if (!t.parsed) await _parsePlaylist(t);
      if (t.state != 'running') return; // 解析期间被暂停/删除

      if (t.hls) {
        await _downloadSegments(t, dir);
        if (t.state != 'running') return;
        // v2.1 AES-128 加密流：分段全部下完后先解密，再走合并
        if (t.hasEncryption) {
          t.state = 'merging';
          _notify();
          await _decryptSegments(t, dir);
          if (t.state != 'merging') return;
        }
        t.state = 'merging';
        _notify();
        final out = await _mergeToMp4(t, dir);
        if (t.state != 'merging') return; // 合并期间被删除
        _checkMinSize(t, out); // v1.9.8 假完成拦截
        await _saveToMovies(t, out);
      } else {
        final out = File('${dir.path}/out.mp4');
        await _downloadMp4(t, out);
        if (t.state != 'running') return;
        _checkMinSize(t, out); // v1.9.8 假完成拦截
        await _saveToMovies(t, out);
      }
      t.state = 'done';
      t.progress = 1;
      t.doneAt = DateTime.now().millisecondsSinceEpoch; // v1.9.8 完成时间
      _notify();
      _notifyDone(t); // v2.0 下载完成通知
    } catch (e) {
      if (t.state == 'paused' || t.state == 'done') return;
      // v1.6.1 播放得看但下不了的常见场景：该线路/片源对下载不友好
      // → 自动换本片源的其他线路，线路用尽再自动换其他片源的同名影片
      final switched = await _autoSwitchForDownload(t);
      if (switched) return; // 任务已重置为 waiting，泵会继续跑
      t.state = 'failed';
      t.error = '$e';
      _notify();
    } finally {
      _stats.remove(t.id);
      t.speedBps = 0;
      _persist();
    }
  }

  /// v1.6.1 下载失败自动兜底：换线路 → 换片源（同名影片），最多尝试 5 次
  Future<bool> _autoSwitchForDownload(DownloadTask t) async {
    if (t.attempts >= 5) return false;
    if (t.state != 'running') return false; // 已被暂停/删除
    t.attempts++;
    try {
      // ① 本片源其他线路
      final src = MacApi.instance.sources
          .where((s) => s.id == t.sourceId)
          .firstOrNull;
      if (src != null) {
        final d = await MacApi.instance.detail(src, t.vodId).timeout(
            const Duration(seconds: 20),
            onTimeout: () => null);
        if (d != null) {
          for (var g = t.groupIndex + 1; g < d.groups.length; g++) {
            final eps = d.groups[g].episodes;
            if (t.epIndex < eps.length && eps[t.epIndex].url.isNotEmpty) {
              _retarget(t,
                  sourceId: src.id,
                  sourceName: src.name,
                  vodId: t.vodId,
                  groupIndex: g,
                  groupName: d.groups[g].from,
                  url: eps[t.epIndex].url);
              return true;
            }
          }
        }
      }
      // ② 其他片源同名影片
      final exclude = src ??
          const MovieSource(id: -999, name: '-', url: '');
      final results = await MacApi.instance
          .searchSameNameAllSources(t.movieName, exclude)
          .timeout(const Duration(seconds: 40), onTimeout: () => const []);
      for (final d in results) {
        for (final g in d.groups) {
          if (t.epIndex < g.episodes.length && g.episodes[t.epIndex].url.isNotEmpty) {
            _retarget(t,
                sourceId: d.item.sourceId,
                sourceName: d.item.sourceName,
                vodId: d.item.vodId,
                groupIndex: d.groups.indexOf(g),
                groupName: g.from,
                url: g.episodes[t.epIndex].url);
            return true;
          }
        }
      }
    } catch (_) {/* 兜底失败 → 按原错误标记 */}
    return false;
  }

  void _retarget(
    DownloadTask t, {
    required int sourceId,
    required String sourceName,
    required String vodId,
    required int groupIndex,
    required String groupName,
    required String url,
  }) {
    t.sourceId = sourceId;
    t.sourceName = sourceName;
    t.vodId = vodId;
    t.groupIndex = groupIndex;
    t.groupName = groupName;
    t.url = url;
    t.segments = [];
    t.hls = true;
    t.parsed = false;
    t.encKeyUrls = const []; // v2.1 换线路后加密信息按新清单重新解析
    t.encKeyIvs = const [];
    t.segKeys = const [];
    t.encSeq = 0;
    t.progress = 0;
    t.bytesDone = 0;
    t.bytesTotal = 0;
    t.error = null;
    t.state = 'waiting';
    _notify();
    _persist();
    // v2.2.10：清掉上一轮的分段目录，避免缓存无限增长（失败忽略）
    final prev = t.attempts - 1;
    unawaited(() async {
      try {
        final cache = await getTemporaryDirectory();
        final name = t.id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_') +
            (prev > 0 ? '_a$prev' : '');
        final d = Directory('${cache.path}/dl/$name');
        if (await d.exists()) await d.delete(recursive: true);
      } catch (_) {}
    }());
  }

  // ---------- 清单解析 ----------

  Future<String> _fetchText(String url) async {
    final resp = await _client
        .get(Uri.parse(url), headers: const {'User-Agent': _kUa})
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) throw '清单获取失败（${resp.statusCode}）';
    return utf8.decode(resp.bodyBytes, allowMalformed: true);
  }

  Future<void> _parsePlaylist(DownloadTask t) async {
    var url = t.url;
    var text = await _fetchText(url);
    if (!text.contains('#EXTM3U')) {
      t.hls = false;
      t.segments = [url];
      t.parsed = true;
      return;
    }
    // 主清单 → 选最高码率变体
    if (text.contains('#EXT-X-STREAM-INF')) {
      final lines = text.split('\n');
      var best = -1;
      var bestBw = -1;
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i].trim();
        if (!l.startsWith('#EXT-X-STREAM-INF')) continue;
        final bw = int.tryParse(
                RegExp(r'BANDWIDTH=(\d+)').firstMatch(l)?.group(1) ?? '') ??
            0;
        if (bw > bestBw) {
          bestBw = bw;
          best = i;
        }
      }
      if (best >= 0 && best + 1 < lines.length) {
        url = Uri.parse(url).resolve(lines[best + 1].trim()).toString();
        text = await _fetchText(url);
      }
    }
    // v2.2.3（需求4）：下载链路同样接入去广告净化 —— 与在线播放共用同一套 v4 判据。
    // 原实现只做「片头贴片」剔除，中段的同目录夹心岛广告不会被去掉；
    // 这里补上完整净化。净化返回 null（判不准 / 命中安全红线 / 非点播）→ 原样使用原清单，
    // 遵循「宁可漏杀，不可误杀」。净化器会把分片 URI 改写为绝对地址，不影响后续解析。
    final purified = HlsPurifier.purifyMedia(text, url);
    if (purified != null) text = purified;

    // v2.1 AES-128 加密流改为可下载（此前直接报错，靳老师 2026-09-24）
    // v2.1.1 支持密钥轮换 / 加密未加密分段混排；SAMPLE-AES 等仍在此抛明确错误
    final aesPlan = HlsKeyPlan.parse(text, Uri.parse(url));

    final base = Uri.parse(url);
    final segs = <String>[];
    final ends = <double>[];
    var time = 0.0;
    var pending = 0.0;
    double? boundary; // 片头贴片结束时间（秒）
    for (final rawLine in text.split('\n')) {
      final l = rawLine.trim();
      if (l.isEmpty) continue;
      if (l.startsWith('#')) {
        if (l.startsWith('#EXTINF:')) {
          pending =
              double.tryParse(l.substring(8).split(',').first) ?? 0;
        } else if (l.startsWith('#EXT-X-DISCONTINUITY') &&
            !l.contains('SESSION') &&
            boundary == null &&
            time >= 2 &&
            time <= 150) {
          boundary = time; // 与在线播放的片头识别逻辑一致
        }
        continue;
      }
      segs.add(base.resolve(l).toString());
      time += pending;
      pending = 0;
      ends.add(time);
    }

    // 剔除片头广告分段：保留累计结束时间越过分界的分段
    var list = segs;
    var trimOffset = 0;
    if (boundary != null) {
      final idx = ends.indexWhere((e) => e > boundary!);
      if (idx > 0) {
        list = segs.sublist(idx);
        trimOffset = idx; // IV 未指定时媒体序号要跟着后移
      }
    }
    t.segments = list;
    t.hls = true;
    t.parsed = true;
    if (aesPlan.hasEncryption) {
      // 裁掉片头广告分段后，媒体序号要跟着后移（IV 未指定时按序号取）
      t.encKeyUrls = [for (final k in aesPlan.keys) k.url];
      t.encKeyIvs = [for (final k in aesPlan.keys) k.ivHex];
      t.segKeys = aesPlan.segKeyIdx.sublist(trimOffset);
      t.encSeq = aesPlan.seqBase + trimOffset;
    } else {
      t.encKeyUrls = const [];
      t.encKeyIvs = const [];
      t.segKeys = const [];
      t.encSeq = 0;
    }
    _persist();
  }

  // ---------- 分段下载 ----------

  Future<void> _downloadSegments(DownloadTask t, Directory dir) async {
    final total = t.segments.length;
    if (total == 0) throw '清单中没有分段';
    // 续传：已有非空分段文件直接跳过
    var done = 0;
    for (var i = 0; i < total; i++) {
      final f = _segFile(dir, i);
      if (await f.exists() && await f.length() > 0) done++;
    }
    t.progress = done / total;
    _notify();

    var cursor = 0;
    var failed = false;
    String? err;
    Future<void> worker() async {
      while (true) {
        if (t.state != 'running' || failed) return;
        final i = cursor++;
        if (i >= total) return;
        final f = _segFile(dir, i);
        if (await f.exists() && await f.length() > 0) continue; // 续传跳过
        var ok = false;
        for (var attempt = 0; attempt < _segRetry; attempt++) {
          if (t.state != 'running') return;
          try {
            final resp = await _client
                .get(Uri.parse(t.segments[i]),
                    headers: const {'User-Agent': _kUa})
                .timeout(const Duration(seconds: 60));
            if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
              await f.writeAsBytes(resp.bodyBytes, flush: true);
              t.bytesDone += resp.bodyBytes.length; // v1.6.1 速度统计
              ok = true;
              break;
            }
            if (attempt == _segRetry - 1) {
              failed = true;
              err = '分段 ${i + 1} 下载失败（HTTP ${resp.statusCode}）';
            }
          } catch (_) {
            if (attempt == _segRetry - 1) {
              failed = true;
              err = '分段 ${i + 1} 下载失败';
            }
          }
        }
        // v2.2.2（D6）：失败分段不计入 done —— 否则进度虚高；
        // 仍按原逻辑抛错/标记失败，错误语义不变。
        if (ok) {
          done++;
          t.progress = done / total;
          if (done % 10 == 0 || done == total || failed) {
            _notify();
            _persist();
          }
        } else {
          _notify();
          _persist();
        }
      }
    }

    await Future.wait([for (var i = 0; i < _segConcurrency; i++) worker()]);
    if (failed) throw err ?? '分段下载失败';
    for (var i = 0; i < total; i++) {
      final f = _segFile(dir, i);
      if (!await f.exists() || await f.length() == 0) throw '分段 ${i + 1} 缺失';
    }
  }

  File _segFile(Directory dir, int i) =>
      File('${dir.path}/seg_${i.toString().padLeft(5, '0')}.ts');

  /// v2.1 AES-128 解密（合并前执行）；v2.1.1 升级为按分段多密钥：
  /// 去重取回全部钥匙 → 每个分段算出自己的 keyHex/ivHex →
  /// 交原生逐段 AES-128-CBC 解密 + 去 PKCS7 填充（原地覆盖，未加密分段不动）
  Future<void> _decryptSegments(DownloadTask t, Directory dir) async {
    final count = t.segments.length;
    final keyHexes = List<String>.filled(count, '');
    final ivHexes = List<String>.filled(count, '');
    final fetched = <int, String>{}; // 钥匙下标 → 16 字节 hex（每把只取一次）
    for (var i = 0; i < count; i++) {
      final k = i < t.segKeys.length ? t.segKeys[i] : -1;
      if (k < 0 || k >= t.encKeyUrls.length) continue; // 该分段未加密
      var hex = fetched[k];
      if (hex == null) {
        final resp = await _client
            .get(Uri.parse(t.encKeyUrls[k]), headers: const {'User-Agent': _kUa})
            .timeout(const Duration(seconds: 20));
        if (resp.statusCode != 200) throw '密钥获取失败（HTTP ${resp.statusCode}）';
        if (resp.bodyBytes.length != 16) {
          throw '密钥获取失败（长度 ${resp.bodyBytes.length}，应为 16 字节）';
        }
        hex = resp.bodyBytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        fetched[k] = hex;
      }
      keyHexes[i] = hex;
      final tagIv = k < t.encKeyIvs.length ? t.encKeyIvs[k] : '';
      // 清单没给 IV 的钥匙 → 按该分段的媒体序号取 IV（HLS 标准）
      ivHexes[i] = tagIv.isNotEmpty ? tagIv : hlsIvForSeq(t.encSeq + i);
    }
    if (fetched.isEmpty) return; // 没有加密分段（理论上不会进来）
    final r = await _storageChannel.invokeMethod<Map>('aesDecryptSegments', {
      'dir': dir.path,
      'count': count,
      'keyHexes': keyHexes,
      'ivHexes': ivHexes,
    });
    final failed = (r?['failed'] as List?) ?? const [];
    if (failed.isNotEmpty) {
      throw '分段解密失败（${failed.length} 个），该线路加密数据可能不完整';
    }
  }

  /// v1.9.8 最低体积校验：正常影片文件远大于 1MB，过小说明下到的是错误页/
  /// 失效占位内容（如「高压监狱」2KB 假完成），判失败走自动换线路（靳老师 2026-09-23）
  void _checkMinSize(DownloadTask t, File out) {
    final len = out.lengthSync();
    if (len < 1 << 20) {
      throw '下载内容不完整（仅 ${(len / 1024).toStringAsFixed(0)}KB），'
          '该线路视频地址已失效';
    }
  }

  // ---------- mp4 直链 ----------

  Future<void> _downloadMp4(DownloadTask t, File out) async {
    final req = http.Request('GET', Uri.parse(t.url))
      ..headers['User-Agent'] = _kUa;
    final resp = await _client.send(req).timeout(const Duration(minutes: 10));
    if (resp.statusCode != 200) throw '下载失败（HTTP ${resp.statusCode}）';
    final total = resp.contentLength ?? 0;
    t.bytesTotal = total; // v1.6.1
    final sink = out.openWrite();
    var received = 0;
    try {
      await for (final chunk in resp.stream) {
        if (t.state != 'running') {
          await sink.close();
          return;
        }
        sink.add(chunk);
        received += chunk.length;
        t.bytesDone = received; // v1.6.1
        if (total > 0) t.progress = received / total;
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      await sink.close();
      rethrow;
    }
    if (await out.length() == 0) throw '下载的文件为空';
  }

  // ---------- 合并 ----------

  Future<File> _mergeToMp4(DownloadTask t, Directory dir) async {
    final sb = StringBuffer();
    for (var i = 0; i < t.segments.length; i++) {
      sb.writeln("file '${_segFile(dir, i).path}'");
    }
    final listFile = File('${dir.path}/list.txt');
    await listFile.writeAsString(sb.toString(), flush: true);
    final out = File('${dir.path}/out.mp4');
    if (await out.exists()) await out.delete();

    final session = await FFmpegKit.execute(
        '-y -f concat -safe 0 -i "${listFile.path}" -c copy -movflags +faststart "${out.path}"');
    final rc = await session.getReturnCode();
    if (!ReturnCode.isSuccess(rc)) {
      throw '合并失败（ffmpeg 返回码 ${rc?.getValue() ?? "-"}）';
    }
    if (!await out.exists() || await out.length() == 0) throw '合并输出为空';
    return out;
  }

  // ---------- 保存到媒体库 ----------

  Future<void> _saveToMovies(DownloadTask t, File out) async {
    if (!await _ensureStoragePermission()) throw '未获得存储权限';
    final movie = _sanitize(t.movieName);
    final ep = _sanitize(t.epName.isEmpty ? '第${t.epIndex + 1}集' : t.epName);
    String saved;
    try {
      saved = await _storageChannel.invokeMethod<String>('saveToMovies', {
        'srcPath': out.path,
        'relativePath': '电影世界/$movie',
        'displayName': '$ep.mp4',
      }) ??
          '';
    } on PlatformException catch (e) {
      throw e.message ?? '保存到 Movies 失败';
    }
    if (saved.isEmpty) throw '保存到 Movies 失败';
    t.savedPath = saved;

    // 清理临时分段
    try {
      await out.parent.delete(recursive: true);
    } catch (_) {}
  }

  String _sanitize(String s) =>
      s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim().isEmpty
          ? '未命名'
          : s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();

  /// Android 10+ 走 MediaStore 免权限；7~9 需要 WRITE_EXTERNAL_STORAGE
  ///
  /// v2.2.2（A6）：版本判断方式与同文件 restoreFromLibrary() 统一 —— 走原生
  /// `sdkInt`（Build.VERSION.SDK_INT = API 级别），不再用正则从
  /// operatingSystemVersion 猜「Android N」。原逻辑 `ver >= 10`（Android 10）
  /// 等价于 API 29，此处保持行为等价（Android 10 = API 29）。
  Future<bool> _ensureStoragePermission() async {
    if (!Platform.isAndroid) return true;
    final sdk = await _storageChannel.invokeMethod<int>('sdkInt') ?? 0;
    if (sdk >= 29) return true; // Android 10（API 29）起 MediaStore 免权限
    var st = await Permission.storage.status;
    if (!st.isGranted) {
      st = await Permission.storage.request();
    }
    return st.isGranted;
  }

  // ---------- 管理操作 ----------

  void pause(String id) {
    final t = tasks.where((x) => x.id == id).firstOrNull;
    if (t == null) return;
    if (t.state == 'waiting' || t.state == 'running') {
      t.state = 'paused';
      _stats.remove(t.id);
      _notify();
      _persist();
    }
  }

  void resume(String id) {
    final t = tasks.where((x) => x.id == id).firstOrNull;
    if (t == null) return;
    if (t.state == 'paused' || t.state == 'failed') {
      t.state = 'waiting';
      t.error = null;
      t.attempts = 0; // v1.6.1 手动重试：重新给足自动换线路/换片源机会
      _notify();
      _persist();
      pump();
    }
  }

  /// v1.6.1 下载中预览：用已下载的分段拼一个本地 m3u8（ExoPlayer 可直接播），
  /// 返回播放列表路径；无可用分段或 mp4 直链任务返回 null
  Future<String?> buildPreview(DownloadTask t) async {
    if (!t.hls || !t.parsed) return null;
    try {
      final cache = await getTemporaryDirectory();
      final dir = _taskDir(cache, t);
      if (!await dir.exists()) return null;
      final sb = StringBuffer('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n');
      var n = 0;
      for (var i = 0; i < t.segments.length; i++) {
        final f = _segFile(dir, i);
        if (await f.exists() && await f.length() > 0) {
          sb.writeln('#EXTINF:10.0,');
          sb.writeln(Uri.file(f.path).toString());
          n++;
        }
      }
      if (n == 0) return null;
      sb.writeln('#EXT-X-ENDLIST');
      final list = File('${dir.path}/preview.m3u8');
      await list.writeAsString(sb.toString(), flush: true);
      return list.path;
    } catch (_) {
      return null;
    }
  }

  /// v2.0 返回值：{recordRemoved, fileDeleted, failedPaths: 未删掉的路径列表}
  Future<Map<String, dynamic>> delete(String id,
      {bool withFile = false}) async {
    final t = tasks.where((x) => x.id == id).firstOrNull;
    if (t == null) {
      return {'recordRemoved': false, 'fileDeleted': false, 'failedPaths': <String>[]};
    }
    t.state = 'deleted'; // 让运行中的 worker 尽快退出
    tasks.remove(t);
    _stats.remove(t.id);
    _notify();
    _persistNow();
    if (!withFile) {
      return {'recordRemoved': true, 'fileDeleted': false, 'failedPaths': <String>[]};
    }
    // 删完本集后若「电影名」文件夹已空，连同文件夹一起清理
    final (fileOk, failed) = await _deleteSavedAndClean(t);
    return {
      'recordRemoved': true,
      'fileDeleted': fileOk,
      'failedPaths': failed,
    };
  }

  /// v2.0 删除链 v2（靳老师 2026-09-24）：
  /// 直删 → 原生回报「需要授权」时弹系统「允许删除」→ 授权后重试 →
  /// File 兜底 + 刷新媒体库；目录级清理后**真的去核对残留**。
  /// 返回 (是否删净, 未删掉的路径列表)
  Future<(bool, List<String>)> _deleteSavedAndClean(DownloadTask t) async {
    final failed = <String>[];
    var fileOk = true;
    final p = t.savedPath;
    if (p != null && p.isNotEmpty) {
      final r = await _deleteTarget(p);
      fileOk = r.$1;
      if (!fileOk) failed.addAll(r.$2);
    }
    // v2.2.10 修复 P0：只有该片名已无其他任务时才清目录，
    // 否则「删除本集」会把同片其余集数的文件一起删掉（tasks 里已移除本任务）。
    final others = tasks.where((x) => x.movieName == t.movieName && x.id != t.id);
    if (others.isNotEmpty) return (fileOk, failed);
    // 目录级清理：把该片名下所有残留（含子目录）一并清掉
    final folder = await _deleteFolder('电影世界/${_sanitize(t.movieName)}');
    if (folder.$1) {
      fileOk = true; // 目录已删净 → 本集文件自然也没了
      failed.clear();
    } else if (failed.isEmpty) {
      fileOk = false;
      failed.addAll(folder.$2);
    }
    return (fileOk, failed);
  }

  /// 删除单个目标；若原生判定「需要系统授权」，走授权弹窗后重试一次
  Future<(bool, List<String>)> _deleteTarget(String target) async {
    var r = await _invokeDelete(target);
    if (!r.$1 && r.$2) {
      // 安卓 10+ 删非本应用归属的媒体必须先经用户同意（只需授权一次）
      final granted = await _requestDeleteAuth([target]);
      if (granted) r = await _invokeDelete(target);
    }
    return (r.$1, r.$1 ? <String>[] : [r.$3.isEmpty ? target : r.$3]);
  }

  /// 调用原生删除，返回 (是否成功, 是否需要系统授权, 展示用路径)
  Future<(bool, bool, String)> _invokeDelete(String target) async {
    try {
      final m = await _storageChannel
          .invokeMethod<Map<dynamic, dynamic>>('deleteSaved', {'target': target});
      if (m == null) return (false, false, target);
      final p = '${m['path'] ?? ''}';
      return (m['ok'] == true, m['needAuth'] == true, p.isEmpty ? target : p);
    } catch (_) {
      return (false, false, target);
    }
  }

  /// 请求系统「允许删除」授权（安卓 10+ 首次删他人媒体时必弹，只需授权一次）
  Future<bool> _requestDeleteAuth(List<String> uris) async {
    if (!Platform.isAndroid) return false;
    try {
      final m = await _storageChannel
          .invokeMethod<Map<dynamic, dynamic>>('requestDeleteAuth', {'uris': uris});
      return m?['granted'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 目录级清理，返回 (是否删净, 残留路径列表)
  Future<(bool, List<String>)> _deleteFolder(String relativePath) async {
    try {
      final m = await _storageChannel.invokeMethod<Map<dynamic, dynamic>>(
          'deleteMovieFolder', {'relativePath': relativePath});
      if (m == null) return (false, ['全部文件/$relativePath']);
      final left =
          (m['remaining'] as List?)?.map((e) => '$e').toList() ?? <String>[];
      return (m['ok'] == true, left);
    } catch (_) {
      return (false, ['全部文件/$relativePath']);
    }
  }

  /// v2.0 删除整部影片：同片名的全部任务（含下载中/失败）一并移除，
  /// 已保存的视频逐个删除，最后清理「电影名」文件夹并核对残留。
  /// 返回 (删除任务数, 文件是否删净, 未删掉的路径)
  Future<(int, bool, List<String>)> deleteMovie(String movieName) async {
    final list = tasks.where((x) => x.movieName == movieName).toList();
    if (list.isEmpty) return (0, true, <String>[]);
    final failed = <String>[];
    for (final t in list) {
      t.state = 'deleted';
      tasks.remove(t);
      _stats.remove(t.id);
      try {
        final p = t.savedPath;
        if (p != null && p.isNotEmpty) {
          final r = await _deleteTarget(p);
          if (!r.$1) failed.addAll(r.$2);
        }
      } catch (_) {}
    }
    _notify();
    _persistNow();
    final folder = await _deleteFolder('电影世界/${_sanitize(movieName)}');
    if (folder.$1) return (list.length, true, <String>[]);
    if (failed.isEmpty) failed.addAll(folder.$2);
    return (list.length, false, failed);
  }

}
