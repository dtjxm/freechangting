/// 收藏 / 观看历史（本机 shared_preferences 存储）
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class HistoryEntry {
  VideoItem item;
  String epName;
  int epIndex;
  int groupIndex; // v1.5.6 播放线路（分组）下标，续播恢复用
  int positionSec; // 播放进度
  int updatedAt;

  HistoryEntry({
    required this.item,
    required this.epName,
    required this.epIndex,
    this.groupIndex = 0,
    required this.positionSec,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        'item': item.toMap(),
        'epName': epName,
        'epIndex': epIndex,
        'groupIndex': groupIndex,
        'positionSec': positionSec,
        'updatedAt': updatedAt,
      };

  factory HistoryEntry.fromMap(Map<String, dynamic> m) => HistoryEntry(
        item: VideoItem.fromMap((m['item'] ?? const {}) as Map<String, dynamic>),
        epName: _stStr(m['epName']),
        epIndex: _stInt(m['epIndex']),
        groupIndex: _stInt(m['groupIndex']),
        positionSec: _stInt(m['positionSec']),
        updatedAt: _stInt(m['updatedAt']),
      );

  // ---- v1.9.9（代码审查 3.5）旧数据字段类型漂移的兼容转换 ----
  static int _stInt(dynamic v, [int def = 0]) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) return int.tryParse(v) ?? def;
    return def;
  }

  static String _stStr(dynamic v, [String def = '']) {
    if (v is String) return v;
    if (v == null) return def;
    return '$v';
  }
}

class AppStore extends ChangeNotifier {
  AppStore._();
  static final AppStore instance = AppStore._();

  static const _kFav = 'dysj_favorites';
  static const _kFavTip = 'dysj_fav_tip_dismissed';
  static const _kHis = 'dysj_history';
  static const _kLastSource = 'dysj_last_source';
  static const _kAutoNext = 'dysj_auto_next';
  static const _kShowOther = 'dysj_show_other';
  static const _kManualSource = 'dysj_manual_source';
  static const _kFastSource = 'dysj_fast_source';
  // ---- v2.2.4 片源管理（独立页面）----
  static const _kDisabledSrc = 'dysj_disabled_sources';
  static const _kSrcLatency = 'dysj_source_latency';
  static const _kSrcFail = 'dysj_source_fail';
  static const _kSrcLastTest = 'dysj_source_last_test';
  static const _kSrcLastNet = 'dysj_source_last_net';
  static const _kSearchHis = 'dysj_search_history';
  static const _kLiveM3u = 'dysj_live_m3u';
  static const _kAdSkip = 'dysj_ad_skip';
  static const _kThemeMode = 'dysj_theme_mode';
  static const _maxHistory = 300;

  SharedPreferences? _prefs;
  final List<VideoItem> _favorites = [];
  final List<HistoryEntry> _history = [];
  final List<String> _searchHis = [];

  List<VideoItem> get favorites => List.unmodifiable(_favorites);
  List<HistoryEntry> get history => List.unmodifiable(_history);
  List<String> get searchHistory => List.unmodifiable(_searchHis);

  // ---- 设置项 ----
  bool get autoNext => _prefs?.getBool(_kAutoNext) ?? true;
  set autoNext(bool v) => _prefs?.setBool(_kAutoNext, v);

  bool get showOther => _prefs?.getBool(_kShowOther) ?? false;
  set showOther(bool v) {
    _prefs?.setBool(_kShowOther, v);
    notifyListeners(); // v1.9.0：频道开关返回首页立即生效
  }

  // ---- v1.7.0 首页频道（一级分类）显示开关 ----
  // 默认开启：电影、电视剧、综艺、动漫、纪录片；其余（短剧/体育/影视解说/伦理）默认关闭。
  // 「其他」沿用旧开关 showOther 的取值，老用户设置不丢失。
  static const bigCatDefaults = {
    'movies': true,
    'tv': true,
    'variety': true,
    'anime': true,
    'documentary': true,
    'shortdrama': false,
    'sports': false,
    'commentary': false,
    'ethics': false,
  };
  static const _kCatPrefix = 'dysj_cat_';

  bool bigCatVisible(String key) {
    // v2.2.3 v11：一级「其他」大类已取消 —— 成人 / 擦边内容随之整体隐藏，恒不可见。
    //（showOther 偏好项保留仅为兼容老用户数据，不再影响任何显示）
    if (key == 'other') return false;
    // v2.2.0：只读已知频道 —— 老用户 prefs 里可能残留已下线频道（如 news）的开关值，
    // 未知名目一律按关闭处理，不会被重新显示出来。
    if (!bigCatDefaults.containsKey(key)) return false;
    final d = bigCatDefaults[key] ?? false;
    return _prefs?.getBool('$_kCatPrefix$key') ?? d;
  }

  void setBigCatVisible(String key, bool v) {
    _prefs?.setBool('$_kCatPrefix$key', v);
    notifyListeners(); // v1.9.0：频道开关返回首页立即生效
  }

  /// 开启「伦理」等敏感频道时需要二次确认
  ///（v2.2.3 v11：一级「其他」已取消，不再作为可选频道）
  static const sensitiveCats = {'ethics'};

  /// 用户是否手动选过片源（手动选择后不再自动切最快源）
  bool get manualSource => _prefs?.getBool(_kManualSource) ?? false;
  set manualSource(bool v) => _prefs?.setBool(_kManualSource, v);

  int get fastSourceId => _prefs?.getInt(_kFastSource) ?? -1;
  set fastSourceId(int v) => _prefs?.setInt(_kFastSource, v);

  // ==================== v2.2.4 片源管理 ====================
  // 「片源管理」独立页面用：停用集合 / 最近测速延迟 / 失败清单 / 上次测速时间。
  // 与 PC 版口径一致：停用的片源不再参与加载与检索（至少保留 1 个启用）。

  /// 已停用片源 id（空 = 全部启用）
  Set<int> get disabledSourceIds {
    final raw = _prefs?.getString(_kDisabledSrc);
    if (raw == null || raw.isEmpty) return <int>{};
    try {
      final d = jsonDecode(raw);
      if (d is List) return d.whereType<num>().map((e) => e.toInt()).toSet();
    } catch (_) {/* 旧数据损坏 → 视为全部启用 */}
    return <int>{};
  }

  set disabledSourceIds(Set<int> v) {
    _prefs?.setString(_kDisabledSrc, jsonEncode(v.toList()..sort()));
  }

  bool isSourceEnabled(int id) => !disabledSourceIds.contains(id);

  /// 最近一次测速结果：片源 id → 毫秒（失败的不在表内）
  Map<int, int> get sourceLatency {
    final raw = _prefs?.getString(_kSrcLatency);
    if (raw == null || raw.isEmpty) return <int, int>{};
    try {
      final d = jsonDecode(raw);
      if (d is Map) {
        final out = <int, int>{};
        d.forEach((k, v) {
          final id = int.tryParse('$k');
          if (id != null && v is num) out[id] = v.toInt();
        });
        return out;
      }
    } catch (_) {}
    return <int, int>{};
  }

  set sourceLatency(Map<int, int> v) {
    final m = <String, int>{};
    v.forEach((k, val) => m['$k'] = val);
    _prefs?.setString(_kSrcLatency, jsonEncode(m));
  }

  /// 测速失败的片源 id
  List<int> get sourceFail {
    final raw = _prefs?.getString(_kSrcFail);
    if (raw == null || raw.isEmpty) return <int>[];
    try {
      final d = jsonDecode(raw);
      if (d is List) return d.whereType<num>().map((e) => e.toInt()).toList();
    } catch (_) {}
    return <int>[];
  }

  set sourceFail(List<int> v) =>
      _prefs?.setString(_kSrcFail, jsonEncode(v));

  /// 上次测速时间戳（毫秒；0 = 尚未测速）
  int get sourceLastTest => _prefs?.getInt(_kSrcLastTest) ?? 0;
  set sourceLastTest(int v) => _prefs?.setInt(_kSrcLastTest, v);

  /// 上次测速时的网络指纹（wlan0:192.168.x.x 等；空 = 旧版本未记录）
  String get sourceLastTestNetwork => _prefs?.getString(_kSrcLastNet) ?? '';
  set sourceLastTestNetwork(String v) =>
      _prefs?.setString(_kSrcLastNet, v);

  /// 片源管理变更信号：每次「立即测速 / 开关片源 / 全部开启」自增并通知，
  /// 首页据此重新按优先级选源并重载（v2.2.4 需求：首页默认为最快片源）。
  int _srcRev = 0;
  int get sourceRev => _srcRev;
  void bumpSourceRev() {
    _srcRev++;
    notifyListeners();
  }

  /// 主题外观：0 跟随系统 / 1 浅色 / 2 深色
  int get themeModeIndex => _prefs?.getInt(_kThemeMode) ?? 0;
  set themeModeIndex(int v) {
    _prefs?.setInt(_kThemeMode, v);
    notifyListeners(); // 让 MaterialApp 即时换肤
  }

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    final p = _prefs!;
    // v1.9.9（代码审查 3.5）：初始化全面容错 —— 顶层 JSON 损坏/不是 List、
    // 单条记录损坏都只跳过该项，绝不阻塞收藏/历史/搜索记录的加载；
    // 只读不写，不会把尚未读取成功的有效数据覆盖掉。
    _favorites
      ..clear()
      ..addAll(parseFavoritesJson(p.getString(_kFav)));
    _history
      ..clear()
      ..addAll(parseHistoryJson(p.getString(_kHis)));
    _searchHis
      ..clear()
      ..addAll(parseSearchHisJson(p.getString(_kSearchHis)));
  }

  /// 顶层解码：损坏或非 List 一律按空列表处理（数据保留在原键，不覆盖）
  static List<dynamic> _decodeList(String? raw) {
    try {
      if (raw == null || raw.isEmpty) return const [];
      final d = jsonDecode(raw);
      return d is List ? d : const [];
    } catch (_) {
      return const [];
    }
  }

  @visibleForTesting
  static List<VideoItem> parseFavoritesJson(String? raw) => _decodeList(raw)
      .map(_oneFavorite)
      .whereType<VideoItem>()
      .toList();

  @visibleForTesting
  static List<HistoryEntry> parseHistoryJson(String? raw) => _decodeList(raw)
      .map(_oneHistory)
      .whereType<HistoryEntry>()
      .toList();

  @visibleForTesting
  static List<String> parseSearchHisJson(String? raw) =>
      _decodeList(raw).whereType<String>().toList();

  static VideoItem? _oneFavorite(dynamic e) {
    try {
      if (e is! Map) return null;
      return VideoItem.fromMap(e.cast<String, dynamic>());
    } catch (_) {
      return null; // 单条损坏 → 跳过，不影响其他记录
    }
  }

  static HistoryEntry? _oneHistory(dynamic e) {
    try {
      if (e is! Map) return null;
      return HistoryEntry.fromMap(e.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  void addSearchHistory(String wd) {
    _searchHis
      ..remove(wd)
      ..insert(0, wd);
    if (_searchHis.length > 15) _searchHis.removeRange(15, _searchHis.length);
    _prefs?.setString(_kSearchHis, jsonEncode(_searchHis));
    notifyListeners();
  }

  void removeSearchHistory(String wd) {
    _searchHis.remove(wd);
    _prefs?.setString(_kSearchHis, jsonEncode(_searchHis));
    notifyListeners();
  }

  void clearSearchHistory() {
    _searchHis.clear();
    _prefs?.setString(_kSearchHis, '[]');
    notifyListeners();
  }

  Future<void> _saveFav() async =>
      _prefs!.setString(_kFav, jsonEncode(_favorites.map((e) => e.toMap()).toList()));
  Future<void> _saveHis() async =>
      _prefs!.setString(_kHis, jsonEncode(_history.map((e) => e.toMap()).toList()));

  /// v1.3.0 直播源最后成功拉取的 M3U 内容（离线兜底）
  String get liveM3uCache => _prefs?.getString(_kLiveM3u) ?? '';
  set liveM3uCache(String v) {
    if (v.isNotEmpty) _prefs?.setString(_kLiveM3u, v);
  }

  /// v2.2.0 去广告（**清单净化**）：在线播放前先把 m3u8 里的广告分片删掉，
  /// 再把净化后的清单交给播放器 —— 不是快进跳过，分片是真的没有拉取。
  ///
  /// 这一版起下线了 v1.4.5 的「画幅突变 → 快进跳过」与 v1.4.9 的
  /// 「m3u8 分界分析 → seek」两套旧逻辑（v2.2 之前靠它们去广告）。
  /// true = 开启净化；false = 直连原地址。
  bool get adSkip => _prefs?.getBool(_kAdSkip) ?? true;
  set adSkip(bool v) => _prefs?.setBool(_kAdSkip, v);

  /// v2.2.0 收藏页「长按海报可取消收藏」提示条是否已关闭（只提示一次，不再打扰）。
  bool get favTipDismissed => _prefs?.getBool(_kFavTip) ?? false;
  set favTipDismissed(bool v) => _prefs?.setBool(_kFavTip, v);

  bool isFavorite(VideoItem v) => _favorites.any((e) => e.vodId == v.vodId && e.sourceId == v.sourceId);

  Future<void> toggleFavorite(VideoItem v) async {
    final i = _favorites.indexWhere((e) => e.vodId == v.vodId && e.sourceId == v.sourceId);
    if (i >= 0) {
      _favorites.removeAt(i);
    } else {
      _favorites.insert(0, v);
    }
    await _saveFav();
    notifyListeners();
  }

  HistoryEntry? findHistory(VideoItem v) {
    for (final h in _history) {
      if (h.item.vodId == v.vodId && h.item.sourceId == v.sourceId) return h;
    }
    return null;
  }

  Future<void> saveHistory(VideoItem v, String epName, int epIndex, int posSec,
      {int groupIndex = 0}) async {
    _history.removeWhere((h) => h.item.vodId == v.vodId && h.item.sourceId == v.sourceId);
    _history.insert(
        0,
        HistoryEntry(
          item: v,
          epName: epName,
          epIndex: epIndex,
          groupIndex: groupIndex,
          positionSec: posSec,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ));
    if (_history.length > _maxHistory) _history.removeRange(_maxHistory, _history.length);
    await _saveHis();
    notifyListeners();
  }

  Future<void> removeHistory(HistoryEntry h) async {
    _history.remove(h);
    await _saveHis();
    notifyListeners();
  }

  Future<void> clearHistory() async {
    _history.clear();
    await _saveHis();
    notifyListeners();
  }

  int get lastSourceId => _prefs?.getInt(_kLastSource) ?? -1;
  set lastSourceId(int v) => _prefs?.setInt(_kLastSource, v);

  // ---- v1.8.0 检索页筛选状态记忆（大类/排序/地区/风格/年份） ----
  static const _kBrowse = 'dysj_browse_state';
  Map<String, Object?>? _browseCache;

  Map<String, Object?> _browse() {
    if (_browseCache == null) {
      try {
        final raw = _prefs?.getString(_kBrowse) ?? '';
        _browseCache = raw.isEmpty
            ? <String, Object?>{}
            : (jsonDecode(raw) as Map).cast<String, Object?>();
      } catch (_) {
        _browseCache = <String, Object?>{};
      }
    }
    return _browseCache!;
  }

  Object? browseValue(String key) => _browse()[key];

  void setBrowseValue(String key, Object? v) {
    final m = _browse();
    if (v == null) {
      m.remove(key);
    } else {
      m[key] = v;
    }
    _prefs?.setString(_kBrowse, jsonEncode(m));
  }
}
