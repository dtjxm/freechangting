/// MacCMS 采集 API 客户端（与桌面版同协议）
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'models.dart';
import 'vod_source_health.dart';

class CatResult {
  final List<Category> categories;
  final int pagecount;
  const CatResult(this.categories, this.pagecount);
}

/// v1.4.0：列表页 + 该查询实际总页数
class ListPage {
  final List<VideoItem> items;
  final int pagecount;
  const ListPage(this.items, this.pagecount);
}

/// v2.2.1：分类校准结果 —— 该源该分类的「实际大类」+ 本次为校准抓取的 page1 样本。
/// [sample] 仅当本次真的发起了请求且成功时非空，首页首屏可直接复用它，
/// 从而把「同一页抓两遍」合并成一次请求。
class CalibResult {
  final String cat;
  final ListPage? sample;
  const CalibResult(this.cat, {this.sample});
}

/// v2.2.3 v11：伦理 type_id —— [generic] 为 true 表示该分类是源站的泛伦理桶
/// （伦理 / 三级伦理 / 理论片），其中的影片需按片名自动分派到 4 个区域二级。
class EthicsId {
  final String id;
  final bool generic;
  const EthicsId(this.id, this.generic);
}

class MacApi {
  MacApi._();
  static final MacApi instance = MacApi._();

  final http.Client _client = http.Client();
  static const _timeout = Duration(seconds: 15);

  /// 全部片源（从 assets/sources.json 加载）
  List<MovieSource> sources = [];
  MovieSource get defaultSource =>
      sources.isNotEmpty ? sources.first : const MovieSource(id: 0, name: '-', url: '');

  /// v2.2.4 片源管理：**已停用**片源 id（空 = 全部启用）。
  ///
  /// 由启动流程（[AppStore.disabledSourceIds]）与「片源管理」页在开关变更时写入。
  /// 加载 / 检索 / 换源一律只看 [activeSources]，停用源等同于不存在
  /// （与 PC 版「停用片源后，该源的影片会从列表与搜索结果中移除」完全一致）。
  final Set<int> disabledIds = <int>{};

  void setDisabledSources(Iterable<int> ids) {
    disabledIds
      ..clear()
      ..addAll(ids);
  }

  /// 参与加载 / 检索 / 换源的片源（排除已停用；全部停用时退回全量，避免首页空白）
  List<MovieSource> get activeSources {
    final on = sources.where((s) => !disabledIds.contains(s.id)).toList();
    return on.isNotEmpty ? on : sources;
  }

  Future<void> loadSources() async {
    if (sources.isNotEmpty) return;
    final raw = await rootBundle.loadString('assets/sources.json');
    final decoded = jsonDecode(raw);
    // v2.2.2（D8）：外层容错 —— 顶层非 List → 空片源（不崩）；
    // 数组元素非对象 → 跳过该元素（不再因单个坏元素整份配置加载失败）。
    if (decoded is! List) {
      sources = [];
      return;
    }
    sources = decoded
        .whereType<Map<String, dynamic>>()
        .map(MovieSource.fromJson)
        .toList();
  }

  Uri _buildUri(String base, Map<String, String> q) {
    final sep = base.contains('?') ? '&' : '?';
    final qs = q.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return Uri.parse('$base$sep$qs');
  }

  static const _ua =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36';

  /// v2.2.1：从响应体解析 JSON 对象（兼容 jsonp / BOM / 前置杂质）。
  /// 抽成静态方法，供「测速顺手预热分类缓存」复用；失败返回 null。
  static Map<String, dynamic>? decodeJsonObject(String body) {
    try {
      final text = body.trim();
      final cands = <int>[
        if (text.contains('{')) text.indexOf('{'),
        if (text.contains('[')) text.indexOf('['),
      ];
      if (cands.isEmpty) return null;
      final i = cands.reduce((a, b) => a < b ? a : b);
      final j = text.lastIndexOf('}');
      if (i < 0 || j <= i) return null;
      final obj = jsonDecode(text.substring(i, j + 1));
      return obj is Map<String, dynamic> ? obj : null;
    } catch (_) {
      return null;
    }
  }

  /// v2.2.1：解析 `ac=list` 的 class 分类树。
  /// 传入 null（本次没请求到）→ 返回 null，调用方据此**不写缓存**。
  static CatResult? catResultOf(Map<String, dynamic>? obj) {
    if (obj == null) return null;
    final cls = obj['class'];
    final cats = <Category>[];
    if (cls is List) {
      for (final c in cls.whereType<Map<String, dynamic>>()) {
        final id = '${c['type_id'] ?? ''}';
        final name = '${c['type_name'] ?? ''}'.trim();
        if (id.isNotEmpty && name.isNotEmpty) {
          cats.add(Category(id, name, pid: '${c['type_pid'] ?? '0'}'));
        }
      }
    }
    final pagecount = int.tryParse('${obj['pagecount'] ?? 1}') ?? 1;
    return CatResult(cats, pagecount);
  }

  Future<Map<String, dynamic>?> _getJson(String url,
      {Map<String, String>? query, Duration? timeout}) async {
    try {
      final resp = await _client
          .get(_buildUri(url, query ?? const {}),
              headers: const {
                'User-Agent': _ua,
                'Accept': 'application/json, text/plain, */*',
              })
          .timeout(timeout ?? _timeout);
      if (resp.statusCode != 200) return null;
      return decodeJsonObject(resp.body);
    } catch (_) {
      return null;
    }
  }

  List<VideoItem> _parseItems(Map<String, dynamic>? obj, MovieSource s) {
    final raw = obj?['list'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map((m) {
          // v1.6.3 卡片展示：年份 + 主演（主演为空时用导演兜底）
          final actor = '${m['vod_actor'] ?? ''}'.trim();
          final director = '${m['vod_director'] ?? ''}'.trim();
          return VideoItem(
              vodId: '${m['vod_id'] ?? ''}',
              name: '${m['vod_name'] ?? ''}'.trim(),
              pic: '${m['vod_pic'] ?? ''}',
              remarks: '${m['vod_remarks'] ?? ''}'.trim(),
              typeId: '${m['type_id'] ?? ''}',
              typeName: '${m['type_name'] ?? ''}',
              vodClass: '${m['vod_class'] ?? ''}',
              time: '${m['vod_time'] ?? ''}',
              sourceId: s.id,
              sourceName: s.name,
              year: '${m['vod_year'] ?? ''}'.trim(),
              actor: actor.isNotEmpty ? actor : director,
              director: director, // v1.9.5 检索用：主演非空时导演不再被吞
              score: double.tryParse('${m['vod_score'] ?? ''}') ?? 0,
              hits: int.tryParse('${m['vod_hits'] ?? ''}') ?? 0,
              area: '${m['vod_area'] ?? ''}'.trim(),
            );
        })
        .where((v) => v.vodId.isNotEmpty && v.name.isNotEmpty)
        .toList();
  }

  /// 分类列表 + 总页数（v1.4.5：按源缓存，分类体系不会变化，避免重复请求）
  ///
  /// v2.2.1 关键修复：**请求失败时绝不写缓存**。
  /// 原先无论成败都 `_catCache[s.id] = result`，一次超时/非 200 就会把
  /// 「空分类」缓存整个会话 —— 该片源此后永远解析不出任何 type_id，
  /// 被 `_advanceSource()` 静默跳过，表现为
  /// 「片源地址没失效（浏览器能打开），但分类下永远加载不出电影」。
  final Map<int, CatResult> _catCache = {};
  static const CatResult _emptyCat = CatResult(<Category>[], 1);

  Future<CatResult> categories(MovieSource s) async {
    final hit = _catCache[s.id];
    if (hit != null) return hit;
    final obj = await _getJson(s.url, query: {'ac': 'list', 'pg': '1'});
    final result = catResultOf(obj);
    if (result == null) return _emptyCat; // 失败：返回空但不缓存，下次重试
    _catCache[s.id] = result;
    return result;
  }

  // v2.2.1：同一时刻只跑一次测速 —— 启动 bootstrap 与首页 initState 会同时触发，
  // 原实现会把 40 个片源探测两遍（浪费一倍流量与等待）。
  Future<Map<int, int>>? _benchInFlight;

  /// 测速：并发探测全部片源，返回「毫秒延迟」表（失败的不在表内）
  ///
  /// v2.2.1 三项改进：
  /// ①**复用探测结果预热分类缓存** —— 探测器本来就把每源的 ac=list 分类树
  ///   下载回来了，原先只取耗时、正文丢弃，首页还要再抓一次（40 次请求白等）；
  /// ②并发内的重复调用复用同一个 Future（启动与首页不再各测一遍）；
  /// ③单源超时 8s→5s、并发 10→20：死源不再把整体拖到十几秒。
  /// [force] 为 true 时忽略在途请求，用于「片源管理」页「立即测速」。
  /// [activeOnly] 为 true 时只探测**已启用**片源（启动提速）；「立即测速」用 false
  /// 以便把已停用源也一起测出来（与 PC 版一致，停用源也要能看到失败/延迟）。
  Future<Map<int, int>> benchmarkSources(
      {Duration timeout = const Duration(seconds: 5),
      bool force = false,
      bool activeOnly = false}) {
    if (!force) {
      final running = _benchInFlight;
      if (running != null) return running;
    }
    final fut = _doBenchmark(timeout, activeOnly);
    _benchInFlight = fut;
    return fut.whenComplete(() {
      if (identical(_benchInFlight, fut)) _benchInFlight = null;
    });
  }

  Future<Map<int, int>> _doBenchmark(Duration timeout, bool activeOnly) async {
    final latencies = <int, int>{};
    final tasks = (activeOnly ? activeSources : sources)
        .map((s) => () async {
              final sw = Stopwatch()..start();
              try {
                final resp = await _client
                    .get(_buildUri(s.url, {'ac': 'list', 'pg': '1'}),
                        headers: const {'User-Agent': _ua})
                    .timeout(timeout);
                sw.stop();
                if (resp.statusCode == 200 && resp.bodyBytes.length > 64) {
                  latencies[s.id] = sw.elapsedMilliseconds;
                  // 顺带预热分类缓存：省掉首页/换源时对同一接口的重复请求
                  final cr = catResultOf(decodeJsonObject(resp.body));
                  if (cr != null && cr.categories.isNotEmpty) {
                    _catCache[s.id] = cr;
                  }
                }
              } catch (_) {/* 失败不记录 */}
            })
        .toList();
    await parallel(tasks, 20);
    return latencies;
  }

  // ============ 大类归属（移植自 PC 版规则） ============
  /// 优先级：纪录片 > 短剧 > 动漫 > 综艺 > 电影 > 电视剧 > 体育 > 影视解说 > 伦理
  /// （v10：一级「资讯」取消，资讯类改由 _otherForce 直接进「其他」）
  static const _catOrder = [
    'documentary', 'shortdrama', 'anime', 'variety', 'movies', 'tv',
    'sports', 'commentary', 'ethics',
  ];
  // v1.7.0：明确归入「其他」的关键词（优先于一切大类匹配）
  // v2.2.0 分类方案 v10：补「里番」「资讯」——「里番动漫」改归其他；
  // 一级「资讯」取消后，新闻资讯/头条/公告/娱乐动态/糖果画报 一律进「其他」
  //（含「伦理」二字者仍豁免归伦理频道）
  static const _otherForce = ['擦边', '三级', '写真', '福利', '里番', '资讯', '主播'];

  /// v2.2.3（对齐 PC 版 v11）：伦理一族命名空间 —— 一级「伦理」独占。
  /// ⚠ 必须在 [matchTopCategory] 里**最先判定**：否则「港台三级」「三级伦理」
  ///   会被 [_otherForce] 的「三级」抢走，归入已隐藏的 other 大类，
  ///   导致「港台伦理」永远取不到内容。
  static const _ethicsKw = [
    '日本伦理', '西方伦理', '韩国伦理', '港台伦理', '港台三级', '三级伦理', '理论片', '伦理'
  ];

  /// 伦理一级的「片名自动分派」（v11）：
  /// 源站的「伦理 / 三级伦理 / 理论片」是不分地区的泛化桶，按片名关键词分派到
  /// 4 个区域二级；分不出地区的一律落到默认桶「港台伦理」，保证不丢内容。
  static const ethicsRegions = ['日本伦理', '西方伦理', '韩国伦理', '港台伦理'];
  static const ethicsDefault = '港台伦理';

  /// 需按片名分派的「泛伦理桶」分类名（规范化之后）
  static const ethicsGeneric = ['伦理', '三级伦理', '理论片'];

  /// 区域关键词表 —— **顺序即优先级**；均为多字词或高辨识度词，避免「日/韩」单字误伤
  static const Map<String, List<String>> ethicsRegionKw = {
    '韩国伦理': ['韩国', '韩语', '韩剧', '首尔', '大韩', '思密达'],
    '日本伦理': ['日本', '日语', '日剧', '东京', '大阪', '北海道', '京都', '日式'],
    '西方伦理': ['欧美', '美国', '美剧', '西方', '英国', '英剧', '法国', '德国', '意大利',
      '西班牙', '俄罗斯', '荷兰', '瑞典', '波兰', '巴西', '西片', '荷里活', '好莱坞'],
    '港台伦理': ['香港', '港产', '港剧', '香港电影', '台湾', '台剧', '台语', '粤语', '港片', 'TVB'],
  };

  /// 纪录片「内容主题」关键词表（v2.2.3，移植自 PC 版）。
  /// 源站没有纪录片子分类（实探 12 个主力源子分类数均为 0），因此按
  /// 片名 / 简介 / 备注 里的关键词把条目归入主题二级。
  /// 各主题独立匹配；全都不命中的片子只出现在「全部」里。
  static const Map<String, List<String>> docThemes = {
    '自然地理': ['自然', '地理', '地球', '海洋', '海底', '动物', '野生', '生态', '行星', '太空',
      '宇宙', '山河', '冰川', '极地', '雨林', '秘境', '奇观', '国家公园', '大河', '珠峰', '乔戈里',
      '喜马拉雅', '攀登', '沙漠', '草原', '湿地', '飞鸟', '猛兽', '大自然', '新疆', '西藏', '黄河', '长江'],
    '历史人文': ['历史', '文明', '考古', '古迹', '古墓', '王朝', '故宫', '长城', '丝路', '三星堆',
      '文物', '非遗', '传承', '民俗', '人文', '艺术', '书画', '诗词', '国学', '通史', '档案', '遗址',
      '博物馆', '典籍', '汉字', '那年', '往事', '记忆', '三国', '大唐', '大明', '大清', '宋朝', '明朝',
      '清朝', '民国', '春秋', '战国', '秦汉', '长安', '敦煌'],
    '军事战争': ['军事', '战争', '战役', '二战', '抗战', '抗日', '武器', '军工', '军队', '战场',
      '战士', '士兵', '国防', '特种兵', '谍战', '军武', '战机', '导弹', '军舰', '空战', '海战'],
    '科学探索': ['科学', '科技', '技术', '工程', '发明', '制造', '物理', '化学', '数学', '医学',
      '生物', '量子', '实验', '解密', '真相', '原理', '未来', '机器人', '人工智能', '航天', '火箭', '卫星'],
    '美食旅行': ['美食', '味道', '舌尖', '料理', '餐厅', '厨房', '小吃', '食味', '旅行', '旅途',
      '旅游', '行走', '游记', '向导', '风景', '城市', '在路上', '远方', '民宿', '逛吃', '街头'],
    '人物社会': ['人物', '传记', '大师', '传奇', '人生', '社会', '纪实', '调查', '故事', '匠人',
      '先生', '面孔', '医生', '老师', '律师', '记者', '打工', '乡村', '人间', '智慧人物'],
  };

  static const _catMatch = {
    'documentary': ['纪录片', '记录片', '纪实', '科教', '科普'],
    // v2.3.0（U3）：'都市' / '民国' / '恋爱' 等泛词归短剧是**产品口径**（靳老师确认），
    // 源站的「都市剧场」「民国剧」也按短剧收录，勿改成电视剧。
    'shortdrama': ['短剧', '爽剧', '漫剧', 'AI', '女频', '恋爱', '言情', '反转', '仙侠', '穿越', '都市', '脑洞', '总裁', '民国', '闪婚', '逆袭'],
    'movies': ['电影', '动作', '喜剧', '爱情', '科幻', '恐怖', '剧情', '战争', '悬疑', '惊悚', '犯罪', '冒险', '奇幻', '大片', '灾难', '历史', '古装', '家庭', '西部', '邵氏', '武侠'],
    'tv': ['电视剧', '连续剧', '港剧', '台剧', '韩剧', '日剧', '美剧', '泰剧', '英剧', '国产剧', '海外剧', '韩国剧', '日本剧', '台湾剧', '香港剧', '美国剧', '泰国剧', '大陆剧', '其他剧', '自制剧', '剧集', '内地剧'],
    'variety': ['综艺', '真人秀', '脱口秀', '音乐', '演唱会'],
    'anime': ['动漫', '动画', '国漫', '番剧', '儿歌'],
    // v1.9.2：补网球/排球/拳击等关键词 —— 「美国网球赛」等体育分类不再落入其他（靳老师）
    'sports': ['体育', '篮球', '足球', '斯诺克', '台球', '赛事', '网球', '排球', '乒乓球',
      '棒球', '橄榄球', '拳击', '搏击', '格斗', '赛车', '高尔夫', '羽毛球', 'NBA', 'LPL'],
    'commentary': ['解说', '预告'],
    'ethics': ['伦理', '两性', '理论片'],
  };
  static const catNames = {
    'movies': '电影',
    'tv': '电视剧',
    'variety': '综艺',
    'anime': '动漫',
    'documentary': '纪录片',
    'shortdrama': '短剧',
    'sports': '体育',
    'commentary': '影视解说',
    'ethics': '伦理',
    'other': '其他',
  };

  /// v1.7.0：全部常规一级大类（固定顺序，不含「其他」特殊频道）
  static const allBigCats = [
    'movies', 'tv', 'variety', 'anime', 'documentary',
    'shortdrama', 'sports', 'commentary', 'ethics',
  ];

  static bool _matchKw(List<String> kws, String name) => kws.any(name.contains);

  /// v1.9.1：二级分类固定清单 —— 严格按《电影世界-片源分类说明》（拟定稿），
  /// 数量与顺序固定，不再随片源连通情况增减变化（靳老师 2026-09-21）。
  /// 加载时仍按分类名在各片源解析 type_id，解析不到自动跨源补位。
  /// 短剧频道首位「短剧大全」由「短剧」与「大全」合并而来（v1.9.2，靳老师）——
  /// 「短剧大全」是暴风/茅台/豆瓣资源/豆瓣备用 4 源的顶级分类，作全部短剧合集入口。
  /// v1.9.3：按 v9 分类说明落地——动漫新增「儿童儿歌」（索尼/无尽/无尽备用/索尼备用 4 源），
  /// 百度云「港澳剧」指定归入 电视剧·港台剧（靳老师确认）。
  /// v2.2.3（对齐 PC 版 v11）二级分类固定清单：
  /// · 取消一级分类下与自身同名的二级（电影 / 电视剧 / 综艺 / 纪录片）
  /// · 伦理一级重构为 4 个区域二级，取消「伦理」「三级伦理」「两性课堂」
  /// · 取消一级「其他」大类（原「港台三级」并入「港台伦理」）
  /// · 纪录片改为**按内容主题切分**（源站纪录片是扁平大类，没有可借用的子分类）
  static const Map<String, List<String>> docSubcats = {
    'movies': ['剧情片', '动作片', '喜剧片', '恐怖片', '战争片', '爱情片', '科幻片',
      '犯罪片', '奇幻片', '悬疑片', '冒险片', '惊悚片', '邵氏电影', '网络电影', 'Netflix电影'],
    'tv': ['国产剧', '日韩剧', '欧美剧', '海外剧', '港台剧', 'Netflix自制剧', '其他剧'],
    'variety': ['大陆综艺', '日韩综艺', '欧美综艺', '港台综艺', '海外综艺', '其他综艺', '演唱会'],
    'anime': ['动漫', '国产动漫', '日韩动漫', '欧美动漫', '海外动漫', '港台动漫', '有声动漫',
      '动漫电影', '儿童动漫', '儿童儿歌'],
    'documentary': ['全部', '自然地理', '历史人文', '军事战争', '科学探索', '美食旅行', '人物社会'],
    'shortdrama': ['短剧大全', '反转爽剧', '古装仙侠', '现代都市', '穿越短剧', 'AI漫剧',
      '脑洞悬疑', '女频恋爱', '言情短剧', '重生民国', '成长逆袭', '闪婚离婚'],
    'sports': ['体育赛事', '篮球', '足球', '斯诺克', '其他体育'],
    'commentary': ['影视解说', '预告片', '预告解说'],
    'ethics': ['日本伦理', '西方伦理', '韩国伦理', '港台伦理'],
  };

  /// v2.2.3：各频道的「聚合 Tab」——收纳归入本频道、但不被固定分类覆盖的杂项。
  /// v11 取消了 other 大类（成人/擦边内容随之整体隐藏），故只剩 sports。
  static const aggTabs = {'sports': '其他体育'};

  /// 大类归属（v2.2.3，对齐 PC 版 v11）
  static String matchTopCategory(String typeName) {
    // ⚠ 伦理一族必须**最先**判定：否则「港台三级」「三级伦理」会被
    //   _otherForce 的「三级」抢走、归入已隐藏的 other，导致伦理频道取不到内容。
    if (_ethicsKw.any(typeName.contains)) return 'ethics';
    // 明确归「其他」的内容（擦边/写真/福利/里番/资讯类）—— v11 起「其他」大类
    // 已从频道栏移除，等于整体隐藏这些内容（含成人向）。
    if (_otherForce.any(typeName.contains) && !typeName.contains('伦理')) {
      return 'other';
    }
    // 解说/预告类优先判定 —— 「电影解说」含「电影」二字会被误归电影频道
    if (_matchKw(_catMatch['commentary']!, typeName)) return 'commentary';
    // 指定归属 —— 「港澳剧」（百度云）→ 电视剧·港台剧
    if (typeName == '港澳剧') return 'tv';
    for (final key in _catOrder) {
      if (_matchKw(_catMatch[key]!, typeName)) return key;
    }
    return 'other';
  }

  /// 伦理「泛化桶」的片名自动分派（v11）。
  /// 只对源站「伦理 / 三级伦理 / 理论片」这类不分地区的分类生效；
  /// 源站已明确标了地区的（日本伦理…）直接沿用，不再二次判定。
  /// 返回 4 个区域二级之一；分不出地区 → 默认桶「港台伦理」。
  static String classifyEthics(String name) {
    final n = name.toLowerCase();
    if (n.isEmpty) return ethicsDefault;
    for (final e in ethicsRegionKw.entries) {
      if (e.value.any((k) => n.contains(k.toLowerCase()))) return e.key;
    }
    return ethicsDefault;
  }

  /// 该（规范化后）分类名是否属于「需按片名分派」的泛伦理桶
  static bool isGenericEthicsSub(String canonName) =>
      ethicsGeneric.contains(canonName);

  /// 纪录片主题判定（v2.2.3）：把条目归入主题二级。
  /// 「全部」恒为真（不过滤）；主题名查不到也放行（避免误伤）。
  /// 匹配范围：片名 + 简介 + 备注。
  static bool docThemeMatch(String subName, VideoItem item) {
    if (subName.isEmpty || subName == '全部') return true;
    final kws = docThemes[subName];
    if (kws == null) return true;
    final hay = '${item.name} ${item.remarks} ${item.vodClass}'.toLowerCase();
    return kws.any((k) => hay.contains(k.toLowerCase()));
  }

  /// v1.7.0 智能特征兜底：影片自身类型名标注不可信时，
  /// 用备注集数 / 风格标签推断真实大类（推断不出时返回 'other'）
  static String inferCat(VideoItem it) {
    final rm = it.remarks;
    // 连续剧特征：更新至XX集 / 共XX集 / 全XX集（2 集以上算剧）
    final m = RegExp(r'(?:更新至|共|全)\s*(\d{1,4})集').firstMatch(rm);
    if (m != null && (int.tryParse(m.group(1)!) ?? 1) >= 2) return 'tv';
    if (rm.contains('连载中') || rm.contains('连播中')) return 'tv';
    // 风格标签兜底（如「古装,言情」「科幻」）
    if (it.vodClass.isNotEmpty) return matchTopCategory(it.vodClass);
    return '';
  }

  // ---- v1.7.0 采样动态校准：识别「分类挂错牌」的片源（如建安把电视剧塞进电影分类）----
  // 首次访问某源某分类时抓一页样本，统计影片真实类型与分类名的一致率；
  // 低于阈值则按样本多数票改判该分类实际归属。结果缓存整个会话（片源分类极少变动）。
  static final Map<String, String> _calibCache = {}; // 'sourceId|tid' -> 实际大类
  static const double _calibThreshold = 0.6;

  /// v2.2.1：分类校准 —— 返回「实际大类」+ 本次抓取的 page1 样本。
  ///
  /// 与旧版 `calibratedCatOf` 的差别：
  /// ①**判定口径与首页列表过滤完全一致**：一条内容只要
  ///   `matchTopCategory(typeName) == catKey` **或** `inferCat(it) == catKey`
  ///   就算属于本频道。旧版只看 typeName，会把「type_name 字段脏、但内容
  ///   其实对」的片源误判成挂错牌 → 整源跳过 → 该分类下一片空白；
  /// ②样本不足 5 条不做改判，避免拿 1~2 条就把整个片源毙掉；
  /// ③把 page1 样本回传首页复用，省掉「同一页抓两遍」的重复请求；
  /// ④请求失败（返回 null）时信任原始分类名，不上报样本，由首页自行重试。
  Future<CalibResult> calibrate(
      MovieSource s, String catKey, String typeId) async {
    if (typeId.isEmpty) return CalibResult(catKey);
    final key = '${s.id}|$typeId';
    final hit = _calibCache[key];
    if (hit != null) return CalibResult(hit);
    var real = catKey;
    final lp = await listPageOrNull(s, typeId, 1);
    if (lp != null) {
      final sample = lp.items.take(20).toList();
      if (sample.length >= 5) {
        final votes = <String, int>{};
        for (final it in sample) {
          final c = matchTopCategory(it.typeName);
          final k = (c == catKey || inferCat(it) == catKey) ? catKey : c;
          votes[k] = (votes[k] ?? 0) + 1;
        }
        final agree = (votes[catKey] ?? 0) / sample.length;
        if (agree < _calibThreshold) {
          // 一致率不足 → 多数票改判（并列时保持原分类）
          final best = votes.entries.reduce((a, b) => a.value >= b.value ? a : b);
          if (best.key != catKey) real = best.key;
        }
      }
    }
    _calibCache[key] = real;
    // v2.2.2（B5）：容量上限 —— 防御异常源导致的 map 无界增长；
    // 超限直接清空（校准结果可重算，正确性不受影响，改动最简）。
    if (_calibCache.length > 800) _calibCache.clear();
    return CalibResult(real, sample: lp);
  }

  static bool _matchCat(String catKey, String name) =>
      _matchKw(_catMatch[catKey] ?? const [], name);

  // ============ v1.8.0 二级分类同名/同类归并（分类文档 v3~v7 方案落地） ============
  /// 别名归一表：原始分类名 → 规范名（支持链式：日剧→日本剧→日韩剧）
  static const _subAlias = {
    '电影片': '电影', '电视剧片': '电视剧', '电视片': '电视剧', '纪录': '纪录片', '记录片': '纪录片',
    '动画片': '动漫', '动画': '动漫', '动画电影': '动漫电影',
    '女恋总裁': '女频恋爱', '反转爽文': '反转爽剧', '爽文短剧': '反转爽剧',
    '都市脑洞': '现代都市', '穿越年代': '穿越短剧', '穿越现代': '穿越短剧', '年代穿越': '穿越短剧',
    '言情总裁': '言情短剧', '现代言情': '言情短剧', '漫剧': 'AI漫剧',
    '邵氏大片': '邵氏电影', '4K电影': '电影', '电影解说': '影视解说',
    '连续剧': '电视剧', '台剧': '台湾剧', '港剧': '香港剧', '日剧': '日本剧', '韩剧': '韩国剧',
    '美剧': '美国剧', '英剧': '英国剧', '泰剧': '泰国剧',
    '台湾剧': '港台剧', '香港剧': '港台剧', '日本剧': '日韩剧', '韩国剧': '日韩剧',
    '美国剧': '欧美剧', '泰国剧': '海外剧', '剧集': '其他剧', '大陆剧': '国产剧',
    '体育': '体育赛事', '日本动漫': '日韩动漫',
    // v2.2.0 v10：一级「资讯」取消，降为「其他·资讯」——
    // 新闻资讯/头条/公告/娱乐动态/糖果画报 及其既有别名全部归一到「资讯」
    '新闻资讯': '资讯', '站内新闻': '资讯', '影片资讯': '资讯', '头条': '资讯',
    '公告': '资讯', '娱乐动态': '资讯', '糖果画报': '资讯', '头条女神': '资讯',
    '港澳剧': '港台剧',
    // v1.9.5 分类修正（靳老师 2026-09-22 全源体检）：挂错牌分类归位
    '内地剧': '国产剧', 'NBA': '篮球', 'LPL': '体育赛事',
    '理论片': '三级伦理', '武侠': '动作片',
    // v2.2.3 v11：源站的「港台三级」统一并入「港台伦理」
    '港台三级': '港台伦理',
  };

  /// 频道内二级分类尾部位次（靳老师 2026-09-21）：列表内依次排倒数第 N 位
  static const _tailOrder = {
    'variety': ['其他综艺', '演唱会'],
    'movies': ['邵氏电影', '网络电影', 'Netflix电影'],
  };

  /// 二级分类规范名：①「电影/恐怖片」取末段；②「短剧X」去前缀；③别名链式归一
  static String canonSubName(String name) {
    var n = name.trim();
    if (n.contains('/')) n = n.split('/').last.trim();
    if (n.startsWith('短剧') && n.length > 2) n = n.substring(2);
    for (var i = 0; i < 4; i++) {
      final m = _subAlias[n];
      if (m == null || m == n) break;
      n = m;
    }
    return n;
  }

  /// 频道内二级分类排序位次：同名频道首位 > 国产剧第二（电视剧）> 常规 > 尾部位次
  static int _subRank(String catKey, String name) {
    final tail = _tailOrder[catKey];
    if (tail != null && tail.contains(name)) return 100 + tail.indexOf(name);
    if (name == '全部') return -1; // 纪录片主题二级的「全部」恒排首位
    if (name == (catNames[catKey] ?? catKey)) return 0;
    if (catKey == 'tv' && name == '国产剧') return 1;
    return 2;
  }

  /// v1.9.0：频道内二级分类排序位次（公开，供首页合并多源 Tab 统一排序用）
  static int subRank(String catKey, String name) => _subRank(catKey, name);

  /// v2.2.0 v10：固定清单的展示顺序 —— 按频道内位次做**稳定排序**
  ///（同名频道首位 > 国产剧第二 > 常规 > 尾部位次；同位次保持清单原序）。
  /// 使各频道的聚合 Tab（其他频道为「福利视频」）排在最后，
  /// 与 collectCategoryTabs 的排序口径一致。
  static List<String> sortedDocSubcats(String catKey) {
    final names = docSubcats[catKey] ?? const <String>[];
    final pairs = <List<Object>>[];
    for (var i = 0; i < names.length; i++) {
      pairs.add(<Object>[names[i], i]);
    }
    pairs.sort((a, b) {
      final r = subRank(catKey, a[0] as String)
          .compareTo(subRank(catKey, b[0] as String));
      return r != 0 ? r : (a[1] as int).compareTo(b[1] as int);
    });
    return [for (final p in pairs) p[0] as String];
  }

  /// 收集某大类下的子分类 tabs（与 PC 版 collectCategoryTabs 同逻辑）
  /// v1.7.0：二级分类全量展示 —— 不再截断 20 个，上限放宽到 60 防御异常源
  /// v1.8.0：二级分类同名/同类归并（规范名去重）+ 频道内排序（同名首位、国产剧第二、尾部位次）
  static List<Category> collectCategoryTabs(List<Category> classes, String catKey) {
    final top = classes.where((c) => c.isTop).toList();
    bool owns(Category c) =>
        _matchCat(catKey, c.name) && matchTopCategory(c.name) == catKey;

    List<Category> picked;
    if (catKey == 'documentary' || catKey == 'shortdrama') {
      picked = top.where(owns).toList();
      if (picked.isEmpty) picked = classes.where(owns).toList();
    } else {
      // v2.2.3 v11：取消 other 大类的分支（该大类已整体隐藏）
      picked = top.where(owns).toList();
    }
    // 规范名归并去重：同名分类（含「电影/恐怖片」式写法）只保留首个，取其 id
    final seen = <String, Category>{};
    for (final c in picked) {
      final cn = canonSubName(c.name);
      seen.putIfAbsent(cn, () => Category(c.id, cn, pid: c.pid));
      if (seen.length >= 60) break;
    }
    final list = seen.values.toList()
      ..sort((a, b) {
        final r = _subRank(catKey, a.name).compareTo(_subRank(catKey, b.name));
        return r != 0 ? r : a.name.compareTo(b.name);
      });
    return list;
  }

  /// 按分类分页取列表
  /// v1.2.1 关键修复：改用 ac=detail —— ac=list 返回的数据不含 vod_pic 字段，
  /// 导致海报墙永远空图；ac=detail 同样支持 t 分类筛选与 pg 分页，且带完整字段
  Future<List<VideoItem>> listByCategory(MovieSource s, String typeId, int pg) =>
      _getJson(s.url, query: {'ac': 'detail', 't': typeId, 'pg': '$pg'})
          .then((o) => _parseItems(o, s));

  /// v2.2.1：列表页（可空版）—— 严格区分「请求失败」与「该分类没内容」。
  /// 失败返回 null，调用方可重试或换源；成功返回实际结果（**可能**是空页）。
  ///
  /// 原实现里 `_getJson` 失败 → 解析出空列表 → 被上层当成「该源该分类无片」
  /// 直接换源；一次网络抖动/慢响应就让该片源在本 Tab 里**永不再被加载**，
  /// 表现出来就是「片源地址没失效，但分类下什么都没有」。
  Future<ListPage?> listPageOrNull(MovieSource s, String typeId, int pg,
      {Duration timeout = const Duration(seconds: 8)}) async {
    final obj = await _getJson(s.url,
        query: {'ac': 'detail', 't': typeId, 'pg': '$pg'}, timeout: timeout);
    if (obj == null) return null;
    final pc = int.tryParse('${obj['pagecount'] ?? 1}') ?? 1;
    return ListPage(_parseItems(obj, s), pc);
  }

  /// v2.2.9：最新更新 —— 不带分类 id 的 `ac=detail&pg=1`，MacCMS 默认按更新时间倒序。
  /// 个别源不支持无 t 查询时退回 `ac=list`（字段少一些，但能拿到列表）。
  Future<List<VideoItem>> latest(MovieSource s, {int pg = 1}) async {
    var obj = await _getJson(s.url, query: {'ac': 'detail', 'pg': '$pg'});
    var items = _parseItems(obj, s);
    if (items.isEmpty) {
      obj = await _getJson(s.url, query: {'ac': 'list', 'pg': '$pg'});
      items = _parseItems(obj, s);
    }
    return items;
  }

  /// 全部启用片源的最新更新（并发 8，单源取第 1 页）。
  Future<List<VideoItem>> latestAll({int pages = 1}) async {
    final tasks = activeSources.map((s) => () async {
      final out = <VideoItem>[];
      for (var p = 1; p <= pages; p++) {
        final items = await latest(s, pg: p);
        if (items.isEmpty) break;
        out.addAll(items);
      }
      return out;
    }).toList();
    final res = await parallel(tasks, 8);
    return res.expand((e) => e).toList();
  }

  /// v2.2.0 v10：固定 Tab 的**多 id 解析** —— 同一片源里所有「规范名 == [subName]」的分类 id。
  ///
  /// 背景：一级「资讯」取消后，新闻资讯 / 头条 / 公告 / 娱乐动态 / 糖果画报 等
  /// 经别名归一全部变成「资讯」，而 resolveTypeId 一个 Tab 只返回一个 id ——
  /// 未被选中的那些就会掉进「福利视频」聚合 Tab（靳老师：资讯必须归「其他 · 资讯」）。
  ///
  /// - 带频道归属校验（matchTopCategory(c.name) == catKey），不会把别的频道的分类拉进来
  /// - 上限 [maxTabIds] 防御异常源
  /// - 返回空表示「严格匹配不到」，由调用方回退到 resolveTypeId（保持原有单 id 行为）
  static const int maxTabIds = 20;

  Future<List<String>> resolveTabIds(
      MovieSource s, String catKey, String subName) async {
    if (subName.isEmpty) return const <String>[];
    try {
      final cat = await categories(s);
      final target = canonSubName(subName);
      // v2.2.1：**顶级分类优先**。部分源在子分类下也有同名分类
      //（如「电影/电影」），父级才是主入口，取 id 列表首位时顺序很关键。
      final tops = <String>[];
      final rest = <String>[];
      for (final c in cat.categories) {
        if (tops.length + rest.length >= maxTabIds) break; // 防御异常源
        if (matchTopCategory(c.name) != catKey) continue;
        if (c.name == subName || canonSubName(c.name) == target) {
          (c.isTop ? tops : rest).add(c.id);
        }
      }
      return [...tops, ...rest];
    } catch (_) {
      return const <String>[];
    }
  }

  /// v2.2.1：某 Tab 在本源上「按顺序可加载的全部 type_id」——在 resolveTabIds
  /// 基础上，**当 Tab 就是本频道名时（电影/电视剧/综艺/动漫/纪录片/伦理/影视解说），
  /// 把该分类下的、同样归属本频道的直属子分类一并追加**（父 id 在前）。
  ///
  /// 背景（实测 40 源）：不少 MacCMS 源把内容**全部挂在子分类上、父分类是空壳**。
  /// 例如天堂「电影片」id=1 → `t=1` 返回 0 条，而它的子分类 6:动作片/7:喜剧片/
  /// 11:剧情片… 每个都返回 20~30 条；猫眼/360资源/非凡/牛牛/索尼备用 等同样如此。
  /// 只解析父 id 会让这些源在该 Tab 下**一片空白**（正是「片源地址没失效，
  /// 但分类下加载不出电影」的主因）。实测展开后（40 源真实网络）：
  /// 电影 Tab 7 个源、电视剧 Tab 11 个源、动漫 Tab 5 个源、体育赛事 Tab 10 个源
  /// 由「空」变「有内容」；同 id 列表下的个别波动均属网络抖动，无真实退化。
  ///
  /// 子分类按频道归属过滤 —— 只收 `matchTopCategory(child.name) == catKey` 的，
  /// 所以「天堂/电影片」下混着的 记录片/伦理片/动画片 不会被拉进电影 Tab。
  Future<List<String>> resolveFeedIds(
      MovieSource s, String catKey, String subName) async {
    final direct = await resolveTabIds(s, catKey, subName);
    if (direct.isEmpty) return direct;
    // 仅「Tab 名 == 本频道名」时展开，避免把「网络电影 / 邵氏电影 / 三级伦理」
    // 这种细粒度 Tab 也扩成一大片
    if (canonSubName(subName) != canonSubName(catNames[catKey] ?? catKey)) {
      return direct;
    }
    try {
      final cat = await categories(s);
      final has = direct.toSet();
      final extra = <String>[];
      for (final c in cat.categories) {
        if (direct.length + extra.length >= maxTabIds) break;
        if (has.contains(c.id)) continue;
        if (!direct.contains(c.pid)) continue; // 只收 direct 的直属子分类
        if (matchTopCategory(c.name) != catKey) continue; // 跨频道子分类丢掉
        extra.add(c.id);
      }
      return [...direct, ...extra];
    } catch (_) {
      return direct;
    }
  }

  /// v2.2.3 v11：伦理一级专用 —— 解析该 Tab 在本源要取的 type_id。
  /// 返回 [EthicsId]：generic=false（源站已标地区 / 已归并）全部保留；
  /// generic=true（泛伦理桶）其中的影片需按片名自动分派。
  Future<List<EthicsId>> resolveEthicsIds(MovieSource s, String subName) async {
    try {
      final cat = await categories(s);
      final out = <EthicsId>[];
      final seen = <String>{};
      for (final c in cat.categories) {
        if (seen.contains(c.id)) continue;
        if (matchTopCategory(c.name) != 'ethics') continue;
        final canon = canonSubName(c.name);
        if (canon == subName) {
          seen.add(c.id);
          out.add(EthicsId(c.id, false));
          continue;
        }
        if (isGenericEthicsSub(canon) || isGenericEthicsSub(c.name)) {
          seen.add(c.id);
          out.add(EthicsId(c.id, true));
        }
      }
      return out;
    } catch (_) {
      return const <EthicsId>[];
    }
  }

  /// v2.2.3 v11：纪录片专用 —— 取本源「纪录片」大类下的**全部** type_id。
  /// 源站纪录片是扁平大类、没有子分类可按（实探 12 个主力源子分类数均为 0），
  /// 所以把整大类的 id 都交给首页，条目再由 [docThemeMatch] 按主题归类。
  Future<List<String>> resolveDocIds(MovieSource s) async {
    try {
      final cat = await categories(s);
      final out = <String>[];
      final seen = <String>{};
      for (final c in cat.categories) {
        if (out.length >= maxTabIds) break;
        if (matchTopCategory(c.name) != 'documentary') continue;
        if (seen.contains(c.id)) continue;
        seen.add(c.id);
        out.add(c.id);
      }
      return out;
    } catch (_) {
      return const <String>[];
    }
  }

  /// v1.4.0：按子分类名称在新源中解析 type_id。
  /// 匹配顺序：同名 > 互相包含 > 大类首个 tab > 空（全站）
  /// v1.4.5：[fallbackFirst] 为 false 时（固定共同子分类 Tab），名称匹配不到
  /// 直接返回空串 —— 该片源没有此子分类，由调用方跳过该源，避免混入无关内容
  Future<String> resolveTypeId(MovieSource s, String catKey, String subName,
      {bool fallbackFirst = true}) async {
    try {
      final cat = await categories(s);
      if (subName.isNotEmpty) {
        final target = canonSubName(subName);
        // v1.8.0：同名/规范名相等优先（Tab 显示规范名，源里可能是原始写法，如「日剧」vs「日本剧」）
        for (final c in cat.categories) {
          if (c.name == subName || canonSubName(c.name) == target) return c.id;
        }
        for (final c in cat.categories) {
          // v2.2.0 v10：跨频道的「互相包含」一律不接受（对齐电视版 v0.4.0）——
          // 否则「其他·里番动漫」会被解析到该源的「动漫 / 动画片」（32 个源受影响），
          // 「其他·擦边短剧」同理会被解析到「短剧」。
          if (matchTopCategory(c.name) != catKey) continue;
          final cn = canonSubName(c.name);
          if (cn.contains(target) || target.contains(cn)) return c.id;
        }
        if (!fallbackFirst) return '';
      }
      final tabs = collectCategoryTabs(cat.categories, catKey);
      return tabs.isEmpty ? '' : tabs.first.id;
    } catch (_) {
      return '';
    }
  }

  /// v1.9.1：聚合 Tab —— 某片源中属于 [catKey] 大类的杂项分类 id 列表；
  /// v1.9.2 泛化：排除已被固定分类 Tab 覆盖的分类，其余全部纳入聚合
  ///（other → 「福利视频」；sports → 「其他体育」，收纳网球赛等无固定入口的体育分类）
  /// v2.2.0 v10：排除方式由「名称像不像固定分类」改为「本源固定 Tab 实际解析出的 id」，
  /// 修掉「多个分类归一到同一 Tab 时其余同类被判为已覆盖 → 内容彻底不可见」的丢内容问题。
  Future<List<String>> resolveMiscIds(MovieSource s, String catKey) async {
    try {
      final cat = await categories(s);
      final aggName = aggTabs[catKey];
      // 先算出「本源各固定 Tab 实际解析出的 id 集合」：多个分类归一到同一个 Tab 时，
      // Tab 只会选中其中一个 id，其余同类分类必须留给聚合 Tab，否则内容彻底看不到。
      //（resolveTypeId 传了非空 subName + fallbackFirst=false，不会回调本方法，无递归风险）
      final used = <String>{};
      for (final t in (docSubcats[catKey] ?? const <String>[])) {
        if (t == aggName) continue;
        // 先取该 Tab 在本源的**全部** id（v2.2.0 v10 多 id）：
        // 归一到同一 Tab 的分类（如 新闻资讯/头条/公告 → 资讯）必须一起排除，
        // 否则它们会掉进聚合 Tab，出现「福利视频里装着公告头条」的观感问题。
        // 严格匹配不到时回退原有单 id 解析，保持原有覆盖口径不变。
        final ids = await resolveTabIds(s, catKey, t);
        if (ids.isNotEmpty) {
          used.addAll(ids);
          continue;
        }
        final id = await resolveTypeId(s, catKey, t, fallbackFirst: false);
        if (id.isNotEmpty) used.add(id);
      }
      final ids = <String>[];
      for (final c in cat.categories) {
        if (ids.length >= 60) break; // 单源聚合分类上限，防御异常源
        if (matchTopCategory(c.name) != catKey) continue;
        if (used.contains(c.id)) continue;
        ids.add(c.id);
      }
      return ids;
    } catch (_) {
      return const [];
    }
  }

  /// v1.4.0：多源加载队列 —— 指定源置顶，其余按测速延迟升序（未测速的排最后，保持原序）
  /// v2.2.4：已停用片源不参与加载（与 PC 版一致）
  /// v2.2.8：本机近期整源失败的排到同延迟组的后面，避免每次首屏都先撞坏源。
  List<MovieSource> feedQueue(MovieSource first, Map<int, int> latency) {
    // 带下标排序：权重与延迟都相同时按下标兜底，保证「保持原序」不依赖
    // List.sort 的稳定性（Dart 的 sort 不保证稳定）。
    final indexed = activeSources
        .where((s) => s.id != first.id)
        .toList()
        .asMap()
        .entries
        .toList()
      ..sort((a, b) {
        final ra = VodSourceHealth.rank(a.value.id);
        final rb = VodSourceHealth.rank(b.value.id);
        if (ra != rb) return ra.compareTo(rb);
        final la = latency[a.value.id] ?? 1 << 30;
        final lb = latency[b.value.id] ?? 1 << 30;
        if (la != lb) return la.compareTo(lb);
        return a.key.compareTo(b.key);
      });
    final rest = indexed.map((e) => e.value).toList();
    return [first, ...rest];
  }

  /// 搜索（单个片源）
  Future<List<VideoItem>> search(MovieSource s, String wd) =>
      _getJson(s.url, query: {'ac': 'detail', 'wd': wd})
          .then((o) => _parseItems(o, s));

  /// v1.4.0：搜索（区分网络失败与空结果）—— 失败返回 null
  Future<List<VideoItem>?> searchOrNull(MovieSource s, String wd) async {
    final obj = await _getJson(s.url, query: {'ac': 'detail', 'wd': wd});
    if (obj == null) return null;
    return _parseItems(obj, s);
  }

  /// 详情（含播放地址）
  Future<VideoDetail?> detail(MovieSource s, String vodId) async {
    final obj = await _getJson(s.url, query: {'ac': 'detail', 'ids': vodId});
    final raw = obj?['list'];
    if (raw is! List || raw.isEmpty) return null;
    final m = raw.first;
    if (m is! Map<String, dynamic>) return null;

    final groups = <PlayGroup>[];
    // v2.2.0 修复：多片源分隔符是 $$$（与 vod_play_url 一致）。原按单 $ 拆分会让
    // 第 2 条起的线路名错位、被兜底成「线路N」，故改为按 $$$ 拆分。
    final froms = '${m['vod_play_from'] ?? ''}'.split(r'$$$');
    final urls = '${m['vod_play_url'] ?? ''}'.split(r'$$$');
    for (var i = 0; i < urls.length; i++) {
      // v1.5.3：分组名为空（部分源 vod_play_from 缺失）时兜底为「线路N」，避免空白方块
      final from = i < froms.length && froms[i].trim().isNotEmpty
          ? froms[i].trim()
          : '线路${i + 1}';
      final eps = <Episode>[];
      for (final pair in urls[i].split('#')) {
        // v2.2.0 修复：只在「第一个 $」处切分「集名$地址」，避免地址本身含 $ 被截断。
        final sep = pair.indexOf(r'$');
        if (sep < 0) continue;
        final name = pair.substring(0, sep).trim();
        final epUrl = pair.substring(sep + 1).trim();
        if (epUrl.isNotEmpty) {
          eps.add(Episode(name.isEmpty ? '第${eps.length + 1}集' : name, epUrl));
        }
      }
      if (eps.isNotEmpty) groups.add(PlayGroup(from, eps));
    }

    return VideoDetail(
      item: VideoItem(
        vodId: '${m['vod_id'] ?? vodId}',
        name: '${m['vod_name'] ?? ''}'.trim(),
        pic: '${m['vod_pic'] ?? ''}',
        remarks: '${m['vod_remarks'] ?? ''}'.trim(),
        typeId: '${m['type_id'] ?? ''}',
        typeName: '${m['type_name'] ?? ''}',
        vodClass: '${m['vod_class'] ?? ''}',
        time: '${m['vod_time'] ?? ''}',
        sourceId: s.id,
        sourceName: s.name,
      ),
      year: '${m['vod_year'] ?? ''}'.trim(),
      area: '${m['vod_area'] ?? ''}'.trim(),
      actor: '${m['vod_actor'] ?? ''}'.trim(),
      director: '${m['vod_director'] ?? ''}'.trim(),
      content: _stripTags('${m['vod_content'] ?? ''}'),
      groups: groups,
    );
  }

  static String _stripTags(String s) =>
      s.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll(RegExp(r'\s+'), ' ').trim();

  /// 并发上限 map（用于全源搜索/换源）
  static Future<List<T>> parallel<T>(
      Iterable<Future<T> Function()> tasks, int limit) async {
    // v2.2.2（D7）：先物化 —— 传惰性 Iterable 时多次迭代会出错
    //（原实现用 tasks.length + tasks.iterator 各取一次，生成器会被重复消费）
    final list = tasks.toList();
    final results = <T>[];
    final it = list.iterator;
    var running = 0;
    final completer = Completer<void>();
    void next() {
      if (results.length >= list.length && running == 0) {
        if (!completer.isCompleted) completer.complete();
        return;
      }
      while (running < limit) {
        if (!it.moveNext()) {
          if (running == 0 && !completer.isCompleted) completer.complete();
          return;
        }
        running++;
        it.current().then((r) {
          results.add(r);
        }).catchError((_) {}).whenComplete(() {
          running--;
          next();
        });
      }
    }

    next();
    await completer.future;
    return results;
  }

  /// 全源搜索同名影片（用于换源）；v2.2.4：跳过已停用片源
  Future<List<VideoDetail>> searchSameNameAllSources(
      String name, MovieSource exclude) async {
    final tasks = activeSources
        .where((s) => s.id != exclude.id)
        .map((s) => () async {
              final items = await search(s, name);
              for (final it in items) {
                if (it.name == name) {
                  final d = await detail(s, it.vodId);
                  if (d != null && d.playable) return d;
                }
              }
              return null;
            })
        .toList();
    final res = await parallel(tasks, 8);
    // v2.2.8：健康片源优先（稳定排序，同权重保持搜索完成顺序）。
    return VodSourceHealth.order(
      res.whereType<VideoDetail>().toList(),
      (d) => d.item.sourceId,
    );
  }
}
