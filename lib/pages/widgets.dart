/// 通用小组件：海报卡片 / 加载与空态
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';

class PosterCard extends StatelessWidget {
  final VideoItem item;
  final VoidCallback onTap;
  final String? badge;
  // v2.2.0 长按回调：收藏页用它做「单独取消收藏」。不传则与普通海报行为一致。
  final VoidCallback? onLongPress;

  const PosterCard({
    super.key,
    required this.item,
    required this.onTap,
    this.badge,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final remark = badge ?? item.remarks;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: item.pic.isNotEmpty
                      // v1.2.0 图片修复②：cached_network_image 带超时/自动重试/磁盘缓存
                      ? CachedNetworkImage(
                          imageUrl: item.pic,
                          fit: BoxFit.cover,
                          httpHeaders: const {'User-Agent': 'Mozilla/5.0'},
                          placeholder: (_, _) => _placeholder(context, loading: true),
                          errorWidget: (_, _, _) => _placeholder(context),
                        )
                      : _placeholder(context),
                ),
                if (remark.isNotEmpty)
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      constraints: const BoxConstraints(maxWidth: 200),
                      child: Text(
                        remark,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 10),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // v1.6.3 片名最多两行，长名不再截断成一行
          Text(
            item.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w500, color: context.tMain),
          ),
          // v1.6.3 副标题：年份 + 主演（替换原片源信息；主演只取第一位避免过长）
          Builder(builder: (_) {
            final lead = item.actor
                .split(RegExp(r'[,，/]'))
                .where((s) => s.trim().isNotEmpty)
                .toList();
            final parts = [
              if (item.year.isNotEmpty) item.year,
              if (lead.isNotEmpty) lead.first.trim(),
            ];
            final sub = parts.isNotEmpty ? parts.join(' · ') : item.typeName;
            if (sub.isEmpty) return const SizedBox.shrink();
            return Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: context.tSub),
            );
          }),
        ],
      ),
    );
  }

  Widget _placeholder(BuildContext context, {bool loading = false}) => Container(
        color: context.chipBg,
        alignment: Alignment.center,
        child: loading
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: context.brand))
            : Icon(Icons.movie_outlined, color: context.tFaint, size: 32),
      );
}

/// 网络海报（详情页 / 历史缩略图共用）
class NetImage extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;

  const NetImage(this.url,
      {super.key, this.width, this.height, this.fit = BoxFit.cover, this.borderRadius});

  @override
  Widget build(BuildContext context) {
    final body = url.isNotEmpty
        ? CachedNetworkImage(
            imageUrl: url,
            width: width,
            height: height,
            fit: fit,
            httpHeaders: const {'User-Agent': 'Mozilla/5.0'},
            placeholder: (_, _) => _box(context, loading: true),
            errorWidget: (_, _, _) => _box(context),
          )
        : _box(context);
    if (borderRadius != null) return ClipRRect(borderRadius: borderRadius!, child: body);
    return body;
  }

  Widget _box(BuildContext context, {bool loading = false}) => Container(
        width: width,
        height: height,
        color: context.chipBg,
        alignment: Alignment.center,
        child: loading
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: context.brand))
            : Icon(Icons.movie_outlined, color: context.tFaint, size: 26),
      );
}

class EmptyView extends StatelessWidget {
  final String message;
  final IconData icon;
  const EmptyView({super.key, required this.message, this.icon = Icons.inbox_outlined});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: context.tFaint),
            const SizedBox(height: 10),
            Text(message, style: TextStyle(color: context.tSub, fontSize: 13)),
          ],
        ),
      );
}
