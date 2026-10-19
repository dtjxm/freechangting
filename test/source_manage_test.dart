// v2.2.4 片源管理：停用过滤逻辑防回归
//
// 「片源管理」页把停用的片源写进 MacApi.disabledIds，此后：
//   · activeSources 不再包含它（首页加载 / 检索 / 换源统一走这里）；
//   · 全部停用时回退为全量，避免首页一片空白；
//   · feedQueue 也不再把停用源排进多源加载队列。
import 'package:dianying_shijie/api.dart';
import 'package:dianying_shijie/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const a = MovieSource(id: 1, name: 'A', url: 'http://a/api.php/provide/vod/');
  const b = MovieSource(id: 2, name: 'B', url: 'http://b/api.php/provide/vod/');
  const c = MovieSource(id: 3, name: 'C', url: 'http://c/api.php/provide/vod/');

  setUp(() {
    MacApi.instance.sources = [a, b, c];
    MacApi.instance.disabledIds.clear();
  });

  tearDown(() => MacApi.instance.disabledIds.clear());

  test('停用后 activeSources 排除该源', () {
    MacApi.instance.setDisabledSources([2]);
    expect(MacApi.instance.activeSources.map((s) => s.id).toList(), [1, 3]);
  });

  test('全部停用 → 回退为全量（避免首页空白）', () {
    MacApi.instance.setDisabledSources([1, 2, 3]);
    expect(MacApi.instance.activeSources.length, 3);
  });

  test('feedQueue 跳过停用源', () {
    MacApi.instance.setDisabledSources([3]);
    final q = MacApi.instance.feedQueue(a, const <int, int>{});
    expect(q.map((s) => s.id).toList(), [1, 2]);
  });

  test('未停用时 activeSources 与 sources 等长', () {
    expect(MacApi.instance.activeSources.length, MacApi.instance.sources.length);
  });
}
