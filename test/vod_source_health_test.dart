import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dianying_shijie/vod_source_health.dart';

/// 只为排序测试准备的最小片源模型（真实 MovieSource 字段多，这里用不上）。
class _Src {
  const _Src(this.id, this.name);
  final int id;
  final String name;
}

void main() {
  final t0 = DateTime(2026, 10, 19, 12);

  setUp(() async {
    VodSourceHealth.resetForTest();
    SharedPreferences.setMockInitialValues({});
    VodSourceHealth.now = () => t0;
    await VodSourceHealth.load();
  });

  tearDown(() {
    // 清掉去抖落盘定时器，避免测试结束时留下 pending timer
    VodSourceHealth.resetForTest();
  });

  test('整源失败的片源排到健康片源后面，同权重保持原顺序', () {
    VodSourceHealth.markFailure(2);

    final order = VodSourceHealth.order(
      const [_Src(1, '甲'), _Src(2, '乙'), _Src(3, '丙')],
      (s) => s.id,
    );

    expect(order.map((s) => s.id), [1, 3, 2]);
  });

  test('冷却期内压后，冷却期过后恢复权重', () {
    VodSourceHealth.markFailure(7);
    expect(VodSourceHealth.rank(7), 2);

    VodSourceHealth.now = () => t0.add(const Duration(minutes: 9));
    expect(VodSourceHealth.rank(7), 2);

    VodSourceHealth.now = () => t0.add(const Duration(minutes: 11));
    expect(VodSourceHealth.rank(7), 0);
  });

  test('稳定播放确认成功后清除失败记录', () {
    VodSourceHealth.markFailure(5);
    expect(VodSourceHealth.recordCount, 1);

    VodSourceHealth.markSuccess(5);
    expect(VodSourceHealth.recordCount, 0);
    expect(VodSourceHealth.rank(5), 0);
  });

  test('记录可持久化到 shared_preferences 并读回', () async {
    VodSourceHealth.markFailure(9);
    await VodSourceHealth.saveNow();

    VodSourceHealth.resetForTest();
    VodSourceHealth.now = () => t0;
    await VodSourceHealth.load();

    expect(VodSourceHealth.recordCount, 1);
    expect(VodSourceHealth.rank(9), 2);
  });

  test('点播与直播的健康记录互不干扰', () async {
    // 只在直播的存储键里放一条「42 是坏源」，点播侧不应读到。
    SharedPreferences.setMockInitialValues({
      'live_source_health_v1': ['1|${t0.millisecondsSinceEpoch}|42'],
    });
    VodSourceHealth.resetForTest();
    VodSourceHealth.now = () => t0;
    await VodSourceHealth.load();

    expect(VodSourceHealth.recordCount, 0);
    expect(VodSourceHealth.rank(42), 0);
  });
}
