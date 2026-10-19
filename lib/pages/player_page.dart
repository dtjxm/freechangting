/// 全屏播放器：横屏沉浸 + 手势（亮度/音量/快进）+ 倍速 + 选集 + 换源 + 进度记忆
/// v1.4.6：新增「换源」（查找其他片源的同名可播资源，片内直接切换）；
/// 画面比例补齐 9:16 档位（v1.4.5 已有渲染分支但档位标签遗漏，导致按钮循环不到）
library;

import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:video_player/video_player.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../api.dart';
import '../download_service.dart';
import '../local_proxy.dart';
import '../models.dart';
import '../store.dart';
import '../vod_source_health.dart';
import 'player_widgets.dart';

class PlayerPage extends StatefulWidget {
  final MovieSource source;
  final VideoDetail detail;
  final int groupIndex;
  final int epIndex;
  final Duration? initialPosition;

  const PlayerPage({
    super.key,
    required this.source,
    required this.detail,
    required this.groupIndex,
    required this.epIndex,
    this.initialPosition,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  VideoPlayerController? _vp;
  bool _initialized = false;
  // v1.9.9 播放代号（代码审查 3.2）：每次 _play() 递增；异步等待点之后必须
  // 核对代号与控制器归属，过期请求只丢弃自己的控制器、绝不触碰页面状态
  int _playGen = 0;
  String? _error;
  bool _showControls = true;
  Timer? _hideTimer;
  double? _dragStartBrightness;
  double? _dragStartVolume;
  double _currentVolume = 0.8;
  double _currentBrightness = 0.5;
  String? _gestureHint;
  int _arMode = 0; // 0 原比 1 铺满 2 16:9 3 4:3 4 9:16
  int _rotation = 0; // v1.4.7 画面旋转：0/1/2/3 个 90°
  // v2.2.0：去广告改为「清单净化」——在线流先经本地代理删掉广告分片再交给播放器。
  // 播放器侧不再做任何跳段/快进（原 v1.4.5 画幅突变检测已整体下线）。
  static const _arLabels = ['原比', '铺满', '16:9', '4:3', '9:16'];
  // v1.6.1 比例切换顺序：原比 → 9:16 → 16:9 → 4:3 → 铺满 → 循环
  static const _arCycle = [0, 4, 2, 3, 1];
  double _pressSpeed = 1.0; // 长按前的倍速（中部长按 3 倍速用）
  // v2.2.7：用户选择的播放倍速。换源/换线路会重建 controller，_play() 里必须重设，
  // 否则每次换源都会回落成 1.0。网络点播 / 本地 file:// / content:// 三条路径共用本页。
  double _speed = 1.0;
  // v1.5.2 按住倍速快进/快退：按住屏幕左侧持续快退、右侧持续快进，倍速渐增
  Timer? _holdTimer;
  int _seekDir = 0; // -1 快退 / 1 快进 / 0 未按住
  bool _speedHold = false; // 中部长按：3 倍速播放
  DateTime _holdStart = DateTime.now();
  bool _switchingSource = false; // v1.4.6 换源查找中
  bool _isLocalFile = false; // v1.6.0 本地下载文件播放
  // v1.5.4 线路自动切换：播放失败自动换下一条线路，全部失败才提示换源
  final Set<int> _triedLines = {};
  bool _autoSwitching = false;

  // v2.2.8 点播回退状态机：
  //   线路失败 → 本片源其余线路 → 同名搜索换源（最多 3 个）→ 明确报错。
  // _triedSources 记录本轮已尝试的片源 id；_fallbackStatus 是自动回退期间
  // 常驻在加载动画下方的状态文案（_showHint 只有 0.8 秒，来不及读完）。
  final Set<int> _triedSources = {};
  int _autoSourceTries = 0;
  static const int _maxAutoSources = 3;
  String? _fallbackStatus;
  Timer? _sourceHealthTimer;

  /// 用户手动起播代号。自动回退期间用户一旦手动换集/换源，
  /// 回退流程必须在下一个检查点立刻让路，不能把用户的选择覆盖掉。
  int _manualPlayGen = 0;

  /// 最近一次「确实播到过」的位置。换线路/换源时用它续播，
  /// 而不是用失败控制器上的 0（起播失败时 position 一直是 0）。
  Duration _lastGoodPos = Duration.zero;

  /// 片源稳定播放 20 秒才算健康 —— 起播即卡住的线路不能重置失败计数。
  static const Duration _sourceHealthyAfter = Duration(seconds: 20);
  // v1.9.0 顶栏时间展示：播放中不用退出也能看时间
  Timer? _clockTimer;
  String _clock = '';

  // v2.2.2（A3）：进度记录时间戳节流 —— 每 10 秒最多记一次；
  // 原 `pos % 10 == 0` 依赖回调恰好落在整 10 秒，会漏记且写盘频繁。
  DateTime _lastProgSave = DateTime.fromMillisecondsSinceEpoch(0);

  // v1.4.6：可变片源/影片（换源时替换 widget 传入的初始值）
  late VideoDetail _detail;
  late MovieSource _source;

  late int _group;
  late int _ep;

  Episode get _current => _detail.groups[_group].episodes[_ep];

  @override
  void initState() {
    super.initState();
    _detail = widget.detail;
    _source = widget.source;
    _group = widget.groupIndex;
    _ep = widget.epIndex;
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    // v1.9.0：顶栏时钟（每 10 秒刷新，分钟级展示足够）
    _clock = _nowClock();
    _clockTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() => _clock = _nowClock());
    });
    VolumeController.instance.addListener((v) {
      if (mounted) setState(() => _currentVolume = v);
    });
    _play(widget.initialPosition);
  }

  /// 起播当前 [from] 位置。
  ///
  /// 返回是否真正初始化成功。**自动回退必须自己检查返回值并继续尝试**：
  /// `autoRetry: true` 时本方法不会自行调度下一轮（旧实现里内层回退会被
  /// `_autoSwitching` 守卫挡住，导致整条回退链只走一步就停）。
  Future<bool> _play(Duration? from, {bool autoRetry = false}) async {
    if (!autoRetry) {
      // 手动起播/换集/换源：重置本轮回退记录与续播位置
      _manualPlayGen++;
      _triedLines.clear();
      _triedSources
        ..clear()
        ..add(_source.id);
      _autoSourceTries = 0;
      _lastGoodPos = from ?? Duration.zero;
      _fallbackStatus = null;
    }
    _sourceHealthTimer?.cancel();
    final gen = ++_playGen; // v1.9.9 本轮播放代号
    setState(() {
      _initialized = false;
      _error = null;
    });
    // v1.9.9：先把 _vp 置空再异步销毁旧控制器 —— 销毁期间 UI/其他逻辑不会
    // 误用旧控制器；若销毁期间又有新 _play()（代号变化），本轮立即作废
    final old = _vp;
    _vp = null;
    if (old != null) {
      try {
        await old.dispose();
      } catch (_) {}
    }
    if (!mounted || gen != _playGen) return false;
    final url = _current.url;
    // v1.6.0：本地下载文件（file://）与在线流分开构建控制器；
    // v1.9.5：content://（媒体库恢复/文件管理外部视频）走专用控制器
    // v2.2.0：在线流先包一层本地「清单净化」代理（代理只改写 m3u8 文本，
    //         分片仍由播放器直连源站，不额外占带宽；本地文件已是干净的，不走代理）
    final isLocal = url.startsWith('file:') || url.startsWith('content:');
    final playUrl = isLocal ? url : await _proxiedUrl(url);
    // v2.2.0 修复：在线 m3u8 显式声明 HLS 格式，避免 ExoPlayer 仅按 URL 后缀
    // 推断媒体类型时把「本地代理地址」误判为渐进式媒体 → 全量点播播不出来。
    // （本地文件不需要，直接给 null 保持原行为）
    final hlsHint = (!isLocal && AdFilterProxy.isHlsUrl(url))
        ? VideoFormat.hls
        : null;
    final vp = url.startsWith('content:')
        ? VideoPlayerController.contentUri(Uri.parse(url))
        : isLocal
        ? VideoPlayerController.file(File.fromUri(Uri.parse(url)))
        : VideoPlayerController.networkUrl(
            Uri.parse(playUrl),
            formatHint: hlsHint,
            httpHeaders: const {
              'User-Agent': 'Mozilla/5.0 (Linux; Android 13) Chrome/126.0',
            },
          );
    _isLocalFile = isLocal;
    _vp = vp;
    try {
      await vp.initialize();
      // v1.9.9：初始化期间已被更新请求取代/页面已销毁 → 丢弃本控制器，
      // 不再添加监听、不更新 _initialized，旧画面状态得以保留给新请求
      if (!mounted || gen != _playGen || _vp != vp) {
        try {
          await vp.dispose();
        } catch (_) {}
        return false;
      }
      var start = from ?? Duration.zero;
      // v1.5.7：记录的进度已超片长（换线路片源时长不同等）→ 从头播
      if (vp.value.duration > Duration.zero && start >= vp.value.duration) {
        start = Duration.zero;
      }
      if (start > Duration.zero) await vp.seekTo(start);
      if (!mounted || gen != _playGen || _vp != vp) {
        try {
          await vp.dispose();
        } catch (_) {}
        return false;
      }
      await vp.play();
      if (!mounted || gen != _playGen || _vp != vp) {
        try {
          await vp.dispose();
        } catch (_) {}
        return false;
      }
      vp.addListener(_onTick);
      // v2.2.7：把用户选的倍速落到新建的 controller 上（换源/换集后保持倍速）。
      // 不 await —— 避免在 addListener 与 setState 之间多一个挂起点。
      unawaited(vp.setPlaybackSpeed(_speed));
      setState(() {
        _initialized = true;
        _fallbackStatus = null;
      });
      // 稳定播放 20 秒后才给片源记「成功」：起播即卡住的线路不能洗白。
      // 本地文件（sourceId == -1）不参与片源健康度。
      final sourceId = _source.id;
      if (sourceId >= 0) {
        _sourceHealthTimer = Timer(_sourceHealthyAfter, () {
          if (!mounted || !_initialized || _error != null) return;
          if (_vp != vp || !vp.value.isInitialized || vp.value.hasError) return;
          if (_source.id != sourceId) return;
          VodSourceHealth.markSuccess(sourceId);
        });
      }
      _armHide();
      return true;
    } catch (e) {
      // v1.9.9：过期请求的失败不再触发自动换线路（避免旧失败覆盖新播放）
      if (!mounted || gen != _playGen || _vp != vp) {
        try {
          await vp.dispose();
        } catch (_) {}
        return false;
      }
      // 自动回退流程自己会根据返回值继续尝试，不能在这里再调度一轮。
      if (autoRetry) return false;
      // v1.5.4：播放失败自动切换下一条线路，全部失败再换源
      unawaited(_autoNextLine());
      return false;
    }
  }

  /// v1.6.0：下载当前集（加入串行队列， Movies/电影世界/片名/）
  Future<void> _downloadCurrent() async {
    final item = _detail.item;
    final existing = DownloadService.instance.taskOf(
      item.sourceId,
      item.vodId,
      _ep,
    );
    if (existing != null && existing.state != 'failed') {
      _showHint(existing.state == 'done' ? '该集已下载' : '该集已在下载队列中');
      return;
    }
    await DownloadService.instance.addTasks([
      DownloadTask(
        id: '${item.sourceId}|${item.vodId}|$_group|$_ep',
        sourceId: item.sourceId,
        sourceName: item.sourceName,
        vodId: item.vodId,
        movieName: item.name,
        groupIndex: _group,
        groupName: _detail.groups[_group].from,
        epIndex: _ep,
        epName: _current.name,
        url: _current.url,
        subcat: item.typeName, // v1.9.8 软件二级分类
      ),
    ]);
    _showHint('已加入下载队列，可在「我的-下载」中查看进度');
  }

  /// v1.5.4 / v2.2.8 自动回退状态机：
  ///   当前线路失败 → 本片源其余线路 → 同名搜索换源（最多 3 个）→ 明确报错。
  ///
  /// 整个流程只持有一把 `_autoSwitching` 锁，内部通过 [_tryRemainingLines]
  /// 等待每一次 [_play] 的结果，失败后接着试下一个 —— 不会再出现
  /// 「切了一条线路就停住、一直转圈」的情况。
  Future<void> _autoNextLine() async {
    if (_autoSwitching || !mounted || _error != null) return;
    _autoSwitching = true;
    final manual = _manualPlayGen; // 本轮回退属于哪一次用户操作
    try {
      _triedLines.add(_group);
      if (await _tryRemainingLines(_group + 1, manual)) return;

      // 当前片源所有线路都失败 → 记一次片源级失败（单条线路失败不记）。
      // 本地文件（sourceId == -1）不参与片源健康度。
      if (_source.id >= 0) VodSourceHealth.markFailure(_source.id);
      if (!mounted) return;
      setState(() => _fallbackStatus = '当前片源不可用，正在搜索其他片源…');

      final results = await _searchSameName();
      if (!mounted || manual != _manualPlayGen) return;

      for (final d in results) {
        if (!mounted || manual != _manualPlayGen) return;
        if (_autoSourceTries >= _maxAutoSources) break;
        if (_triedSources.contains(d.item.sourceId)) continue;
        final src = _sourceOf(d);
        if (src == null) continue;

        _triedSources.add(src.id);
        _autoSourceTries++;
        setState(() => _fallbackStatus = '正在尝试「${src.name}」…');
        _adoptDetail(d, src);
        _triedLines.clear();
        if (await _tryRemainingLines(0, manual)) return;

        if (src.id >= 0) VodSourceHealth.markFailure(src.id);
      }

      if (!mounted || manual != _manualPlayGen) return;
      setState(() {
        _fallbackStatus = null;
        final tried = _autoSourceTries > 0
            ? '已尝试当前片源全部线路及另外 $_autoSourceTries 个同名片源'
            : '已尝试当前片源全部线路';
        _error = '播放失败：$tried，均无法播放，请稍后重试或点右上角「换源」手动选择';
      });
      _triedLines.clear(); // 允许用户手动重试
      _triedSources.clear();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _fallbackStatus = null;
        _error = '播放失败：自动切换线路时出错，请点「重试」或右上角「换源」';
      });
    } finally {
      _autoSwitching = false;
    }
  }

  /// 从 [start] 开始环形尝试本片源尚未试过的线路；成功返回 true。
  ///
  /// 续播位置用 [_lastGoodPos]：失败线路的 position 一直是 0，拿它续播
  /// 会把用户直接甩回片头。
  Future<bool> _tryRemainingLines(int start, int manualGen) async {
    final groups = _detail.groups;
    if (groups.isEmpty) return false;

    for (var step = 0; step < groups.length; step++) {
      // 用户已手动换台/换源 → 视为「本轮回退已被取代」，直接结束。
      if (!mounted || manualGen != _manualPlayGen) return true;
      final cand = (start + step) % groups.length;
      if (_triedLines.contains(cand)) continue;
      if (groups[cand].episodes.isEmpty) {
        _triedLines.add(cand);
        continue;
      }
      final newEp = _ep < groups[cand].episodes.length ? _ep : 0;
      setState(() {
        _group = cand;
        _ep = newEp;
        _fallbackStatus = '正在尝试线路 ${cand + 1}…';
      });
      if (await _play(_lastGoodPos, autoRetry: true)) return true;
      if (!mounted || manualGen != _manualPlayGen) return true;
      _triedLines.add(cand);
    }
    return false;
  }

  /// 跨源同名搜索。超时/异常按「没有结果」处理，保证回退流程能走到明确报错。
  Future<List<VideoDetail>> _searchSameName() async {
    try {
      final results = await MacApi.instance
          .searchSameNameAllSources(_detail.item.name, _source)
          .timeout(const Duration(seconds: 25));
      // 健康片源优先；权重相同保持搜索完成顺序（稳定排序）。
      return VodSourceHealth.order(results, (d) => d.item.sourceId);
    } catch (_) {
      return const <VideoDetail>[];
    }
  }

  MovieSource? _sourceOf(VideoDetail d) => MacApi.instance.sources
      .where((s) => s.id == d.item.sourceId)
      .firstOrNull;

  /// 把播放页切换到另一个片源的同名资源（不负责起播）。
  void _adoptDetail(VideoDetail d, MovieSource src) {
    final epsCount = d.groups.isNotEmpty ? d.groups.first.episodes.length : 0;
    setState(() {
      _detail = d;
      _source = src;
      _group = 0;
      _ep = epsCount > 0 ? _ep.clamp(0, epsCount - 1) : 0;
    });
  }

  double _dblX = -1;

  /// 按当前比例模式渲染视频（外层叠加 v1.4.7 旋转）
  Widget _videoLayer() {
    final inner = _videoInner();
    if (_rotation == 0) return inner;
    return RotatedBox(quarterTurns: _rotation, child: inner);
  }

  Widget _videoInner() {
    final vp = _vp!;
    final vAr = vp.value.aspectRatio;
    final safe = (vAr <= 0 || vAr.isNaN || vAr.isInfinite) ? 16 / 9 : vAr;
    switch (_arMode) {
      case 1: // 铺满（拉伸填满屏幕）
        // v1.9.5 修复：FittedBox 在 Center 内会收缩到子控件尺寸（约 178x100 逻辑像素），
        // 导致点「铺满」画面反而变小；外层 SizedBox.expand 强制充满父容器后再拉伸（靳老师）
        return SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.fill,
            child: SizedBox(
              width: 100 * safe,
              height: 100,
              child: VideoPlayer(vp),
            ),
          ),
        );
      case 2:
        return AspectRatio(aspectRatio: 16 / 9, child: VideoPlayer(vp));
      case 3:
        return AspectRatio(aspectRatio: 4 / 3, child: VideoPlayer(vp));
      case 4: // 9:16 竖屏（适配竖屏拍摄/短视频内容）
        return AspectRatio(aspectRatio: 9 / 16, child: VideoPlayer(vp));
      default:
        return AspectRatio(aspectRatio: safe, child: VideoPlayer(vp));
    }
  }

  void _onTick() {
    if (!mounted) return;
    final v = _vp;
    if (v == null) return;
    // v1.5.4：播放中途出错（解码/断流等）→ 自动切换下一条线路
    if (v.value.hasError && mounted) {
      unawaited(_autoNextLine());
      return;
    }
    // 记录真实播到过的位置，供换线路/换源续播。
    if (v.value.position > _lastGoodPos) _lastGoodPos = v.value.position;
    if (v.value.isCompleted && mounted) {
      // 自动下一集（可在设置中关闭）
      final eps = _detail.groups[_group].episodes;
      if (_ep + 1 < eps.length && AppStore.instance.autoNext) {
        setState(() => _ep++);
        _play(null);
      }
    }
    // v2.2.2（A3）：时间戳节流省流 —— 每 10 秒最多记一次，且不会因回调落在
    // 非整 10 秒而漏记（原 `pos % 10 == 0` 会漏记，且写盘过于频繁）
    final pos = v.value.position.inSeconds;
    if (pos > 0 && DateTime.now().difference(_lastProgSave).inSeconds >= 10) {
      _lastProgSave = DateTime.now();
      AppStore.instance.saveHistory(
        _detail.item,
        _current.name,
        _ep,
        pos,
        groupIndex: _group,
      );
    }
    if (mounted) setState(() {});
  }

  /// 在线播放地址 → 本地「清单净化」代理地址。
  ///
  /// 代理只改写 m3u8 文本并把广告分片删掉，随后播放器按清单里的绝对地址
  /// 直连源站拉分片，**不经过本 App 转发**，因此不额外占带宽。
  /// 服务没起来时原样返回，保证最坏情况仍能正常播放。
  Future<String> _proxiedUrl(String url) async {
    if (!AppStore.instance.adSkip) return url;
    try {
      AdFilterProxy.instance.enabled = true;
      await AdFilterProxy.instance.start();
      return AdFilterProxy.instance.proxyUrl(url);
    } catch (_) {
      return url; // 代理不可用 → 退回直连，绝不阻断播放
    }
  }

  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && (_vp?.value.isPlaying ?? false)) {
        setState(() => _showControls = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _armHide();
  }

  Future<void> _seekRelative(int seconds) async {
    final vp = _vp;
    if (vp == null) return;
    var target = vp.value.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (target > vp.value.duration) target = vp.value.duration;
    await vp.seekTo(target);
    _showHint(seconds > 0 ? '快进 ${seconds.abs()}s' : '快退 ${seconds.abs()}s');
  }

  /// v1.5.3 按住手势：左/右侧按住 → 倍速快退/快进（3 倍起，每按住 0.5 秒升 1 档，
  /// 最高 20 倍，实时定位）；中间按住 → 3 倍速播放（松开恢复）
  void _onHoldStart(double x) {
    final vp = _vp;
    if (vp == null || !_initialized) return;
    final w = context.size?.width ?? 1;
    if (x < w * 0.35) {
      _startHoldSeek(-1);
    } else if (x > w * 0.65) {
      _startHoldSeek(1);
    } else {
      _speedHold = true;
      _pressSpeed = vp.value.playbackSpeed;
      vp.setPlaybackSpeed(3.0);
      _showHint('3 倍速播放中');
    }
  }

  void _startHoldSeek(int dir) {
    _seekDir = dir;
    _holdStart = DateTime.now();
    _holdTimer?.cancel();
    _holdTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final vp = _vp;
      if (vp == null || !mounted) return;
      final held = DateTime.now().difference(_holdStart).inMilliseconds / 1000;
      // v1.5.6：每 0.5 秒升 1 档，3 → 4 → 5 … 最高 50 倍逐级递增
      final rate = (3 + (held / 0.5).floor()).clamp(3, 50);
      var target = vp.value.position + Duration(milliseconds: 200 * rate * dir);
      if (target < Duration.zero) target = Duration.zero;
      if (target > vp.value.duration) target = vp.value.duration;
      unawaited(vp.seekTo(target));
      setState(
        () =>
            _gestureHint = '${dir > 0 ? "快进" : "快退"} $rate 倍 · ${_fmt(target)}',
      );
    });
    setState(() => _gestureHint = dir > 0 ? '按住快进 3 倍…' : '按住快退 3 倍…');
  }

  void _onHoldEnd() {
    _holdTimer?.cancel();
    _holdTimer = null;
    final vp = _vp;
    if (_speedHold) {
      _speedHold = false;
      if (vp != null) {
        vp.setPlaybackSpeed(_pressSpeed);
        _showHint('已恢复 ${_speedLabel(_pressSpeed)} 倍速');
      }
    } else if (_seekDir != 0 && vp != null) {
      _seekDir = 0;
      _showHint('已定位至 ${_fmt(vp.value.position)}');
    }
  }

  void _showHint(String text) {
    setState(() => _gestureHint = text);
    Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _gestureHint = null);
    });
  }

  /// v2.2.7：播放倍速面板（面板实现见 player_widgets.dart）
  void _showSpeedSheet() {
    showVodSpeedSheet(
      context,
      current: _speed,
      onPick: (s) async {
        setState(() => _speed = s);
        await _vp?.setPlaybackSpeed(s);
        if (!mounted) return;
        _showHint('${vodSpeedText(s)} 倍速');
        _armHide();
      },
    );
  }
  /// v1.9.0：当前系统时间 HH:mm
  static String _nowClock() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _playGen++; // v1.9.9：作废尚未完成的播放请求，过期控制器只自弃不碰页面
    _hideTimer?.cancel();
    _holdTimer?.cancel();
    _clockTimer?.cancel();
    _sourceHealthTimer?.cancel();
    final vp = _vp;
    if (vp != null) {
      AppStore.instance.saveHistory(
        _detail.item,
        _current.name,
        _ep,
        vp.value.position.inSeconds,
        groupIndex: _group,
      );
      vp.removeListener(_onTick);
      vp.dispose();
    }
    VolumeController.instance.removeListener();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // v2.2.2（D1）：原 PopScope(canPop: true) 恒真、包装无作用 → 去掉包装，直接返回子树
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        onDoubleTapDown: (d) => _dblX = d.localPosition.dx,
        onDoubleTap: () async {
          final vp = _vp;
          if (vp == null) return;
          final w = context.size?.width ?? 1;
          if (_dblX < w * 0.35) {
            await _seekRelative(-10); // 双击左侧：快退 10 秒
          } else if (_dblX > w * 0.65) {
            await _seekRelative(10); // 双击右侧：快进 10 秒
          } else {
            vp.value.isPlaying ? await vp.pause() : await vp.play();
            _toggleControls();
          }
        },
        onLongPressStart: (d) => _onHoldStart(d.localPosition.dx),
        onLongPressEnd: (_) => _onHoldEnd(),
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v > 200) _seekRelative(-10);
          if (v < -200) _seekRelative(10);
        },
        onVerticalDragStart: _onVStart,
        onVerticalDragUpdate: _onVUpdate,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 视频层（画面比例：原比/铺满/16:9/4:3/9:16 可切换）
            Center(
              child: _initialized && _vp != null
                  ? _videoLayer()
                  : _error != null
                  ? buildVodError(context, _error!, () => _play(null))
                  : _buildLoading(),
            ),
            if (_gestureHint != null)
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Text(
                    _gestureHint!,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                  ),
                ),
              ),
            if (_showControls) _buildControls(),
          ],
        ),
      ),
    );
  }

  /// 加载态：自动回退期间在转圈下方常驻显示当前阶段。
  Widget _buildLoading() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(color: Colors.redAccent),
        if (_fallbackStatus != null) ...[
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              _fallbackStatus!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ],
      ],
    );
  }

  void _onVStart(DragStartDetails d) {
    final w = context.size?.width ?? 1;
    if (d.localPosition.dx < w / 2) {
      _dragStartVolume = _currentVolume; // 左侧：音量
      _dragStartBrightness = null;
    } else {
      _dragStartBrightness = _currentBrightness; // 右侧：亮度
      _dragStartVolume = null;
    }
  }

  void _onVUpdate(DragUpdateDetails d) {
    final h = context.size?.height ?? 1;
    final delta = -d.delta.dy / h;
    if (_dragStartBrightness != null) {
      var v = (_dragStartBrightness! + delta).clamp(0.01, 1.0);
      _currentBrightness = v;
      ScreenBrightness.instance.setApplicationScreenBrightness(v).ignore();
      _showHint('亮度 ${(v * 100).round()}%');
    } else if (_dragStartVolume != null) {
      var v = (_dragStartVolume! + delta).clamp(0.0, 1.0);
      _currentVolume = v;
      VolumeController.instance.setVolume(v);
      _showHint('音量 ${(v * 100).round()}%');
    }
  }

  Widget _buildControls() {
    final vp = _vp;
    final eps = _detail.groups[_group].episodes;
    final pos = vp?.value.position ?? Duration.zero;
    final dur = vp?.value.duration ?? const Duration(days: 1);
    final playing = vp?.value.isPlaying ?? false;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black54,
            Colors.transparent,
            Colors.transparent,
            Colors.black54,
          ],
          stops: [0, 0.18, 0.75, 1],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 顶部栏
          SafeArea(
            bottom: false,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                Expanded(
                  child: Text(
                    '${_detail.item.name} · ${_current.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
                // v1.9.0：顶栏展示当前时间，播放中无需退出即可查看
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    _clock,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                // v1.5.5：线路选择（当前片源多条播放线路时显示）
                if (_detail.groups.length > 1)
                  TextButton(
                    onPressed: _showLineSheet,
                    child: Text(
                      '线路(${_detail.groups.length})',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                TextButton(
                  onPressed: _switchSource,
                  child: Text(
                    _switchingSource ? '找片中…' : '换源',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                // v1.6.0：下载当前集（本地文件播放时不显示）
                if (!_isLocalFile)
                  TextButton(
                    onPressed: _downloadCurrent,
                    child: const Text(
                      '下载',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                TextButton(
                  onPressed: () => _showEpSheet(eps),
                  child: Text(
                    '选集(${eps.length})',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      // v1.6.1 循环顺序：原比 → 9:16 → 16:9 → 4:3 → 铺满 → 原比
                      final i = _arCycle.indexOf(_arMode);
                      _arMode = _arCycle[(i + 1) % _arCycle.length];
                    });
                    _showHint('画面比例：${_arLabels[_arMode]}');
                  },
                  child: Text(
                    _arLabels[_arMode],
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                // v1.4.9：旋转按钮改为文字（与其他顶部按钮统一）；v1.6.1 改为逆时针循环
                TextButton(
                  onPressed: () {
                    setState(() => _rotation = (_rotation + 3) % 4); // 逆时针 90°
                    _showHint(
                      _rotation == 0
                          ? '画面已复位'
                          : '已逆时针旋转 ${((4 - _rotation) % 4) * 90}°',
                    );
                  },
                  child: const Text(
                    '旋转',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                // v2.2.7：恢复倍速入口（用户需求），0.5/0.75/1.0/1.5/2.0 五档。
                // 只改表现层，长按 3 倍速与左右按住快进快退手势不受影响。
                TextButton(
                  onPressed: _showSpeedSheet,
                  child: Text(
                    _speed == 1.0 ? '倍速' : '${vodSpeedText(_speed)}x',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          // 底部栏
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      playing ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                      size: 30,
                    ),
                    onPressed: () async {
                      if (vp == null) return;
                      playing ? await vp.pause() : await vp.play();
                      _armHide();
                      setState(() {});
                    },
                  ),
                  Text(
                    _fmt(pos),
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 12,
                        ),
                      ),
                      child: Slider(
                        value: pos.inMilliseconds
                            .clamp(0, dur.inMilliseconds)
                            .toDouble(),
                        max: dur.inMilliseconds == 0
                            ? 1
                            : dur.inMilliseconds.toDouble(),
                        activeColor: Colors.redAccent,
                        inactiveColor: Colors.white24,
                        onChanged: (v) async {
                          await vp?.seekTo(Duration(milliseconds: v.toInt()));
                          _armHide();
                          setState(() {});
                        },
                      ),
                    ),
                  ),
                  Text(
                    _fmt(dur),
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                  if (_ep + 1 < eps.length)
                    IconButton(
                      icon: const Icon(Icons.skip_next, color: Colors.white),
                      tooltip: '下一集',
                      onPressed: () {
                        setState(() => _ep++);
                        _play(null);
                      },
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// v1.4.6 换源：并发查找其他片源的同名可播资源，弹窗选择后片内直接切换
  Future<void> _switchSource() async {
    if (_switchingSource) return;
    setState(() => _switchingSource = true);
    _showHint('正在查找其他片源的同名影片…');
    final results = await _searchSameName();
    if (!mounted) return;
    setState(() => _switchingSource = false);
    if (results.isEmpty) {
      _showHint('其他片源暂无同名可播资源');
      return;
    }
    _hideTimer?.cancel();
    showVodSourceSheet(context, results, _applySource);
  }

  /// 应用换源：记住当前集号（按新源集数收敛），保存进度后从新源重新起播
  void _applySource(VideoDetail d) {
    final src = _sourceOf(d) ?? _source;
    final pos = _vp?.value.position.inSeconds ?? 0;
    if (pos > 0) {
      AppStore.instance.saveHistory(
        _detail.item,
        _current.name,
        _ep,
        pos,
        groupIndex: _group,
      );
    }
    _adoptDetail(d, src);
    _showHint('已切换到「${d.item.sourceName}」');
    // 手动换源 = 新一轮尝试，_play(autoRetry: false) 会清空回退记录。
    // 从最后一次真实播放位置续播，而不是甩回片头。
    unawaited(_play(_lastGoodPos));
  }

  /// v1.5.5 线路选择弹层：当前片源下的多条播放线路单选切换
  void _showLineSheet() {
    _hideTimer?.cancel();
    final groups = _detail.groups;
    showVodLineSheet(
      context,
      groups: groups,
      current: _group,
      onPick: (i) {
        setState(() {
          _group = i;
          if (_ep >= groups[i].episodes.length) _ep = 0;
        });
        // 手动切线路保留当前播放位置。
        _play(_lastGoodPos);
      },
    ).then((_) => _armHide());
  }

  void _showEpSheet(List<Episode> eps) {
    _hideTimer?.cancel();
    final g = _detail.groups[_group];
    showVodEpSheet(
      context,
      title: g.from.isEmpty ? '选集（线路${_group + 1}）' : '选集（${g.from}）',
      episodes: eps,
      current: _ep,
      onPick: (i) {
        setState(() => _ep = i);
        _play(null);
      },
    ).then((_) => _armHide());
  }

  static String _speedLabel(double s) =>
      s == 1.0 ? '1' : (s == 2.0 ? '2' : '$s'.replaceAll('0.', '.'));

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60), s = d.inSeconds.remainder(60);
    final h = d.inHours;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
