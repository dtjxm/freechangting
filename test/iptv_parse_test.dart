// v2.2.4 直播源扩容：TXT 方言解析 + 三道上限防回归
//
// 并入 14 份非成人订阅清单后，两种方言各占一半：
//   · M3U：#EXTINF（tvg-logo / group-title）+ 下一行地址
//   · TXT：`台名,地址` 逐行，`分组名,#genre#` 切分组（DIYP/社区通用方言）
// 海燕 / 易发 / 湘西 / vinkerq 这 4 份合计约 2.2 万条全是 TXT ——
// 只认 M3U 的话它们会「清单可取但一条都进不来」，故本测试锁死方言与三道上限。
//
// v2.2.4（10-14 补充）：一级分类由「只看 group-title 的 5 大类」改为
//   **逐频道判定**（[LiveCats.catOf]，10 类 + 待定；广播整类丢弃，「国际」已整体取消）。
//   旧 5 类下 2.99 万频道里 62% 挤在「国际·其他」、8,340 个误落「地方频道」。
//   本文件同步到新口径；规则表本身在 lib/live_cats.dart，由离线脚本生成。
import 'package:dianying_shijie/iptv.dart';
import 'package:dianying_shijie/live_cats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TXT 方言（name,url + #genre#）', () {
    const txt = '''
咪咕视频,#genre#

CCTV1综合,http://36.134.89.155:1234/608807420
CCTV2财经,http://36.134.89.155:1234/631780532

抖音K歌,#genre#,DE=3
切换EXO解码,1
街道办GDC/欧阳耀莹-春娇与志明,https://x.com/a.m3u8
''';

    test('按 #genre# 切分组，带附加参数的写法也认', () {
      final chans = IptvService.parseList(txt);
      expect(chans.length, 3);
      expect(chans[0].name, 'CCTV1综合');
      expect(chans[0].group, '咪咕视频');
      expect(chans[0].urls, ['http://36.134.89.155:1234/608807420']);
      expect(chans[2].group, '抖音K歌'); // 「抖音K歌,#genre#,DE=3」
    });

    test('右侧不是 http 的行（播放器指令）跳过', () {
      final names = IptvService.parseList(txt).map((c) => c.name).toList();
      expect(names, isNot(contains('切换EXO解码')));
    });

    test('台名内含逗号时按最后一个逗号切地址', () {
      final c = IptvService.parseList('街道办GDC/欧阳耀莹-春娇与志明,https://x.com/a.m3u8');
      expect(c.single.name, '街道办GDC/欧阳耀莹-春娇与志明');
      expect(c.single.urls, ['https://x.com/a.m3u8']);
    });

    test('BOM 被清掉（海燕首行「央视网频道」带 BOM）', () {
      final c = IptvService.parseList(
          '\uFEFF央视网频道,#genre#\nCCTV1,http://a.cn/x.m3u8');
      expect(c.single.group, '央视网频道');
    });

    test('没有 #genre# 时归入「其他频道」', () {
      final c = IptvService.parseList('某台,http://a.cn/x.m3u8');
      expect(c.single.group, '其他频道');
    });
  });

  group('M3U 方言', () {
    test('tvg-logo / group-title 正常取到', () {
      final c = IptvService.parseList('#EXTM3U\n'
          '#EXTINF:-1 tvg-logo="http://l/1.png" group-title="央视",CCTV1\n'
          'http://a/1.m3u8\n');
      expect(c.single.name, 'CCTV1');
      expect(c.single.logo, 'http://l/1.png');
      expect(c.single.group, '央视');
    });

    test('group-title 为 Undefined（iptv-org / 全球直播大量存在）归「其他频道」', () {
      final c = IptvService.parseList('#EXTM3U\n'
          '#EXTINF:-1 group-title="Undefined",US: ABC\nhttp://a/2.m3u8\n');
      expect(c.single.group, '其他频道');
    });
  });

  group('三道上限', () {
    test('parseList(limit:) 单清单截断', () {
      final sb = StringBuffer('央视,#genre#\n');
      for (var i = 0; i < 50; i++) {
        sb.write('台$i,http://a/$i.m3u8\n');
      }
      expect(IptvService.parseList(sb.toString(), limit: 10).length, 10);
    });

    test('mergeSources(limit:) 触顶后不再收新频道（已在表内的仍可累加线路）', () {
      final l1 = IptvService.parseList('A,http://a/1\nB,http://a/2');
      final l2 = IptvService.parseList('C,http://a/3\nA,http://a/9');
      final merged = IptvService.mergeSources([l1, l2], limit: 2);
      expect(merged.length, 2);
      expect(merged.first.urls, ['http://a/1', 'http://a/9']); // A 仍累加到线路
    });

    test('mergeSources：同台名归一化后合并线路（CCTV-1 与 CCTV1 视为同台）', () {
      final l1 = IptvService.parseList('CCTV-1,http://a/1');
      final l2 = IptvService.parseList('CCTV1,http://b/2');
      final merged = IptvService.mergeSources([l1, l2]);
      expect(merged.length, 1);
      expect(merged.single.urls, ['http://a/1', 'http://b/2']);
    });

    test('serializeM3u(maxChars:) 写满预算即停', () {
      final chans = IptvService.parseList(
          'A,http://a/1\nB,http://a/2\nC,http://a/3\nD,http://a/4');
      final full = IptvService.serializeM3u(chans);
      final cut = IptvService.serializeM3u(chans, maxChars: 40);
      expect(full.length, greaterThan(40));
      expect(cut.length, lessThan(full.length));
    });
  });

  group('源表扩容', () {
    test('源组数为 20（原有 7 组 + v2.2.4 并入 13 份非成人订阅）', () {
      expect(IptvService.sourceSetCount, 20);
    });

    test('三道上限都在（并入后总量可达 3 万，必须设闸）', () {
      expect(IptvService.maxPerList, greaterThan(0));
      expect(IptvService.maxChannels, greaterThanOrEqualTo(30000));
      expect(IptvService.maxCacheChars, greaterThan(0));
    });
  });

  // ============================================================
  // v2.2.4（10-14 补充）：一级分类改为**逐频道判定**（10 类 + 待定；
  //   第 3 批已取消「国际」大类，广播整类丢弃）
  // 规则在 lib/live_cats.dart。旧 5 大类只按 group-title 判定，
  // 并入国际清单后 62% 堆进「国际·其他」、8,340 个误落「地方频道」。
  // ============================================================
  group('一级大类（逐频道判定）', () {
    test('央视系：别名表 / 品牌前缀 / 中文名都归「央视」', () {
      expect(IptvService.topGroupOf('CCTV-1综合'), '央视');
      expect(IptvService.topGroupOf('央视'), '央视');
      expect(IptvService.topGroupOf('CGTN'), '央视');
      // 不在别名表、也没有中文类型词 → 靠品牌前缀兜住
      expect(IptvService.topGroupOf('CETV-2教育教学'), '央视');
      expect(IptvService.topGroupOf('CEC健康'), '央视');
    });

    test('卫视：别名表命中且非央视系 → 「卫视」', () {
      expect(IptvService.topGroupOf('湖南卫视'), '卫视');
      expect(IptvService.topGroupOf('东方卫视'), '卫视');
    });

    test('港澳台：分组名带 emoji/间隔符也要认出；台名关键词同样认', () {
      // v1.5.1 的坑：分组名带 emoji/间隔符必须仍能识别
      expect(IptvService.topGroupOf('🌊港·澳·台'), '港澳台');
      expect(IptvService.topGroupOf('凤凰中文'), '港澳台');
    });

    test('纯外文名 → 「国际」（iptv-org 的英文分组不再整批落进地方频道）', () {
      for (final g in ['General', 'News', 'Movies', 'Sports', 'Documentary', 'Undefined']) {
        expect(IptvService.topGroupOf(g), '国际', reason: g);
      }
      // 带分号的组合分类（iptv-org 大量存在）同样归此
      expect(IptvService.topGroupOf('Movies;Comedy'), '国际');
    });

    test('ASCII 关键词加左边界：ACETV 不再命中 CETV、TVSPINBALL 不再命中 NBA', () {
      // 裸子串匹配时央视一度虚增到 61 个（ACETV / POLICETV / DANCETV 都含 CETV）
      for (final n in ['Ace TV', 'Police TV', 'DanceTV Algorhythm']) {
        expect(IptvService.topGroupOf(n), isNot('央视'), reason: n);
      }
      // TVSPINBALL 含 NBA、TBNBALTIA 含 NBA、IBCBAKTHI 含 CBA
      for (final n in ['TVS Pinball Network', 'TBN Baltia', 'IBC Bakthi']) {
        expect(IptvService.topGroupOf(n), isNot('体育'), reason: n);
      }
    });

    test('中文短名看不出类型 → 「地方」', () {
      expect(IptvService.topGroupOf('北京'), '地方');
      expect(IptvService.topGroupOf('广东电信'), '地方');
    });

    test('急救科普 / 相声 / 小品最先拦下 → 「影视点播」', () {
      // 这些名字含「儿童」「健康」等，不先拦会被少儿动画 / 音乐戏曲按名抢走
      expect(IptvService.topGroupOf('儿童心肺复苏'), '影视点播');
      expect(IptvService.topGroupOf('人工呼吸法'), '影视点播');
      expect(IptvService.topGroupOf('郭德纲相声精选'), '影视点播');
    });

    test('广播整类丢弃（本软件已移除，记录另存《广播频道清单》）', () {
      expect(LiveCats.catOf('收音广播', '中国之声', ''), LiveCats.radioCat);
      expect(LiveCats.catOf('某分组', 'FM 90.9 音乐台', ''), LiveCats.radioCat);
      // 广播不得出现在一级分类表里（否则会多出一个空分类）
      expect(LiveCats.catOrder.contains(LiveCats.radioCat), isFalse);
    });

    test('topGroups = LiveCats.catOrder，含「影视点播」与「待定」', () {
      expect(IptvService.topGroups, LiveCats.catOrder);
      // v2.2.4（10-14 第 3 批）：取消「国际」大类 → 10 大类 + 待定 = 11 项
      expect(IptvService.topGroups.length, 11);
      expect(IptvService.topGroups.first, '央视');
      expect(IptvService.topGroups.contains('影视点播'), isTrue);
      expect(IptvService.topGroups.contains('待定'), isTrue);
      // 「国际」已整体取消、「广播」本就不在本表 —— 两者都不该出现在一级大类里
      expect(IptvService.topGroups.contains('国际'), isFalse);
      expect(IptvService.topGroups.contains('广播'), isFalse);
    });
  });

  // ============================================================
  // v2.2.4（10-14 追加）：跨源去重 + 境外频道过滤
  // 用户反馈「央视分类下，不同来源的同一套台被列了好几遍」——
  // 归并键由「去空格大写」升级为 LiveCats.mergeKey。
  // ============================================================
  group('跨源去重（mergeKey）', () {
    test('同一台的五种写法归并为一条、多线路', () {
      final l = IptvService.parseList('CCTV1,http://a/1\n'
          'CCTV-1,http://b/2\n'
          'CCTV1综合,http://c/3\n'
          '央视一套,http://d/4\n'
          'CCTV1高清,http://e/5');
      final m = IptvService.mergeSources([l]);
      expect(m.length, 1);
      expect(m.single.name, 'CCTV1'); // 展示名取别名表规范名
      expect(m.single.urls.length, 5);
    });

    test('尾部「频道 / 综合」也归一：上虞新闻频道 = 上虞新闻综合', () {
      expect(LiveCats.mergeKey('上虞新闻频道'), LiveCats.mergeKey('上虞新闻综合'));
      expect(LiveCats.mergeKey('上虞新商都频道'), LiveCats.mergeKey('上虞新商都'));
    });

    test('分辨率与括号注记不影响归并', () {
      expect(LiveCats.mergeKey('上虞1新闻 (720p) [Not 24/7]'), LiveCats.mergeKey('上虞1新闻'));
      expect(LiveCats.mergeKey('CCTV1 综合高清'), LiveCats.mergeKey('CCTV1'));
    });

    test('CCTV4K / CCTV8K 是独立频道，不能被当噪声抹掉', () {
      expect(LiveCats.mergeKey('CCTV4K'), isNot(LiveCats.mergeKey('CCTV8K')));
      expect(LiveCats.mergeKey('CCTV4K'), contains('4K'));
      expect(LiveCats.mergeKey('CCTV8K'), contains('8K'));
    });

    test('不过度合并：卫视与其同名地方频道是两个台', () {
      expect(LiveCats.mergeKey('北京卫视'), isNot(LiveCats.mergeKey('北京')));
      expect(LiveCats.mergeKey('湖南卫视'), isNot(LiveCats.mergeKey('湖南')));
    });
  });

  group('境外与非中文频道过滤', () {
    test('国际大类整类丢弃；其他大类的非中文频道也丢；国内 / 港澳台的非中文保留', () {
      final l = IptvService.parseList('#EXTM3U\n'
          '#EXTINF:-1 group-title="News",CNN\nhttp://a/1\n'
          '#EXTINF:-1 group-title="体育",NBA TV\nhttp://a/2\n'
          '#EXTINF:-1 group-title="央视",CCTV5+\nhttp://a/3\n'
          '#EXTINF:-1 group-title="港澳台",TVB Pearl\nhttp://a/4\n');
      final i = IptvIndex.of(l);
      expect(i.intlDropped, 2, reason: 'CNN 属国际；NBA TV 属体育但无中文 → 都丢');
      expect(i.all.map((c) => c.name).toSet(), {'CCTV5+', 'TVB Pearl'});
      expect(i.tops.contains('国际'), isFalse);
    });
  });

  // ============================================================
  // v2.2.4（10-14 追加）：「影视点播里还混着电视台」的修复
  // 分组是省级 / 地方标记、但频道名带「影院 / 影视」的，其实是地方台。
  // ============================================================
  group('影视点播里的地方台归位', () {
    test('省级分组 + 影视类台名 → 地方（而不是影视点播）', () {
      expect(LiveCats.catOf('江苏频道', '句容影院频道', ''), '地方');
      expect(LiveCats.catOf('地方频道', '句容影院', ''), '地方');
      expect(LiveCats.catOf('☘️上海频道', '东方影视', ''), '地方');
      expect(LiveCats.catOf('浙江频道', '浙江教科影院', ''), '地方');
    });

    test('真正的轮播频道仍留在影视点播', () {
      expect(LiveCats.catOf('🎦影视频道', '动作电影频道', ''), '影视点播');
      expect(LiveCats.catOf('💎华数影院', '传奇剧场频道', ''), '影视点播');
      expect(LiveCats.catOf('🎬电影轮播(捐5元获取密码)_8657', '成龙频道', ''), '影视点播');
    });

    test('片名里的地名不参与判定（「上海正午2上海骑士」不是上海台）', () {
      expect(LiveCats.catOf('🎦家庭影院', '上海正午2上海骑士', ''), '影视点播');
    });
  });

  group('英文分组名 → 中文展示名', () {
    test('常见分类翻译', () {
      expect(IptvService.displayGroup('General'), '综合');
      expect(IptvService.displayGroup('News'), '新闻');
      expect(IptvService.displayGroup('TopNews'), '头条新闻');
      expect(IptvService.displayGroup('Kids'), '少儿');
    });

    test('分号组合分类逐段翻译后以 · 连接', () {
      expect(IptvService.displayGroup('Movies;Comedy'), '电影·喜剧');
      expect(IptvService.displayGroup('Animation;Kids'), '动画·少儿');
    });

    test('中文分组名原样返回，未知英文名不丢', () {
      expect(IptvService.displayGroup('央视'), '央视');
      expect(IptvService.displayGroup('虎牙电视剧'), '虎牙电视剧');
      expect(IptvService.displayGroup('SomeUnknownCat'), 'SomeUnknownCat');
    });

    test('「其他频道」（源站未标注分组，4132 个）展示为「未分组」', () {
      expect(IptvService.displayGroup('其他频道'), '未分组');
    });

    test('展示名只影响 UI —— 分组/筛选仍用原始名（翻译表是独立的一份）', () {
      expect(IptvService.groupZhNames.containsKey('general'), isTrue);
      expect(IptvService.displayGroup('GENERAL'), '综合'); // 大小写不敏感
    });
  });

  // ============================================================
  // v2.2.4：电视页索引（IptvIndex）
  // 2.99 万频道下「每次 build 现算」会卡帧，改为加载后建一次索引。
  // 索引是纯优化，必须保证与「全量逐条过滤」结果**完全一致**（含顺序），
  // 故这里用等价性断言把它锁住。
  // v2.2.4（10-14 补充）：分桶键由「一级大类」下沉到「一级大类 × 二级分类」，
  //   因为地方台要按省份、国际台要按国家、影视点播要按内容类型再分一层。
  // ============================================================
  group('频道索引 IptvIndex', () {
    final chans = IptvService.parseList('#EXTM3U\n'
        '#EXTINF:-1 group-title="央视",CCTV1\nhttp://a/1\n'
        '#EXTINF:-1 group-title="卫视",湖南卫视\nhttp://a/2\n'
        '#EXTINF:-1 group-title="港澳台",凤凰中文\nhttp://a/3\n'
        '#EXTINF:-1 group-title="General",US: ABC\nhttp://a/4\n'
        '#EXTINF:-1 group-title="央视",CCTV2\nhttp://a/5\n'
        '#EXTINF:-1 group-title="收音广播",中国之声\nhttp://a/6\n');
    final idx = IptvIndex.of(chans);

    test('按原始分组与一级大类分桶，顺序保持源清单顺序', () {
      expect(chans.length, 6);
      expect(idx.byGroup['央视']!.map((c) => c.name).toList(), ['CCTV1', 'CCTV2']);
      expect(idx.byTop['央视']!.map((c) => c.name).toList(), ['CCTV1', 'CCTV2']);
      expect(idx.groupOrder, ['央视', '卫视', '港澳台']);
    });

    test('一级大类列表按固定顺序，且只含实际存在的类', () {
      expect(idx.tops, ['央视', '卫视', '港澳台']);
      for (final t in idx.tops) {
        expect(IptvService.topGroups.contains(t), isTrue);
      }
    });

    test('二级分类：地方=省份 / 港澳台=地区 / 影视点播=内容类型', () {
      expect(idx.subsOfTop('港澳台'), ['香港']); // 凤凰中文 → 香港
      expect(idx.subsOfTop('央视'), isEmpty); // 央视不设二级
      expect(idx.subsOfTop('地方'), isEmpty); // 样例里没有地方台
    });

    test('subset：给定二级取该二级；只给一级取大类；「全部」= 本级全量', () {
      expect(idx.subset('全部', '全部').length, 4);
      expect(idx.subset('央视', '全部').length, 2);
      expect(idx.subset('港澳台', '香港').length, 1);
      expect(idx.subset('地方', '全部'), isEmpty);
      expect(idx.subset('央视', '不存在的二级'), isEmpty);
    });

    test('广播与境外频道整批丢弃，不进任何大类', () {
      expect(idx.radioDropped, 1, reason: '中国之声');
      expect(idx.intlDropped, 1, reason: 'US: ABC 属国际大类');
      expect(idx.all.map((c) => c.name).toList(),
          ['CCTV1', '湖南卫视', '凤凰中文', 'CCTV2']);
      expect(idx.tops.contains('广播'), isFalse);
      expect(idx.tops.contains('国际'), isFalse);
    });

    test('groupsOfTop 与全量过滤一致（兼容旧调用）', () {
      expect(idx.groupsOfTop('央视'), ['央视']);
      expect(idx.groupsOfTop('卫视'), ['卫视']);
      expect(idx.groupsOfTop('地方'), isEmpty);
    });

    test('分桶结果与「逐频道分类结果」完全等价（含顺序）', () {
      for (final t in idx.tops) {
        expect(
          idx.subset(t, '全部').map((c) => c.name).toList(),
          idx.all.where((c) => c.cat == t).map((c) => c.name).toList(),
          reason: '大类 $t',
        );
      }
      for (final g in idx.groupOrder) {
        expect(
          idx.byGroup[g]!.map((c) => c.name).toList(),
          idx.all.where((c) => c.group == g).map((c) => c.name).toList(),
          reason: '分组 $g',
        );
      }
    });

    test('空频道列表 → 空索引（不炸、不给假数据）', () {
      final e = IptvIndex.of(const []);
      expect(e.tops, isEmpty);
      expect(e.groupOrder, isEmpty);
      expect(e.radioDropped, 0);
      expect(e.intlDropped, 0);
      expect(e.subset('全部', '全部'), isEmpty);
      expect(e.subset('央视', '央视'), isEmpty);
    });

    test('台名搜索键懒缓存与既有归一化规则一致', () {
      final c = LiveChannel(
          name: 'CCTV-1 综合', logo: '', group: '央视', urls: ['http://a']);
      expect(c.nameUpper, 'CCTV-1 综合'.toUpperCase());
      expect(c.nameNorm, IptvService.normalizeName('CCTV-1 综合'));
      // 二次读取命中缓存（返回同一实例，不再重新分配字符串）
      expect(identical(c.nameUpper, c.nameUpper), isTrue);
      expect(identical(c.nameNorm, c.nameNorm), isTrue);
    });
  });
}
