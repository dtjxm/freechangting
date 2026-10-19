/// v1.9.0 首页频道显示（从设置页独立成页）：
/// 控制首页顶部频道栏显示哪些内容频道；开关即时保存，
/// 返回首页立即生效（首页已监听 AppStore 变更，无需重启）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../store.dart';
import '../theme.dart';

class ChannelSettingsPage extends StatefulWidget {
  const ChannelSettingsPage({super.key});

  @override
  State<ChannelSettingsPage> createState() => _ChannelSettingsPageState();
}

class _ChannelSettingsPageState extends State<ChannelSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('首页频道显示')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 30),
        children: [
          _groupTitle(context, '开启后显示在首页顶部频道栏'),
          _card(context, [
            for (final key in MacApi.allBigCats) ...[
              if (key != MacApi.allBigCats.first) _divider(context),
              _switchRow(
                  context,
                  _catIcon(key),
                  MacApi.catNames[key] ?? key,
                  _catDesc(key),
                  store.bigCatVisible(key), (v) async {
                // 敏感分类开启前二次确认
                if (v && AppStore.sensitiveCats.contains(key)) {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text('开启「${MacApi.catNames[key]}」频道？'),
                      content: const Text(
                          '该频道可能包含成人或不良内容，请谨慎开启。\n\n确定要开启吗？'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('取消')),
                        FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('确定开启')),
                      ],
                    ),
                  );
                  if (ok != true) return;
                }
                store.setBigCatVisible(key, v);
                setState(() {});
              }),
            ],
          ]),
          Padding(
            padding: const EdgeInsets.only(left: 6, top: 6),
            child: Row(children: [
              Icon(Icons.warning_amber_rounded, size: 14, color: context.gold),
              const SizedBox(width: 4),
              Expanded(
                child: Text('提示：开关后返回首页立即生效，无需重启应用',
                    style: TextStyle(fontSize: 11.5, color: context.tFaint)),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  // ---- 频道图标与说明 ----
  IconData _catIcon(String key) => switch (key) {
        'movies' => Icons.movie_outlined,
        'tv' => Icons.tv_outlined,
        'variety' => Icons.emoji_emotions_outlined,
        'anime' => Icons.animation_outlined,
        'documentary' => Icons.public_outlined,
        'shortdrama' => Icons.smartphone_outlined,
        'sports' => Icons.sports_basketball_outlined,
        'commentary' => Icons.record_voice_over_outlined,
        'ethics' => Icons.warning_amber_outlined,
        _ => Icons.category_outlined,
      };

  String _catDesc(String key) => switch (key) {
        'movies' => '电影 / 动作 / 喜剧 / 科幻等',
        'tv' => '电视剧 / 国产剧 / 海外剧等',
        'variety' => '综艺 / 真人秀 / 演唱会',
        'anime' => '动漫 / 动画 / 番剧',
        'documentary' => '纪录片 / 科教 / 科普',
        'shortdrama' => '短剧 / 爽剧 / 漫剧',
        'sports' => '体育赛事 / 篮球 / 足球 / 斯诺克',
        'commentary' => '影视解说 / 预告片',
        'ethics' => '伦理内容（含成人内容，谨慎开启）',
        _ => '',
      };

  // ---- 行组件 ----
  Widget _ric(BuildContext context, IconData icon) => Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: context.gold.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Icon(icon, size: 17, color: context.gold),
      );

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
