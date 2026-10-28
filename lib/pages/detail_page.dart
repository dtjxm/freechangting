/// 详情页：信息、简介、选集、收藏、换源
library;

import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../download_service.dart';
import '../models.dart';
import '../share_card.dart';
import '../store.dart';
import '../theme.dart';
import 'player_page.dart';
import 'widgets.dart';

class DetailPage extends StatefulWidget {
  final VideoItem item;
  const DetailPage({super.key, required this.item});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late MovieSource _source;
  VideoDetail? _detail;
  bool _loading = true;
  String? _error;
  int _groupIndex = 0;
  bool _expanded = false;
  bool _switching = false;
  final List<VideoDetail> _related = []; // 其他片源的同名可播资源
  bool _loadingRelated = false;

  @override
  void initState() {
    super.initState();
    _source = MacApi.instance.sources
            .where((s) => s.id == widget.item.sourceId)
            .firstOrNull ??
        MacApi.instance.defaultSource;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final d = await MacApi.instance.detail(_source, widget.item.vodId);
    if (!mounted) return;
    if (d == null) {
      setState(() {
        _loading = false;
        _error = '加载失败，该源可能已失效，试试「换源」';
      });
      return;
    }
    // v1.5.6 续播修复：恢复上次观看的线路（分组），越界时收敛到有效线路
    final h = AppStore.instance.findHistory(d.item);
    if (h != null && d.groups.isNotEmpty) {
      var gi = h.groupIndex;
      if (gi < 0 || gi >= d.groups.length) gi = 0;
      // 该线路没有这一集 → 找包含这一集的其他线路；都没有则用第一个有效线路
      if (h.epIndex >= d.groups[gi].episodes.length) {
        var found = false;
        for (var g = 0; g < d.groups.length; g++) {
          if (h.epIndex < d.groups[g].episodes.length) {
            gi = g;
            found = true;
            break;
          }
        }
        if (!found) gi = 0;
      }
      _groupIndex = gi;
    }
    setState(() {
      _detail = d;
      _loading = false;
    });
    _loadRelated();
  }

  /// 后台并发查找其他片源的同名可播资源（逐个到位，边找边显示）
  Future<void> _loadRelated() async {
    if (_loadingRelated || widget.item.name.isEmpty) return;
    setState(() => _loadingRelated = true);
    // v2.2.4：换源/找同名只走已启用片源（与首页、检索口径一致）
    final tasks = MacApi.instance.activeSources
        .where((s) => s.id != _source.id)
        .map((s) => () async {
              final items = await MacApi.instance.search(s, widget.item.name);
              for (final it in items) {
                if (it.name == widget.item.name) {
                  final d = await MacApi.instance.detail(s, it.vodId);
                  if (d != null && d.playable && mounted) {
                    setState(() {
                      _related.removeWhere((e) => e.item.sourceId == s.id);
                      _related.add(d);
                    });
                  }
                  return;
                }
              }
            }).toList();
    try {
      await MacApi.parallel(tasks, 6).timeout(const Duration(seconds: 40));
    } catch (_) {/* 超时不影响主内容 */}
    if (mounted) setState(() => _loadingRelated = false);
  }

  void _switchToRelated(VideoDetail d) {
    final s = MacApi.instance.sources
            .where((s) => s.id == d.item.sourceId)
            .firstOrNull;
    if (s == null) return;
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => DetailPage(item: d.item)));
  }

  Future<void> _switchSource() async {
    if (_switching) return;
    setState(() => _switching = true);
    final results = await MacApi.instance
        .searchSameNameAllSources(widget.item.name, _source);
    if (!mounted) return;
    setState(() => _switching = false);
    if (results.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('其他片源暂无同名可播资源')));
      return;
    }
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('选择其他片源播放', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            ...results.map((d) => ListTile(
                  leading: const Icon(Icons.play_circle_outline),
                  title: Text(d.item.sourceName),
                  subtitle: Text(
                      '${d.item.typeName} ${d.year}｜共 ${d.groups.fold<int>(0, (a, g) => a + g.episodes.length)} 集'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    setState(() {
                      _source = MacApi.instance.sources
                              .where((s) => s.id == d.item.sourceId)
                              .firstOrNull ??
                          _source;
                    });
                    Navigator.of(context).pushReplacement(
                        MaterialPageRoute(builder: (_) => DetailPage(item: d.item)));
                  },
                )),
          ],
        ),
      ),
    );
  }

  // ===== v2.4.0 小窗播放 =====
  // PlayerPage 以 embedded 模式挂在详情页树上；GlobalKey 保证小窗 ↔ 全屏
  // 之间搬动 Widget 时 State 不重建（播放器不中断、进度不丢）。
  final GlobalKey _playerKey = GlobalKey();
  bool _playerStarted = false;
  bool _playerFullscreen = false;
  int _pGroup = 0;
  int _pEp = 0;
  Duration? _pPos;

  /// 由详情页构造内嵌播放器。每次 build 重新构造 widget 是无害的：
  /// GlobalKey 相同 → Element/State 复用，controller 不会重建。
  Widget _buildInlinePlayer() {
    final d = _detail;
    if (d == null) return const SizedBox.shrink();
    return PlayerPage(
      key: _playerKey,
      source: _source,
      detail: d,
      groupIndex: _pGroup,
      epIndex: _pEp,
      initialPosition: _pPos,
      embedded: true,
      fullscreen: _playerFullscreen,
      onExitFullscreen: () => setState(() => _playerFullscreen = false),
      onToggleFullscreen: () => setState(() => _playerFullscreen = true),
    );
  }

  void _play(int group, int ep) {
    final d = _detail!;
    // v1.5.7 续播修复：同线路同集时恢复上次播放进度（时间点），
    // 此前 initialPosition 固定传 null，只回到正确的集却从头播放
    final h = AppStore.instance.findHistory(d.item);
    Duration? pos;
    if (h != null &&
        h.groupIndex == group &&
        h.epIndex == ep &&
        h.positionSec > 30) {
      pos = Duration(seconds: h.positionSec);
    }
    // v2.4.0：不再 push 独立播放页，改为在详情页内以小窗起播；
    // 点小窗全屏按钮才铺满整屏，退出全屏回到小窗且播放不中断。
    setState(() {
      _playerStarted = true;
      _playerFullscreen = false;
      _pGroup = group;
      _pEp = ep;
      _pPos = pos;
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    // v2.4.0：全屏时拦截系统返回键 → 先退出全屏（回到小窗），不直接退出详情页
    return PopScope(
      canPop: !_playerFullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _playerFullscreen) {
          setState(() => _playerFullscreen = false);
        }
      },
      child: Stack(
        children: [
          // v2.1 收藏入口只保留按钮区一处（此前 AppBar 与按钮区各有一个，重复）
          Scaffold(
      appBar: AppBar(
        title: Text(widget.item.name, style: const TextStyle(fontSize: 17)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null || d == null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error ?? '加载失败',
                          style: TextStyle(color: context.tSub)),
                      const SizedBox(height: 12),
                      FilledButton.tonal(
                          onPressed: _switchSource, child: const Text('换源')),
                      const SizedBox(height: 8),
                      TextButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : _buildBody(d),
          ),
          if (_playerStarted && _playerFullscreen)
            Positioned.fill(child: _buildInlinePlayer()),
        ],
      ),
    );
  }

  Widget _buildBody(VideoDetail d) {
    final eps = d.groups.isNotEmpty ? d.groups[_groupIndex].episodes : const <Episode>[];
    final h = AppStore.instance.findHistory(d.item);
    final fav = AppStore.instance.isFavorite(widget.item); // v2.0 按钮区收藏态
    final resume = h != null && h.positionSec > 30 && h.epIndex < eps.length;
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        // ============ v2.2.5 上部播放区：海报 + 中央播放按钮 + 底部片名 ============
        // 用户 2026-10-15 定：纯海报 + 按钮，不加视频预览；点中央按钮直接起播。
        _buildPlayArea(d, h, resume),
        // ============ 操作条：收藏 / 下载 / 换源 / 分享（播放区正下方） ============
        _buildActionRow(d, eps, fav),
        // ============ 下部详情 ============
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTags(d),
              _buildPlot(d),
              if (d.director.isNotEmpty || d.actor.isNotEmpty)
                _buildStaff(d),
              _buildSourceSection(d, eps),
              if (d.groups.length > 1) _buildLineChips(d),
              _buildEpisodes(d, eps, h),
            ],
          ),
        ),
      ],
    );
  }

  // ============ v2.2.5 详情页改版（B 站式）============

  /// 上部播放区：黑底、海报居中、中央大播放按钮、底部片名 + 元信息。
  /// 有续播 → 中央按钮下方加「继续播放第 N 集」提示，点击从记录位置续播。
  Widget _buildPlayArea(VideoDetail d, HistoryEntry? h, bool resume) {
    // v2.4.0：已起播 → 原位换成小窗（同一 GlobalKey，滚动时跟着列表走）
    if (_playerStarted && !_playerFullscreen) {
      return SizedBox(
        height: 240,
        child: _KeepAlive(child: _buildInlinePlayer()),
      );
    }
    final meta = [
      d.item.typeName,
      if (d.year.isNotEmpty) d.year,
      if (d.area.isNotEmpty) d.area,
      if (d.item.remarks.isNotEmpty) d.item.remarks,
    ].where((e) => e.isNotEmpty).join(' · ');
    return GestureDetector(
      onTap: () => _playFromArea(d, h, resume),
      child: Container(
        height: 240,
        color: const Color(0xFF0A0C11),
        child: Stack(
          children: [
            // 中央海报（无图则显示占位图标）
            Center(
              child: d.item.pic.isNotEmpty
                  ? NetImage(d.item.pic, width: 112, height: 156,
                      fit: BoxFit.cover, borderRadius: BorderRadius.circular(10))
                  : const Icon(Icons.movie_outlined, size: 64, color: Colors.white24),
            ),
            // 中央播放按钮（续播时下方加提示）
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black38,
                      border: Border.all(color: Colors.white70, width: 2),
                    ),
                    child: const Icon(Icons.play_arrow_rounded,
                        size: 40, color: Colors.white),
                  ),
                  if (resume) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '继续播放第 ${h!.epIndex + 1} 集',
                        style: const TextStyle(fontSize: 12, color: Colors.white),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // 底部片名 + 元信息（压屏）
            Positioned(
              left: 12,
              right: 12,
              bottom: 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11.5, color: Colors.white70)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 播放区点击 → 直接起播。有续播 → 从记录集/位置续播；否则第 1 集。
  void _playFromArea(VideoDetail d, HistoryEntry? h, bool resume) {
    final eps = d.groups.isNotEmpty ? d.groups[_groupIndex].episodes : const <Episode>[];
    if (eps.isEmpty) return;
    if (resume && h != null) {
      _play(_groupIndex, h.epIndex); // _play 内部会按同线路同集恢复时间点
    } else {
      _play(_groupIndex, 0);
    }
  }

  /// 操作条：收藏 / 下载 / 换源 / 分享，四等宽。
  Widget _buildActionRow(VideoDetail d, List<Episode> eps, bool fav) {
    return Container(
      color: context.card,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: _opBtn(
                icon: fav ? Icons.favorite : Icons.favorite_border,
                label: fav ? '已收藏' : '收藏',
                on: fav,
                onTap: () async {
                  await AppStore.instance.toggleFavorite(widget.item);
                  if (mounted) setState(() {});
                }),
          ),
          Expanded(
            child: _opBtn(
                icon: Icons.download_outlined,
                label: '下载',
                on: false,
                onTap: eps.isEmpty ? null : _showDownloadSheet),
          ),
          Expanded(
            child: _opBtn(
                icon: Icons.swap_horiz,
                label: '换源',
                on: false,
                onTap: _switching ? null : _switchSource),
          ),
          Expanded(
            child: _opBtn(
                icon: Icons.share_outlined,
                label: '分享',
                on: false,
                onTap: _sharing ? null : _share),
          ),
        ],
      ),
    );
  }

  bool _sharing = false;

  /// v2.2.8 分享：生成本地「带二维码」分享卡片图，弹出动作面板。
  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      final bytes =
          await ShareService.instance.renderCard(context, widget.item);
      if (!mounted) return;
      if (bytes == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('生成分享图失败，请重试')));
        return;
      }
      await _showShareSheet(bytes);
    } catch (e) {
      // v2.2.10：分享失败给出可见提示，不再抛未捕获异步异常
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('分享失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  /// 分享动作面板：系统分享 / 复制链接。
  Future<void> _showShareSheet(Uint8List bytes) {
    return showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('分享',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('发送给好友'),
              subtitle: const Text('带二维码的分享卡片图'),
              onTap: () async {
                Navigator.of(ctx).pop();
                await ShareService.instance.shareBytes(bytes, widget.item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('复制下载链接'),
              onTap: () async {
                Navigator.of(ctx).pop();
                await ShareService.instance.copyLink();
                if (!mounted) return;
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('下载链接已复制')));
              },
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  /// 操作条单个按钮（竖排图标 + 文字，选中态橙色）
  Widget _opBtn({
    required IconData icon,
    required String label,
    required bool on,
    VoidCallback? onTap,
  }) {
    final color = on ? context.brand : context.tSub;
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(height: 3),
          Text(label, style: TextStyle(fontSize: 11, color: color)),
        ],
      ),
    );
  }

  /// 标签行：类型 / 年份 / 地区 / 状态 / 风格
  Widget _buildTags(VideoDetail d) {
    final tags = <String>[
      if (d.item.typeName.isNotEmpty) d.item.typeName,
      if (d.year.isNotEmpty) d.year,
      if (d.area.isNotEmpty) d.area,
      if (d.item.remarks.isNotEmpty) d.item.remarks,
      if (d.item.vodClass.isNotEmpty) d.item.vodClass,
    ];
    if (tags.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final t in tags)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: context.chipBg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(t, style: TextStyle(fontSize: 11.5, color: context.tSub)),
          ),
      ],
    );
  }

  /// 剧情简介：默认 3 行 + 展开全部
  Widget _buildPlot(VideoDetail d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        _secTitle('剧情简介'),
        const SizedBox(height: 6),
        if (d.content.trim().isEmpty)
          Text('暂无简介',
              style: TextStyle(fontSize: 12.5, color: context.tFaint))
        else ...[
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            behavior: HitTestBehavior.opaque,
            child: Text(
              d.content,
              maxLines: _expanded ? 200 : 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, height: 1.7, color: context.tSub),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(_expanded ? '收起' : '展开全部',
                      style: TextStyle(fontSize: 12, color: context.brand)),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16, color: context.brand),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 导演 / 主演（数据只有文字，无演员头像 → 用键值行展示）
  Widget _buildStaff(VideoDetail d) {
    final rows = <(String, String)>[
      if (d.director.isNotEmpty) ('导演', d.director),
      if (d.actor.isNotEmpty) ('主演', d.actor),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        _secTitle('演职员'),
        const SizedBox(height: 6),
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 40,
                  child: Text(k,
                      style: TextStyle(fontSize: 12, color: context.tFaint)),
                ),
                Expanded(
                  child: Text(v,
                      style: TextStyle(fontSize: 12.5, height: 1.5, color: context.tMain)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 片源区：当前源 + 换源下拉
  Widget _buildSourceSection(VideoDetail d, List<Episode> eps) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: _secTitle('播放片源')),
            Text('共 ${_related.length + 1} 个源可用',
                style: TextStyle(fontSize: 11, color: context.tFaint)),
          ],
        ),
        const SizedBox(height: 6),
        DropdownButton<int>(
          value: widget.item.sourceId,
          isExpanded: true,
          underline: Container(height: 1, color: context.divider),
          items: [
            DropdownMenuItem(
              value: widget.item.sourceId,
              child: Text('${_source.name}（当前｜${eps.length}集）',
                  style: const TextStyle(fontSize: 13)),
            ),
            ..._related.map((r) => DropdownMenuItem(
                  value: r.item.sourceId,
                  child: Text(
                      '${r.item.sourceName}｜${r.groups.fold<int>(0, (a, g) => a + g.episodes.length)}集',
                      style: const TextStyle(fontSize: 13)),
                )),
          ],
          onChanged: (id) {
            if (id == null || id == widget.item.sourceId) return;
            final r =
                _related.where((e) => e.item.sourceId == id).firstOrNull;
            if (r != null) _switchToRelated(r);
          },
        ),
      ],
    );
  }

  /// 线路选择（多线路时才显示）
  Widget _buildLineChips(VideoDetail d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        _secTitle('线路'),
        const SizedBox(height: 6),
        SizedBox(
          height: 34,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: d.groups.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, i) => ChoiceChip(
              label: Text(d.groups[i].from.isEmpty
                  ? '线路${i + 1}'
                  : d.groups[i].from),
              selected: i == _groupIndex,
              onSelected: (_) => setState(() => _groupIndex = i),
            ),
          ),
        ),
      ],
    );
  }

  /// 选集
  Widget _buildEpisodes(VideoDetail d, List<Episode> eps, HistoryEntry? h) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: _secTitle('选集')),
            Text('共 ${eps.length} 集',
                style: TextStyle(fontSize: 11, color: context.tFaint)),
          ],
        ),
        const SizedBox(height: 8),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 2.2,
          ),
          itemCount: eps.length,
          itemBuilder: (_, i) {
            final resume = h != null && h.epIndex == i && h.positionSec > 30;
            final dl = DownloadService.instance
                .taskOf(d.item.sourceId, d.item.vodId, i);
            final dlDone = dl?.state == 'done';
            return OutlinedButton(
              onPressed: () => _play(_groupIndex, i),
              style: OutlinedButton.styleFrom(
                padding: EdgeInsets.zero,
                side: BorderSide(
                    color: resume ? context.gold : context.divider),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Text(
                    resume ? '▶ ${eps[i].name}' : eps[i].name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (dlDone)
                    Positioned(
                      top: 1,
                      right: 2,
                      child: Icon(Icons.download_done,
                          size: 13, color: context.brand),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  /// 小节标题（橙色竖条前缀，与设计图一致）
  Widget _secTitle(String t) {
    return Row(
      children: [
        Container(width: 3, height: 14, color: context.brand,
            margin: const EdgeInsets.only(right: 6)),
        Text(t,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
      ],
    );
  }

  /// v1.6.0：多选集数批量下载（当前线路）
  Future<void> _showDownloadSheet() async {
    final d = _detail!;
    final eps = d.groups[_groupIndex].episodes;
    final svc = DownloadService.instance;
    final sel = <int>{};
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 8, 4),
                child: Row(children: [
                  const Text('选择要下载的集数',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setSt(() {
                      if (sel.length == eps.length) {
                        sel.clear();
                      } else {
                        sel.addAll(List.generate(eps.length, (i) => i));
                      }
                    }),
                    child: Text(sel.length == eps.length ? '取消全选' : '全选'),
                  ),
                ]),
              ),
              Flexible(
                child: GridView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 2.4,
                  ),
                  itemCount: eps.length,
                  itemBuilder: (_, i) {
                    final exist =
                        svc.taskOf(d.item.sourceId, d.item.vodId, i);
                    final blocked = exist != null && exist.state != 'failed';
                    final checked = sel.contains(i);
                    return InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: blocked
                          ? null
                          : () => setSt(() {
                                checked ? sel.remove(i) : sel.add(i);
                              }),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: blocked
                                  ? context.divider
                                  : checked
                                      ? context.brand
                                      : context.divider,
                              width: checked ? 1.5 : 1),
                          color: checked
                              ? context.brand.withValues(alpha: 0.10)
                              : null,
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          blocked
                              ? (exist.state == 'done' ? '已下载' : '下载中')
                              : eps[i].name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11.5,
                              color: blocked
                                  ? context.tFaint
                                  : context.tMain),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: context.brand,
                        foregroundColor: Colors.white),
                    onPressed: sel.isEmpty
                        ? null
                        : () async {
                            final newTasks = sel
                                .map((i) => DownloadTask(
                                      id:
                                          '${d.item.sourceId}|${d.item.vodId}|$_groupIndex|$i',
                                      sourceId: d.item.sourceId,
                                      sourceName: d.item.sourceName,
                                      vodId: d.item.vodId,
                                      movieName: d.item.name,
                                      groupIndex: _groupIndex,
                                      groupName:
                                          d.groups[_groupIndex].from,
                                      epIndex: i,
                                      epName: eps[i].name,
                                      url: eps[i].url,
                                      subcat: d.item.typeName, // v1.9.8 软件二级分类
                                    ))
                                .toList();
                            final messenger = ScaffoldMessenger.of(ctx);
                            final n = await DownloadService.instance
                                .addTasks(newTasks);
                            if (!ctx.mounted) return;
                            Navigator.pop(ctx);
                            if (!mounted) return;
                            setState(() {});
                            messenger.showSnackBar(
                              SnackBar(
                                  content: Text(n > 0
                                      ? '已加入 $n 集下载任务，可在「我的-下载」查看进度'
                                      : '所选集数已在下载列表中')),
                            );
                          },
                    child: Text('下载所选（${sel.length}）'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// v2.4.0：小窗播放器必须常驻，不能被 ListView 回收。
///
/// 详情页是长列表，滚动到简介/剧集区时播放区会滑出视口；ListView 默认会销毁
/// 不可见子项 —— 那会让 PlayerPage 被 dispose、视频直接停掉。这里用
/// AutomaticKeepAlive 让它在整个详情页生命周期内保持挂载。
class _KeepAlive extends StatefulWidget {
  final Widget child;
  const _KeepAlive({required this.child});

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
