import 'source_health_store.dart';

/// 点播片源（MacCMS 站点）健康度记忆。
///
/// 哪些情况算「片源失败」：当前片源**所有播放线路都起播失败**时记一次。
/// 单条线路失败不记——同站点的其他线路往往还能播，把整个站点降权会误伤。
///
/// 哪些情况算「片源成功」：播放稳定 20 秒后记一次，起播即卡住的不算。
/// 这套规则与直播侧 `LiveSourceHealth` 保持一致，共用 [SourceHealthStore]。
class VodSourceHealth {
  VodSourceHealth._();

  /// 本地存储键（公开便于测试与线上排查）
  static const String prefsKey = 'vod_source_health_v1';

  static final SourceHealthStore _store = SourceHealthStore(prefsKey: prefsKey);

  /// 可注入时钟，单元测试用；运行时保持默认即可。
  static DateTime Function() get now => _store.now;
  static set now(DateTime Function() fn) => _store.now = fn;

  static bool get isLoaded => _store.isLoaded;

  static int get recordCount => _store.recordCount;

  static Future<void> load() => _store.load();

  /// 片源排序权重：0 表示可优先尝试，越大越靠后。
  static int rank(int sourceId) => _store.rank('$sourceId');

  /// 按片源健康度稳定排序（权重相同保持传入顺序）。
  static List<T> order<T>(List<T> items, int Function(T) idOf) =>
      _store.order(items, (e) => '${idOf(e)}');

  static void markSuccess(int sourceId) => _store.markSuccess('$sourceId');

  static void markFailure(int sourceId) => _store.markFailure('$sourceId');

  static Future<void> saveNow() => _store.saveNow();

  /// 仅测试使用。
  static void resetForTest() => _store.resetForTest();
}
