// 分类方案 v11 落地测试（v2.2.3 起；文件名沿用 v10，内容已随规则升级重写）
//
// v11 变更要点（对齐 PC 版）：
// ① 取消一级「其他」大类 —— 成人 / 擦边内容（写真 / 福利 / 擦边 / 里番 / 资讯 / 主播）
//    随之整体隐藏
// ② 伦理一级重构为 4 个区域二级（日本 / 西方 / 韩国 / 港台伦理），
//    取消「伦理」「三级伦理」「两性课堂」
// ③ 泛伦理桶（伦理 / 三级伦理 / 理论片）内的影片按片名自动分派到 4 个区域二级
// ④ 取消一级分类下与自身同名的二级：电影 / 电视剧 / 综艺 / 纪录片
// ⑤ 纪录片按**内容主题**切分（源站纪录片是扁平大类，没有可借用的子分类）
// ⑥ 伦理一族在 matchTopCategory 里最先判定（否则「三级」会被 _otherForce 抢走）
//
// 聚合覆盖与多 id 解析的用例放在 category_v10_server_test.dart（需真实本地 HTTP）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dianying_shijie/api.dart';
import 'package:dianying_shijie/models.dart';
import 'package:dianying_shijie/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('v11 · 一级频道', () {
    test('一级「其他」已取消（allBigCats / docSubcats / aggTabs 均无）', () {
      expect(MacApi.allBigCats.contains('other'), isFalse);
      expect(MacApi.docSubcats.containsKey('other'), isFalse);
      expect(MacApi.aggTabs.containsKey('other'), isFalse);
      expect(MacApi.allBigCats.length, 9);
    });

    test('成人 / 擦边内容仍归 other —— 因大类已隐藏而整体不可见', () {
      for (final n in <String>[
        '写真热舞', '擦边短剧', '福利视频', '里番动漫', '资讯', '主播', '八卦爆料',
      ]) {
        expect(MacApi.matchTopCategory(n), 'other', reason: n);
      }
    });

    test('聚合 Tab 只剩体育（其他体育）', () {
      expect(MacApi.aggTabs['sports'], '其他体育');
      expect(MacApi.aggTabs.length, 1);
    });

    test('频道开关默认值与敏感频道不含 other', () {
      expect(AppStore.bigCatDefaults.containsKey('other'), isFalse);
      expect(AppStore.sensitiveCats, <String>{'ethics'});
    });
  });

  group('v11 · 伦理一级重构', () {
    test('伦理二级 = 4 个区域，且不含 伦理 / 三级伦理 / 两性课堂', () {
      expect(MacApi.docSubcats['ethics'], <String>[
        '日本伦理', '西方伦理', '韩国伦理', '港台伦理',
      ]);
      expect(MacApi.docSubcats['ethics']!.contains('伦理'), isFalse);
      expect(MacApi.docSubcats['ethics']!.contains('三级伦理'), isFalse);
      expect(MacApi.docSubcats['ethics']!.contains('两性课堂'), isFalse);
    });

    test('伦理一族最先判定：伦理 / 三级伦理 / 理论片 / 港台三级 都归 ethics', () {
      for (final n in <String>[
        '伦理', '三级伦理', '理论片', '港台三级', '日本伦理', '伦理片',
      ]) {
        expect(MacApi.matchTopCategory(n), 'ethics', reason: n);
      }
    });

    test('片名自动分派 classifyEthics', () {
      expect(MacApi.classifyEthics('东京热恋物语'), '日本伦理');
      expect(MacApi.classifyEthics('韩国情事录'), '韩国伦理');
      expect(MacApi.classifyEthics('欧美风情画'), '西方伦理');
      expect(MacApi.classifyEthics('香港奇案录'), '港台伦理');
      // 分不出地区 → 默认桶，保证不丢内容
      expect(MacApi.classifyEthics('无名之片'), '港台伦理');
    });

    test('泛伦理桶识别 isGenericEthicsSub', () {
      expect(MacApi.isGenericEthicsSub('伦理'), isTrue);
      expect(MacApi.isGenericEthicsSub('三级伦理'), isTrue);
      expect(MacApi.isGenericEthicsSub('理论片'), isTrue);
      expect(MacApi.isGenericEthicsSub('日本伦理'), isFalse);
      expect(MacApi.isGenericEthicsSub('港台伦理'), isFalse);
    });

    test('「港台三级」别名归一到「港台伦理」', () {
      expect(MacApi.canonSubName('港台三级'), '港台伦理');
      // 「理论片」归一到泛桶「三级伦理」，再由 classifyEthics 按片名分派
      expect(MacApi.canonSubName('理论片'), '三级伦理');
    });
  });

  group('v11 · 取消同名二级', () {
    test('电影 / 电视剧 / 综艺 二级不含同名项，首个二级依次为 剧情片 / 国产剧 / 大陆综艺', () {
      expect(MacApi.docSubcats['movies']!.contains('电影'), isFalse);
      expect(MacApi.docSubcats['tv']!.contains('电视剧'), isFalse);
      expect(MacApi.docSubcats['variety']!.contains('综艺'), isFalse);
      expect(MacApi.sortedDocSubcats('movies').first, '剧情片');
      expect(MacApi.sortedDocSubcats('tv').first, '国产剧');
      expect(MacApi.sortedDocSubcats('variety').first, '大陆综艺');
    });
  });

  group('v11 · 纪录片主题二级', () {
    test('二级 = 全部 + 6 个主题，「全部」恒排首位', () {
      expect(MacApi.docSubcats['documentary'], <String>[
        '全部', '自然地理', '历史人文', '军事战争', '科学探索', '美食旅行', '人物社会',
      ]);
      expect(MacApi.sortedDocSubcats('documentary').first, '全部');
    });

    test('主题判定 docThemeMatch（片名命中 / 不命中 / 全部不过滤）', () {
      VideoItem it(String name) =>
          VideoItem(vodId: '1', name: name, sourceId: 1, sourceName: '测试源');
      expect(MacApi.docThemeMatch('全部', it('任意片名')), isTrue);
      expect(MacApi.docThemeMatch('历史人文', it('探秘三星堆')), isTrue);
      expect(MacApi.docThemeMatch('自然地理', it('极致新疆')), isTrue);
      expect(MacApi.docThemeMatch('美食旅行', it('我的美食向导 第二季')), isTrue);
      expect(MacApi.docThemeMatch('历史人文', it('某个无关片名')), isFalse);
      // 主题名未知 → 放行（避免误伤）
      expect(MacApi.docThemeMatch('不存在的主题', it('任意')), isTrue);
    });
  });

  group('v11 · 既有规则回归（不该被改坏）', () {
    test('「港澳剧」指定归属电视剧', () {
      expect(MacApi.matchTopCategory('港澳剧'), 'tv');
      expect(MacApi.canonSubName('港澳剧'), '港台剧');
    });

    test('「电影解说」→ 影视解说（commentary 前置判定的保护）', () {
      expect(MacApi.matchTopCategory('电影解说'), 'commentary');
      expect(MacApi.matchTopCategory('解说'), 'commentary');
      expect(MacApi.matchTopCategory('预告片'), 'commentary');
    });

    test('常规分类不受影响', () {
      expect(MacApi.matchTopCategory('国产动漫'), 'anime');
      expect(MacApi.matchTopCategory('动作片'), 'movies');
      expect(MacApi.matchTopCategory('国产剧'), 'tv');
      expect(MacApi.matchTopCategory('篮球'), 'sports');
    });

    test('老数据兼容：残留「其他」开关不再影响显示', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'dysj_cat_other': true,
      });
      await AppStore.instance.init();
      expect(AppStore.instance.bigCatVisible('other'), isFalse);
      expect(AppStore.instance.bigCatVisible('movies'), isTrue);
      expect(MacApi.allBigCats.where(AppStore.instance.bigCatVisible),
          isNot(contains('other')));
    });
  });
}
