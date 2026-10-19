/// 独立全文检索页（v1.2.1 贴合设计稿）：搜索框 + 搜索历史 + 热门影片实时榜 + 全源并发搜索去重
/// v1.7.0：输入联想（历史/本地片库/拼音首字母）+ 结果分级排序 + 同名多源聚合
library;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:lpinyin/lpinyin.dart';

import '../api.dart';
import '../models.dart';
import '../store.dart';
import '../theme.dart';
import 'detail_page.dart';
import 'widgets.dart';

class FullSearchPage extends StatefulWidget {
  final String? initialQuery;
  const FullSearchPage({super.key, this.initialQuery});

  @override
  State<FullSearchPage> createState() => _FullSearchPageState();
}

class _FullSearchPageState extends State<FullSearchPage> {
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _searching = false;
  String _query = '';
  int _done = 0;
  int _failed = 0; // 连接失败的片源数
  final int _total = MacApi.instance.activeSources.length; // v2.2.4：不含已停用片源
  final List<VideoItem> _results = []; // 每个片名一个代表条目
  final Map<String, List<VideoItem>> _byName = {}; // 同名聚合：片名 -> 各源条目
  final Map<String, int> _rank = {}; // 片名 -> 分级（0 精确 1 前缀 2 包含 3 演员）

  // 热门影片（基于片源实时数据）
  List<VideoItem> _hot = [];

  @override
  void initState() {
    super.initState();
    AppStore.instance.addListener(_onChange);
    _loadHot();
    final q = widget.initialQuery?.trim() ?? '';
    if (q.isNotEmpty) {
      _ctrl.text = q;
      WidgetsBinding.instance.addPostFrameCallback((_) => _search(q));
    } else {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => FocusScope.of(context).requestFocus(_focus));
    }
  }

  @override
  void dispose() {
    AppStore.instance.removeListener(_onChange);
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {}); // 搜索历史变化时刷新
  }

  /// 热门影片：取默认最快片源第一页，按更新时间排序取前 8（与设计稿一致）
  Future<void> _loadHot() async {
    final store = AppStore.instance;
    final src = MacApi.instance.activeSources
            .where((s) => s.id == store.fastSourceId)
            .firstOrNull ??
        MacApi.instance.activeSources
            .where((s) => s.id == store.lastSourceId)
            .firstOrNull ??
        MacApi.instance.defaultSource;
    try {
      final items = await MacApi.instance
          .listByCategory(src, '', 1)
          .timeout(const Duration(seconds: 12));
      if (!mounted || items.isEmpty) return;
      items.sort((a, b) => b.time.compareTo(a.time));
      setState(() => _hot = items.take(8).toList());
    } catch (_) {/* 热门榜加载失败不影响搜索 */}
  }

  // ---------- v1.7.0 输入联想 ----------
  /// 本地片名池：搜索历史 + 收藏 + 观看历史 + 热门榜
  Set<String> get _titlePool {
    final store = AppStore.instance;
    return {
      ...store.searchHistory,
      ...store.favorites.map((e) => e.name),
      ...store.history.map((e) => e.item.name),
      ..._hot.map((e) => e.name),
    }.where((n) => n.trim().isNotEmpty).toSet();
  }

  bool _isAscii(String s) => RegExp(r'^[a-zA-Z0-9\s]+$').hasMatch(s);

  /// 拼音匹配：全拼或首字母包含关键词（大小写不敏感）
  bool _pinyinHit(String title, String q) {
    try {
      final full = PinyinHelper.getPinyinE(title, separator: '').toLowerCase();
      if (full.contains(q)) return true;
      final short = PinyinHelper.getShortPinyin(title).toLowerCase();
      return short.contains(q);
    } catch (_) {
      return false;
    }
  }

  List<String> get _suggestions {
    final q = _ctrl.text.trim();
    if (q.isEmpty) return const [];
    final pool = _titlePool..remove(q);
    final out = <String>[];
    // 1) 直接包含（历史/片库）
    for (final t in pool) {
      if (t.toLowerCase().contains(q.toLowerCase())) out.add(t);
      if (out.length >= 8) break;
    }
    // 2) 纯字母输入 → 拼音/首字母匹配
    if (_isAscii(q) && q.contains(RegExp(r'[a-zA-Z]'))) {
      for (final t in pool) {
        if (out.contains(t)) continue;
        if (_pinyinHit(t, q.toLowerCase())) out.add(t);
        if (out.length >= 8) break;
      }
    }
    return out;
  }

  Future<void> _search(String wd) async {
    if (wd.isEmpty || _searching) return;
    _focus.unfocus();
    AppStore.instance.addSearchHistory(wd);
    setState(() {
      _searching = true;
      _query = wd;
      _results.clear();
      _byName.clear();
      _rank.clear();
      _done = 0;
      _failed = 0;
    });
    // 默认全源并发检索（不含已停用源）：当前源没有的（如喜剧片），其他源有也能搜出来
    final kw = wd.trim().toLowerCase();
    final tasks = MacApi.instance.activeSources
        .map((s) => () async {
          final items = await MacApi.instance.searchOrNull(s, wd);
          if (!mounted) return;
          if (items == null) {
            setState(() {
              _done++;
              _failed++;
            });
            return;
          }
          setState(() {
            _done++;
            for (final it in items.take(40)) {
              // v2.2.3 v11：一级「其他」大类已取消（成人 / 擦边内容整体隐藏），
              // 检索结果里也一并剔除；伦理频道未开启时同样不展示。
              final cat = MacApi.matchTopCategory(it.typeName);
              if (cat == 'other') continue;
              if (cat == 'ethics' && !AppStore.instance.bigCatVisible('ethics')) {
                continue;
              }
              // v1.7.0 结果分级：0 精确同名 / 1 片名前缀 / 2 片名包含 / 3 主演命中
              final name = it.name.toLowerCase();
              int rank;
              if (name == kw) {
                rank = 0;
              } else if (name.startsWith(kw)) {
                rank = 1;
              } else if (name.contains(kw)) {
                rank = 2;
              } else if (it.actor.toLowerCase().contains(kw) ||
                  it.director.toLowerCase().contains(kw)) {
                rank = 3; // v1.7.0 演职员搜索；v1.9.5 导演字段独立命中
              } else {
                continue; // 片名与演员都不沾边 → 剔除无关结果
              }
              // v1.7.0 同名聚合：所有源的同名影片归并到同一张卡
              final list = _byName.putIfAbsent(it.name, () => []);
              final oldRank = _rank[it.name];
              if (oldRank == null) {
                _byName[it.name] = [it];
                _rank[it.name] = rank;
                _results.add(it);
              } else {
                list.add(it);
                if (rank < oldRank) {
                  // 后到的源分级更高 → 换为代表条目
                  _rank[it.name] = rank;
                  final idx = _results.indexWhere((e) => e.name == it.name);
                  if (idx >= 0) _results[idx] = it;
                }
              }
            }
          });
        }).toList();
    await MacApi.parallel(tasks, 8);
    if (!mounted) return;
    setState(() {
      // v1.7.0 检索完成后按分级统一排序（精确匹配优先）
      _results.sort((a, b) =>
          (_rank[a.name] ?? 9).compareTo(_rank[b.name] ?? 9));
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: _searchField(),
        actions: [
          TextButton(
            onPressed: () => _search(_ctrl.text.trim()),
            child: const Text('搜索'),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _query.isEmpty ? _buildIdle() : _buildResults(),
    );
  }

  Widget _searchField() => Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: context.chipBg,
          borderRadius: BorderRadius.circular(19),
        ),
        child: Row(
          children: [
            Icon(Icons.search, size: 19, color: context.tSub),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                autofocus: false,
                style: TextStyle(fontSize: 14.5, color: context.tMain),
                textInputAction: TextInputAction.search,
                onChanged: (_) => setState(() {}), // v1.7.0 实时刷新输入联想
                onSubmitted: (v) => _search(v.trim()),
                decoration: InputDecoration(
                  hintText: '搜索全源影视',
                  hintStyle: TextStyle(fontSize: 13.5, color: context.tFaint),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            if (_ctrl.text.isNotEmpty)
              GestureDetector(
                onTap: () => setState(() {
                  _ctrl.clear();
                  _query = '';
                  _results.clear();
                }),
                child: Icon(Icons.cancel, size: 17, color: context.tFaint),
              ),
          ],
        ),
      );

  // ---------- 未搜索：输入联想 + 历史 + 热门榜 ----------
  Widget _buildIdle() {
    final his = AppStore.instance.searchHistory;
    final sug = _suggestions;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      children: [
        if (sug.isNotEmpty) ...[
          _seclabel('💡 猜你想搜', trailing: '支持拼音 / 首字母'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final w in sug)
                GestureDetector(
                  onTap: () {
                    _ctrl.text = w;
                    _search(w);
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: context.chipBg,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(w,
                        style: TextStyle(
                            fontSize: 12.5, color: context.tMain)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        if (his.isNotEmpty) ...[
          _seclabel('🕐 搜索历史', trailing: '🗑 清空',
              onTrailing: () => AppStore.instance.clearSearchHistory()),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final w in his)
                GestureDetector(
                  onTap: () {
                    _ctrl.text = w;
                    _search(w);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: context.chipBg,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(w, style: TextStyle(fontSize: 12.5, color: context.tSub)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        if (_hot.isNotEmpty) ...[
          _seclabel('🔥 热门影片', trailing: '基于片源实时数据'),
          const SizedBox(height: 4),
          for (var i = 0; i < _hot.length; i++) _hotItem(i),
        ],
        const SizedBox(height: 14),
        Text('输入关键词后：全源并发检索，按片名去重展示',
            style: TextStyle(fontSize: 12, color: context.brand)),
      ],
    );
  }

  Widget _seclabel(String text, {String? trailing, VoidCallback? onTrailing}) => Row(
        children: [
          Text(text,
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: context.tMain)),
          const Spacer(),
          GestureDetector(
            onTap: onTrailing,
            child: Text(trailing ?? '',
                style: TextStyle(fontSize: 12, color: context.tFaint)),
          ),
        ],
      );

  Widget _hotItem(int i) {
    final v = _hot[i];
    final remark = v.remarks;
    final isNew = remark.contains('更新') || remark.contains('抢先');
    final isHot = !isNew && i < 3;
    return InkWell(
      onTap: () {
        _ctrl.text = v.name;
        _search(v.name);
      },
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Text('${i + 1}',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      fontStyle: FontStyle.italic,
                      color: i < 3 ? context.gold : context.tFaint)),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(v.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: context.tMain)),
            ),
            if (isHot || isNew) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: (isHot ? context.brand : context.gold).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(isHot ? '热' : '新',
                    style: TextStyle(
                        fontSize: 10, color: isHot ? context.brand : context.gold)),
              ),
            ],
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 130),
              child: Text(
                [if (v.typeName.isNotEmpty) v.typeName, if (remark.isNotEmpty) remark]
                    .join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: context.tFaint),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 结果 ----------
  Widget _buildResults() {
    if (_results.isEmpty && _searching) return _buildProgress();
    if (_results.isEmpty) {
      // v1.4.5：空结果只显示图标 + 提示，不展示其他无关内容
      return Center(
        child: const EmptyView(icon: Icons.search_off, message: '没有检索内容'),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '已从 $_total 个片源检索并去重，找到 ${_results.length} 部影片${_searching ? '（搜索中 $_done/$_total）' : ''}${_failed > 0 && !_searching ? '，$_failed 个片源未连通' : ''}',
              style: TextStyle(fontSize: 12, color: context.tFaint),
            ),
          ),
        ),
        Expanded(
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.52,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) {
                      final it = _results[i];
                      final n = _byName[it.name]?.length ?? 1;
                      return Stack(
                        children: [
                          PosterCard(
                            item: it,
                            onTap: () => _openAggregated(it),
                          ),
                          // v1.7.0 同名聚合：多源可播角标
                          if (n > 1)
                            Positioned(
                              right: 4,
                              top: 4,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.65),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text('$n源',
                                    style: const TextStyle(
                                        fontSize: 10, color: Colors.white)),
                              ),
                            ),
                        ],
                      );
                    },
                    childCount: _results.length,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// v1.7.0：打开同名聚合影片 —— 多源时弹出「选片源」列表，单源直接进详情
  void _openAggregated(VideoItem it) {
    final variants = _byName[it.name] ?? [it];
    if (variants.length <= 1) {
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => DetailPage(item: it)));
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: context.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text('《${it.name}》· ${variants.length} 个片源可播',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: context.tMain)),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: variants.length,
                itemBuilder: (_, i) {
                  final v = variants[i];
                  return ListTile(
                    dense: true,
                    leading: Icon(Icons.play_circle_outline,
                        size: 20, color: context.brand),
                    title: Text(v.sourceName,
                        style:
                            TextStyle(fontSize: 14, color: context.tMain)),
                    subtitle: Text(
                      [v.typeName, v.remarks].where((s) => s.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: context.tFaint),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => DetailPage(item: v)));
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgress() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: context.brand),
            const SizedBox(height: 14),
            Text('正在搜索全源 $_done/$_total …',
                style: TextStyle(color: context.tSub, fontSize: 12.5)),
          ],
        ),
      );
}
