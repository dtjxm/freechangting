// 分类方案 v11 · 伦理解析（本地 HttpServer 假片源）
//
// （文件名沿用 v10；内容已随 v2.2.3 的 v11 规则重写：原 other 频道的用例，
//   改为等价地验证 ethics 的「区域二级 + 泛伦理桶」解析，以及 sports 聚合 Tab。）
//
// v2.2.0 起的注意事项仍然有效：本文件**故意不调用 TestWidgetsFlutterBinding.ensureInitialized()**
// —— 一旦初始化，测试框架会把本进程内所有 HttpClient 请求劫持成 400 假响应，
// 本地假片源就取不到数据（症状：resolveXxxIds 恒返回空 []）。
// 需要 SharedPreferences 模拟的用例请放在 category_v10_test.dart。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dianying_shijie/api.dart';
import 'package:dianying_shijie/models.dart';

void main() {
  group('v11 · 伦理解析 resolveEthicsIds / 体育聚合（本地假片源）', () {
    HttpServer? server;
    var port = 0;

    setUpAll(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server!.port;
      server!.listen((req) {
        final many = req.uri.path.contains('many');
        final cls = many
            // 上限防御用：25 个同名分类
            ? <Object>[
                for (var i = 1; i <= 25; i++)
                  {'type_id': '$i', 'type_name': '日本伦理', 'type_pid': '0'},
              ]
            : <Object>[
                {'type_id': '1', 'type_name': '日本伦理', 'type_pid': '0'},
                {'type_id': '2', 'type_name': '伦理', 'type_pid': '0'},
                {'type_id': '3', 'type_name': '三级伦理', 'type_pid': '0'},
                {'type_id': '4', 'type_name': '理论片', 'type_pid': '0'},
                {'type_id': '5', 'type_name': '港台三级', 'type_pid': '0'},
                {'type_id': '6', 'type_name': '动作片', 'type_pid': '0'},
                {'type_id': '7', 'type_name': '体育赛事', 'type_pid': '0'},
                {'type_id': '8', 'type_name': '网球赛', 'type_pid': '0'},
                {'type_id': '9', 'type_name': '资讯', 'type_pid': '0'},
              ];
        final body = jsonEncode(<String, Object>{
          'pagecount': 1,
          'list': <Object>[],
          'class': cls,
        });
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(body)
          ..close();
      });
    });

    tearDownAll(() {
      server?.close(force: true);
      server = null;
    });

    MovieSource src(int id) => MovieSource(
          id: id, // 唯一 id，避免命中分类缓存
          name: 'v11测试源$id',
          url: 'http://127.0.0.1:$port/api',
        );

    test('伦理「日本伦理」：本区分类保留 + 泛伦理桶一并取回（桶内标记 generic）', () async {
      final pairs = await MacApi.instance.resolveEthicsIds(src(998877), '日本伦理');
      expect(pairs.map((p) => p.id).toList(), <String>['1', '2', '3', '4']);
      // 泛桶（伦理 / 三级伦理 / 理论片）需由客户端按片名分派
      expect(pairs.where((p) => p.generic).map((p) => p.id).toList(),
          <String>['2', '3', '4']);
      // 「日本伦理」(1) 是源站已标地区的分类 → 不参与分派
      expect(pairs.firstWhere((p) => p.id == '1').generic, isFalse);
    });

    test('伦理「港台伦理」：港台三级已归并进来（generic=false），泛桶仍在', () async {
      final pairs = await MacApi.instance.resolveEthicsIds(src(998878), '港台伦理');
      expect(pairs.map((p) => p.id).toList(), <String>['2', '3', '4', '5']);
      expect(pairs.where((p) => p.generic).map((p) => p.id).toList(),
          <String>['2', '3', '4']);
      // 归并进来的「港台三级」(5) 已明确地区 → 不再二次分派
      expect(pairs.firstWhere((p) => p.id == '5').generic, isFalse);
      // 其它区域的分类（日本伦理 1）不应被拉进来
      expect(pairs.map((p) => p.id), isNot(contains('1')));
    });

    test('伦理「韩国伦理」：本源没有该区分类 → 只返回泛桶', () async {
      final pairs = await MacApi.instance.resolveEthicsIds(src(998883), '韩国伦理');
      expect(pairs.map((p) => p.id).toList(), <String>['2', '3', '4']);
      expect(pairs.every((p) => p.generic), isTrue);
    });

    test('体育频道回归：固定 Tab 被排除，网球赛 汇入「其他体育」', () async {
      final ids = await MacApi.instance.resolveMiscIds(src(998879), 'sports');
      expect(ids, <String>['8']);
    });

    test('v11 回归：「其他」大类已下线（不进频道栏、无聚合 Tab、内容整体不可见）', () async {
      // v11：other 不再是常规一级大类，聚合 Tab 也不再给它留条目
      expect(MacApi.allBigCats, isNot(contains('other')));
      expect(MacApi.aggTabs.containsKey('other'), isFalse);
      // 未归类的杂项仍会被判为 other —— 由首页频道过滤 / 检索过滤统一剔除，
      // 因此杂项内容（含成人向）整体不可见。
      // 注：resolveMiscIds(src,'other') 本身仍会返回这些分类（函数是通用实现），
      //     但 UI 不会再以 'other' 为参数调用它，故不在此断言其为空。
      expect(MacApi.matchTopCategory('资讯'), 'other');
    });

    test('多 id：同一源多个同规范名分类被一次全收（上限防御）', () async {
      final s = MovieSource(
        id: 998881,
        name: 'v11上限测试源',
        url: 'http://127.0.0.1:$port/many',
      );
      final ids = await MacApi.instance.resolveTabIds(s, 'ethics', '日本伦理');
      expect(ids.length, MacApi.maxTabIds);
      expect(MacApi.maxTabIds, 20);
    });

    test('按名解析：伦理 Tab 能解析到各源分类；跨频道不会被拉进来', () async {
      final s = src(998882);
      expect(await MacApi.instance.resolveTypeId(s, 'ethics', '日本伦理'), '1');
      expect(await MacApi.instance.resolveTypeId(s, 'ethics', '港台三级'), '5');
      // 频道不符 → **模糊匹配阶段**不会把别的频道的分类解析进来（fallbackFirst: false 时为空）。
      // 注：规范名「精确相等」的优先段不做频道校验（v2.2.0 既有行为），
      //     所以这里必须用一个「只能靠模糊匹配命中」的名字：网球 → 网球赛（属 sports）。
      expect(
        await MacApi.instance
            .resolveTypeId(s, 'movies', '网球', fallbackFirst: false),
        '',
      );
      // 对照：同频道的模糊名要能命中（动作 → 动作片）
      expect(
        await MacApi.instance
            .resolveTypeId(s, 'movies', '动作', fallbackFirst: false),
        '6',
      );
      // 本源没有「篮球」→ 默认兜底到该频道第一个分类；显式关掉兜底才为空
      expect(await MacApi.instance.resolveTypeId(s, 'sports', '篮球'), '7');
      expect(
        await MacApi.instance
            .resolveTypeId(s, 'sports', '篮球', fallbackFirst: false),
        '',
      );
    });
  });
}
