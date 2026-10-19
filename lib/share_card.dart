/// v2.2.8 影片分享：本地合成「带下载二维码」的分享卡片图。
///
/// 核心诉求（用户 2026-10-15 定）：点「分享」不是转发明细，而是把**软件本身**
/// 分享出去 —— 生成一张带「下载 APP 二维码」的卡片图，别人扫码下载安装。
///
/// 设计决策：
/// - 二维码内容 = GitHub 仓库页（永久稳定），别人扫码进页面点 APK 下载，
///   避免用 ghfast.top 镜像直链（易失效/被墙，扫码体验差）。
/// - 二维码本地生成（qr_flutter），离线、无隐私风险。
/// - 卡片图本地合成：`RepaintBoundary` 截图 → PNG 字节，不依赖任何服务端。
/// - 微信对第三方 APK 直链封控严格，故卡片上印「如无法下载请用浏览器打开」。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import 'models.dart';

/// 分享卡片：纯展示 Widget，供 `RepaintBoundary` 截图。
///
/// 深色底、固定宽 320，高度自适应内容。海报用网络图，二维码用 qr_flutter。
class ShareCard extends StatelessWidget {
  final VideoItem item;
  final String qrUrl;

  const ShareCard({super.key, required this.item, required this.qrUrl});

  @override
  Widget build(BuildContext context) {
    final meta = [
      if (item.year.isNotEmpty) item.year,
      if (item.area.isNotEmpty) item.area,
      if (item.typeName.isNotEmpty) item.typeName,
    ].where((e) => e.isNotEmpty).join(' · ');
    return Container(
      width: 320,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0C11),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '电影世界 · 免费看片',
            style: TextStyle(
                color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: item.pic.isNotEmpty
                ? Image.network(
                    item.pic,
                    width: 160,
                    height: 224,
                    fit: BoxFit.cover,
                    headers: const {'User-Agent': 'Mozilla/5.0'},
                    errorBuilder: (_, _, _) => _picPlaceholder(),
                  )
                : _picPlaceholder(),
          ),
          const SizedBox(height: 14),
          Text(
            item.name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: Colors.white, fontSize: 17, fontWeight: FontWeight.w500),
          ),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              meta,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFB4B2A9), fontSize: 12),
            ),
          ],
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                QrImageView(
                  data: qrUrl,
                  version: QrVersions.auto,
                  size: 120,
                  backgroundColor: Colors.white,
                ),
                const SizedBox(height: 6),
                const Text(
                  '扫码下载 App',
                  style: TextStyle(
                      color: Color(0xFF18191C),
                      fontSize: 12,
                      fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '如无法下载，请长按识别后用浏览器打开',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF8A9099), fontSize: 11),
          ),
          const SizedBox(height: 6),
          const Text(
            '免费 · 无广告 · 多片源',
            style: TextStyle(color: Color(0xFF5F5E5A), fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _picPlaceholder() => Container(
        width: 160,
        height: 224,
        color: const Color(0xFF24272D),
        alignment: Alignment.center,
        child: const Icon(Icons.movie_outlined, color: Colors.white24, size: 48),
      );
}

/// 分享服务：把分享卡片截图成 PNG，再保存相册 / 系统分享 / 复制链接。
class ShareService {
  ShareService._();
  static final ShareService instance = ShareService._();

/// 二维码指向的下载入口 —— GitHub 仓库页（永久稳定，不受镜像失效/被墙影响）。
/// 别人扫码打开仓库页，点 `dysj-release.apk` 即可下载安装。
/// 与 `update_service.dart` 的 `_rawBase` 同仓库（dtjxm/freechangting）。
static String get qrUrl => 'https://github.com/dtjxm/freechangting';

  /// 卡片分享入口：先在离屏 OverlayEntry 里渲染卡片并截图，成功后弹出动作面板。
  ///
  /// 截图需要真实渲染（`RepaintBoundary` 离屏），用隐藏 OverlayEntry 承载卡片，
  /// 截图完成后移除，再把字节交给动作面板。
  Future<Uint8List?> renderCard(BuildContext context, VideoItem item) async {
    final key = GlobalKey();
    final overlay = Overlay.of(context);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
        left: -10000, // 移到屏幕外，避免闪烁
        top: 0,
        child: RepaintBoundary(
          key: key,
          child: Material(
            color: Colors.transparent,
            child: ShareCard(item: item, qrUrl: qrUrl),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    try {
      // 等一帧，让布局完成、网络海报尽量加载
      await Future.delayed(const Duration(milliseconds: 500));
      final renderObj =
          key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (renderObj == null) return null;
      final image = await renderObj.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } finally {
      entry.remove();
    }
  }

  /// 系统分享（带图片 + 文字）。
  Future<void> shareBytes(Uint8List bytes, VideoItem item) async {
    final tmpDir = await getTemporaryDirectory();
    final file = File(
        '${tmpDir.path}/dysj_share_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(bytes);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'image/png')],
        text: '推荐你看《${item.name}》—— 电影世界 App，扫码免费看片',
      ),
    );
  }

  /// 复制下载链接到剪贴板。
  Future<void> copyLink() async {
    await Clipboard.setData(ClipboardData(text: qrUrl));
  }
}
