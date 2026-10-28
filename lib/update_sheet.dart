/// 更新弹窗（v2.2.5，v2.2.7 状态机优化）—— 发现新版时弹出的底部卡片。
/// 版本号 / 更新说明 / 包大小 + 「稍后」「立即更新」；点更新后显示下载进度，
/// 下完变「立即安装」，重复点击直接调系统安装器、不再重新下载。
/// about_page 与 main.dart（启动静默检查）共用。
library;

import 'package:flutter/material.dart';

import 'theme.dart';
import 'update_service.dart';

/// 弹窗状态：待下载 / 下载中 / 已下载待安装 / 安装器已拉起
enum _UpdState { idle, downloading, downloaded, installing }

class UpdateSheet extends StatefulWidget {
  final UpdateInfo info;
  const UpdateSheet({super.key, required this.info});

  @override
  State<UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<UpdateSheet> {
  _UpdState _state = _UpdState.idle;
  double _progress = 0;
  String? _apkPath; // 已下载完整的 APK 本地路径

  @override
  void initState() {
    super.initState();
    // 弹窗打开时先看本地有没有下载完整的缓存 —— 有就直接进「已下载」状态，
    // 按钮显示「立即安装」，避免上次下载完成后没装成又全量重下。
    UpdateService.instance.cachedApkPath(widget.info).then((p) {
      if (mounted && p != null) {
        setState(() {
          _apkPath = p;
          _state = _UpdState.downloaded;
          _progress = 1.0;
        });
      }
    });
  }

  Future<void> _startUpdate() async {
    if (_state == _UpdState.downloading || _state == _UpdState.installing) return;
    // 已有缓存 → 直接安装，不下载
    if (_state == _UpdState.downloaded && _apkPath != null) {
      await _install();
      return;
    }
    setState(() {
      _state = _UpdState.downloading;
      _progress = 0;
    });
    try {
      final path = await UpdateService.instance
          .download(widget.info, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      setState(() {
        _apkPath = path;
        _state = _UpdState.downloaded;
      });
      await _install();
    } catch (e) {
      if (!mounted) return;
      setState(() => _state = _UpdState.idle);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('更新失败：$e')));
    }
  }

  /// 调系统安装器。成功拉起 → 进 installing 态；失败回退（缓存仍在，可重试不重下）。
  Future<void> _install() async {
    if (_apkPath == null) return;
    setState(() => _state = _UpdState.installing);
    try {
      await UpdateService.instance.install(_apkPath!);
      // 安装页已弹出。用户若取消安装回到 App，弹窗保持「立即安装」，可再点。
    } catch (e) {
      if (!mounted) return;
      setState(() => _state = _UpdState.downloaded);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('安装失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('发现新版本',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('v${info.versionName}',
                style: TextStyle(fontSize: 14, color: context.brand)),
            const SizedBox(height: 10),
            Text(info.note.isEmpty ? '修复已知问题，优化使用体验' : info.note,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, height: 1.6, color: context.tSub)),
            if (info.size > 0) ...[
              const SizedBox(height: 8),
              Text('安装包 ${UpdateService.fmtSize(info.size)}',
                  style: TextStyle(fontSize: 12, color: context.tFaint)),
            ],
            const SizedBox(height: 16),
            if (_state == _UpdState.downloading) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _progress.clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: context.chipBg,
                  color: context.brand,
                ),
              ),
              const SizedBox(height: 6),
              Text('下载中 ${(_progress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(fontSize: 12, color: context.tFaint)),
            ] else ...[
              if (_state == _UpdState.downloaded) ...[
                Text('✓ 安装包已就绪，点「立即安装」即可（不会重新下载）',
                    style: TextStyle(fontSize: 12, color: context.tFaint)),
                const SizedBox(height: 8),
              ],
              if (_state == _UpdState.installing)
                Text('正在打开系统安装器…',
                    style: TextStyle(fontSize: 12, color: context.tFaint)),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (!info.force)
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final nav = Navigator.of(context);
                          await UpdateService.instance
                              .setSkipped(info.versionCode);
                          if (!mounted) return;
                          nav.pop();
                        },
                        child: const Text('稍后'),
                      ),
                    ),
                  if (!info.force) const SizedBox(width: 12),
                  Expanded(
                    flex: info.force ? 2 : 1,
                    child: FilledButton(
                      onPressed: _startUpdate,
                      style: FilledButton.styleFrom(
                          backgroundColor: context.brand,
                          foregroundColor: Colors.white),
                      child: Text(_state == _UpdState.downloaded
                          ? '立即安装'
                          : '立即更新'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

