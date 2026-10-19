/// 最新更新：聚合所有启用片源第一页的最近更新影片，按更新时间倒序。
/// v2.2.9 新增（用户需求：底部导航增加「最新」）。
library;

import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'detail_page.dart';
import 'widgets.dart';

class LatestPage extends StatefulWidget {
  /// 是否正处于前台 Tab。首次切到「最新」时才发请求，避免启动时
  /// 同时对几十个片源发 40+ 个请求、和首页抢带宽。
  final bool active;

  const LatestPage({super.key, required this.active});

  @override
  State<LatestPage> createState() => _LatestPageState();
}

class _LatestPageState extends State<LatestPage> {
  List<VideoItem> _items = const [];
  bool _loading = true;
  bool _loadedOnce = false;
  int _sourceCount = 0;

  @override
  void initState() {
    super.initState();
    if (widget.active) _load();
  }

  @override
  void didUpdateWidget(covariant LatestPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 首次切到本 Tab 才加载；之后切走再回来保留已有结果，不重复请求
    if (widget.active && !oldWidget.active && !_loadedOnce && !_loading) {
      _load();
    }
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    List<VideoItem> raw;
    try {
      raw = await MacApi.instance.latestAll();
    } catch (_) {
      raw = const [];
    }
    if (!mounted) return;

    // 同名影片跨源只留更新时间最新的一条；时间相同优先有海报的。
    final byName = <String, VideoItem>{};
    final times = <String, DateTime?>{};
    for (final it in raw) {
      final key = _normName(it.name);
      if (key.isEmpty) continue;
      final t = _parseTime(it.time);
      final old = byName[key];
      if (old == null) {
        byName[key] = it;
        times[key] = t;
        continue;
      }
      final ot = times[key];
      final newer = (t?.millisecondsSinceEpoch ?? 0) >
          (ot?.millisecondsSinceEpoch ?? 0);
      if (newer || (t == ot && old.pic.isEmpty && it.pic.isNotEmpty)) {
        byName[key] = it;
        times[key] = t;
      }
    }

    final list = byName.values.toList()
      ..sort((a, b) {
        final ta = _parseTime(a.time)?.millisecondsSinceEpoch ?? 0;
        final tb = _parseTime(b.time)?.millisecondsSinceEpoch ?? 0;
        if (ta != tb) return tb.compareTo(ta);
        // 没有时间的排最后，再按片名稳定排序
        return a.name.compareTo(b.name);
      });

    setState(() {
      _items = list;
      _sourceCount = list.map((e) => e.sourceId).toSet().length;
      _loading = false;
      _loadedOnce = true;
    });
  }

  static String _normName(String s) => s
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\-_:：·•|/\\]+'), '');

  /// 兼容 `2026-10-19 22:00:00` / `2026/10/19` / 秒级或毫秒级时间戳。
  static DateTime? _parseTime(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final m =
        RegExp(r'(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})').firstMatch(s);
    if (m != null) {
      final y = int.tryParse(m.group(1)!);
      final mo = int.tryParse(m.group(2)!);
      final d = int.tryParse(m.group(3)!);
      if (y == null || mo == null || d == null) return null;
      var h = 0, mi = 0, sec = 0;
      final hm = RegExp(r'(\d{1,2}):(\d{2})(?::(\d{2}))?')
          .firstMatch(s.substring(m.end));
      if (hm != null) {
        h = int.tryParse(hm.group(1)!) ?? 0;
        mi = int.tryParse(hm.group(2)!) ?? 0;
        sec = int.tryParse(hm.group(3) ?? '') ?? 0;
      }
      return DateTime(y, mo, d, h, mi, sec);
    }
    final n = int.tryParse(s);
    if (n != null && n > 0) {
      // 10 位为秒，13 位为毫秒
      return DateTime.fromMillisecondsSinceEpoch(n < 100000000000 ? n * 1000 : n);
    }
    return null;
  }

  static String _shortDate(String raw) {
    final t = _parseTime(raw);
    if (t == null) return '';
    final now = DateTime.now();
    final mm = t.month.toString().padLeft(2, '0');
    final dd = t.day.toString().padLeft(2, '0');
    if (t.year == now.year) return '$mm-$dd';
    return '${t.year}-$mm-$dd';
  }

  void _open(VideoItem item) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => DetailPage(item: item)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('最新更新'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadedOnce && _items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const EmptyView(
              icon: Icons.new_releases_outlined,
              message: '暂时没有拿到各片源的最新更新，请稍后重试',
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
            child: Row(
              children: [
                Icon(Icons.update, size: 16, color: context.brand),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '按更新时间排序 · ${_items.length} 部 · $_sourceCount 个片源',
                    style: TextStyle(fontSize: 12, color: context.tSub),
                  ),
                ),
                if (_loading)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: context.brand),
                  ),
              ],
            ),
          ),
          Expanded(
            child: GridView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 12,
                crossAxisSpacing: 10,
                childAspectRatio: 0.52,
              ),
              itemCount: _items.length,
              itemBuilder: (context, i) {
                final it = _items[i];
                final d = _shortDate(it.time);
                return PosterCard(
                  item: it,
                  badge: d.isEmpty ? null : d,
                  onTap: () => _open(it),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
