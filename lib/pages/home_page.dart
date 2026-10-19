/// 首页：内容优先（弱化片源）+ 频道 + 二级分类（全片源并集）+ 海报墙
/// v1.9.0：
/// ①整体弱化片源：切换片源不再清空已加载内容，仅把所选源提到加载队列首位
///   （影响后续影片加载的优先级）；片源入口弱化为右上角小按钮；
/// ②二级分类 Tab 改为全部启用片源分类的并集（规范名归并 + 统一排序），
///   不随片源切换增减隐藏；当前片源没有该分类时自动加载其他片源的资源；
/// ③每个二级分类可下滑一直加载，直到所有片源加载完毕；
/// ④监听设置变更：首页频道开关后返回首页立即生效（无需重启）。
library;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../store.dart';
import '../theme.dart';
import 'detail_page.dart';
import 'search_input_page.dart';
import 'widgets.dart';

/// 子分类 Tab（v1.9.0）：只存规范分类名，各片源加载时按名解析 type_id
class _SubTab {
  final String name;
  const _SubTab(this.name);
}

/// v2.2.3 v11：某个 Tab 在本源解析出的 type_id 集合。
/// [generic] 内的 id 需要**在客户端按内容过滤**：
///   · 伦理 —— 源站泛伦理桶（伦理/三级伦理/理论片），条目按片名分派到 4 个区域二级；
///   · 纪录片 —— 源站是扁平大类，条目按内容主题归类。
class _TabIds {
  final List<String> ids;
  final Set<String> generic;
  const _TabIds(this.ids, [this.generic = const <String>{}]);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late MovieSource _source;
  // v2.2.3（需求3）：打开软件默认选中**第一个可见的一级分类**
  //（v11 起一级「其他」已取消，频道栏只列常规一级分类）
  String _bigCat = '';
  List<_SubTab> _subTabs = const []; // 全片源并集的子分类 Tab
  int _subIdx = 0; // 选中的子分类下标
  String _typeId = ''; // 当前子分类（当前正在翻页的源 type_id）
  final List<VideoItem> _items = [];
  final Set<String> _seenIds = {}; // 分页去重（sourceId|vodId）
  final Set<String> _seenNames = {}; // 跨源片名去重
  int _page = 1;
  int _pagecount = 1;
  // v1.4.0 多源队列：当前源翻完后自动续接下一片源，实现无限加载
  List<MovieSource> _queue = const [];
  int _qIdx = 0;
  bool _exhausted = false;
  String _subName = ''; // 选中的子分类名称（跨源按名解析）
  // v1.9.1：「其他」聚合 Tab 的多分类加载（当前源的杂项 type_id 队列）
  // v2.2.0 v10：固定 Tab 也支持多 id（如「资讯」一次收 新闻资讯/头条/公告），
  // 因此复用同一套「当前源 id 队列 + 下标」：逐个翻页翻完再换源。
  // 单 id 的 Tab 只有一个元素，行为与改动前逐字一致。
  List<String> _tabIds = const [];
  int _tabIdx = 0;
  /// v2.2.3 v11：当前 Tab 中需要「在客户端按内容过滤」的 type_id
  /// （伦理泛桶按片名分派 / 纪录片按内容主题归类）
  Set<String> _genericIds = const <String>{};
  bool get _isMiscTab =>
      MacApi.aggTabs[_bigCat] != null && _subName == MacApi.aggTabs[_bigCat];
  bool _loading = false;
  // v1.9.4：切源/切 Tab 竞态修复 —— 加载进行中收到新请求时排队接力；
  // 代际号失配的在途循环立即作废，保证切源后严格从新源优先加载
  bool _pendingLoad = false;
  int _gen = 0;
  bool _initialError = false;
  Map<int, int> _latency = {}; // 测速结果（弹窗里显示）
  int _seenSrcRev = 0; // v2.2.4：片源管理变更信号快照（测速/开关后据此重选源）
  final ScrollController _scroll = ScrollController();

  /// v2.2.4：按优先级选源 —— 用户手选 > 测速最快 > 第一个启用源。
  /// 已停用片源不参选（与 PC 版「停用源不参与加载」一致）。
  void _pickSource() {
    final api = MacApi.instance;
    final store = AppStore.instance;
    final pool = api.activeSources;
    _source = pool.where((s) => s.id == store.lastSourceId).firstOrNull ??
        pool.where((s) => s.id == store.fastSourceId).firstOrNull ??
        (pool.isNotEmpty ? pool.first : api.defaultSource);
  }

  @override
  void initState() {
    super.initState();
    final api = MacApi.instance;
    final store = AppStore.instance;
    _seenSrcRev = store.sourceRev;
    _pickSource();
    // v2.2.3（需求3）：默认选中第一个可见的一级分类；其下第一个二级分类由
    // _subIdx = 0 保证（切换一级分类时 _switchBigCat 同样把 _subIdx 归零）
    _bigCat = _bigCatKeys.isNotEmpty ? _bigCatKeys.first : 'movies';
    _scroll.addListener(_onScroll);
    // v1.9.0：频道显示开关等设置变更 → 返回首页立即生效
    store.addListener(_onStoreChanged);
    _reset();
    // 后台补测速仅供片源弹窗展示延迟；bootstrap 已测过或用户手选过则跳过
    if (api.sources.isNotEmpty &&
        !store.manualSource &&
        store.fastSourceId < 0) {
      api.benchmarkSources(activeOnly: true).then((lat) {
        if (mounted && lat.isNotEmpty) setState(() => _latency = lat);
      });
    }
  }

  @override
  void dispose() {
    AppStore.instance.removeListener(_onStoreChanged);
    _scroll.dispose();
    super.dispose();
  }

  /// v1.9.0：设置页频道开关变化 → 频道栏立即增减；
  /// 当前频道被关闭时自动切到第一个可见频道
  /// v2.2.4：片源管理页测速 / 开关片源后（sourceRev 变化）→ 重新按优先级选源并重载，
  /// 落实「测速后首页默认为最快片源」。
  void _onStoreChanged() {
    if (!mounted) return;
    final rev = AppStore.instance.sourceRev;
    if (rev != _seenSrcRev) {
      _seenSrcRev = rev;
      _pickSource();
      _reset();
      return;
    }
    final keys = _bigCatKeys;
    if (keys.isNotEmpty && !keys.contains(_bigCat)) {
      setState(() {
        _bigCat = keys.first;
        _subIdx = 0;
      });
      _reset();
    } else {
      setState(() {});
    }
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  Future<void> _reset() async {
    _gen++; // v1.9.4：作废在途加载
    setState(() {
      _items.clear();
      _seenIds.clear();
      _seenNames.clear();
      _page = 1;
      _pagecount = 1;
      _initialError = false;
      _exhausted = false;
      _qIdx = 0;
      _tabIds = const [];
      _genericIds = const <String>{};
      _tabIdx = 0;
      _queue = MacApi.instance.feedQueue(_source, _latency);
    });
    await _buildSubTabs();
    if (!mounted) return;
    if (_subIdx >= _subTabs.length) {
      _subIdx = _subTabs.isNotEmpty ? _subTabs.length - 1 : 0;
    }
    await _selectTab(_subTabs.isNotEmpty ? _subTabs[_subIdx] : null);
    await _loadPage(force: true);
  }

  /// v1.9.1：构建当前大类的子分类 Tab —— 改为按《片源分类说明》固定清单展示，
  /// 数量与顺序严格固定，不随片源连通情况增减变化（靳老师 2026-09-21）。
  /// 加载时仍按分类名在各片源解析 type_id，解析不到自动跨源补位。
  Future<void> _buildSubTabs() async {
    // v2.2.0 v10：按频道内位次排序（聚合 Tab「福利视频」排最后），其余频道顺序不变
    final names = MacApi.sortedDocSubcats(_bigCat);
    if (!mounted) return;
    setState(() {
      _subTabs = [for (final n in names) _SubTab(n)];
    });
  }

  /// 选中某个子分类 Tab：按名称在当前源解析 type_id
  ///（解析不到为空 → 加载时自动跳到下一个片源，实现跨源补位）
  Future<void> _selectTab(_SubTab? t) async {
    if (t == null) {
      _typeId = '';
      _subName = '';
      return;
    }
    _subName = t.name;
    // v2.2.0 v10：统一解析「当前源上该 Tab 的全部 id」——
    // 聚合 Tab 取杂项清单；固定 Tab 取所有规范名等于 Tab 名的分类（可多 id）。
    // 解析不到为空 → 由加载流程跨源补位（与原逻辑一致）
    // ⚠ 变量名不能再用 t —— 会遮蔽形参 t（_SubTab），触发
    //   "Local variable 't' can't be referenced before it is declared" 编译错误
    final r = await _resolveIdsForSource(_source);
    _tabIds = r.ids;
    _genericIds = r.generic;
    _tabIdx = 0;
    _typeId = r.ids.isEmpty ? '' : r.ids.first;
  }

  /// 当前 Tab 在 [src] 上的全部 type_id：
  /// - 聚合 Tab：该源的杂项分类清单（resolveMiscIds）
  /// - 固定 Tab：该源里所有规范名等于 Tab 名的分类（resolveFeedIds，可多 id），
  ///   且当 Tab 就是频道名时**追加该分类下同频道的子分类**（v2.2.1：
  ///   修「父分类是空壳 → 分类下一片空白」）；严格匹配不到 → 回退原有单 id
  ///   解析 resolveTypeId（含「互相包含」兜底），保证「网络电影 → 电影」
  ///   这类原有宽容回退一个都不丢。
  Future<_TabIds> _resolveIdsForSource(MovieSource src) async {
    final api = MacApi.instance;
    // v2.2.3 v11：伦理一级 —— 区域二级 + 泛伦理桶（桶内条目按片名自动分派）
    if (_bigCat == 'ethics') {
      final pairs = await api.resolveEthicsIds(src, _subName);
      return _TabIds(
        [for (final p in pairs) p.id],
        {for (final p in pairs) if (p.generic) p.id},
      );
    }
    // v2.2.3 v11：纪录片 —— 源站是扁平大类，取整大类 id，条目按内容主题过滤
    if (_bigCat == 'documentary') {
      final ids = await api.resolveDocIds(src);
      return _TabIds(ids, ids.toSet());
    }
    if (_isMiscTab) return _TabIds(await api.resolveMiscIds(src, _bigCat));
    final ids = await api.resolveFeedIds(src, _bigCat, _subName);
    if (ids.isNotEmpty) return _TabIds(ids);
    final id = await api
        .resolveTypeId(src, _bigCat, _subName, fallbackFirst: false);
    return _TabIds(id.isEmpty ? const <String>[] : <String>[id]);
  }

  Future<void> _loadPage({bool force = false}) async {
    if (_loading) {
      // v1.9.4：已有加载在跑（可能是切源/切 Tab 之前的旧请求）→ 排队，
      // 旧循环因代际号失配退出后，由 finally 接力执行本次加载
      _pendingLoad = true;
      return;
    }
    if (!force && _exhausted) return;
    final myGen = _gen; // v1.9.4：本轮代际快照
    setState(() => _loading = true);
    try {
      while (mounted && !_exhausted) {
        if (_gen != myGen) return; // v1.9.4：状态已被切源/切 Tab 重置 → 本轮作废
        if (_queue.isEmpty) {
          _exhausted = true;
          break;
        }
        // 队列头部源未解析到分类 → 先按当前子分类名解析；
        // 该源没有此分类（typeId 为空）→ 跳到下一个片源
        if (_typeId.isEmpty) {
          final t = await _resolveIdsForSource(_queue[_qIdx]);
          if (t.ids.isEmpty) {
            if (!await _advanceSource()) break;
            continue;
          }
          _tabIds = t.ids;
          _genericIds = t.generic;
          _tabIdx = 0;
          _typeId = t.ids.first;
        }
        if (_page > _pagecount) {
          // v1.9.1：聚合 Tab 当前源还有杂项分类 → 继续翻该源下一个分类
          if (_tabIdx < _tabIds.length - 1) {
            // v2.2.0 v10：不只是聚合 Tab —— 固定 Tab 也可能有多个 id；
            // 当前源还有 id 就继续翻下一个，翻完才换源
            _tabIdx++;
            _typeId = _tabIds[_tabIdx];
            _page = 1;
            _pagecount = 1;
          } else {
            // 当前源已翻完 → 自动续接下一片源（无限加载）
            if (!await _advanceSource()) break;
          }
        }
        final src = _queue[_qIdx];
        // v1.7.0 采样动态校准：分类挂错牌的源（如「建安」电影分类实际是电视剧）
        // 直接跳过该源该分类，避免逐页拉取后再被过滤的浪费。
        // v2.2.1：校准用的样本页就是 page 1 —— 直接复用它，省掉「同一页请求两遍」。
        ListPage? lp;
        if (_typeId.isNotEmpty) {
          final cal = await MacApi.instance.calibrate(src, _bigCat, _typeId);
          if (cal.cat != _bigCat) {
            // v2.2.0 v10：多 id Tab 先试该源下一个 id，都判不过才换源
            if (_tabIdx < _tabIds.length - 1) {
              _tabIdx++;
              _typeId = _tabIds[_tabIdx];
              _page = 1;
              _pagecount = 1;
              continue;
            }
            if (!await _advanceSource()) break;
            continue;
          }
          if (_page == 1) lp = cal.sample;
        }
        // v2.2.1：区分「请求失败」与「空页」—— 失败先重试一次再考虑换源，
        // 避免一次网络抖动就把该片源在本 Tab 里永久跳过。
        lp ??= await MacApi.instance.listPageOrNull(src, _typeId, _page);
        lp ??= await MacApi.instance.listPageOrNull(src, _typeId, _page);
        if (lp == null) {
          if (!await _advanceSource()) break;
          continue;
        }
        if (!mounted) return;
        if (_gen != myGen) return; // v1.9.4：请求期间已切源/切 Tab → 丢弃本轮结果
        if (lp.pagecount > 0) _pagecount = lp.pagecount;
        // v1.9.9（代码审查 3.3）：分别记录本页「原始条目数」与「过滤后新增数」，
        // 用于区分空页与整页被过滤，避免误跳过当前片源剩余分页
        final rawCount = lp.items.length;
        var added = 0;
        for (final it in lp.items) {
          // v1.6.3/v1.7.0 分类混杂双重过滤：
          // ①影片自身类型名归属必须匹配；②类型名标错时用集数备注/风格标签特征兜底
          final c = MacApi.matchTopCategory(it.typeName);
          if (c != _bigCat && MacApi.inferCat(it) != _bigCat) continue;
          // v2.2.3 v11：泛伦理桶按片名分派到 4 个区域二级；
          // 纪录片（源站扁平大类）按内容主题归类。「全部」不过滤 → 不会丢内容。
          if (_genericIds.contains(_typeId)) {
            if (_bigCat == 'ethics') {
              if (MacApi.classifyEthics(it.name) != _subName) continue;
            } else if (_bigCat == 'documentary') {
              if (!MacApi.docThemeMatch(_subName, it)) continue;
            }
          }
          if (_seenIds.add('${it.sourceId}|${it.vodId}') &&
              _seenNames.add(it.name)) {
            _items.add(it);
            added++;
          }
        }
        _page++;
        // v1.5.5/v1.9.9 换源判定：
        // ①本页原始条目为 0（该源该分类无片）→ 换下一个片源；
        // ②有原始条目但全部被客户端过滤 → 继续翻当前源下一页（有效内容可能
        //   就在下一页；翻完由循环顶 _page > _pagecount 处理换源/换杂项分类）；
        // ③有新增 → 正常收手，滚动触发下一页。
        if (added == 0 && rawCount == 0) {
          // v2.2.1：当前源还有其它 type_id（同频道子分类 / 多 id 归一）→ 先试
          // 下一个 id，全部试完才换源。否则「父分类是空壳、内容全挂子分类」的源
          // 会在第一个 id 上被整源跳过，该分类下一片空白。
          if (_tabIdx < _tabIds.length - 1) {
            _tabIdx++;
            _typeId = _tabIds[_tabIdx];
            _page = 1;
            _pagecount = 1;
            continue;
          }
          if (!await _advanceSource()) break;
          continue;
        }
        if (added == 0) continue;
        break; // 每次调用只拉一页，滚动触发下一页（含跨源边界自动续接）
      }
    } finally {
      if (mounted) {
        final stale = _gen != myGen;
        setState(() {
          _loading = false;
          if (!stale && _items.isEmpty && _exhausted) _initialError = true;
        });
        // v1.9.4：排队中的新加载（切源/切 Tab 触发）在此接力执行
        if (_pendingLoad) {
          _pendingLoad = false;
          _loadPage();
        }
      }
    }
    // v1.5.7：内容不足一屏时 GridView 无法滚动，滚动监听不会触发
    // → 自动继续加载/跨源补位，直到铺满一屏或全部片源试完
    if (mounted && !_exhausted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _loading || _exhausted) return;
        if (_scroll.hasClients && _scroll.position.maxScrollExtent <= 0) {
          _loadPage();
        }
      });
    }
  }

  /// 切换到队列中下一个片源，并按子分类名称在新源中解析 type_id
  ///（同名 > 互相包含 > 大类首个分类；解析不到则跳过该源）
  Future<bool> _advanceSource() async {
    while (true) {
      _qIdx++;
      if (_qIdx >= _queue.length) {
        _exhausted = true;
        return false;
      }
      final src = _queue[_qIdx];
      final t = await _resolveIdsForSource(src);
      if (t.ids.isEmpty) continue; // 该源没有对应分类 → 跳过
      _tabIds = t.ids;
      _genericIds = t.generic;
      _tabIdx = 0;
      _typeId = t.ids.first;
      _page = 1;
      _pagecount = 1;
      return true;
    }
  }

  Future<void> _loadMore() => _loadPage();

  void _switchBigCat(String key) {
    if (key == _bigCat) return;
    setState(() {
      _bigCat = key;
      _subIdx = 0; // 切大类回到第一个子分类
    });
    _reset();
  }

  void _switchSub(int idx) {
    if (idx == _subIdx) return;
    setState(() => _subIdx = idx);
    _reset();
  }

  /// v1.9.0：切换片源不再清空已加载内容（突出内容为主），
  /// 仅把所选源提到加载队列首位 —— 后续上滑加载优先取该片源；
  /// 二级分类 Tab 为全片源并集，保持不变。
  Future<void> _switchSource(MovieSource s) async {
    Navigator.pop(context);
    // v1.3.0：测速已做但该源未连通 → 大概率需要外网/代理，切换前提示
    if (_latency.isNotEmpty && _latency[s.id] == null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('「${s.name}」可能需要外网'),
          content: const Text(
              '当前网络环境下该片源无法直连（测速未通过），可能位于境外服务器，'
              '需要连接外网/代理后才能正常使用。仍要切换到该源吗？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('仍要切换')),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    _gen++; // v1.9.4：作废在途加载 —— 此后严格从新源优先加载
    setState(() {
      _source = s;
      _queue = MacApi.instance.feedQueue(s, _latency);
      _qIdx = 0; // 下一次加载从新源开始
      _page = 1;
      _pagecount = 1;
      _exhausted = false;
      _tabIds = const []; // v1.9.1：聚合 Tab 按新源重新解析
      _genericIds = const <String>{};
      _tabIdx = 0;
      _typeId = ''; // 让加载时按新源重新解析当前子分类
    });
    AppStore.instance.lastSourceId = s.id;
    AppStore.instance.manualSource = true;
    _loadPage();
  }

  /// 片源单选弹窗：最快源置顶，显示延迟与库存（弱化片源后的备用入口）
  void _showSourcePicker() {
    final api = MacApi.instance;
    final fastId = AppStore.instance.fastSourceId;
    final list = [...api.activeSources]..sort((a, b) {
        int score(MovieSource s) {
          final l = _latency[s.id];
          if (s.id == fastId) return -1; // 最快置顶
          if (l == null) return 999999;
          return l;
        }

        return score(a).compareTo(score(b));
      });
    showModalBottomSheet(
      context: context,
      backgroundColor: context.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Icon(Icons.bolt, color: context.gold, size: 20),
                const SizedBox(width: 6),
                Text('选择片源（共 ${list.length} 个）',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: context.tMain)),
                const Spacer(),
                if (_latency.isNotEmpty)
                  Text('已测速',
                      style: TextStyle(fontSize: 11, color: context.tFaint)),
              ]),
            ),
            Flexible(
              child: RadioGroup<int>(
                groupValue: _source.id,
                onChanged: (v) {
                  final s = list.where((x) => x.id == v).firstOrNull;
                  if (s != null) _switchSource(s);
                },
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final s = list[i];
                    final sel = s.id == _source.id;
                    final l = _latency[s.id];
                    final isFast = s.id == fastId;
                    return RadioListTile<int>(
                      value: s.id,
                      activeColor: context.brand,
                      title: Row(children: [
                        Flexible(
                          child: Text(s.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: sel ? FontWeight.bold : null,
                                  color: sel ? context.tMain : context.tSub)),
                        ),
                        const SizedBox(width: 8),
                        if (isFast)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: context.gold.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text('最快',
                                style: TextStyle(
                                    fontSize: 10, color: context.gold)),
                          )
                        else if (l != null)
                          Text('${l}ms',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: l < 1000
                                      ? Colors.green
                                      : (l < 3000
                                          ? Colors.orange
                                          : Colors.red)))
                        else if (_latency.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.red.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text('需外网?',
                                style: TextStyle(
                                    fontSize: 10, color: Colors.red)),
                          ),
                      ]),
                      subtitle: s.library.isEmpty
                          ? null
                          : Text(s.library,
                              style: TextStyle(
                                  fontSize: 11, color: context.tFaint)),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openDetail(VideoItem v) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => DetailPage(item: v)));
  }

  void _openSearch() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const FullSearchPage()));
  }

  /// v2.2.3 v11：一级「其他」大类已取消（成人 / 擦边内容随之整体隐藏），
  /// 频道栏只列常规一级分类，且受「频道显示开关」控制。
  List<String> get _bigCatKeys =>
      MacApi.allBigCats.where(AppStore.instance.bigCatVisible).toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.asset('assets/icon.png', width: 28, height: 28, fit: BoxFit.cover),
          ),
          const SizedBox(width: 8),
          Text('电影世界', style: TextStyle(fontWeight: FontWeight.bold, color: context.tMain)),
        ]),
        actions: [
          // v1.2.0：右上角搜索 → 独立全文检索页（v1.9.0 检索从底部导航移到这里）
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '搜索全源',
            onPressed: _openSearch,
          ),
          // v1.9.0：片源入口弱化 —— 小号淡色按钮，不抢内容视线
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: ActionChip(
              visualDensity: VisualDensity.compact,
              avatar: Icon(Icons.swap_horiz, size: 14, color: context.tFaint),
              label: Text(_source.name,
                  style: TextStyle(fontSize: 10.5, color: context.tFaint)),
              backgroundColor: Colors.transparent,
              side: BorderSide(color: context.divider),
              onPressed: _showSourcePicker,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // 大类频道
          Container(
            height: 40,
            decoration: BoxDecoration(
              color: context.subBg,
              border: Border(bottom: BorderSide(color: context.divider)),
            ),
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              children: _bigCatKeys.map((k) {
                final sel = k == _bigCat;
                return Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: sel ? context.brand : context.tSub,
                      textStyle: TextStyle(
                          fontSize: 14,
                          fontWeight: sel ? FontWeight.bold : FontWeight.normal),
                    ),
                    onPressed: () => _switchBigCat(k),
                    child: Text(MacApi.catNames[k] ?? k),
                  ),
                );
              }).toList(),
            ),
          ),
          // 二级分类（v1.9.0：全片源并集，不随片源切换增减）
          if (_subTabs.isNotEmpty)
            SizedBox(
              height: 38,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                scrollDirection: Axis.horizontal,
                children: [
                  for (var i = 0; i < _subTabs.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(_subTabs[i].name,
                            style: TextStyle(
                                fontSize: 12,
                                color: _subIdx == i ? context.brand : context.tSub)),
                        selected: _subIdx == i,
                        selectedColor: context.brandWeak,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => _switchSub(i),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(child: _buildGrid()),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    if (_initialError && !_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const EmptyView(
              icon: Icons.wifi_off_outlined,
              message: '该分类下暂时没有找到内容，请稍后重试或换个分类',
            ),
            const SizedBox(height: 4),
            FilledButton.tonal(
              onPressed: () => _reset(),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _reset,
      child: GridView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 12,
          crossAxisSpacing: 10,
          childAspectRatio: 0.52,
        ),
        itemCount: _items.length + 1,
        itemBuilder: (context, i) {
          if (i >= _items.length) {
            return Center(
              // v1.5.0：加载提示图标与文字上下排列
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: _loading
                    ? Column(mainAxisSize: MainAxisSize.min, children: [
                        SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: context.brand)),
                        const SizedBox(height: 6),
                        Text('正在加载中…',
                            style: TextStyle(
                                fontSize: 12, color: context.tFaint)),
                      ])
                    : _exhausted
                        ? Text('全部内容加载完毕 · 共 ${_items.length} 部',
                            style: TextStyle(
                                fontSize: 12, color: context.tFaint))
                        : const SizedBox.shrink(),
              ),
            );
          }
          return PosterCard(
              item: _items[i], onTap: () => _openDetail(_items[i]));
        },
      ),
    );
  }
}
