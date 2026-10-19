import 'live_tv.dart';
import 'source_health_store.dart';

/// 直播源健康度记忆。
///
/// 解决什么问题：直播列表里每个频道有多条线路，但只有内置的静态测速顺序，
/// 某条线路实际已经失效时，每次进台都要先等一遍起播看门狗（20 秒）才会换到
/// 下一条，而且**第二次打开 App 不会比第一次快**——失败经验一点没留下。
/// 有了这份记忆，坏线路会被排到后面，用户本机的真实播放结果才作数。
///
/// 存储取舍：**只记坏源，不记好源**。默认所有源都是健康的，只有失败过的才入库，
/// 数据量极小（通常几十条），一个 StringList 装得下。
///
/// 本文件改编自 HTV（HTWMedia/HTV）的 `lib/common/utils/source_health.dart`，
/// 原项目以 Apache License 2.0 授权。修改内容：
/// - 用 shared_preferences 直接读写，去除原项目的 PrefsUtil/Logger 依赖；
/// - 排序对象由 `String` URL 改为本项目的 `TvLine`（保留测速值）；
/// - 增加可注入时钟，便于单元测试覆盖冷却与过期逻辑；
/// - 存储键改为 `live_source_health_v1`，与原应用互不干扰；
/// - 通用存储逻辑抽到 `SourceHealthStore`，供点播片源复用。
/// 详见随包的 THIRD_PARTY_NOTICES.md 与 LICENSES/Apache-2.0.txt。
class LiveSourceHealth {
  LiveSourceHealth._();

  /// 本地存储键（公开便于测试与线上排查）
  static const String prefsKey = 'live_source_health_v1';

  /// 连续失败 N 次后要冷却多久（分钟），下标 = 失败次数 - 1。
  static const List<int> cooldownMinutes = SourceHealthStore.cooldownMinutes;

  /// 冷却期过后仍未再失败，多久彻底忘掉这条记录。
  static const int forgetAfterMs = SourceHealthStore.forgetAfterMs;

  /// 最多保留多少条记录，超出后按最后失败时间从旧到新淘汰。
  static const int maxEntries = SourceHealthStore.maxEntries;

  static final SourceHealthStore _store = SourceHealthStore(prefsKey: prefsKey);

  /// 可注入时钟，单元测试用；运行时保持默认即可。
  static DateTime Function() get now => _store.now;
  static set now(DateTime Function() fn) => _store.now = fn;

  /// 健康度记录是否已从本地载入。
  static bool get isLoaded => _store.isLoaded;

  /// 当前记录条数（测试与自检用）。
  static int get recordCount => _store.recordCount;

  /// 从本地存储载入健康度记录。在 `main()` 启动阶段调用一次即可。
  static Future<void> load() => _store.load();

  /// 该线路的排序权重：0 表示可优先尝试，越大越靠后。
  static int rank(String url) => _store.rank(url);

  /// 按健康度**稳定**排序后的线路列表。
  ///
  /// 稳定很关键：权重相同时必须保持内置清单的原始顺序（测速由快到慢），
  /// 否则每次进频道都可能重排，用户手动切线路时的位置感会乱。
  static List<TvLine> orderLines(List<TvLine> lines) =>
      _store.order(lines, (l) => l.url);

  /// 播放成功：抹掉这条源的失败记录。
  static void markSuccess(String url) => _store.markSuccess(url);

  /// 播放失败：记一次，冷却期按失败次数拉长一档。
  static void markFailure(String url) => _store.markFailure(url);

  /// 立即落盘（退出前或测试里调用）。
  static Future<void> saveNow() => _store.saveNow();

  /// 仅测试使用：清空内存、载入标记与待落盘定时器。
  static void resetForTest() => _store.resetForTest();
}
