import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';

/// 点播播放器浮层与弹层。
///
/// 从 `player_page.dart` 拆出：这些只依赖传入参数、不持有播放状态，
/// 独立成文件后播放页可以专注于控制器生命周期与手势。
const List<double> vodSpeeds = [0.5, 0.75, 1.0, 1.5, 2.0];

/// 倍速档位的展示文案：0.5 / 0.75 / 1.0 / 1.5 / 2.0
String vodSpeedText(double s) => s == 0.75 ? '0.75' : s.toStringAsFixed(1);

/// v2.2.7：播放倍速面板（与播放器同一套深色风格）
///
/// ⚠️ 必须是 `isScrollControlled: true` + 横向 chip 行：
/// 播放器是**横屏**，屏幕高度只有 ~386dp，而 `showModalBottomSheet` 默认把面板高度
/// 限制在屏幕的 9/16（≈217dp）。此前用「标题 + 5 个 ListTile」竖排（≈280dp），
/// 1.5x / 2.0x 两档直接被裁到屏幕外 —— 用户只能选到 1.0x。
/// 改成一行 Wrap 芯片后总高 ≈100dp，横竖屏都放得下。
void showVodSpeedSheet(
  BuildContext context, {
  required double current,
  required Future<void> Function(double) onPick,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.black87,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '播放倍速',
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            // 一行放 5 档；屏宽不够时 Wrap 自动换行，仍不会超出面板
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final s in vodSpeeds)
                  _speedChip(ctx, s, current, onPick),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// 单个倍速芯片：当前档位高亮 + 打勾
Widget _speedChip(
  BuildContext ctx,
  double s,
  double current,
  Future<void> Function(double) onPick,
) {
  final sel = (s - current).abs() < 0.001;
  return InkWell(
    borderRadius: BorderRadius.circular(20),
    onTap: () async {
      Navigator.of(ctx).pop();
      await onPick(s);
    },
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: BoxDecoration(
        color: sel
            ? ctx.brand.withValues(alpha: 0.22)
            : Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: sel ? Border.all(color: ctx.brand, width: 1.4) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${vodSpeedText(s)}x',
            style: TextStyle(
              color: sel ? ctx.brand : Colors.white,
              fontSize: 14,
              fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          if (sel) ...[
            const SizedBox(width: 4),
            Icon(Icons.check, size: 15, color: ctx.brand),
          ],
        ],
      ),
    ),
  );
}

/// 播放失败提示
Widget buildVodError(
  BuildContext context,
  String message,
  VoidCallback onRetry,
) =>
    Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.white38, size: 44),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: onRetry,
            child: const Text('重试'),
          ),
        ],
      ),
    );

/// v1.4.6 换源结果面板：选择其他片源的同名可播资源
Future<void> showVodSourceSheet(
  BuildContext context,
  List<VideoDetail> results,
  ValueChanged<VideoDetail> onPick,
) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF1A1D23),
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.all(14),
            child: Text(
              '切换到其他片源播放',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          ...results.map(
            (d) => ListTile(
              leading: const Icon(
                Icons.play_circle_outline,
                color: Colors.redAccent,
              ),
              title: Text(
                d.item.sourceName,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              subtitle: Text(
                '${d.item.typeName}｜共 ${d.groups.fold<int>(0, (a, g) => a + g.episodes.length)} 集',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                onPick(d);
              },
            ),
          ),
        ],
      ),
    ),
  );
}

/// v1.5.5 线路选择弹层：当前片源下的多条播放线路单选切换
Future<void> showVodLineSheet(
  BuildContext context, {
  required List<PlayGroup> groups,
  required int current,
  required ValueChanged<int> onPick,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF1A1D23),
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.all(14),
            child: Text(
              '选择播放线路（当前片源）',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          for (var i = 0; i < groups.length; i++)
            ListTile(
              leading: Icon(
                i == current
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: i == current ? Colors.redAccent : Colors.white38,
                size: 20,
              ),
              title: Text(
                groups[i].from.isEmpty ? '线路${i + 1}' : groups[i].from,
                style: TextStyle(
                  fontSize: 13.5,
                  color: i == current ? Colors.redAccent : Colors.white70,
                  fontWeight: i == current
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
              subtitle: Text(
                '${groups[i].episodes.length} 集',
                style: const TextStyle(fontSize: 11, color: Colors.white38),
              ),
              onTap: () {
                Navigator.pop(ctx);
                if (i == current) return;
                onPick(i);
              },
            ),
        ],
      ),
    ),
  );
}

/// 选集面板
Future<void> showVodEpSheet(
  BuildContext context, {
  required String title,
  required List<Episode> episodes,
  required int current,
  required ValueChanged<int> onPick,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF1A1D23),
    builder: (ctx) => SafeArea(
      child: SizedBox(
        height: 360,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 2.4,
                ),
                itemCount: episodes.length,
                itemBuilder: (_, i) => OutlinedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    onPick(i);
                  },
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.zero,
                    side: BorderSide(
                      color: i == current ? Colors.redAccent : Colors.white24,
                    ),
                  ),
                  child: Text(
                    episodes[i].name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
