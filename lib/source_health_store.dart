import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// 通用「坏源记忆」存储。
///
/// 直播线路（`LiveSourceHealth`）与点播片源（`VodSourceHealth`）各持有一个实例，
/// 用不同的 [prefsKey] 隔离数据。只记坏源、不记好源：默认所有源都是健康的，
/// 失败过的才入库，数据量极小。
///
/// 规则改编自 HTV（HTWMedia/HTV）的 `lib/common/utils/source_health.dart`
/// （Apache-2.0），详见 THIRD_PARTY_NOTICES.md。
class SourceHealthStore {
  SourceHealthStore({required this.prefsKey});

  final String prefsKey;

  /// 连续失败 N 次后要冷却多久（分钟），下标 = 失败次数 - 1。
  /// 10min → 1h → 6h → 12h → 24h（封顶）。
  static const List<int> cooldownMinutes = [10, 60, 360, 720, 1440];

  /// 冷却期过后仍未再失败，多久彻底忘掉这条记录。
  static const int forgetAfterMs = 7 * 24 * 60 * 60 * 1000;

  /// 最多保留多少条记录，超出后按最后失败时间从旧到新淘汰。
  static const int maxEntries = 2000;

  final Map<String, _Record> _records = {};
  bool _loaded = false;
  Timer? _saveTimer;

  /// 可注入时钟，单元测试用；运行时保持默认即可。
  DateTime Function() now = DateTime.now;

  bool get isLoaded => _loaded;

  int get recordCount => _records.length;

  /// 从本地存储载入记录。失败按「没有记录」处理，不阻塞启动。
  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(prefsKey);
      _records.clear();
      if (list != null) {
        for (final item in list) {
          final h = _Record.decode(item);
          if (h != null) _records[h.key] = h;
        }
      }
      _prune();
    } catch (_) {
      _records.clear();
    } finally {
      _loaded = true;
    }
  }

  /// 排序权重：0 表示可优先尝试，越大越靠后。
  int rank(String key) {
    final h = _records[key];
    if (h == null) return 0;

    // 冷却期已过：再给一次机会，而不是一直压着。
    if (_nowMs() - h.lastFailMs >= _cooldownMsFor(h.failCount)) return 0;

    return 1 + h.failCount;
  }

  /// 按健康度**稳定**排序：权重相同时保持传入顺序。
  List<T> order<T>(List<T> items, String Function(T) keyOf) {
    if (items.length <= 1) return List<T>.of(items);

    final indexed = items.asMap().entries.toList()
      ..sort((a, b) {
        final ra = rank(keyOf(a.value));
        final rb = rank(keyOf(b.value));
        if (ra != rb) return ra.compareTo(rb);
        return a.key.compareTo(b.key);
      });

    return indexed.map((e) => e.value).toList();
  }

  /// 成功：抹掉失败记录。本来没有记录时不做任何事，也不触发落盘。
  void markSuccess(String key) {
    if (key.isEmpty) return;
    if (_records.remove(key) == null) return;
    _scheduleSave();
  }

  /// 失败：记一次，冷却期按失败次数拉长一档。
  void markFailure(String key) {
    if (key.isEmpty) return;

    final old = _records[key];
    _records[key] = _Record(
      key: key,
      failCount: (old?.failCount ?? 0) + 1,
      lastFailMs: _nowMs(),
    );
    _scheduleSave();
  }

  /// 落盘去抖：换台/换线路都会触发记录，攒 2 秒写一次足够。
  void _scheduleSave() {
    // 还没载入过说明本地存储没就绪，这时不排定时器，
    // 避免把已有记录覆盖成空。
    if (!_loaded) return;

    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () {
      _saveTimer = null;
      saveNow();
    });
  }

  /// 立即落盘（退出前或测试里调用）。
  Future<void> saveNow() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_loaded) return;

    try {
      _prune();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        prefsKey,
        _records.values.map((h) => h.encode()).toList(),
      );
    } catch (_) {
      // 落盘失败无所谓：内存里的记录本轮照样生效，下次启动再积累。
    }
  }

  void _prune() {
    final current = _nowMs();
    _records.removeWhere((_, h) => current - h.lastFailMs > forgetAfterMs);

    if (_records.length <= maxEntries) return;

    // 新的在前，淘汰尾巴上最旧的。
    final sorted = _records.values.toList()
      ..sort((a, b) => b.lastFailMs.compareTo(a.lastFailMs));
    for (final h in sorted.skip(maxEntries)) {
      _records.remove(h.key);
    }
  }

  /// 仅测试使用：清空内存、载入标记与待落盘定时器。
  void resetForTest() {
    _saveTimer?.cancel();
    _saveTimer = null;
    _records.clear();
    _loaded = false;
    now = DateTime.now;
  }

  int _nowMs() => now().millisecondsSinceEpoch;

  static int _cooldownMsFor(int failCount) {
    var i = failCount - 1;
    if (i < 0) i = 0;
    if (i >= cooldownMinutes.length) i = cooldownMinutes.length - 1;
    return cooldownMinutes[i] * 60 * 1000;
  }
}

/// 单条记录，编码为 `失败次数|最后失败时刻|key`。
/// 两个数字放前面、key 放最后：key 里理论上可能出现 `|`，按前两个分隔符切即可。
class _Record {
  const _Record({
    required this.key,
    required this.failCount,
    required this.lastFailMs,
  });

  final String key;
  final int failCount;
  final int lastFailMs;

  String encode() => '$failCount|$lastFailMs|$key';

  static _Record? decode(String s) {
    final i1 = s.indexOf('|');
    if (i1 < 0) return null;
    final i2 = s.indexOf('|', i1 + 1);
    if (i2 < 0) return null;

    final fail = int.tryParse(s.substring(0, i1));
    final lastFail = int.tryParse(s.substring(i1 + 1, i2));
    final key = s.substring(i2 + 1);
    if (fail == null || lastFail == null || key.isEmpty) return null;

    return _Record(key: key, failCount: fail, lastFailMs: lastFail);
  }
}
