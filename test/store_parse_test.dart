// v1.9.9（代码审查 3.5/六）AppStore 持久化容错测试
//
// 覆盖五类情况：空数据 / 合法数据 / 单条损坏 / 顶层 JSON 损坏 / 旧字段缺失。
// 直接测 AppStore 的静态容错解析函数（不依赖 SharedPreferences 实例），
// 与 init() 的行为一致：损坏项跳过、其余照常加载。
import 'package:flutter_test/flutter_test.dart';

import 'package:dianying_shijie/store.dart';

void main() {
  group('AppStore 收藏/历史/搜索记录容错解析', () {
    test('① 空数据：null / 空串 → 空列表不报错', () {
      expect(AppStore.parseFavoritesJson(null), isEmpty);
      expect(AppStore.parseFavoritesJson(''), isEmpty);
      expect(AppStore.parseHistoryJson(null), isEmpty);
      expect(AppStore.parseSearchHisJson(''), isEmpty);
    });

    test('② 合法数据：收藏与历史正常解析', () {
      const fav = '''
      [{"vodId":"101","name":"流浪地球","sourceId":2,"sourceName":"暴风",
        "typeName":"科幻","score":8.5,"hits":1234}]''';
      const his = '''
      [{"item":{"vodId":"101","name":"流浪地球","sourceId":2,"sourceName":"暴风"},
        "epName":"第01集","epIndex":0,"groupIndex":0,"positionSec":360,
        "updatedAt":1758600000000}]''';
      final f = AppStore.parseFavoritesJson(fav);
      expect(f.length, 1);
      expect(f.first.name, '流浪地球');
      expect(f.first.score, 8.5);
      final h = AppStore.parseHistoryJson(his);
      expect(h.length, 1);
      expect(h.first.epName, '第01集');
      expect(h.first.positionSec, 360);
      expect(AppStore.parseSearchHisJson('["猫眼","渡神"]'), ['猫眼', '渡神']);
    });

    test('③ 单条损坏：损坏项跳过，其余继续加载', () {
      const fav = '''
      [{"vodId":"1","name":"好的","sourceId":1},
       {"vodId":"2"},
       {"vodId":"3","name":"也好","sourceId":3}]''';
      // 第 2 条缺 name（VideoItem name 兼容成空串，仍可加载）——
      // 真正"损坏"的是类型错乱到连兜底都救不了的项：
      const favHard = '''
      ["纯字符串垃圾", 12345, {"vodId":"1","name":"好的","sourceId":1}]''';
      final f = AppStore.parseFavoritesJson(favHard);
      expect(f.length, 1);
      expect(f.first.vodId, '1');
      expect(f.length, isNot(3)); // 垃圾项被跳过而非整体失败

      const his = '''
      [{"item":{"vodId":"1","name":"A","sourceId":1},"epName":"第01集",
        "epIndex":0,"groupIndex":0,"positionSec":10,"updatedAt":1},
       {"item":"不是Map的item","epName":"第02集","epIndex":0,
        "positionSec":10,"updatedAt":2},
       {"item":{"vodId":"3","name":"C","sourceId":3},"epName":"第03集",
        "epIndex":0,"positionSec":30,"updatedAt":3}]''';
      final h = AppStore.parseHistoryJson(his);
      expect(h.length, 2);
      expect(h[0].epName, '第01集');
      expect(h[1].epName, '第03集');
      // 第一组里缺 name 的那条走兼容转换（空串），不算损坏
      expect(AppStore.parseFavoritesJson(fav).length, 3);
    });

    test('④ 顶层 JSON 损坏/非 List：整体按空处理不抛异常', () {
      expect(AppStore.parseFavoritesJson('{不是数组}'), isEmpty);
      expect(AppStore.parseHistoryJson('{"a":1}'), isEmpty); // Map 而非 List
      expect(AppStore.parseSearchHisJson('"字符串"'), isEmpty);
      expect(AppStore.parseFavoritesJson('完全不是JSON'), isEmpty);
    });

    test('⑤ 旧字段缺失/类型漂移：兼容转换不崩溃', () {
      // 旧版本记录缺 v1.7.0 之后新增的字段；数值字段漂成字符串
      const fav = '''
      [{"vodId":"9","name":"旧记录","sourceId":"2","score":"7.5",
        "hits":"88"}]''';
      final f = AppStore.parseFavoritesJson(fav);
      expect(f.length, 1);
      expect(f.first.sourceId, 2);
      expect(f.first.score, 7.5);
      expect(f.first.hits, 88);
      expect(f.first.director, ''); // 新字段缺省为空串

      const his = '''
      [{"item":{"vodId":"9","name":"旧记录","sourceId":2},
        "epName":"第01集","epIndex":"0","positionSec":"600",
        "updatedAt":1758600000000}]''';
      final h = AppStore.parseHistoryJson(his);
      expect(h.length, 1);
      expect(h.first.epIndex, 0);
      expect(h.first.positionSec, 600);
    });
  });
}
