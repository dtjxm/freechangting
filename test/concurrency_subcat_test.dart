// v2.0 新增能力测试：
// ①「同时下载数量」设置项（按「集」算）的默认值与 1~10 范围钳制、持久化
// ②「找回影片补分类」的同片名批量更新
//
// 说明：只覆盖不触网、不开 MethodChannel 的纯逻辑；下载并发调度与删除授权
// 依赖原生通道与真实网络，按既定约定以真机验收为准（见交付报告「未自动化项」）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dianying_shijie/download_service.dart';

DownloadTask _localTask(int ep, String movie) => DownloadTask(
      id: 'local|$movie|第${ep + 1}集',
      sourceId: -1,
      sourceName: '本地恢复',
      vodId: movie,
      movieName: movie,
      groupIndex: 0,
      groupName: '媒体库',
      epIndex: ep,
      epName: '第${ep + 1}集',
      url: 'content://media/external/video/media/$ep',
      state: 'done',
      progress: 1,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 注意：DownloadService 是懒加载单例，必须放在 setUp / 用例内首次访问
  //（构造时会 new http.Client，在 test zone 外访问会触发 mock http 报错）
  late DownloadService svc;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    svc = DownloadService.instance;
    svc.tasks.clear();
  });

  tearDown(() => svc.tasks.clear());

  test('同时下载数量：默认 3', () {
    expect(DownloadService.kDefaultMaxConcurrent, 3);
    expect(svc.maxConcurrent, 3);
  });

  test('同时下载数量：小于 1 钳到 1，大于 10 钳到 10', () async {
    await svc.setMaxConcurrent(0);
    expect(svc.maxConcurrent, 1);

    await svc.setMaxConcurrent(-5);
    expect(svc.maxConcurrent, 1);

    await svc.setMaxConcurrent(99);
    expect(svc.maxConcurrent, DownloadService.kMaxConcurrentLimit);
    expect(DownloadService.kMaxConcurrentLimit, 10);
  });

  test('同时下载数量：合法值原样生效并写入持久化', () async {
    await svc.setMaxConcurrent(7);
    expect(svc.maxConcurrent, 7);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('dysj_max_concurrent'), 7);

    await svc.setMaxConcurrent(1);
    expect(svc.maxConcurrent, 1);
  });

  test('补分类：同片名下所有集数一起更新，其他影片不受影响', () {
    svc.tasks.addAll([
      _localTask(0, '流浪地球3'),
      _localTask(1, '流浪地球3'),
      _localTask(0, '另一部片'),
    ]);

    svc.setSubcatForMovie('流浪地球3', '科幻片');

    final target = svc.tasks.where((t) => t.movieName == '流浪地球3');
    expect(target.length, 2);
    expect(target.every((t) => t.subcat == '科幻片'), isTrue);
    expect(
      svc.tasks.firstWhere((t) => t.movieName == '另一部片').subcat,
      isEmpty,
    );
  });

  test('补分类：清空分类（传空串）时不被写进记忆表', () {
    svc.tasks.add(_localTask(0, '测试片'));

    svc.setSubcatForMovie('测试片', '动作片');
    expect(svc.tasks.first.subcat, '动作片');

    svc.setSubcatForMovie('测试片', '');
    expect(svc.tasks.first.subcat, isEmpty);
  });
}
