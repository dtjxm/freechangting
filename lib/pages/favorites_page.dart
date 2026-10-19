/// 收藏页（v1.2.1）：底部导航第三入口，收藏海报墙
///
/// v2.2.0：**长按单张海报可单独取消收藏**（此前只能整页「清空」）。
/// 取消后有「撤销」，误触可立刻找回。
library;

import 'package:flutter/material.dart';

import '../models.dart';
import '../store.dart';
import '../theme.dart';
import 'detail_page.dart';
import 'widgets.dart';

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  // v2.2.0 首次进收藏页给一条用法提示，关掉后不再出现
  bool _tip = !AppStore.instance.favTipDismissed;

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

  /// v2.2.0 长按单张海报 → 确认后单独取消收藏，并提供「撤销」。
  Future<void> _removeOne(VideoItem v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消收藏？'),
        content: Text(
          v.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13.5),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('再想想')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('取消收藏')),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    if (!AppStore.instance.isFavorite(v)) return; // 期间已不在收藏里，避免误加回来

    await AppStore.instance.toggleFavorite(v);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已取消收藏《${v.name}》'),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: '撤销',
          onPressed: () async {
            if (AppStore.instance.isFavorite(v)) return; // 防重复添加
            await AppStore.instance.toggleFavorite(v);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final favs = AppStore.instance.favorites;
    return Scaffold(
      appBar: AppBar(
        title: const Text('收藏', style: TextStyle(fontSize: 17)),
        actions: [
          if (favs.isNotEmpty)
            TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('清空收藏？'),
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
                if (ok == true) {
                  for (final v in List.of(favs)) {
                    await AppStore.instance.toggleFavorite(v);
                  }
                }
              },
              child: const Text('清空'),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: favs.isEmpty
          ? const EmptyView(icon: Icons.favorite_outline, message: '还没有收藏，去首页逛逛吧')
          : Column(children: [
              if (_tip)
                _TipBar(onClose: () {
                  AppStore.instance.favTipDismissed = true;
                  if (mounted) setState(() => _tip = false);
                }),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.52,
                  ),
                  itemCount: favs.length,
                  itemBuilder: (_, i) => PosterCard(
                    item: favs[i],
                    // v2.2.0 长按单张 → 单独取消收藏
                    onLongPress: () => _removeOne(favs[i]),
                    onTap: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => DetailPage(item: favs[i]))),
                  ),
                ),
              ),
            ]),
    );
  }
}

/// 首次进收藏页的用法提示条（可关闭，关闭后不再出现）
class _TipBar extends StatelessWidget {
  final VoidCallback onClose;
  const _TipBar({required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: context.chipBg,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(children: [
        Icon(Icons.info_outline, size: 15, color: context.tSub),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            '长按海报可单独取消收藏',
            style: TextStyle(fontSize: 12, color: context.tSub),
          ),
        ),
        SizedBox(
          height: 30,
          child: TextButton(
            onPressed: onClose,
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
            child: Text('知道了', style: TextStyle(fontSize: 12, color: context.brand)),
          ),
        ),
      ]),
    );
  }
}
