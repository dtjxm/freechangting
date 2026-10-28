/// 设置（v1.2.1 贴合设计稿）：外观 / 播放 / 数据 / 关于 分组行式布局
library;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../api.dart';
import '../download_service.dart';
import '../store.dart';
import '../theme.dart';
import 'channel_settings_page.dart';
import 'source_manage_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// v2.2.4 片源管理入口的副标题（已启用数 / 最快片源）
  String _sourceSub() {
    final total = MacApi.instance.sources.length;
    final st = AppStore.instance;
    final on = total - st.disabledSourceIds.length;
    final lat = st.sourceLatency;
    if (lat.isEmpty) return '已启用 $on / $total 个片源 · 点此测速并按速度排序';
    final fastest = lat.entries.reduce((a, b) => a.value <= b.value ? a : b);
    final name = MacApi.instance.sources
        .where((s) => s.id == fastest.key)
        .map((s) => s.name)
        .firstOrNull;
    return '已启用 $on / $total 个片源 · 最快 ${name ?? '-'} ${fastest.value}ms';
  }

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 30),
        children: [
          _groupTitle(context, '外观'),
          _card(context, [
            // 主题外观行：右侧紧凑分段控件
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Row(
                children: [
                  _ric(context, Icons.brightness_6_outlined, brand: true),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('主题外观',
                            style: TextStyle(fontSize: 14, color: context.tMain)),
                        const SizedBox(height: 2),
                        Text('浅色 / 深色 / 跟随系统切换',
                            style: TextStyle(fontSize: 11.5, color: context.tFaint)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _segControl(store),
                ],
              ),
            ),
          ]),

          // v1.9.0：首页频道显示独立成页（开关返回首页立即生效）；片源开关已取消
          _groupTitle(context, '首页显示'),
          _card(context, [
            _row(context, Icons.category_outlined, '首页频道显示',
                sub: '控制首页顶部显示哪些内容频道',
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const ChannelSettingsPage()));
                  if (mounted) setState(() {});
                }),
          ]),
          Padding(
            padding: const EdgeInsets.only(left: 6, top: 6),
            child: Row(children: [
              Icon(Icons.warning_amber_rounded, size: 14, color: context.gold),
              const SizedBox(width: 4),
              Expanded(
                child: Text('提示：「伦理 / 其他」频道可能包含成人内容，请谨慎开启',
                    style: TextStyle(fontSize: 11.5, color: context.tFaint)),
              ),
            ]),
          ),

          _groupTitle(context, '播放'),
          _card(context, [
            _switchRow(context, Icons.play_circle_outline, '自动连播',
                '一集播完自动播放下一集', store.autoNext, (v) {
              store.autoNext = v;
              setState(() {});
            }),
            _divider(context),
            _switchRow(context, Icons.cleaning_services_outlined, '去广告（推荐开启）',
                '播放前把广告分片从播放列表里删掉，不再需要快进跳过。'
                '看不准的源会自动原样播放，不会误删正片',
                store.adSkip, (v) {
              store.adSkip = v;
              setState(() {});
            }),
          ]),

          // v2.0 同时下载数量（按「集」算，靳老师 2026-09-24）
          _groupTitle(context, '下载'),
          _card(context, [
            _row(context, Icons.download_outlined, '同时下载数量',
                sub: '当前最多同时下载 ${DownloadService.instance.maxConcurrent} 集，'
                    '其余排队等待',
                onTap: _pickMaxConcurrent),
          ]),

          // v2.2.4：片源管理独立成页（参考 PC 版）—— 测速 + 开关 + 按速度排序
          _groupTitle(context, '片源'),
          _card(context, [
            _row(context, Icons.dns_outlined, '片源管理',
                sub: _sourceSub(),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const SourceManagePage()));
                  if (mounted) setState(() {});
                }),
          ]),

          _groupTitle(context, '数据'),
          _card(context, [
            _row(context, Icons.delete_outline, '清除观看历史',
                sub: '共 ${AppStore.instance.history.length} 条记录',
                onTap: _confirmClear(context, '清空观看历史？', () async {
                  await AppStore.instance.clearHistory();
                  _toast('观看历史已清空');
                })),
            _divider(context),
            _row(context, Icons.manage_search_outlined, '清空搜索历史',
                sub: '共 ${AppStore.instance.searchHistory.length} 条记录',
                onTap: _confirmClear(context, '清空搜索历史？', () {
                  AppStore.instance.clearSearchHistory();
                  _toast('搜索历史已清空');
                })),
            _divider(context),
            _row(context, Icons.image_outlined, '清除图片缓存',
                sub: '释放已下载的海报缓存',
                onTap: () {
                  PaintingBinding.instance.imageCache.clear();
                  PaintingBinding.instance.imageCache.clearLiveImages();
                  DefaultCacheManager().emptyCache();
                  _toast('图片缓存已清除');
                }),
          ]),
        ],
      ),
    );
  }

  // ---- 紧凑三段选择控件（浅色/深色/跟随系统） ----
  Widget _segControl(AppStore store) {
    const options = [(0, '系统'), (1, '浅色'), (2, '深色')];
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: context.chipBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, (v, label)) in options.indexed) ...[
            if (i > 0) const SizedBox(width: 2),
            GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => store.themeModeIndex = v);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: store.themeModeIndex == v
                      ? context.brand
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(label,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: store.themeModeIndex == v
                            ? FontWeight.w600
                            : null,
                        color: store.themeModeIndex == v
                            ? Colors.white
                            : context.tSub)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---- 行组件 ----
  Widget _ric(BuildContext context, IconData icon, {bool brand = false}) =>
      Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: brand ? context.brandWeak : context.gold.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Icon(icon,
            size: 17, color: brand ? context.brand : context.gold),
      );

  Widget _row(BuildContext context, IconData icon, String title,
      {String? sub, VoidCallback? onTap, Widget? trailing}) {
    return ListTile(
      dense: true,
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: _ric(context, icon),
      title: Text(title,
          style: TextStyle(fontSize: 14, color: context.tMain)),
      subtitle: sub == null
          ? null
          : Text(sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: context.tFaint)),
      trailing: trailing ??
          (onTap == null
              ? null
              : Icon(Icons.chevron_right, size: 20, color: context.tFaint)),
    );
  }

  Widget _switchRow(BuildContext context, IconData icon, String title,
          String sub, bool val, ValueChanged<bool> onChanged) =>
      SwitchListTile(
        dense: true,
        secondary: _ric(context, icon),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        activeThumbColor: context.brand,
        title: Text(title,
            style: TextStyle(fontSize: 14, color: context.tMain)),
        subtitle: Text(sub,
            style: TextStyle(fontSize: 11.5, color: context.tFaint)),
        value: val,
        onChanged: (v) {
          HapticFeedback.selectionClick();
          onChanged(v);
        },
      );

  /// v2.0 同时下载数量：1~10 数字网格，点一下立即生效并记住（默认 3）
  Future<void> _pickMaxConcurrent() async {
    final svc = DownloadService.instance;
    final cur = svc.maxConcurrent;
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('同时下载数量',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: context.tMain)),
                  const SizedBox(height: 5),
                  Text('按「集」计算：数字表示最多同时下载几集，其余排队等待。数量越大越占网速',
                      style: TextStyle(fontSize: 11.5, color: context.tFaint)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
              child: GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 5,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.55,
                ),
                itemCount: DownloadService.kMaxConcurrentLimit,
                itemBuilder: (_, i) {
                  final v = i + 1;
                  final on = v == cur;
                  return InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => Navigator.pop(ctx, v),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: on
                            ? context.brand.withValues(alpha: 0.12)
                            : context.chipBg,
                        border: Border.all(
                            color:
                                on ? context.brand : Colors.transparent,
                            width: 1.5),
                      ),
                      child: Text('$v',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: on ? FontWeight.w600 : null,
                              color: on ? context.brand : context.tMain)),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await svc.setMaxConcurrent(picked);
    if (!mounted) return;
    setState(() {});
    _toast('已设为最多同时下载 $picked 集');
  }

  VoidCallback _confirmClear(BuildContext context, String title, VoidCallback act) =>
      () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('清空')),
            ],
          ),
        );
        if (ok == true) act();
      };

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  Widget _groupTitle(BuildContext context, String t) => Padding(
        padding: const EdgeInsets.only(left: 4, top: 18, bottom: 8),
        child: Text(t,
            style: TextStyle(
                fontSize: 12.5, fontWeight: FontWeight.w600, color: context.tFaint)),
      );

  Widget _card(BuildContext context, List<Widget> children) => Container(
        decoration: BoxDecoration(
          color: context.card,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(children: children),
      );

  Widget _divider(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Divider(height: 1, color: context.divider),
      );
}

