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

  /// v2.4.0：内嵌模式 —— 作为详情页的小窗 / 全屏层使用。
  /// 不套 Scaffold、不自行 pop，屏幕方向由 [fullscreen] 与视频比例决定。
  final bool embedded;

  /// 内嵌模式下当前是否全屏。切换只改父级约束，播放器实例不变。
  final bool fullscreen;

  /// 内嵌模式：点「退出全屏」按钮时的回调。
  final VoidCallback? onExitFullscreen;

  /// 内嵌模式：点小窗上的「全屏」按钮时的回调。
  final VoidCallback? onToggleFullscreen;

  /// v2.4.3：详情页点下方选集时的联动请求。每次点击 token 自增，
  /// 已存在的播放器在 didUpdateWidget 里切集并起播，不用重建页面。
  final int jumpGroup;
  final int jumpEp;
  final int jumpToken;

  /// v2.4.4：实际开始播放某一集时回调（含自动联播跳到下一集）。
  /// 详情页据此把「正在播放」的选集按钮高亮，避免高亮与实际播放脱节。
  final void Function(int group, int ep)? onEpisodeChanged;

  const PlayerPage({
    super.key,
    required this.source,
    required this.detail,
    required this.groupIndex,
    required this.epIndex,
    this.initialPosition,
    this.embedded = false,
    this.fullscreen = false,
    this.onExitFullscreen,
    this.onToggleFullscreen,
    this.jumpGroup = 0,
    this.jumpEp = 0,
    this.jumpToken = 0,
    this.onEpisodeChanged,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  VideoPlayerController? _vp;
  bool _initialized = false;
  // v1.9.9 播放代号（代码审查 3.2）：每次 _play() 递增；异步等待点之后必须
  // 核对代号与控制器归属，过期请求只丢弃自己的控制器、绝不触碰页面状态
  int _playGen = 0;
  String? _error;
  bool _showControls = true;
  int _notifiedGroup = -1;
  int _notifiedEp = -1;

  /// v2.4.1：小窗点「播放」后短暂显示「播放中」交互动画
  bool _playFlash = false;
  Timer? _flashTimer;
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

  /// v2.4.3：自动联播只触发一次 —— isCompleted 会连续多个 tick 为 true，
  /// 原实现可能一次播完连跳好几集。
  bool _autoNextFired = false;

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

  /// v2.4.0（P2-1）：源异常时 duration 会返回 24:00:00 这类离谱值。
  /// 超过 12 小时一律视为「时长未知」，进度条按未知处理，不显示假总时长。
  static bool _saneDuration(Duration d) =>
      d > Duration.zero && d <= const Duration(hours: 12);

  /// v2.4.0（P2-2）：把底层异常翻译成用户能懂的失败原因，
  /// 供最终错误文案展示（断网时不能再只显示「均无法播放」）。
  String _failHint = '';

  static String _describeError(Object e) {
    final s = e.toString();
    if (e is TimeoutException || s.contains('TimeoutException')) return '线路连接超时';
    if (e is SocketException ||
        s.contains('SocketException') ||
        s.contains('Failed host lookup') ||
        s.contains('Network is unreachable')) {
      return '网络未连接';
    }
    if (s.contains('403')) return '线路拒绝访问';
    if (s.contains('404')) return '线路资源不存在';
    if (s.contains('Source error') || s.contains('InvalidResponseCode')) {
      return '线路返回错误';
    }
    return '';
  }

  /// v2.4.0（P1-2）：退到后台自动暂停，回前台恢复。
  /// 原实现没有生命周期处理，按 Home 后视频继续解码播放（耗流量、可能出声）。
  bool _pausedByLifecycle = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final vp = _vp;
    if (vp == null || !_initialized) return;
    if (state == AppLifecycleState.paused) {
      _pausedByLifecycle = vp.value.isPlaying;
      if (_pausedByLifecycle) {
        vp.pause().catchError((_) {});
        if (mounted) setState(() {});
      }
    } else if (state == AppLifecycleState.resumed) {
      // 后台期间系统可能重置方向，回前台按当前模式重新应用
      _applyOrientation();
      if (_pausedByLifecycle) {
        _pausedByLifecycle = false;
        vp.play().catchError((_) {});
        if (mounted) setState(() {});
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _detail = widget.detail;
    _source = widget.source;
    // v2.2.10 修复 P0：四个入口共用，统一收敛入参，杜绝越界崩溃
    final groups0 = widget.detail.groups;
    _group = groups0.isEmpty ? 0 : widget.groupIndex.clamp(0, groups0.length - 1);
    final eps0 = groups0.isEmpty ? const <Episode>[] : groups0[_group].episodes;
    _ep = eps0.isEmpty ? 0 : widget.epIndex.clamp(0, eps0.length - 1);
    // v2.4.0：方向不再写死横屏 —— 竖屏视频全屏要保持竖屏（用户需求第 6 条）
    _applyOrientation();
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

  /// v2.4.0：视频本身是竖屏（宽/高 < 1）。
  /// 全屏方向必须跟着片源走：竖屏短视频横过来看等于毁掉体验。
  bool get _isPortraitVideo {
    final r = _vp?.value.aspectRatio ?? 0;
    return r > 0 && r < 1.0;
  }

  /// v2.4.0：按「当前模式 + 视频比例」决定系统方向。
  /// 小窗固定竖屏；全屏时竖屏片走竖屏、横屏片走横屏。
  void _applyOrientation() {
    if (widget.embedded && !widget.fullscreen) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      return;
    }
    if (_isPortraitVideo) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void didUpdateWidget(PlayerPage old) {
    super.didUpdateWidget(old);
    if (widget.fullscreen != old.fullscreen) _applyOrientation();
    // v2.4.3：详情页点了另一集 → 直接在这里切集起播，保证上下联动
    if (widget.jumpToken != old.jumpToken) {
      final groups = _detail.groups;
      if (groups.isNotEmpty) {
        final g = widget.jumpGroup.clamp(0, groups.length - 1);
        final eps = groups[g].episodes;
        if (eps.isNotEmpty) {
          _group = g;
          _ep = widget.jumpEp.clamp(0, eps.length - 1);
          unawaited(_play(null));
        }
      }
    }
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
      _failHint = '';
    }
    _sourceHealthTimer?.cancel();
    _autoNextFired = false;
    // v2.4.4：把「当前播放的集」同步给详情页（自动联播换集也会走到这里）
    if (_group != _notifiedGroup || _ep != _notifiedEp) {
      _notifiedGroup = _group;
      _notifiedEp = _ep;
      widget.onEpisodeChanged?.call(_group, _ep);
    }
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
    // v2.2.10：空线路直接报错，避免 _current 越界
    if (_detail.groups.isEmpty || _detail.groups[_group].episodes.isEmpty) {
      setState(() => _error = '该影片暂无可播放线路');
      return false;
    }
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
      // v2.4.0（P1-1）：initialize() 必须带超时。源站不响应时原实现会无限
      // 等待，界面永久停在「正在尝试线路 N…」，既不出错也不换线。
      // 本地文件读取快，超时值放宽差异意义不大，统一 15 秒。
      await vp.initialize().timeout(const Duration(seconds: 15));
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
      if (_saneDuration(vp.value.duration) && start >= vp.value.duration) {
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
      // 起播成功后才知道真实宽高比：全屏时在这里校准横竖屏
      _applyOrientation();
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
      // v2.4.0（P2-2）：记录失败原因，供最终错误文案展示
      _failHint = _describeError(e);
      // v2.2.10：本轮控制器已初始化失败，及时释放，避免残留到退出播放页
      try {
        await vp.dispose();
      } catch (_) {}
      if (_vp == vp) _vp = null;
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
        final why = _failHint.isEmpty ? '' : '（本地原因：$_failHint）';
        _error = '播放失败：$tried$why，均无法播放，请稍后重试或点右上角「换源」手动选择';
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
      if (!_autoNextFired &&
          _ep + 1 < eps.length &&
          AppStore.instance.autoNext) {
        _autoNextFired = true;
        setState(() => _ep++);
        _play(null);
      }
    } else if (!v.value.isCompleted) {
      _autoNextFired = false;
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
      // v2.4.0：代理启动同样要有上限，否则本地 server 起不来时
      // 播放会卡在 await 上，界面上什么都看不到。
      await AdFilterProxy.instance.start().timeout(const Duration(seconds: 3));
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

  /// v2.4.1：点击规则（全屏 / 小窗统一）
  ///  · 全屏且控件隐藏 → 这一次只负责呼出控件
  ///  · 回调出后再点中部 → 播放 / 暂停
  ///  · 点左右两侧 → 显隐控件（不影响播放状态）
  /// 小窗控件常显，所以点中部直接就是播放 / 暂停。
  void _onTapUp(TapUpDetails d) {
    final size = context.size;
    final w = size?.width ?? 1;
    final h = size?.height ?? 1;
    final mini = widget.embedded && !widget.fullscreen;
    // 小窗底部进度条区域交给 Slider，不当作播放/暂停
    if (mini && d.localPosition.dy > h - 52) return;
    // 控件隐藏时，第一次点击只负责呼出；再点中部才切换播放（全屏/小窗统一）
    if (!_showControls) {
      setState(() => _showControls = true);
      _armHide();
      return;
    }
    final center =
        d.localPosition.dx > w * 0.28 && d.localPosition.dx < w * 0.72;
    if (mini || center) {
      _togglePlay();
    } else {
      setState(() => _showControls = !_showControls);
      if (_showControls) _armHide();
    }
  }

  Future<void> _togglePlay() async {
    final vp = _vp;
    if (vp == null || !vp.value.isInitialized) return;
    if (vp.value.isPlaying) {
      await vp.pause();
    } else {
      await vp.play();
      _flashPlaying();
    }
    if (mounted) setState(() {});
    _armHide();
  }

  /// 小窗点播放后展示约 1.1 秒「播放中」
  void _flashPlaying() {
    if (!widget.embedded || widget.fullscreen) return;
    _flashTimer?.cancel();
    setState(() => _playFlash = true);
    _flashTimer = Timer(const Duration(milliseconds: 1100), () {
      if (mounted) setState(() => _playFlash = false);
    });
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

  Timer? _hintTimer;

  void _showHint(String text) {
    setState(() => _gestureHint = text);
    // v2.2.10：取消上一条定时器，连续提示不会被前一条提前抹掉
    _hintTimer?.cancel();
    _hintTimer = Timer(const Duration(milliseconds: 800), () {
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
    WidgetsBinding.instance.removeObserver(this);
    _hintTimer?.cancel();
    _flashTimer?.cancel();
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
    // v2.4.0：小窗模式下禁用全屏手势（双击快进 / 长按倍速 / 上下滑调亮度），
    // 让上下滑穿透给详情页列表滚动；小窗只保留控制条上的播放与全屏按钮。
    final mini = widget.embedded && !widget.fullscreen;
    final content = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: _onTapUp,
      onDoubleTapDown: mini ? null : (d) => _dblX = d.localPosition.dx,
      onDoubleTap: mini
          ? null
          : () async {
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
      onLongPressStart: mini ? null : (d) => _onHoldStart(d.localPosition.dx),
      onLongPressEnd: mini ? null : (_) => _onHoldEnd(),
      onHorizontalDragEnd: mini
          ? null
          : (d) {
              final v = d.primaryVelocity ?? 0;
              if (v > 200) _seekRelative(-10);
              if (v < -200) _seekRelative(10);
            },
      onVerticalDragStart: mini ? null : _onVStart,
      onVerticalDragUpdate: mini ? null : _onVUpdate,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 视频层（画面比例：原比/铺满/16:9/4:3/9:16 可切换）
          Center(
            child: _initialized && _vp != null
                ? _videoLayer()
                : _error != null
                ? buildVodError(context, _error!, () => _play(null))
                // v2.4.6：小窗模式转圈移进中央按钮内，这里只留阶段文案
                : _buildLoading(showSpinner: !mini),
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
          // 小窗用极简控制条：完整控制栏在 375dp 竖屏下会横向溢出
          if (mini)
            _buildMiniOverlay()
          else if (_showControls)
            _buildControls(),
        ],
      ),
    );
    // 内嵌模式：不套 Scaffold（否则会盖掉详情页 AppBar 与背景）
    if (widget.embedded) {
      return ColoredBox(color: Colors.black, child: content);
    }
    return Scaffold(backgroundColor: Colors.black, body: content);
  }

  /// v2.4.1：小窗交互层 —— 中央播放按钮 + 底部可拖动进度条 +「播放中」动画。
  /// 所有可点元素都不拦截手势，点哪儿由外层 [_onTapUp] 统一判定，
  /// 保证「第一次点击呼出、第二次切换播放」的规则在全屏和小窗一致。
  Widget _buildMiniOverlay() {
    final vp = _vp;
    final playing = vp?.value.isPlaying ?? false;
    // v2.4.6：未起播且无错误 = 正在加载，中央按钮直接变成转圈，
    // 不再出现"播放按钮不动、按钮下方另起一个转圈"的割裂感。
    final loading = !_initialized && _error == null;
    final pos = vp?.value.position ?? Duration.zero;
    final raw = vp?.value.duration ?? Duration.zero;
    final dur = _saneDuration(raw) ? raw : Duration.zero;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 中央按钮：受控件显示态控制；播放中显示暂停图标，暂停时显示播放图标
        Center(
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 160),
              opacity: (_showControls && !_playFlash) ? 1.0 : 0.0,
              child: Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // 同样用不透明深色，避免在亮色画面上透色
                  color: const Color(0xCC1A1A1A),
                  border: Border.all(color: Colors.white70, width: 1.6),
                ),
                child: loading
                    ? const Padding(
                        padding: EdgeInsets.all(15),
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 32,
                        color: Colors.white,
                      ),
              ),
            ),
          ),
        ),
        if (_playFlash) Center(child: _buildPlayingFlash()),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _buildMiniProgress(pos, dur),
        ),
      ],
    );
  }

  /// 「播放中」交互动画：轻微放大的胶囊 + 转圈 + 文案
  Widget _buildPlayingFlash() {
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.88, end: 1.0),
        duration: const Duration(milliseconds: 620),
        curve: Curves.easeOutBack,
        builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
          decoration: BoxDecoration(
            // v2.4.2：不透明深色。半透明黑叠在亮色画面上，胶囊边缘会透出
            // 画面颜色（黄底 → 看着像两条黄线），靳老师反馈的正是这个。
            color: const Color(0xE6101010),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white70,
                ),
              ),
              SizedBox(width: 8),
              Text(
                '播放中',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 小窗底部进度条：当前时间 / 可拖动滑块 / 总时长 / 全屏
  Widget _buildMiniProgress(Duration pos, Duration dur) {
    final vp = _vp;
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 2),
      // v2.4.3：原渐变底衬在亮色画面上边缘会形成一条亮带，看着像横线
      color: const Color(0x8C000000),
      child: Row(
        children: [
          Text(
            _fmt(pos),
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 10,
              decoration: TextDecoration.none,
            ),
          ),
          Expanded(
            // v2.4.2：原 Slider 会在同一条线上叠「红（已播）+ 灰（未播）」两段，
            // 视觉上像两条横线。改成自绘单线：底色 1 条 + 进度覆盖同一条，
            // 无论播放到哪都只有 1 条线。
            child: _MiniProgressBar(
              pos: pos,
              dur: dur,
              onSeek: (ms) async {
                await vp?.seekTo(Duration(milliseconds: ms));
                if (mounted) setState(() {});
              },
            ),
          ),
          Text(
            dur > Duration.zero ? _fmt(dur) : '--:--',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 10,
              decoration: TextDecoration.none,
            ),
          ),
          IconButton(
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            icon: const Icon(Icons.fullscreen, color: Colors.white),
            onPressed: widget.onToggleFullscreen,
          ),
        ],
      ),
    );
  }

  /// 加载态：自动回退期间在转圈下方常驻显示当前阶段。
  ///
  /// v2.4.6：小窗里转圈改到中央按钮内部（见 [_buildMiniOverlay]），
  /// 这里传 showSpinner: false 只显示文案，避免"按钮 + 下方转圈"两截脱节。
  Widget _buildLoading({bool showSpinner = true}) {
    return Padding(
      // v2.4.6：小窗里转圈在中央按钮内，文案要下移，避免压在按钮上
      padding: EdgeInsets.only(top: showSpinner ? 0 : 96),
      child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showSpinner) const CircularProgressIndicator(color: Colors.redAccent),
        if (_fallbackStatus != null) ...[
          SizedBox(height: showSpinner ? 14 : 0),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              _fallbackStatus!,
              textAlign: TextAlign.center,
              // v2.4.3：显式关闭装饰，排除继承到双下划线的可能
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ],
      ],
      ),
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
                // v2.4.0：内嵌全屏时返回 = 退出全屏（回到小窗继续播）
                IconButton(
                  icon: Icon(
                    widget.embedded ? Icons.fullscreen_exit : Icons.arrow_back,
                    color: Colors.white,
                  ),
                  onPressed: widget.embedded
                      ? widget.onExitFullscreen
                      : () => Navigator.of(context).pop(),
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
              // v2.4.0（P2-3）：底部再留 8dp，避免播放/下一集按钮贴住
              // 系统手势条导致首次点击被吞
              padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
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
                        // v2.4.2：与小窗一致，用不透明深灰，避免透出画面颜色
                        inactiveColor: const Color(0xFF4A4A4A),
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

/// v2.4.2：小窗自绘进度条 —— 只有一条线（底色）+ 同一条上的进度覆盖，
/// 不再像 Slider 那样把「已播/未播」画成两段、视觉上像两条横线。
class _MiniProgressBar extends StatelessWidget {
  final Duration pos;
  final Duration dur;
  final ValueChanged<int> onSeek;

  const _MiniProgressBar({
    required this.pos,
    required this.dur,
    required this.onSeek,
  });

  @override
  Widget build(BuildContext context) {
    final maxMs = dur.inMilliseconds > 0 ? dur.inMilliseconds : 1;
    final frac = (pos.inMilliseconds / maxMs).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (ctx, c) {
        void seekTo(double dx) {
          if (c.maxWidth <= 0) return;
          final f = (dx / c.maxWidth).clamp(0.0, 1.0);
          onSeek((f * maxMs).round());
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => seekTo(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => seekTo(d.localPosition.dx),
          child: SizedBox(
            height: 26,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 2.5,
                  decoration: BoxDecoration(
                    // v2.4.2：必须用**不透明**深灰。原来 white24 是半透明，
                    // 叠在亮色画面上会透出画面颜色（例如片尾黄底 → 进度条
                    // 左右未播段变成两条黄线，靳老师反馈的正是这个）。
                    color: const Color(0xFF4A4A4A),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: frac,
                  child: Container(
                    height: 2.5,
                    decoration: BoxDecoration(
                      color: Colors.redAccent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment(frac * 2 - 1, 0),
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
