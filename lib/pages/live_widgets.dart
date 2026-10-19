import 'package:flutter/material.dart';

import '../live_tv.dart';
import '../logo_cache.dart';
import '../theme.dart';

/// 直播频道行：台标 + 台名 + 分类/线路数 + 最快实测速度。
///
/// 从 `live_page.dart` 拆出，供频道列表与后续可能的收藏/历史列表复用。
class LiveChannelTile extends StatelessWidget {
  final TvChannel channel;
  final VoidCallback onTap;

  const LiveChannelTile({
    super.key,
    required this.channel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            // 台标位维持 56×42（此前修过压扁问题，不要改成 weight=1 铺满）
            width: 56,
            height: 42,
            // v2.2.7：台标图本身已带底色（深灰 #2E2E2E），容器不再套浅色底，
            // 否则深灰图上会多出一圈浅色边；无台标时由 fallback 自己铺色块。
            color: Colors.transparent,
            alignment: Alignment.center,
            child: LiveChannelLogo(channel: channel),
          ),
        ),
        title: Text(
          channel.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${channel.sub.isEmpty ? channel.top : channel.sub} · '
          '${channel.lines.length} 条线路${_speedText(channel)}',
          style: TextStyle(fontSize: 11, color: context.tFaint),
        ),
        trailing: Icon(
          Icons.play_circle_outline,
          size: 24,
          color: context.brand.withValues(alpha: 0.8),
        ),
        onTap: onTap,
      ),
    );
  }

  /// 副标题带上最快线路的实测速度
  static String _speedText(TvChannel c) {
    var best = -1;
    for (final l in c.lines) {
      if (l.ms > 0 && (best < 0 || l.ms < best)) best = l.ms;
    }
    return best > 0 ? ' · 最快 ${(best / 1000).toStringAsFixed(2)}s' : '';
  }
}

/// 台标本体：随包内置（`asset:cctv1.png`）→ 本地缓存命中 → 网络 → 占位。
class LiveChannelLogo extends StatelessWidget {
  final TvChannel channel;

  const LiveChannelLogo({super.key, required this.channel});

  @override
  Widget build(BuildContext context) {
    final col = _logoColor(channel.name);
    final img = LogoCache.instance.provider(channel.logo);
    if (img != null) {
      // v2.2.7 第二轮：内置台标现在是高分辨率（≥160px 高），要缩到 56×42 显示，
      // 默认 FilterQuality.low（双线性）缩小时会有阶梯感；medium 走 mipmap 采样，
      // 边缘更干净。
      return Image(
        image: img,
        width: 56,
        height: 42,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      );
    }
    if (channel.logo.isEmpty) return _logoFallback(channel.name, col);
    // 有网络地址但还没下好：先给占位，同时后台缓存（下好后滚动/重建即出图）
    return Image.network(
      channel.logo,
      width: 56,
      height: 42,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => _logoFallback(channel.name, col),
    );
  }

  /// 高对比首字色块（v2.2.7 修复 缺陷 6）：
  /// 原先是「品牌色 alpha 0.14 + 同色字」，深色底上几乎看不见；
  /// 现改为**纯品牌色实底 + 白色 800 粗体**，字号用 FittedBox 跟随容器自适应。
  Widget _logoFallback(String name, Color col) {
    return Container(
      width: 56,
      height: 42,
      color: col,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          _logoInitial(name),
          maxLines: 1,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            height: 1.05,
          ),
        ),
      ),
    );
  }

  static String _logoInitial(String s) {
    final t = s.trim();
    if (t.isEmpty) return '#';
    for (final r in t.runes) {
      final isCjk = r >= 0x4E00 && r <= 0x9FA5;
      final isDigit = r >= 0x30 && r <= 0x39;
      if (isCjk || isDigit) return String.fromCharCode(r);
    }
    return t[0].toUpperCase();
  }

  static const List<Color> _logoPalette = [
    Color(0xFFE8490F),
    Color(0xFF0D7F6F),
    Color(0xFF1F6FD0),
    Color(0xFF8B3FD0),
    Color(0xFFC2410C),
    Color(0xFF0D8A4A),
    Color(0xFFB5851B),
    Color(0xFF5A67D8),
    Color(0xFF0F766E),
    Color(0xFFB91C1C),
  ];

  static Color _logoColor(String s) {
    var h = 0;
    for (final r in s.runes) {
      h = (h * 31 + r) & 0x7FFFFFFF;
    }
    return _logoPalette[h % _logoPalette.length];
  }
}
