/// v1.3.0 观看历史独立页（「我的」二级入口）
library;

import 'package:flutter/material.dart';

import '../api.dart';
import '../download_service.dart';
import '../models.dart';
import '../store.dart';
import '../theme.dart';
import 'player_page.dart';
import 'widgets.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  @override
  void initState() {
    super.initState();
    AppStore.instance.addListener(_onChange);
    // v2.2.4：本地条目要按下载记录取文件路径 —— 下载列表变动（删除/找回）也跟着刷新
    DownloadService.instance.addListener(_onChange);
  }

  @override
  void dispose() {
    AppStore.instance.removeListener(_onChange);
    DownloadService.instance.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  MovieSource? _sourceOf(VideoItem v) {
    for (final s in MacApi.instance.sources) {
      if (s.id == v.sourceId) return s;
    }
    return null;
  }

  /// v2.2.4：本地条目（sourceId == -1）的可播路径。
  /// - `local_<任务id>`  → 下载成片：按任务 id 从下载服务取 savedPath
  /// - `external_<uri>`  → 外部文件（分享/「打开方式」进入）
  /// 返回 null 表示文件记录已不存在（下载已被删除 / 任务记录丢失）。
  static String? _localPathOf(VideoItem v) {
    if (v.sourceId != LocalKeys.localSourceId) return null;
    final ext = LocalKeys.externalUriOf(v.vodId);
    if (ext != null) return ext.isEmpty ? null : ext;
    final taskId = LocalKeys.taskIdOf(v.vodId);
    if (taskId == null) return null;
    for (final t in DownloadService.instance.tasks) {
      if (t.id == taskId) {
        final p = t.savedPath;
        return (p == null || p.isEmpty) ? null : p;
      }
    }
    return null;
  }

  static String _fmtTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  static String _fmtDur(int sec) {
    final h = sec ~/ 3600, m = (sec % 3600) ~/ 60, s = sec % 60;
    if (h > 0) return '$h时$m分';
    return '$m分${s.toString().padLeft(2, '0')}秒';
  }

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('观看历史'),
        actions: [
          if (store.history.isNotEmpty)
            TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('清空观看历史？'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清空')),
                    ],
                  ),
                );
                if (ok == true) await store.clearHistory();
              },
              child: const Text('清空'),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: _buildHistory(store),
    );
  }

  Widget _buildHistory(AppStore store) {
    final his = store.history;
    if (his.isEmpty) return const EmptyView(icon: Icons.history, message: '暂无观看记录');
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      itemCount: his.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final h = his[i];
        // v2.2.4：本地视频（下载成片 / 外部文件）sourceId == -1，不在片源表里，
        // 单独解析本地路径 —— 观看历史里也能续播并定位到记录位置。
        final isLocal = h.item.sourceId == LocalKeys.localSourceId;
        final localPath = _localPathOf(h.item);
        final src = isLocal
            ? const MovieSource(
                id: LocalKeys.localSourceId, name: '本地', url: '')
            : _sourceOf(h.item);
        final gone = isLocal
            ? (localPath == null || localPath.isEmpty)
            : src == null;
        return Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            leading: NetImage(h.item.pic,
                width: 52, height: 72, borderRadius: BorderRadius.circular(8)),
            title: Text(h.item.name,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: Text(
              '${h.epName} · 已看 ${_fmtDur(h.positionSec)} · ${_fmtTime(h.updatedAt)}'
              '${isLocal ? ' · 本地' : ''}'
              '${gone ? (isLocal ? ' · 文件已丢失' : ' · 片源已不存在') : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: context.tFaint),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => store.removeHistory(h),
            ),
            onTap: () async {
              // 记录进度 → 续播定位（本地 / 在线一致）
              final start =
                  h.positionSec > 0 ? Duration(seconds: h.positionSec) : null;
              if (isLocal) {
                final path = localPath;
                if (path == null || path.isEmpty) {
                  _toast('本地文件已丢失，无法播放（可能已在下载管理中删除）');
                  return;
                }
                // 本地条目：用文件路径直接重建播放详情，不走片源详情接口
                final detail = VideoDetail(
                  item: h.item,
                  groups: [
                    PlayGroup('本地', [Episode(h.epName, path)]),
                  ],
                );
                if (!mounted) return;
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => PlayerPage(
                    source: const MovieSource(
                        id: LocalKeys.localSourceId, name: '本地', url: ''),
                    detail: detail,
                    groupIndex: 0,
                    epIndex: 0,
                    initialPosition: start,
                  ),
                ));
                return;
              }
              if (src == null) return;
              // 有进度直接进播放器续播
              final detail = await MacApi.instance.detail(src, h.item.vodId) ??
                  VideoDetail(item: h.item);
              if (!mounted) return;
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => PlayerPage(
                  source: src,
                  detail: detail,
                  groupIndex: 0,
                  epIndex: h.epIndex,
                  initialPosition: start,
                ),
              ));
            },
          ),
        );
      },
    );
  }
}
