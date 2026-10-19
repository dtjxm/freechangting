/// 我的（v1.4.8 重排）：头部上下布局（LOGO+应用名）+ 收藏/历史/播放手势/设置/关于
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../download_service.dart';
import '../store.dart';
import '../theme.dart';
import '../version.dart';
import 'about_page.dart';
import 'download_page.dart';
import 'favorites_page.dart';
import 'gesture_page.dart';
import 'history_page.dart';
import 'settings_page.dart';

class MinePage extends StatefulWidget {
  const MinePage({super.key});

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  @override
  void initState() {
    super.initState();
    AppStore.instance.addListener(_onChange);
  }

  @override
  void dispose() {
    AppStore.instance.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _go(Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  /// v1.6.0：下载入口摘要
  String _downloadSub() {
    final tasks = DownloadService.instance.tasks;
    if (tasks.isEmpty) return '暂无下载任务';
    final active = tasks
        .where((t) =>
            t.state == 'running' ||
            t.state == 'merging' ||
            t.state == 'waiting')
        .length;
    final done = tasks.where((t) => t.state == 'done').length;
    return active > 0 ? '正在下载 $active 集 · 已完成 $done 集' : '已下载 $done 集视频';
  }

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 30),
        children: [
          // ---- 头部（v1.5.2：与下方列表大卡片同宽）----
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
              decoration: BoxDecoration(
                color: context.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: context.brandWeak, width: 1),
              ),
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.asset('assets/icon.png',
                        width: 56, height: 56, fit: BoxFit.cover),
                  ),
                  const SizedBox(height: 9),
                  Text('电影世界',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: context.tMain)),
                  const SizedBox(height: 5),
                  Text(
                      '$kAppVersion ｜ 片源 ${MacApi.instance.sources.length} 个 ｜ 收藏 ${store.favorites.length} ｜ 历史 ${store.history.length}',
                      style: TextStyle(
                          fontSize: 11.5, color: context.tFaint)),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // ---- 五个入口（v1.4.8：新增播放手势） ----
          Container(
            decoration: BoxDecoration(
              color: context.card,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(children: [
              _entry(context, Icons.favorite, '收藏',
                  sub: '${store.favorites.length} 部影片',
                  color: const Color(0xFFE05A6D),
                  onTap: () => _go(const FavoritesPage())),
              _divider(context),
              _entry(context, Icons.history, '历史',
                  sub: store.history.isEmpty
                      ? '暂无观看记录'
                      : '最近：${store.history.first.item.name}',
                  color: const Color(0xFFF2A33D),
                  onTap: () => _go(const HistoryPage())),
              _divider(context),
              // v1.6.0：下载管理入口
              _entry(context, Icons.download_outlined, '下载',
                  sub: _downloadSub(),
                  color: const Color(0xFF3FA7E0),
                  onTap: () => _go(const DownloadPage())),
              _divider(context),
              _entry(context, Icons.touch_app_outlined, '播放手势',
                  sub: '快进快退 / 音量亮度 / 倍速操作说明',
                  color: const Color(0xFF9B6BF0),
                  onTap: () => _go(const GesturePage())),
              _divider(context),
              _entry(context, Icons.settings_outlined, '设置',
                  sub: '主题外观 / 播放 / 数据',
                  color: const Color(0xFF6B8AF0),
                  onTap: () => _go(const SettingsPage())),
              _divider(context),
              _entry(context, Icons.info_outline, '关于',
                  sub: '软件说明 · 免责声明 · 版本信息',
                  color: const Color(0xFF4CBFA6),
                  onTap: () => _go(const AboutPage())),
            ]),
          ),
        ],
      ),
    );
  }


  Widget _entry(BuildContext context, IconData icon, String title,
      {String? sub, required Color color, required VoidCallback onTap}) {
    return ListTile(
      dense: true,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(icon, size: 20, color: color),
      ),
      title: Text(title,
          style: TextStyle(
              fontSize: 15, fontWeight: FontWeight.w600, color: context.tMain)),
      subtitle: sub == null
          ? null
          : Text(sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: context.tFaint)),
      trailing:
          Icon(Icons.chevron_right, size: 22, color: context.tFaint),
    );
  }

  Widget _divider(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Divider(height: 1, color: context.divider),
      );
}
