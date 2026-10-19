/// v1.9.8 下载管理页改版（靳老师 2026-09-23 八条需求）：
/// - 卡片：状态徽章 / 软件二级分类标签 / 友好路径 / 完成时间+大小
/// - 按钮收纳：每卡只留主按钮，其余操作进「⋮」菜单
/// - 批量操作：右上「管理」或长按卡片进入多选，底部批量栏（全选/重试所选/删除）
/// - 删除带结果反馈：文件删不掉会明确提示
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../download_service.dart';
import '../models.dart';
import '../store.dart';
import '../theme.dart';
import 'player_page.dart';

class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key});

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  bool _selectMode = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    DownloadService.instance.addListener(_onChange);
    DownloadService.instance.pump(); // 进入页面确保队列在跑
  }

  @override
  void dispose() {
    DownloadService.instance.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  // ---------- v1.9.8 展示辅助 ----------

  /// 友好路径：全部文件/Movies/电影世界/片名/集名.mp4（超长自动省略号）
  String _friendlyPath(DownloadTask t) {
    final ep = t.epName.isEmpty ? '第${t.epIndex + 1}集' : t.epName;
    return '全部文件/Movies/电影世界/${t.movieName}/$ep.mp4';
  }

  /// v1.9.8 完成时间：今天/昨天/M月d日
  String _fmtDoneAt(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(d.year, d.month, d.day);
    final hm =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final diff = today.difference(that).inDays;
    if (diff == 0) return '今天 $hm 完成';
    if (diff == 1) return '昨天 $hm 完成';
    return '${d.month}月${d.day}日 $hm 完成';
  }

  String _fmtBytes(int b) {
    if (b <= 0) return '';
    if (b < 1 << 20) return '${(b / (1 << 10)).toStringAsFixed(0)}KB';
    if (b < 1 << 30) return '${(b / (1 << 20)).toStringAsFixed(1)}MB';
    return '${(b / (1 << 30)).toStringAsFixed(2)}GB';
  }

  String _fmtSpeed(double bps) {
    if (bps <= 0) return '-';
    if (bps < 1 << 20) return '${bps.toStringAsFixed(0)}KB/s';
    return '${(bps / (1 << 20)).toStringAsFixed(1)}MB/s';
  }

  String _fmtDur(int s) {
    if (s <= 0) return '-';
    if (s < 60) return '${s}s';
    if (s < 3600) return '${s ~/ 60}分${s % 60}秒';
    return '${s ~/ 3600}时${(s % 3600) ~/ 60}分';
  }

  String _statsText(DownloadTask t) {
    final total = t.bytesTotal > 0
        ? '${_fmtBytes(t.bytesDone)}/${_fmtBytes(t.bytesTotal)}'
        : _fmtBytes(t.bytesDone);
    final speed = t.state == 'running' ? ' ｜ ${_fmtSpeed(t.speedBps)}' : '';
    final elapsed = t.elapsedSec > 0 ? ' ｜ 已用${_fmtDur(t.elapsedSec)}' : '';
    final eta = t.state == 'running' && t.etaSec > 0
        ? ' ｜ 剩余约${_fmtDur(t.etaSec)}'
        : '';
    return '$total$speed$elapsed$eta';
  }

  String _stateText(DownloadTask t) => switch (t.state) {
        'waiting' => '等待中',
        'running' => '下载中 ${(t.progress * 100).toStringAsFixed(0)}%',
        'merging' => '合并保存中…',
        'paused' => '已暂停',
        'done' => '已完成',
        _ => '下载失败',
      };

  /// v1.6.2 失败原因转成非技术人员能看懂的中文
  String _friendlyError(DownloadTask t) {
    final e = t.error ?? '';
    if (e.contains('下载内容不完整')) {
      return '该线路视频已失效（内容不完整），建议重试（会自动换线路）';
    }
    if (e.contains('Failed host lookup') ||
        e.contains('SocketException') ||
        e.contains('Connection refused') ||
        e.contains('Network is unreachable')) {
      return '网络连接失败，请检查手机网络后重试';
    }
    if (e.contains('Timeout') || e.contains('超时')) {
      return '连接超时，片源响应太慢，建议稍后重试';
    }
    if (e.contains('加密') || e.contains('密钥') || e.contains('解密')) {
      // v2.1 普通加密（AES-128）已支持；走到这里的多为 SAMPLE-AES 等罕见加密
      return '该影片的加密方式暂不支持下载，建议重试（会自动换线路）';
    }
    if (e.contains('HTTP')) {
      return '片源服务器返回错误，该线路可能已失效，建议重试（会自动换线路）';
    }
    if (e.contains('清单获取失败') || e.contains('清单中没有分段')) {
      return '片源视频地址已失效，建议重试（会自动换线路）';
    }
    if (e.contains('分段') && (e.contains('失败') || e.contains('缺失'))) {
      return '视频分段下载不完整，建议重试';
    }
    if (e.contains('合并失败') || e.contains('合并输出为空')) {
      return '视频合成失败，建议重试';
    }
    if (e.contains('存储权限') || e.contains('保存到 Movies')) {
      return '保存失败：未获得存储权限或手机存储空间不足';
    }
    if (e.contains('为空')) {
      return '下载的内容为空，该线路可能已失效';
    }
    return '下载出错，建议重试（会自动换线路）或删除后重新添加';
  }

  Color _stateColor(BuildContext context, DownloadTask t) => switch (t.state) {
        'done' => const Color(0xFF0F6E56),
        'failed' => Colors.redAccent,
        'running' || 'merging' => context.brand,
        _ => context.tFaint,
      };

  // ---------- v1.9.8 删除（带结果反馈） ----------

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 「⋮」更多菜单：预览 / 删除本集视频文件（推荐） / 删除整部影片 / 仅移除记录
  Future<void> _moreMenu(DownloadTask t) async {
    final hasFile = t.savedPath != null;
    final sameMovie = DownloadService.instance.tasks
        .where((x) => x.movieName == t.movieName)
        .length;
    final mode = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
                padding: const EdgeInsets.all(14),
                child: Text('「${t.movieName} · ${t.epName.isEmpty ? '第${t.epIndex + 1}集' : t.epName}」',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold))),
            if ((t.state == 'running' || t.state == 'paused'))
              ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: const Text('预览已下载部分'),
                onTap: () => Navigator.pop(ctx, 'preview'),
              ),
            if (hasFile)
              ListTile(
                leading: const Icon(Icons.delete_forever_outlined),
                title: const Text('删除本集视频文件（推荐）'),
                subtitle: const Text('记录和手机里的视频一起彻底删除'),
                onTap: () => Navigator.pop(ctx, 'file'),
              ),
            if (sameMovie > 1)
              ListTile(
                leading: const Icon(Icons.movie_filter_outlined),
                title: Text('删除整部影片（全部 $sameMovie 集）'),
                subtitle: const Text('同片名的全部任务与视频文件一起删除'),
                onTap: () => Navigator.pop(ctx, 'movie'),
              ),
            ListTile(
              leading: const Icon(Icons.playlist_remove_outlined),
              title: const Text('仅移除记录'),
              subtitle: const Text('手机里的视频文件保留不动'),
              onTap: () => Navigator.pop(ctx, 'record'),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
    if (mode == null || !mounted) return;
    if (mode == 'preview') {
      _preview(t);
      return;
    }
    if (mode == 'movie') {
      final (n, fileOk, failed) =
          await DownloadService.instance.deleteMovie(t.movieName);
      if (!mounted) return;
      if (fileOk) {
        _toast('已删除「${t.movieName}」全部 $n 集（含视频文件）');
      } else {
        _toast('已移除 $n 条记录，但有文件没能删掉');
        await _showDeleteFailed(failed);
      }
      return;
    }
    final res = await DownloadService.instance
        .delete(t.id, withFile: mode == 'file');
    if (!mounted) return;
    if (mode == 'record') {
      _toast('已移除记录（视频文件保留在 Movies/电影世界/）');
    } else if (res['fileDeleted'] == true) {
      _toast('本集视频已彻底删除');
    } else {
      _toast('记录已删除，但有文件没能删掉');
      await _showDeleteFailed((res['failedPaths'] as List?)
              ?.map((e) => '$e')
              .toList() ??
          const []);
    }
  }

  /// v2.0 删除失败：列出具体文件路径 + 一键复制（不再只说「请手动删除」）
  Future<void> _showDeleteFailed(List<String> paths) async {
    if (paths.isEmpty || !mounted) return;
    final txt = paths.map((e) => e.startsWith('全部文件/') ? e : '全部文件/$e').join('\n');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('有视频文件没能删掉'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('记录已移除，但下面这些文件还在手机里。可复制路径后到「文件管理」里手动删除：',
                  style: TextStyle(fontSize: 12.5, height: 1.5)),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: context.chipBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(txt,
                    style: const TextStyle(fontSize: 11.5, height: 1.6)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: txt));
              Navigator.pop(ctx);
              _toast('路径已复制，粘贴到文件管理器地址栏即可定位');
            },
            child: const Text('复制路径'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  // ---------- v2.0 手动补分类（找回的影片媒体库里没有类型信息）----------

  /// 从固定二级分类清单里选一个，选完记住（同片名全部集数一起更新）
  Future<void> _pickSubcat(DownloadTask t) async {
    final all = <String>[];
    for (final list in MacApi.docSubcats.values) {
      for (final s in list) {
        if (!all.contains(s)) all.add(s);
      }
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('选择影片分类',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: context.tMain)),
                  const SizedBox(height: 5),
                  Text(
                      '「${t.movieName}」当前：${t.subcat.isEmpty ? '未分类' : t.subcat}'
                      '　（同片名全部集数一起更新）',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: context.tFaint)),
                ],
              ),
            ),
            Flexible(
              child: GridView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 2.2,
                ),
                itemCount: all.length,
                itemBuilder: (_, i) {
                  final s = all[i];
                  final on = s == t.subcat;
                  return InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => Navigator.pop(ctx, s),
                    child: Container(
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: on
                            ? context.brand.withValues(alpha: 0.12)
                            : context.chipBg,
                        border: Border.all(
                            color: on
                                ? context.brand
                                : Colors.transparent,
                            width: 1.5),
                      ),
                      child: Text(s,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: on ? FontWeight.w600 : null,
                              color: on ? context.brand : context.tMain)),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx, ''),
                  child: const Text('清除分类'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    DownloadService.instance.setSubcatForMovie(t.movieName, picked);
    _toast(picked.isEmpty ? '已清除分类' : '已标记为「$picked」');
  }

  // ---------- v1.9.8 批量操作 ----------

  void _enterSelect([String? firstId]) {
    setState(() {
      _selectMode = true;
      _selected.clear();
      if (firstId != null) _selected.add(firstId);
    });
  }

  void _exitSelect() {
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
  }

  Future<void> _batchDelete() async {
    if (_selected.isEmpty) return;
    final withFile = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除所选 ${_selected.length} 项？'),
        content: const Text('删除时会连同手机里的视频文件一起删除；\n只想清除记录、保留视频文件，请用「仅移除记录」。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (withFile != true || !mounted) return;
    var removed = 0;
    var fileOk = 0;
    final failed = <String>[];
    for (final id in _selected.toList()) {
      final r = await DownloadService.instance.delete(id, withFile: true);
      if (r['recordRemoved'] == true) removed++;
      if (r['fileDeleted'] == true) {
        fileOk++;
      } else {
        failed.addAll(
            (r['failedPaths'] as List?)?.map((e) => '$e').toList() ?? const []);
      }
    }
    if (!mounted) return;
    _exitSelect();
    if (removed == fileOk) {
      _toast('已删除 $removed 项（含视频文件）');
      return;
    }
    _toast('已删除 $removed 项记录，其中 ${removed - fileOk} 个视频文件没能删掉');
    await _showDeleteFailed(failed);
  }

  /// v2.1.1 批量「仅移除记录」：只清下载列表记录，手机里的视频文件保留不动
  Future<void> _batchRemoveRecords() async {
    if (_selected.isEmpty) return;
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('仅移除所选 $n 项记录？'),
        content: const Text('只清除下载列表里的记录，\n手机里的视频文件全部保留不动。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('仅移除记录')),
        ],
      ),
    );
    if (ok != true) return;
    final ids = _selected.toList();
    for (final id in ids) {
      await DownloadService.instance.delete(id, withFile: false);
    }
    if (!mounted) return;
    _exitSelect();
    _toast('已移除 $n 条记录（视频文件保留在 Movies/电影世界/）');
  }

  void _batchRetry() {
    // v1.9.8 只重试「所选」中的失败任务，不影响未勾选的
    var n = 0;
    for (final t in DownloadService.instance.tasks) {
      if (t.state == 'failed' && _selected.contains(t.id)) {
        DownloadService.instance.resume(t.id);
        n++;
      }
    }
    if (n == 0) {
      _toast('所选任务中没有失败项');
      return;
    }
    _exitSelect();
    _toast('已重新加入 $n 个失败任务');
  }

  // ---------- 播放 ----------

  void _playLocal(DownloadTask t) {
    _playFile(t, t.savedPath ?? '');
  }

  /// v2.2.4：下载成片对应的「本地」播放条目（sourceId=-1，vodId=local_<任务id>）。
  /// 与观看历史使用同一 Key —— 进度记录 / 续播定位才能对上。
  static VideoItem _localItem(DownloadTask t) => VideoItem(
        vodId: LocalKeys.taskVodId(t.id),
        name: '${t.movieName} · ${t.epName}',
        sourceId: LocalKeys.localSourceId,
        sourceName: '本地下载',
        typeName: '离线视频',
      );

  /// 该成片已记录的观看进度（秒；0 = 没看过）
  static int _watchedSec(DownloadTask t) =>
      AppStore.instance.findHistory(_localItem(t))?.positionSec ?? 0;

  static String _fmtPos(int sec) {
    final m = sec ~/ 60, s = sec % 60;
    if (m >= 60) return '${m ~/ 60}时${m % 60}分';
    return '$m分${s.toString().padLeft(2, '0')}秒';
  }

  /// v1.6.1 通用本地播放（离线成片 / 下载中预览的本地 m3u8）
  /// v2.2.4：起播时带上「观看历史」里已记录的进度 —— 本地影片也能续播定位。
  void _playFile(DownloadTask t, String path, {bool resume = true}) {
    if (path.isEmpty) {
      _toast('本地文件已丢失，无法播放（可在「⋮-删除」后重新下载）');
      return;
    }
    const src = MovieSource(
        id: LocalKeys.localSourceId, name: '本地', url: '');
    final item = _localItem(t);
    final detail = VideoDetail(
      item: item,
      groups: [
        PlayGroup('已下载', [Episode(t.epName, path)]),
      ],
    );
    final startSec = resume ? _watchedSec(t) : 0;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerPage(
        source: src,
        detail: detail,
        groupIndex: 0,
        epIndex: 0,
        initialPosition: startSec > 0 ? Duration(seconds: startSec) : null,
      ),
    ));
  }

  /// v1.6.1 下载中预览：用已下载分段拼本地播放列表
  Future<void> _preview(DownloadTask t) async {
    final path = await DownloadService.instance.buildPreview(t);
    if (!mounted) return;
    if (path == null) {
      _toast('已下载分段还不足以预览，稍后再试试');
      return;
    }
    _playFile(t, path, resume: false); // 预览只拼了已下载分段（前缀），从头看
  }

  /// v1.9.7 手动找回已下载视频：请求媒体可见权限后扫描恢复，并反馈结果
  Future<void> _scanRestore() async {
    _toast('正在扫描手机里的已下载视频…');
    final n = await DownloadService.instance
        .restoreFromLibrary(requestPermission: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    _toast(n > 0
        ? '已找回 $n 个视频并恢复到下载列表，点「离线播放」继续观看'
        : '未在媒体库找到可恢复的视频（扫描目录：Movies/电影世界/）');
  }

  @override
  Widget build(BuildContext context) {
    final tasks = DownloadService.instance.tasks;
    final btnStyle = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: const Size(0, 36),
      visualDensity: VisualDensity.compact,
    );

    // v2.1 多选状态下按返回键 / 手势返回：先取消多选，不退出页面（靳老师 2026-09-24）
    return PopScope(
      canPop: !_selectMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectMode) _exitSelect();
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(_selectMode ? '已选 ${_selected.length} 项' : '下载管理'),
        leading: _selectMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelect,
              )
            : null,
        actions: _selectMode
            ? [
                TextButton(
                  onPressed: () => setState(() {
                    if (_selected.length == tasks.length) {
                      _selected.clear();
                    } else {
                      _selected
                        ..clear()
                        ..addAll(tasks.map((t) => t.id));
                    }
                  }),
                  child: Text(_selected.length == tasks.length && tasks.isNotEmpty
                      ? '取消全选'
                      : '全选'),
                ),
              ]
            : [
                // v1.9.8 批量操作入口
                TextButton(
                  onPressed: tasks.isEmpty ? null : () => _enterSelect(),
                  child: const Text('管理'),
                ),
                // v1.9.7 手动找回：清记录/重装后一键扫描恢复已下载视频
                TextButton(
                  onPressed: _scanRestore,
                  child: const Text('找回视频'),
                ),
                // v2.0 移除「重试失败」按钮（靳老师 2026-09-24）：
                // 批量栏已有「重试所选」，卡片上也有单个「重试」，此处不再重复
              ],
      ),
      // v1.9.8 多选模式底部批量操作栏
      bottomNavigationBar: _selectMode && _selected.isNotEmpty
          ? SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                decoration: BoxDecoration(
                  color: context.card,
                  border: Border(
                      top: BorderSide(color: context.divider, width: 0.5)),
                ),
                child: Row(children: [
                  Expanded(
                    child: Text('已选 ${_selected.length} 项',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: context.tMain)),
                  ),
                  // v2.1.1 批量「仅移除记录」（靳老师 2026-09-24：只清记录不删文件）
                  TextButton(
                    onPressed: _batchRemoveRecords,
                    child: const Text('仅移除记录'),
                  ),
                  TextButton(
                    onPressed: _batchRetry,
                    child: const Text('重试所选'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                    ),
                    onPressed: _batchDelete,
                    child: const Text('删除'),
                  ),
                ]),
              ),
            )
          : null,
      body: tasks.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.download_outlined,
                      size: 64, color: context.tFaint),
                  const SizedBox(height: 12),
                  Text('暂无下载任务',
                      style:
                          TextStyle(fontSize: 13, color: context.tFaint)),
                  const SizedBox(height: 6),
                  Text('在影片详情页或播放页点击「下载」即可缓存到本机',
                      style:
                          TextStyle(fontSize: 12, color: context.tFaint)),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
              itemCount: tasks.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                final t = tasks[i];
                final color = _stateColor(context, t);
                final checked = _selected.contains(t.id);
                // v1.9.8 批量操作入口：长按卡片进入多选并选中；多选模式下点按切换勾选
                return GestureDetector(
                  onLongPress: () {
                    if (!_selectMode) {
                      setState(() {
                        _selectMode = true;
                        _selected.add(t.id);
                      });
                    }
                  },
                  onTap: _selectMode
                      ? () => setState(() {
                            checked
                                ? _selected.remove(t.id)
                                : _selected.add(t.id);
                          })
                      : null,
                  child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: context.card,
                    borderRadius: BorderRadius.circular(14),
                    border: _selectMode && checked
                        ? Border.all(color: context.brand, width: 1.5)
                        : null,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        // v1.9.8 多选勾选框（多选模式显示；长按卡片进入）
                        if (_selectMode) ...[
                          Icon(
                            checked
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            size: 20,
                            color:
                                checked ? context.brand : context.tFaint,
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(
                            '${t.movieName} · ${t.epName.isEmpty ? '第${t.epIndex + 1}集' : t.epName}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                                color: context.tMain),
                          ),
                        ),
                        Text(_stateText(t),
                            style: TextStyle(fontSize: 11.5, color: color)),
                      ]),
                      // v1.9.8 软件二级分类 + 片源标签行
                      // v2.0 分类标签可点击 → 手动补分类（找回的影片媒体库里没有类型信息）
                      // v2.1 多选模式下也显示（此前被隐藏，靳老师 2026-09-24 反馈）；
                      //      多选时标签不响应点击，避免与勾选冲突
                      ...[
                        const SizedBox(height: 5),
                        Row(children: [
                          GestureDetector(
                            // v2.1 多选模式下不响应（避免与勾选冲突）
                            onTap: _selectMode ? null : () => _pickSubcat(t),
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(6, 2, 4, 2),
                              decoration: BoxDecoration(
                                color: t.subcat.isEmpty
                                    ? context.chipBg
                                    : context.brand.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(4),
                                border: t.subcat.isEmpty
                                    ? Border.all(color: context.divider)
                                    : null,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                      t.subcat.isEmpty ? '未分类·点击补' : t.subcat,
                                      style: TextStyle(
                                          fontSize: 10.5,
                                          color: t.subcat.isEmpty
                                              ? context.tSub
                                              : context.brand)),
                                  const SizedBox(width: 2),
                                  Icon(Icons.expand_more,
                                      size: 12,
                                      color: t.subcat.isEmpty
                                          ? context.tSub
                                          : context.brand),
                                ],
                              ),
                            ),
                          ),
                          if (t.sourceName.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(t.sourceName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 11, color: context.tFaint)),
                            ),
                          ],
                        ]),
                      ],
                      const SizedBox(height: 4),
                      Padding(
                        padding: EdgeInsets.only(
                            left: _selectMode ? 0 : 0),
                        child: Text(
                          t.state == 'done'
                              ? _friendlyPath(t) // v1.9.8 友好路径
                              : '${t.sourceName} ｜ ${t.groupName.isEmpty ? '默认线路' : t.groupName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11, color: context.tFaint),
                        ),
                      ),
                      // v1.9.8 完成时间 + 文件大小
                      // v2.2.4：已完成再加「已看 xx」—— 本地影片的续播进度一眼可见
                      if (t.state == 'done') ...[
                        if (t.doneAt > 0 || t.bytesDone > 0 || _watchedSec(t) > 0) ...[
                          const SizedBox(height: 3),
                          Text(
                            [
                              if (t.doneAt > 0) _fmtDoneAt(t.doneAt),
                              if (t.bytesDone > 0) _fmtBytes(t.bytesDone),
                              if (_watchedSec(t) > 0) '已看 ${_fmtPos(_watchedSec(t))}',
                            ].join(' ｜ '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11, color: context.tFaint),
                          ),
                        ],
                      ],
                      // v1.6.2 失败任务独立展示中文失败原因
                      if (t.state == 'failed') ...[
                        const SizedBox(height: 5),
                        Text(_friendlyError(t),
                            style: TextStyle(
                                fontSize: 11.5, color: Colors.redAccent)),
                      ],
                      if (t.state == 'running' ||
                          t.state == 'merging' ||
                          t.state == 'paused') ...[
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: t.state == 'merging' ? null : t.progress,
                            minHeight: 5,
                            backgroundColor: context.divider,
                            color: context.brand,
                          ),
                        ),
                        // v1.6.1 实时统计：进度/速度/已用时长/预计剩余
                        const SizedBox(height: 5),
                        Text(_statsText(t),
                            style: TextStyle(
                                fontSize: 10.5, color: context.tSub)),
                      ],
                      const SizedBox(height: 4),
                      Row(children: [
                        const Spacer(),
                        // v1.9.8 主按钮（每卡最多 1 个）+ 更多菜单
                        if (t.state == 'waiting' ||
                            t.state == 'running' ||
                            t.state == 'merging')
                          TextButton(
                              style: btnStyle,
                              onPressed: () => DownloadService.instance
                                  .pause(t.id),
                              child: const Text('暂停')),
                        if (t.state == 'paused' || t.state == 'failed')
                          TextButton(
                              style: btnStyle,
                              onPressed: () => DownloadService.instance
                                  .resume(t.id),
                              child: Text(
                                  t.state == 'failed' ? '重试' : '继续')),
                        if (t.state == 'done')
                          TextButton(
                            style: btnStyle,
                            onPressed: () => _playLocal(t),
                            // v2.2.4：有观看记录时按钮改「继续播放」，点进去自动定位
                            child: Text(_watchedSec(t) > 0 ? '继续播放' : '离线播放',
                                style: TextStyle(
                                    fontSize: 13, color: context.brand)),
                          ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: Icon(Icons.more_vert,
                              size: 20, color: context.tSub),
                          tooltip: '更多操作',
                          onPressed: () => _moreMenu(t),
                        ),
                      ]),
                    ],
                  ),
                  ),
                );
              },
            ),
      ),
    );
  }
}
