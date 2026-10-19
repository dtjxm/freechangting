import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dianying_shijie/live_source_health.dart';
import 'package:dianying_shijie/live_tv.dart';

void main() {
  final t0 = DateTime(2026, 10, 19, 12);

  setUp(() async {
    LiveSourceHealth.resetForTest();
    SharedPreferences.setMockInitialValues({});
    LiveSourceHealth.now = () => t0;
    await LiveSourceHealth.load();
  });

  tearDown(() {
    // 清掉去抖落盘定时器，避免测试结束时留下 pending timer
    LiveSourceHealth.resetForTest();
  });

  test('坏源排在健康源后面，同权重保持原顺序', () {
    LiveSourceHealth.markFailure('http://b');

    final order = LiveSourceHealth.orderLines([
      const TvLine('http://a', 100),
      const TvLine('http://b', 200),
      const TvLine('http://c', 300),
    ]);

    expect(order.map((l) => l.url), ['http://a', 'http://c', 'http://b']);
    // 排序不能丢掉测速值（线路面板还要显示）
    expect(order[0].ms, 100);
    expect(order[2].ms, 200);
  });

  test('冷却期内压后，冷却期过后恢复权重', () {
    LiveSourceHealth.markFailure('http://u');
    expect(LiveSourceHealth.rank('http://u'), 2);

    LiveSourceHealth.now = () => t0.add(const Duration(minutes: 9));
    expect(LiveSourceHealth.rank('http://u'), 2);

    LiveSourceHealth.now = () => t0.add(const Duration(minutes: 11));
    expect(LiveSourceHealth.rank('http://u'), 0);
  });

  test('再次失败会升一档冷却（10 分钟 → 1 小时）', () {
    LiveSourceHealth.markFailure('http://u'); // 第 1 次：10 分钟内冷却
    LiveSourceHealth.now = () => t0.add(const Duration(minutes: 11));
    LiveSourceHealth.markFailure('http://u'); // 第 2 次：1 小时内冷却

    expect(LiveSourceHealth.rank('http://u'), 3);

    LiveSourceHealth.now = () => t0.add(const Duration(minutes: 59));
    expect(LiveSourceHealth.rank('http://u'), 3);

    LiveSourceHealth.now = () => t0.add(const Duration(minutes: 72));
    expect(LiveSourceHealth.rank('http://u'), 0);
  });

  test('播放成功后清除失败记录', () {
    LiveSourceHealth.markFailure('http://u');
    expect(LiveSourceHealth.recordCount, 1);

    LiveSourceHealth.markSuccess('http://u');
    expect(LiveSourceHealth.recordCount, 0);
    expect(LiveSourceHealth.rank('http://u'), 0);
  });

  test('健康源调用 markSuccess 不会产生记录', () {
    LiveSourceHealth.markSuccess('http://never-failed');
    expect(LiveSourceHealth.recordCount, 0);
  });

  test('记录可持久化到 shared_preferences 并读回', () async {
    LiveSourceHealth.markFailure('http://u');
    await LiveSourceHealth.saveNow();

    LiveSourceHealth.resetForTest();
    LiveSourceHealth.now = () => t0;
    await LiveSourceHealth.load();

    expect(LiveSourceHealth.recordCount, 1);
    expect(LiveSourceHealth.rank('http://u'), 2);
  });

  test('损坏的持久化条目被忽略，不影响其它记录', () async {
    LiveSourceHealth.resetForTest();
    SharedPreferences.setMockInitialValues({
      LiveSourceHealth.prefsKey: [
        'not-a-record',
        '2|not-a-number|http://x',
        '1|${t0.millisecondsSinceEpoch}|http://ok',
      ],
    });
    LiveSourceHealth.now = () => t0;
    await LiveSourceHealth.load();

    expect(LiveSourceHealth.recordCount, 1);
    expect(LiveSourceHealth.rank('http://ok'), 2);
  });

  test('7 天后记录过期清除', () async {
    LiveSourceHealth.markFailure('http://u');
    LiveSourceHealth.now = () =>
        t0.add(const Duration(days: 7, minutes: 1));
    await LiveSourceHealth.saveNow();

    expect(LiveSourceHealth.recordCount, 0);
    expect(LiveSourceHealth.rank('http://u'), 0);
  });

  test('超过 2000 条时淘汰最旧记录', () async {
    for (var i = 0; i <= LiveSourceHealth.maxEntries; i++) {
      LiveSourceHealth.now = () => t0.add(Duration(milliseconds: i));
      LiveSourceHealth.markFailure('http://u$i');
    }
    await LiveSourceHealth.saveNow();

    expect(LiveSourceHealth.recordCount, LiveSourceHealth.maxEntries);
    expect(LiveSourceHealth.rank('http://u0'), 0);
    expect(LiveSourceHealth.rank('http://u2000'), 2);
  });
}
