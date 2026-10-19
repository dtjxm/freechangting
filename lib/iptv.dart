/// v1.3.0 直播模块：IPTV 直播源拉取与解析
/// v1.4.2 多源聚合：5 个直播源组并发拉取，按台名归一化合并，
/// 同一频道自动汇总多条线路（播放失败自动换下一线路）。
/// 本地缓存最后成功合并结果，离线也能看。
/// v2.2.4 直播源扩容（靳老师 2026-10-13）：
///   · 并入参考清单里的 15 份非成人订阅，实测后落地 **13 组**（组 8~20）；
///     未单列的 3 处及原因见 `_sourceSets` 上方注释；
///   · 新增 TXT 方言解析（`频道名,地址` + `分组名,#genre#`）—— 海燕/易发/湘西/vinkerq
///     这 4 份合计约 1.2 万条（去重后）走的都是 TXT，不认方言就会
///     「清单可取但一条都进不来」；
///   · 加三道上限（单清单条数 / 合并总频道数 / 本地缓存字符数）——
///     实测合并后约 2.99 万频道、缓存文本 1.9MB，不设闸会顶爆内存与
///     shared_preferences（后者是启动时全量读进内存的）。
library;


import 'dart:async';
import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'live_cats.dart';
import 'store.dart';

class LiveChannel {
  final String name;
  final String logo;
  final String group;

  /// 源的 `tvg-id`（如 `CNN.us@SD` / `NHK.jp@SD`）—— 其**后缀就是国家代码**，
  /// v2.2.4（10-14 补充） 起「国际」大类按国家分组全靠它（离线实测覆盖率 82.9%）。
  final String tvgId;

  final List<String> urls; // 同名多条目合并为多线路，播放失败自动换线

  /// v2.2.4（10-14 补充）：分类结果。建索引时由 [LiveCats] 填充一次，页面只读。
  String cat = '';
  String sub = '';

  LiveChannel({
    required this.name,
    required this.logo,
    required this.group,
    this.tvgId = '',
    required this.urls,
  });

  // ------------------------------------------------------------------
  // v2.2.4：搜索键懒缓存。
  // 电视页「频道筛选」在并入 13 份清单后候选量达 2.99 万，每输入一个字符都会对
  // 全部候选重新 `toUpperCase()` / 去符号（每次都要分配新字符串）→ 输入时掉帧。
  // 这里只算一次、后续只读（字段不参与序列化与相等性判断）。
  // ------------------------------------------------------------------
  String? _upper;
  String? _norm;

  /// 台名大写形式（筛选用）
  String get nameUpper => _upper ??= name.toUpperCase();

  /// 台名去掉空格/连字符后的大写形式（跨源同名匹配用）
  String get nameNorm => _norm ??= IptvService.normalizeName(name);
}

class IptvService {
  IptvService._();
  static final IptvService instance = IptvService._();

  /// 直播源组：每组内为镜像地址（依次容错），组间并发拉取后合并
  ///
  /// ⚠ v2.1.0 同步（2026-10-12，广电/联通/电信三网实测后重排，与 PC 版 live.js 保持一致）：
  ///   把实测可用的镜像提到组内首位（原来排在后面的 gh-proxy 镜像反而最稳），
  ///   直连 raw.githubusercontent 时通时不通，一律降为兜底。
  ///   组4 / 组5 本轮三网均不可用，暂保留（命中失败会自动跳到其它组，不影响可用性）。
  /// ⚠ v2.2.4（2026-10-13）：在原有 7 组之后并入 13 份非成人订阅清单（组 8~20），
  ///   顺序按实测抽样可用率降序；组内镜像与直连写法均已实测（见各组注释）。
  static const List<List<String>> _sourceSets = [
    // 1) iptv2025（zhangbin0301，每日自动更新）· 三网可用 · 544 频道
    [
      'https://gh-proxy.com/raw.githubusercontent.com/zhangbin0301/iptv2025/master/tv/iptv4.m3u',
      'https://live.zbds.top/tv/iptv4.m3u',
      'https://raw.githubusercontent.com/zhangbin0301/iptv2025/master/tv/iptv4.m3u',
    ],
    // 2) Guovin/iptv-api 默认版 · 三网可用 · 1619 频道（本批最大）
    [
      'https://gh-proxy.com/raw.githubusercontent.com/Guovin/iptv-api/gd/output/result.m3u',
      'https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/result.m3u',
    ],
    // 3) best-fan/iptv-sources 完整国内频道 · 三网可用 · 181 频道
    [
      'https://gh-proxy.com/raw.githubusercontent.com/best-fan/iptv-sources/main/cn_all.m3u8',
      'https://raw.githubusercontent.com/best-fan/iptv-sources/main/cn_all.m3u8',
    ],
    // 4) tv.iill.top 综合聚合 · 本轮不可用（超时），留作兜底
    [
      'https://tv.iill.top/m3u/Gather',
    ],
    // 5) fanmingming IPv6 · 本轮不可用（超时），留作兜底
    [
      'https://live.fanmingming.cn/tv/m3u/ipv6.m3u',
    ],
    // 6) Guovin 分版 IPv4 / IPv6（与默认版互补）· 三网可用 · 1303 频道
    [
      'https://gh-proxy.com/raw.githubusercontent.com/Guovin/iptv-api/gd/output/ipv4/result.m3u',
      'https://gh-proxy.com/raw.githubusercontent.com/Guovin/iptv-api/gd/output/ipv6/result.m3u',
      'https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/ipv4/result.m3u',
      'https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/ipv6/result.m3u',
    ],
    // 7) best-fan 付费频道 · 三网可用 · 8 频道
    [
      'https://gh-proxy.com/raw.githubusercontent.com/best-fan/iptv-sources/main/cn_pay.m3u8',
      'https://ghproxy.net/raw.githubusercontent.com/best-fan/iptv-sources/main/cn_pay.m3u8',
      'https://raw.githubusercontent.com/best-fan/iptv-sources/main/cn_pay.m3u8',
    ],

    // ============================================================
    // v2.2.7（2026-10-15）：**撤销 v2.2.4 并入的 13 份清单（组 8~20）**，
    //   恢复 v2.2.3 时期的 7 组直播源 —— 用户反馈 2.2.4 新增的直播源质量太差。
    // ============================================================
  ];

  // ------------------------------------------------------------------
  // v2.2.7（2026-10-15）央视官方直播源（靳老师定：内置官方源治本）
  //
  // 用户反馈：CCTV1 打开是 4:3、CCTV2/3 没声音。根因是上面 7 组第三方清单都是
  // 「每日自动更新」的 GitHub 动态清单，上游已把 CCTV 线路换成标清/无声的差源，
  // 且清单里标着 `hd` 的源实际分片是 `md`（中画质），名不副实。
  //
  // 故内置央视网官方 HLS 直播流（阿里云 CDN，16:9 / 有声 / 国内直连稳定），
  // 在 [load] 合并后**插到对应 CCTV 频道的线路最前面**（先播），官方源失效时
  // 播放器会自动回退到后面的第三方清单线路（现有换线机制），不会黑屏。
  //
  // ⚠ 官方流域名/路径可能随央视改版变动；失效时该频道自动回退动态清单兜底，
  //   不会导致「完全看不了」，只是画质退回到第三方源的旧水平。
  // ------------------------------------------------------------------
  static const Map<String, List<String>> _cctvOfficial = {
    'CCTV1': ['https://cctvalih5ca.v.myalicdn.com/live/cctv1_2/index.m3u8'],
    'CCTV2': ['https://cctvalih5ca.v.myalicdn.com/live/cctv2_2/index.m3u8'],
    'CCTV3': ['https://cctvalih5ca.v.myalicdn.com/live/cctv3_2/index.m3u8'],
    'CCTV4': ['https://cctvalih5ca.v.myalicdn.com/live/cctv4_2/index.m3u8'],
    'CCTV5': ['https://cctvalih5ca.v.myalicdn.com/live/cctv5_2/index.m3u8'],
    'CCTV5+': ['https://cctvalih5ca.v.myalicdn.com/live/cctv5plus_2/index.m3u8'],
    'CCTV6': ['https://cctvalih5ca.v.myalicdn.com/live/cctv6_2/index.m3u8'],
    'CCTV7': ['https://cctvalih5ca.v.myalicdn.com/live/cctv7_2/index.m3u8'],
    'CCTV8': ['https://cctvalih5ca.v.myalicdn.com/live/cctv8_2/index.m3u8'],
    'CCTV9': ['https://cctvalih5ca.v.myalicdn.com/live/cctv9_2/index.m3u8'],
    'CCTV10': ['https://cctvalih5ca.v.myalicdn.com/live/cctv10_2/index.m3u8'],
    'CCTV11': ['https://cctvalih5ca.v.myalicdn.com/live/cctv11_2/index.m3u8'],
    'CCTV12': ['https://cctvalih5ca.v.myalicdn.com/live/cctv12_2/index.m3u8'],
    'CCTV13': ['https://cctvalih5ca.v.myalicdn.com/live/cctv13_2/index.m3u8'],
    'CCTV14': ['https://cctvalih5ca.v.myalicdn.com/live/cctv14_2/index.m3u8'],
    'CCTV15': ['https://cctvalih5ca.v.myalicdn.com/live/cctv15_2/index.m3u8'],
    'CCTV16': ['https://cctvalih5ca.v.myalicdn.com/live/cctv16_2/index.m3u8'],
    'CCTV17': ['https://cctvalih5ca.v.myalicdn.com/live/cctv17_2/index.m3u8'],
    'CCTV4K': ['https://cctvalih5ca.v.myalicdn.com/live/cctv4k_2/index.m3u8'],
  };

  /// 把央视官方源插到对应频道线路最前面（先播，失效自动回退）。
  /// 只对**已在合并结果里**的 CCTV 频道生效（不凭空新增频道，避免打乱分类）。
  static void _injectCctvOfficial(List<LiveChannel> chans) {
    for (final c in chans) {
      final official = _cctvOfficial[c.name];
      if (official == null || official.isEmpty) continue;
      for (final u in official) {
        if (!c.urls.contains(u)) {
          c.urls.insert(0, u);
        }
      }
    }
  }

  // ---- v2.2.4 三道上限（并入 14 份清单后总量可达 5 万+ 条，必须设闸）----

  /// 单个清单最多解析多少条（本批最大约 1.19 万条，留有余量；防个别源异常膨胀）
  static const int maxPerList = 12000;

  /// 合并后最多保留多少个频道（保序：先来的优先 —— 即原有国内精编源 → 新清单按可用率降序）。
  /// 留 3.2 万：2026-10-13 实测合并结果为 **29,889** 个，留出上游每日更新带来的增长余量，
  /// 免得一上来就开始丢弃尾部（最差的那几份）清单。
  static const int maxChannels = 32000;

  /// 本地持久化缓存上限（字符）。超限只存靠前部分 ——
  /// 头部恰好是最有价值的央卫/国内台，离线兜底够用，且避免把
  /// shared_preferences 撑到几 MB 拖慢启动。
  static const int maxCacheChars = 2000000;

  /// 源组数量（原有 7 组 + v2.2.4 并入的 13 组 = 20）—— 测试防回归与诊断用
  static int get sourceSetCount => _sourceSets.length;

  List<LiveChannel>? _cache;

  // ------------------------------------------------------------------
  // 可播白名单（v2.2.4 · 10-14 第 5 批）
  //
  // 用户反馈「山西 · 大同综合」这类台点开没反应。根因：列表展示的是**跨源合并后的全部台**
  // （约 2.99 万），其中大量只有死线路 —— 播放器要把 8 条线路全试完、再后台换源一轮才报错，
  // 用户看到的只是「点不动」。
  //
  // 数据来源：`公共/片源/直播源可用频道表-2026-10-14-v2.json`
  //   （20 组清单全量实测：14,315 个台里筛出 6,002 个「至少一条线路可播」的）。
  //   key = [LiveCats.mergeKey]（台名），与跨源合并同名频道的键**同源**，所以能对上。
  //
  // ⚠ 白名单是**快照**，会随源站变化过期；更新方式是重跑探测后重新生成本文件。
  // ⚠ 文件读不到 / keys 为空 → **不过滤**（宁可多显示，也不能让整页空白）。
  // ------------------------------------------------------------------
  static Set<String>? _okKeys;

  static Future<Set<String>> _loadOkKeys() async {
    final cached = _okKeys;
    if (cached != null) return cached;
    try {
      final raw = await rootBundle.loadString('assets/live_ok.json');
      final m = jsonDecode(raw) as Map<String, dynamic>;
      _okKeys = ((m['keys'] as List?) ?? const []).map((e) => '$e').toSet();
    } catch (_) {
      _okKeys = const <String>{};
    }
    return _okKeys!;
  }

  /// 拉取并解析频道。策略：
  /// 1) 内存缓存直接返回（本会话内只拉一次）
  /// 2) 全部源组并发拉取（组内镜像依次容错），成功的源合并解析
  /// 3) 跨源按台名归一化合并线路，结果写入本地持久化缓存
  /// 4) 全部网络源失败则回退本地缓存
  Future<List<LiveChannel>> load({bool forceRefresh = false}) async {
    if (!forceRefresh && _cache != null) return _cache!;
    // v2.2.4：**边拉边解析** —— 每组一到手就解析成频道、立刻放掉原始文本。
    // 并入 14 份清单后同时在途的清单文本可达十几 MB（最大单份 2.6MB），
    // 先解析可把内存峰值从「所有原始文本」压到「解析结果 + 少量在途文本」。
    final lists = await Future.wait(_sourceSets.map((m) => _fetchSet(m).then(
        (text) => text == null
            ? const <LiveChannel>[]
            : parseList(text, limit: maxPerList))));
    final ok = lists.where((l) => l.isNotEmpty).toList();
    if (ok.isEmpty) {
      // 网络全挂 → 回退上次成功缓存
      final cached = AppStore.instance.liveM3uCache;
      if (cached.isNotEmpty) {
        final chans = parseList(cached);
        if (chans.isNotEmpty) {
          _cache = chans;
          return chans;
        }
      }
      throw Exception(
          '直播源拉取失败（已尝试 ${_sourceSets.length} 个直播源且无本地缓存）');
    }
    final merged = mergeSources(ok, limit: maxChannels);
    // v2.2.7：给 CCTV 频道注入央视官方源（先播，失效自动回退第三方线路）。
    _injectCctvOfficial(merged);
    // v2.2.4（10-14 第 5 批）：按「可播白名单」下架点开播不了的台（详见 _loadOkKeys）。
    final okKeys = await _loadOkKeys();
    final chans = okKeys.isEmpty
        ? merged
        : merged
            .where((c) => okKeys.contains(LiveCats.mergeKey(c.name)))
            .toList();
    if (chans.isEmpty) {
      throw Exception('直播源解析结果为空，请稍后重试');
    }
    _cache = chans;
    AppStore.instance.liveM3uCache = serializeM3u(chans, maxChars: maxCacheChars);
    return chans;
  }

  /// 拉取一个源组：组内镜像**并发**发起，取首个成功者（其余忽略），全失败返回 null。
  ///
  /// v2.2.2（B3）：原实现组内镜像串行、每个 15s 超时 —— 首屏最坏要等 ~45s。
  /// 改为并发发起组内全部镜像、首个成功即采纳（Completer 保证只采纳一个结果；
  /// 其余结果/异常各自兜住，互不影响）。
  Future<String?> _fetchSet(List<String> mirrors) async {
    if (mirrors.isEmpty) return null;
    final completer = Completer<String?>();
    var pending = mirrors.length;
    void onFail() {
      pending--;
      if (pending == 0 && !completer.isCompleted) completer.complete(null);
    }

    for (final u in mirrors) {
      _fetchOne(u).then((text) {
        if (text != null) {
          if (!completer.isCompleted) completer.complete(text);
        } else {
          onFail();
        }
      }).catchError((_) => onFail());
    }
    return completer.future;
  }

  /// 拉取单个镜像：成功返回原始 M3U 文本（UTF-8 严格解码失败回退 GBK），失败返回 null。
  /// 成功判定：`statusCode == 200 && bodyBytes.length > 1024`。
  Future<String?> _fetchOne(String u) async {
    try {
      final resp = await http.get(Uri.parse(u), headers: const {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 13) Chrome/126.0',
      }).timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200 && resp.bodyBytes.length > 1024) {
        // 修复中文乱码：部分直播源为 GBK 编码，UTF-8 严格解码失败时回退 GBK
        final bytes = resp.bodyBytes;
        try {
          return utf8.decode(bytes); // 严格模式，失败抛 FormatException
        } on FormatException {
          return const GbkCodec(allowMalformed: true).decode(bytes);
        }
      }
    } catch (_) {
      // 该镜像失败 → 由并发协调器处理
    }
    return null;
  }

  /// 台名归一化：去掉空格/连字符等差异（如 CCTV-1 与 CCTV1 视为同一频道）
  static String normalizeName(String n) =>
      n.replaceAll(RegExp(r'[\s\-—－·]'), '').toUpperCase();

  /// v2.2.4：清掉 BOM / 零宽字符再 trim。
  /// 不少清单首行带 `\uFEFF`（海燕的「央视网频道」分组名就这么被污染的），
  /// 不清会污染分组名与台名、还会让台名去重失效。
  static String _clean(String s) =>
      s.replaceAll('\uFEFF', '').replaceAll('\u200B', '').trim();

  /// v2.2.4：分组名归一 —— 空 / Undefined / Unknown 一律归「其他频道」。
  /// （iptv-org 与「全球直播」里有大量 `group-title="Undefined"`，
  ///   原样展示会看到几千个频道挂在一个叫 Undefined 的分组下）
  static String _normGroup(String g) {
    final s = _clean(g);
    if (s.isEmpty) return '其他频道';
    final l = s.toLowerCase();
    if (l == 'undefined' || l == 'unknown' || l == 'undefine') return '其他频道';
    return s;
  }

  /// 跨源合并：同台归并，线路去重累加（上限 12 条防极端）；台标/分组取首个非空。
  ///
  /// v2.2.4：新增 [limit]（>0 生效）—— 触顶后**不再收新频道**（已在表内的
  /// 频道仍可继续累加线路）。并入 14 份清单后候选可达 5 万+ 条，必须设闸。
  ///
  /// v2.2.4（10-14 追加）：**归并键由「去空格大写」升级为 [LiveCats.mergeKey]** ——
  ///   用户反馈「央视分类下不同来源的同一套台被列了好几遍」。原键只去空格/连字符，
  ///   所以 `CCTV1` / `CCTV1综合` / `央视一套` / `CCTV1高清` 各算一条。
  ///   现在四者归为 `CCTV1` 一条、多线路；`上虞新闻频道` 与 `上虞新闻综合` 也合并。
  ///   展示名取别名表规范名（[LiveCats.displayName]），取不到才用原始写法。
  /// 线路顺序 = **清单在 [SOURCE_SETS] 里的先后顺序**（靠前的源更可靠，先播）。
  static List<LiveChannel> mergeSources(List<List<LiveChannel>> lists,
      {int limit = 0}) {
    final merged = <String, LiveChannel>{};
    final order = <String>[];
    for (final list in lists) {
      for (final c in list) {
        final key = LiveCats.mergeKey(c.name);
        if (key.isEmpty) continue;
        final exist = merged[key];
        if (exist == null) {
          if (limit > 0 && order.length >= limit) continue; // 触顶：丢新频道
          merged[key] = LiveChannel(
              name: LiveCats.displayName(c.name),
              logo: c.logo,
              group: c.group,
              tvgId: c.tvgId,
              urls: [...c.urls]);
          order.add(key);
        } else {
          for (final u in c.urls) {
            if (!exist.urls.contains(u) && exist.urls.length < 12) {
              exist.urls.add(u);
            }
          }
          // v2.2.4（10-14 补充）：台标与 tvg-id 都要**补齐**（不是只看台标）——
          //   同一频道常由多个清单提供，可能先合并进来的那份没有 tvg-id，
          //   而「国际」按国家分组完全依赖它；只补台标会漏掉国家信息。
          final needLogo = exist.logo.isEmpty && c.logo.isNotEmpty;
          final needTvg = exist.tvgId.isEmpty && c.tvgId.isNotEmpty;
          if (needLogo || needTvg) {
            merged[key] = LiveChannel(
                name: exist.name,
                logo: needLogo ? c.logo : exist.logo,
                group: exist.group,
                tvgId: needTvg ? c.tvgId : exist.tvgId,
                urls: exist.urls);
          }
        }
      }
    }
    return [for (final k in order) merged[k]!];
  }

  /// v2.2.4：解析订阅清单 —— **自动识别两种方言**，直播订阅界两种格式各占一半：
  /// - **M3U**：`#EXTINF ... tvg-logo="x" group-title="y",台名` + 下一行地址；
  /// - **TXT**：`台名,地址` 逐行，`分组名,#genre#` 切分组（DIYP/社区通用方言）。
  ///   海燕 / 易发 / 湘西 / vinkerq 这 4 份合计约 2.2 万条全是 TXT，
  ///   只认 M3U 的话它们会「清单可取但一条都进不来」。
  /// [limit] > 0 时单清单最多解析这么多条（见 [maxPerList]）。
  static List<LiveChannel> parseList(String text, {int limit = 0}) =>
      text.contains('#EXTINF')
          ? _parseM3u(text, limit: limit)
          : _parseTxt(text, limit: limit);

  /// 兼容旧调用：按 M3U 解析（本地缓存与既有代码走这里；缓存本身恒为 M3U）
  static List<LiveChannel> parseM3u(String text) => _parseM3u(text);

  /// TXT 方言：`台名,地址` 逐行；`分组名,#genre#` 切分组。
  /// 例：
  /// ```text
  /// 咪咕视频,#genre#
  /// CCTV1综合,http://36.134.89.155:1234/608807420
  /// ```
  /// 细节：分组行可能带附加参数（`抖音K歌,#genre#,DE=3`）→ 只取第一个逗号前；
  ///      地址取**最后一个逗号**之后（台名里本身可能含逗号）；
  ///      右侧不是 http 开头的行一律跳过（如「切换EXO解码,1」这类播放器指令）。
  static List<LiveChannel> _parseTxt(String text, {int limit = 0}) {
    final merged = <String, LiveChannel>{};
    final order = <String>[];
    var group = '其他频道';
    for (final raw in text.split('\n')) {
      if (limit > 0 && order.length >= limit) break;
      final line = _clean(raw);
      if (line.isEmpty) continue;
      if (line.contains('#genre#')) {
        final g = _clean(line.split(',').first);
        if (g.isNotEmpty) group = g;
        continue;
      }
      final i = line.lastIndexOf(',');
      if (i <= 0) continue;
      final name = _clean(line.substring(0, i));
      final url = _clean(line.substring(i + 1));
      if (name.isEmpty || !url.startsWith('http')) continue;
      final exist = merged[name];
      if (exist != null) {
        if (!exist.urls.contains(url) && exist.urls.length < 12) {
          exist.urls.add(url);
        }
      } else {
        merged[name] =
            LiveChannel(name: name, logo: '', group: group, urls: [url]);
        order.add(name);
      }
    }
    return [for (final k in order) merged[k]!];
  }

  /// 解析单个 M3U：#EXTINF 带 tvg-logo / group-title，下一行是地址。
  /// 同名频道合并为多线路。
  static List<LiveChannel> _parseM3u(String text, {int limit = 0}) {
    final merged = <String, LiveChannel>{};
    final order = <String>[];
    String? pendingName, pendingLogo, pendingGroup, pendingTvg;
    for (var raw in text.split('\n')) {
      if (limit > 0 && order.length >= limit) break;
      final line = _clean(raw).trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXTINF')) {
        final nameM = RegExp(r',\s*([^,]+)$').firstMatch(line);
        pendingName = _clean(nameM?.group(1) ?? '');
        pendingLogo =
            _clean(RegExp(r'tvg-logo="([^"]*)"').firstMatch(line)?.group(1) ?? '');
        // v2.2.4（10-14 补充）：取 tvg-id —— 后缀是国家代码（`CNN.us@SD`），「国际」大类按国家分组靠它
        pendingTvg =
            _clean(RegExp(r'tvg-id="([^"]*)"').firstMatch(line)?.group(1) ?? '');
        // v2.2.4：空 / Undefined 统一归「其他频道」（原实现只处理空字符串）
        pendingGroup = _normGroup(
            RegExp(r'group-title="([^"]*)"').firstMatch(line)?.group(1) ?? '');
        // v1.5.1：过滤源站自带的「更新时间」时间戳伪频道（非真实电视台）
        if (pendingGroup
            .replaceAll(RegExp(r'[^一-龥A-Za-z0-9]'), '')
            .startsWith('更新时间')) {
          pendingName = null;
          pendingGroup = null;
          continue;
        }
      } else if (!line.startsWith('#')) {
        final url = _clean(line);
        if (pendingName != null && pendingName.isNotEmpty && url.startsWith('http')) {
          final key = pendingName;
          final exist = merged[key];
          if (exist != null) {
            if (!exist.urls.contains(url)) exist.urls.add(url);
            if (pendingLogo!.isNotEmpty && exist.logo.isEmpty) {
              merged[key] = LiveChannel(
                  name: exist.name,
                  logo: pendingLogo,
                  group: exist.group,
                  tvgId: exist.tvgId,
                  urls: exist.urls);
            }
          } else {
            merged[key] = LiveChannel(
                name: key,
                logo: pendingLogo ?? '',
                group: pendingGroup!,
                tvgId: pendingTvg ?? '',
                urls: [url]);
            order.add(key);
          }
        }
        pendingName = null;
        pendingLogo = null;
        pendingGroup = null;
        pendingTvg = null;
      }
    }
    return [for (final k in order) merged[k]!];
  }

  /// 合并结果序列化为 M3U 文本（用于本地持久化缓存）。
  ///
  /// v2.2.4：新增 [maxChars]（>0 生效）—— 写满预算即停。
  /// 并入 14 份清单后全量可达几 MB，而 shared_preferences 是启动时全量读进内存的，
  /// 必须设闸。截断时保留的是靠前的频道，恰好是央卫/国内台（最有用的一批）。
  static String serializeM3u(List<LiveChannel> chans, {int maxChars = 0}) {
    final sb = StringBuffer();
    for (final c in chans) {
      if (maxChars > 0 && sb.length >= maxChars) break;
      // v2.2.4（10-14 补充）：必须写回 tvg-id —— 网络全挂走本地缓存回退时，「国际」按国家分组
      //   仍然依赖它；不写回的话缓存回来的频道会整批掉进「其他国家/地区」
      sb.write('#EXTINF:-1 tvg-id="${c.tvgId}" tvg-logo="${c.logo}" '
          'group-title="${c.group}",${c.name}\n');
      sb.write(c.urls.join('\n'));
      sb.write('\n');
    }
    return sb.toString();
  }

  /// 分组名按出现顺序
  static List<String> groupsOf(List<LiveChannel> chans) {
    // v2.2.4：改用 Set 判重 —— 2.99 万频道 / 435 分组下，
    // 原 `List.contains` 是 O(n×g)（每次调用约 650 万次字符串比较）。
    final seen = <String>{};
    final out = <String>[];
    for (final c in chans) {
      if (seen.add(c.group)) out.add(c.group);
    }
    return out;
  }

  // ============================================================
  // v2.2.4（10-14 补充）：一级分类改为**逐频道判定**（11 类，与离线直播源审计方案同一口径）
  // ------------------------------------------------------------
  // 旧的 5 大类（央视频道 / 卫视频道 / 港澳台·国际 / 地方频道 / 国际·其他）只按
  // `group-title` 判定，并入 20 份清单后失效：2.99 万频道里 **62% 堆进「国际·其他」**，
  // 另有 8,340 个落进「地方频道 / 其他」（分组名不是地名，如「高速专享频道」「🛰️数字加密」）。
  // 现由 [LiveCats.catOf] 按「分组名 → 频道名前缀/关键词 → 国家/省份 → 外文名」判定；
  // 二级按大类取（地方=省份 / 港澳台=地区 / 国际=国家 / 影视点播=内容类型）。
  //
  // ⚠ 判定规则与映射表全部在 `lib/live_cats.dart`（由离线脚本自动生成），
  //   本文件只做调用，不要在这里另写一套。
  // ============================================================
  // v2.2.7（10-15）：恢复 2.2.3 五分类。判定逻辑见 [LiveCats.catOfV223]。
  static const List<String> topGroups = LiveCats.fiveOrder;

  /// 分组名 → 一级大类。**兼容旧调用**；新代码请直接用 [LiveCats.catOfV223]（逐频道）。
  ///
  /// ⚠ 分组名要**同时当作频道名**传进去：判定链里大量规则（央视前缀、急救词、
  ///   别名表、外文名→国际）走的是「频道名」这一路，只传分组名会让它们全部落空，
  ///   结果整批掉进「国际」（离线实测踩过）。
  static String topGroupOf(String rawGroup) => LiveCats.catOfV223(rawGroup, rawGroup, '');

  /// 频道 → 一级大类
  static String catOfChannel(LiveChannel c) =>
      c.cat.isNotEmpty ? c.cat : LiveCats.catOfV223(c.group, c.name, c.tvgId);

  /// 频道 → 二级分类（地方频道=省份 / 港澳台·国际=地区）
  static String subOfChannel(LiveChannel c) =>
      c.sub.isNotEmpty ? c.sub : LiveCats.subOf(catOfChannel(c), c.group, c.name, c.tvgId);

  /// 英文分组名 → 中文显示名。**仅用于展示**，分组/筛选仍按原始分组名匹配。
  ///
  /// 覆盖 iptv-org 的全部常规 category；`group-title` 形如 `Movies;Comedy`
  /// 时按 `;` 拆开逐段翻译，再用 `·` 连回去（如「电影·喜剧」）。
  /// 中文分组名原样返回，不做任何加工。
  static const Map<String, String> groupZhNames = {
    'general': '综合',
    'news': '新闻',
    'topnews': '头条新闻',
    'movies': '电影',
    'series': '剧集',
    'tvshows': '电视节目',
    'sports': '体育',
    'kids': '少儿',
    'music': '音乐',
    'documentary': '纪录片',
    'culture': '文化',
    'education': '教育',
    'entertainment': '娱乐',
    'comedy': '喜剧',
    'animation': '动画',
    'family': '家庭',
    'lifestyle': '生活',
    'cooking': '美食',
    'travel': '旅游',
    'weather': '天气',
    'science': '科学',
    'religious': '宗教',
    'shop': '购物',
    'auto': '汽车',
    'business': '财经',
    'classic': '经典',
    'outdoor': '户外',
    'public': '公共',
    'legislative': '政务',
    'relax': '休闲',
    'quiz': '竞猜',
    'reality': '真人秀',
    'other': '其他',
  };

  /// 分组名 → 展示用名（英文分组翻译为中文；中文分组原样）
  ///
  /// ⚠ 仅影响 UI：分组、筛选、缓存序列化**一律仍用原始分组名**。
  static String displayGroup(String raw) {
    if (raw.isEmpty) return raw;
    // 解析层把「源站没写 group-title」统一归一为「其他频道」（4,132 个频道）。
    // 在「国际·其他」大类下与「其他」二字叠在一起容易误读，展示为「未分组」。
    if (raw == '其他频道') return '未分组';
    if (RegExp(r'[一-龥]').hasMatch(raw)) return raw; // 已是中文分组名
    final parts = <String>[];
    for (final seg in raw.split(';')) {
      final t = seg.trim();
      if (t.isEmpty) continue;
      parts.add(groupZhNames[t.toLowerCase()] ?? t);
    }
    return parts.isEmpty ? raw : parts.join('·');
  }
}

/// v2.2.4：电视页用的频道索引（加载后建一次，build 只做查表）。
///
/// 背景：并入 13 份清单后频道量达 **2.99 万**（分组 435 种）。原实现是每次 build
/// 现算「分组列表 / 一级大类 / 当前子集」——等于每次重建都在 3 万条上跑正则归一
/// 与线性判重（`_tops` 与 `_subGroups` 各一遍，合计约 1,300 万次字符串比较），
/// 搜索框输入一个字符就会掉帧。索引化后：
///   · 一级大类判定只对**唯一分组名**算（435 次），不再按频道算（3 万次）；
///   · 切换大类/分组是 Map 取列表，O(1)；
///   · 分桶顺序保持源清单顺序（列表顺序即加载顺序，行为与优化前一致）。
class IptvIndex {
  /// 原始分组名 → 该组频道（保持源清单顺序）
  final Map<String, List<LiveChannel>> byGroup;

  /// 一级大类 → 该大类频道（保持源清单顺序）
  final Map<String, List<LiveChannel>> byTop;

  /// 一级大类 → 二级分类 → 频道
  final Map<String, Map<String, List<LiveChannel>>> bySub;

  /// 原始分组名 → 一级大类（同组内以**首个**频道判定为准，仅供诊断）
  final Map<String, String> groupTop;

  /// 出现过的原始分组名（按首次出现顺序）
  final List<String> groupOrder;

  /// 实际存在的一级大类（按 [IptvService.topGroups] 固定顺序；表外大类追加末尾）
  final List<String> tops;

  /// 全量频道（**已剔除广播与境外频道** —— 见 [radioDropped] / [intlDropped]）
  final List<LiveChannel> all;

  /// 剔除掉的广播频道数（诊断用）
  final int radioDropped;

  /// 剔除掉的境外 / 非中文频道数（诊断用）
  final int intlDropped;

  /// 剔除掉的垃圾台名数 —— 台名长度 ≤ 1（源清单里真实存在一个叫「没」的台，
  /// 列表里看着像软件出错）。v2.2.4（10-14 第 5 批）
  final int junkDropped;

  IptvIndex._(this.all, this.byGroup, this.byTop, this.bySub, this.groupTop,
      this.groupOrder, this.tops, this.radioDropped, this.intlDropped,
      this.junkDropped);

  /// 空索引（频道尚未加载时）
  static final IptvIndex empty = IptvIndex._(
      const [], const {}, const {}, const {}, const {}, const [], const [], 0, 0, 0);

  factory IptvIndex.of(List<LiveChannel> chans) {
    if (chans.isEmpty) return empty;
    final byGroup = <String, List<LiveChannel>>{};
    final byTop = <String, List<LiveChannel>>{};
    final bySub = <String, Map<String, List<LiveChannel>>>{};
    final memo = <String, String>{};
    final kept = <LiveChannel>[];
    var radio = 0;
    var intl = 0;
    var junk = 0;
    for (final c in chans) {
      // v2.2.4（10-14 第 5 批）：**垃圾台名直接丢** —— 源清单里真实存在一个叫「没」的台
      //   （长度 1，无任何可用信息），出现在列表里看着像软件出错。
      if (c.name.trim().length <= 1) {
        junk++;
        continue;
      }
      // v2.2.7（10-15）：分类恢复 2.2.3 五分类 + 轮播频道剔除。
      //   catOfV223 返回 5 大类之一 / radioCat（广播丢弃）/ dropCat（轮播丢弃）。
      final cat = LiveCats.catOfV223(c.group, c.name, c.tvgId);
      // 广播：本软件已移除，整批丢弃（记录另存《广播频道清单》）
      if (cat == LiveCats.radioCat) {
        radio++;
        continue;
      }
      // v2.2.7：影视点播轮播频道整批丢弃（用户要求取消影视直播）
      if (cat == LiveCats.dropCat) {
        intl++; // 复用 intlDropped 计数器统计轮播丢弃量
        continue;
      }
      c.cat = cat;
      c.sub = LiveCats.subOf(cat, c.group, c.name, c.tvgId);
      memo[c.group] = cat;
      kept.add(c);
      (byGroup[c.group] ??= <LiveChannel>[]).add(c);
      (byTop[cat] ??= <LiveChannel>[]).add(c);
      if (c.sub.isNotEmpty) {
        final m = bySub[cat] ??= <String, List<LiveChannel>>{};
        (m[c.sub] ??= <LiveChannel>[]).add(c);
      }
    }
    final present = byTop.keys.toSet();
    final tops = LiveCats.fiveOrder.where(present.contains).toList();
    for (final t in present) {
      if (!tops.contains(t)) tops.add(t); // 表外大类不丢
    }
    // v2.2.4（10-14 第 3 批）：**列表排序** —— 原先按「源清单顺序」，
    //   而 20 份清单各自把 CCTV 系列打散，于是列表里 CCTV1 / CCTV10 / CCTV13 / CCTV6
    //   毫无规律（用户反馈「电视台的排序能否连贯，例如 CCTV6 跑到下边了」）。
    //   改按 [LiveCats.sortKey]：央视按频道号、地方按省份、港澳台按地区、
    //   影视点播·历年春晚按年份升序。只影响展示顺序，不影响判定与去重。
    //   先算一次键再排（避免比较函数里反复跑正则）。
    void sortList(String cat, String sub, List<LiveChannel> l) {
      if (l.length < 2) return;
      final keys = <LiveChannel, String>{};
      for (final c in l) {
        keys[c] = LiveCats.sortKey(cat, sub, c.name);
      }
      l.sort((a, b) => keys[a]!.compareTo(keys[b]!));
    }

    bySub.forEach((cat, m) => m.forEach((sub, l) => sortList(cat, sub, l)));
    byTop.forEach((cat, l) => sortList(cat, '', l));
    return IptvIndex._(kept, byGroup, byTop, bySub, memo, byGroup.keys.toList(),
        tops, radio, intl, junk);
  }

  /// 取子集：给定二级分类就直接取该二级；只给一级大类则取该大类；都是「全部」则给全量。
  List<LiveChannel> subset(String top, String sub) {
    if (sub != '全部') return (bySub[top]?[sub]) ?? const <LiveChannel>[];
    if (top != '全部') return byTop[top] ?? const <LiveChannel>[];
    return all;
  }

  /// 该一级大类下的二级分类。
  /// · 港澳台 = 地区（固定顺序）· 影视点播 = 内容类型（固定顺序）
  /// · 地方 = 省份、国际 = 国家/地区 → **按频道数降序；「其他」挪到最后**
  ///
  /// ⚠ v2.2.4（10-14 追加）：地方由「省级行政区顺序」改为**数量降序**。
  ///   因为用户要求取消二级的「全部」，进「地方」必须有默认选中项 ——
  ///   若按行政区顺序，默认会落在「北京」（仅 7 个频道），点进去近乎空列表；
  ///   按数量降序则默认落在最大的省份（实测「江苏」147 个），更贴近点「地方」时的预期。
  ///   「其他」是兜底桶（实测 3,318 个）**故意排到末尾** —— 它不该是默认项。
  ///   （想改回行政区顺序，只动这一处。）
  List<String> subsOfTop(String top) {
    final m = bySub[top];
    if (m == null || m.isEmpty) return const <String>[];
    final keys = m.keys.toList();
    // 兜底桶垫底，其余按数量降序
    keys.sort((a, b) {
      final oa = LiveCats.isFallbackSub(a) ? 1 : 0;
      final ob = LiveCats.isFallbackSub(b) ? 1 : 0;
      if (oa != ob) return oa - ob;
      return m[b]!.length.compareTo(m[a]!.length);
    });
    final fixed = top == '港澳台·国际'
        ? LiveCats.hmtOrder
        : null;
    if (fixed == null) return keys;
    final out = fixed.where(m.containsKey).toList();
    for (final k in keys) {
      if (!out.contains(k)) out.add(k); // 表外二级不丢
    }
    return out;
  }

  /// 该一级大类下实际有哪些原始分组（按出现顺序）—— 兼容旧调用
  List<String> groupsOfTop(String top) =>
      groupOrder.where((g) => groupTop[g] == top).toList();

  /// 二级分类 → 频道数（给 chips 展示数量用，可选）
  int subCount(String top, String sub) => bySub[top]?[sub]?.length ?? 0;
}
