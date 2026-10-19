/// 电视台固定台数清单（v2.2.7 优化，不升版本）
///
/// 数据来源：随包内置的 `assets/live_tv_channels.json`
/// —— 由 PC 端流水线离线生成并**逐线路实测**：
///   probe_all_live.py（全工程 124 条订阅清单 → 抓取 → 合并 → 全量线路连通性探测）
///   → finalize_tv_channels.py（只留央视/卫视/地方/港澳台·国际，剔除非电视台、补省）
///
/// 与旧实现（运行时拉 20 组动态清单）的区别：
///   · **台数固定**：以这份实测清单为准，上游每日变动不会让用户看到台数忽增忽减；
///   · **只含实测可播线路**：死链在打包前就被剔除；
///   · **线路已按实测速度排序**：第 1 条就是最快的，默认播它；
///   · 一级固定四类，二级按规则给出（央视频道/卫视频道无二级）。
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// 一条线路：地址 + 实测耗时（毫秒；-1 表示当时未测到，仅作兜底）
class TvLine {
  final String url;
  final int ms;
  const TvLine(this.url, this.ms);
}

/// 一个电视台频道
class TvChannel {
  final int number;
  final String name;
  final String logo;
  final String group;
  final String top; // 央视频道 / 卫视频道 / 地方频道 / 港澳台·国际
  final String sub; // 省份 或 香港/澳门/台湾/国际/其他（央视/卫视为空）
  final List<TvLine> lines;

  TvChannel({
    required this.number,
    required this.name,
    required this.logo,
    required this.group,
    required this.top,
    required this.sub,
    required this.lines,
  });

  /// 数字段分割正则（**必须用 allMatches 手工切分**）
  ///
  /// v2.2.7 修复（央视台乱序根因）：Dart 的 `String.split(RegExp)` 不会把捕获组内容
  /// 放进结果，只把匹配当分隔符切掉 —— `'CCTV1'.split(RegExp(r'(\d+)'))` 得到
  /// `['CCTV', '']`、`'CCTV5'` 也一样，两条 key 完全相同 → 比较恒为 0 →
  /// 列表退化成资产里的原始抓取顺序（CCTV、CCTV1、CCTV5、CCTV2…乱序）。
  /// 现改为 allMatches 手工切分，数字段保留为 int，得到 `['CCTV', 1]` / `['CCTV', 5]`。
  static final _numSplit = RegExp(r'(\d+)');

  /// 台名自然序 key：`CCTV1` → `['CCTV', 1]`，`CCTV10` → `['CCTV', 10]`
  static List<Object> naturalKey(String s) {
    final t = s.toUpperCase();
    final out = <Object>[];
    var last = 0;
    for (final m in _numSplit.allMatches(t)) {
      if (m.start > last) out.add(t.substring(last, m.start));
      final n = int.tryParse(m.group(1) ?? '');
      if (n != null) out.add(n);
      last = m.end;
    }
    if (last < t.length) out.add(t.substring(last));
    return out;
  }

  /// 央视台序权重（越小越靠前）
  ///
  /// 靳老师定稿口径：
  ///   `CCTV`（无数字）→ `CCTV1` → `CCTV2` → `CCTV3` → `CCTV4` → `CCTV4K`
  ///   → `CCTV5` → `CCTV5+` → `CCTV6` → … → `CCTV17` → `CCTV-8K` → 其余派生/付费频道
  /// 实现：主台（`CCTV` + 数字 + 可选中文后缀，如 `CCTV-1 综合`）权重 = 100 + N；
  /// 无数字 `CCTV` = 99；`CCTV5+` / `CCTV4K` 这类「同一主台的高清或付费变体」
  /// = 100 + N + 0.5（紧跟在主台后）；
  /// 带 `-` 后缀（CCTV-新闻、CCTV-兵器科技…）与 CCTV+/CGTN/CETV 等非主台 = 1000，
  /// 一律排在国家台之后，彼此按名称自然序。非 CCTV 开头 = 2000（不做特殊排序）。
  static double _cctvRank(String name) {
    final n = name.trim().toUpperCase();
    if (!n.startsWith('CCTV')) return 2000;
    var rest = n.substring(4).trim();
    if (rest.isEmpty) return 99; // CCTV（无数字）排最前
    // PC 白名单归一后的台名形如 `CCTV-1 综合`：先去掉前导 `-` 再匹配，
    // 否则全部落到 1000，台序会退化成纯自然序。
    if (rest.startsWith('-')) rest = rest.substring(1).trim();
    if (rest.isEmpty) return 99;
    final plus = _reCctvPlus.firstMatch(rest);
    if (plus != null) {
      final d = int.tryParse(plus.group(1) ?? '');
      if (d != null && d > 0 && d <= 99) return 100 + d + 0.5; // CCTV-5+ 体育赛事
      return 1000;
    }
    final k = _reCctv4k.firstMatch(rest);
    if (k != null) {
      final d = int.tryParse(k.group(1) ?? '');
      // 8K 不能跟 4K 走同一档：4K 是 CCTV-4 的超清版（104.5，紧跟 CCTV-4），
      // 而目前在播的 8K 只有 CCTV-8K 超高清 —— 它是独立频道，定稿口径要排在
      // CCTV-17（117）之后、付费频道（1000）之前，取 118。
      if (d == 8) return 118;
      if (d != null && d > 0 && d <= 99) return 100 + d + 0.5; // CCTV-4K 超高清
      return 1000;
    }
    final main = _reCctvMain.firstMatch(rest);
    if (main != null) {
      final d = int.tryParse(main.group(1) ?? '');
      if (d != null && d > 0 && d <= 99) return (100 + d).toDouble();
      return 1000; // CCTV999 之类的异常命名按派生处理
    }
    return 1000; // CCTV-新闻 / CCTV-兵器科技 / CCTV+ …（派生频道，排在主台之后）
  }

  static final _reCctvMain = RegExp(r'^(\d+)(?:\s+.*)?$');
  static final _reCctvPlus = RegExp(r'^(\d+)\s*\+');
  static final _reCctv4k = RegExp(r'^(\d+)\s*K(\s*.*)?$');

  /// 台名排序总比较器（唯一入口，`load()` 与 `subset()` 都走它）：
  /// 先按央视台序权重，再按自然序（CCTV2 在 CCTV10 前面）
  static int compareNatural(String a, String b) {
    final ra = _cctvRank(a), rb = _cctvRank(b);
    if (ra != rb) return ra < rb ? -1 : 1;
    final ka = naturalKey(a), kb = naturalKey(b);
    final n = ka.length < kb.length ? ka.length : kb.length;
    for (var i = 0; i < n; i++) {
      final x = ka[i], y = kb[i];
      if (x is int && y is int) {
        if (x != y) return x.compareTo(y);
      } else if (x is int) {
        return -1; // 数字段排在文本段之前（"CCTV1" 优先于 "CCTVX"）
      } else if (y is int) {
        return 1;
      } else {
        final c = x.toString().compareTo(y.toString());
        if (c != 0) return c;
      }
    }
    return ka.length - kb.length;
  }
}

/// 清单：一级 / 二级 / 频道索引
class TvCatalog {
  /// 一级固定四类（顺序即展示顺序）
  static const List<String> tops = ['央视频道', '卫视频道', '地方频道', '港澳台·国际', '未分类'];

  /// 港澳台·国际 的固定二级（靳老师定稿：香港 / 澳门 / 台湾 / 国际 / 其他）
  static const List<String> hmtSubs = ['香港', '澳门', '台湾', '国际', '其他'];

  /// 地方频道的省份顺序
  static const List<String> provinces = [
    '北京',
    '上海',
    '天津',
    '重庆',
    '河北',
    '山西',
    '内蒙古',
    '辽宁',
    '吉林',
    '黑龙江',
    '江苏',
    '浙江',
    '安徽',
    '福建',
    '江西',
    '山东',
    '河南',
    '湖北',
    '湖南',
    '广东',
    '广西',
    '海南',
    '四川',
    '贵州',
    '云南',
    '西藏',
    '陕西',
    '甘肃',
    '青海',
    '宁夏',
    '新疆',
    '其他',
  ];

  /// 央视频道 / 卫视频道：取消二级（整类平铺）
  static bool hasSub(String top) => top == '地方频道' || top == '港澳台·国际';

  final List<TvChannel> all;
  final String generatedAt;

  TvCatalog(this.all, this.generatedAt);

  static final TvCatalog empty = TvCatalog(const [], '');

  static TvCatalog? _cached;

  /// 读内置清单（同步、毫秒级；随包读取，不需要网络）
  static Future<TvCatalog> load() async {
    if (_cached != null) return _cached!;
    try {
      final raw = await rootBundle.loadString('assets/live_tv_channels.json');
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final meta = (j['meta'] ?? {}) as Map<String, dynamic>;
      final list = (j['channels'] ?? const []) as List<dynamic>;
      final out = <TvChannel>[];
      for (final it in list) {
        final m = it as Map<String, dynamic>;
        final urls = ((m['urls'] ?? const []) as List<dynamic>)
            .map((e) => e.toString())
            .toList();
        final ms = ((m['ms'] ?? const []) as List<dynamic>)
            .map((e) => e is int ? e : int.tryParse(e.toString()) ?? -1)
            .toList();
        final lines = <TvLine>[];
        for (var i = 0; i < urls.length; i++) {
          lines.add(TvLine(urls[i], i < ms.length ? ms[i] : -1));
        }
        if (lines.isEmpty) continue;
        out.add(
          TvChannel(
            number: (m['number'] as num?)?.toInt() ?? (out.length + 1),
            name: (m['name'] ?? '').toString(),
            logo: (m['logo'] ?? '').toString(),
            group: (m['group'] ?? '').toString(),
            top: (m['top'] ?? '地方频道').toString(),
            sub: (m['sub'] ?? '').toString(),
            lines: lines,
          ),
        );
      }
      out.sort((a, b) => TvChannel.compareNatural(a.name, b.name));
      _cached = TvCatalog(out, (meta['generatedAt'] ?? '').toString());
      return _cached!;
    } catch (e) {
      _cached = TvCatalog.empty;
      return _cached!;
    }
  }

  /// 某一级下实际存在的二级（按固定顺序）
  List<String> subsOf(String top) {
    if (!hasSub(top)) return const [];
    final present = <String>{
      for (final c in all)
        if (c.top == top) c.sub,
    };
    final order = top == '港澳台·国际' ? hmtSubs : provinces;
    final out = <String>[];
    for (final s in order) {
      if (present.contains(s)) out.add(s);
    }
    return out;
  }

  /// 取某一级 + 某二级的频道（央视/卫视忽略二级，按名称自然序）
  List<TvChannel> subset(String top, String sub) {
    final out = all.where((c) {
      if (c.top != top) return false;
      if (!hasSub(top)) return true;
      return c.sub == sub;
    }).toList()..sort((a, b) => TvChannel.compareNatural(a.name, b.name));
    return out;
  }

  /// 该清单里有多少条实测可播线路
  int get lineCount => all.fold(0, (s, c) => s + c.lines.length);
}
