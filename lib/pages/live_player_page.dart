import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../live_source_health.dart';
import '../live_stall_detector.dart';
import '../live_tv.dart';
import '../theme.dart';

// =============== 横屏全屏直播播放器 ===============

class LivePlayerPage extends StatefulWidget {
  final TvChannel channel;
  final List<TvChannel> all;
  final List<TvLine> lines;

  const LivePlayerPage({
    super.key,
    required this.channel,
    required this.all,
    required this.lines,
  });

  @override
  State<LivePlayerPage> createState() => _LivePlayerPageState();
}

class _LivePlayerPageState extends State<LivePlayerPage> {
  late TvChannel _chan = widget.channel;

  /// 按本机历史失败记录稳定排序：坏线路排后面，同权重保持内置测速顺序。
  late List<TvLine> _lines = LiveSourceHealth.orderLines(widget.lines);
  int _idx = 0;

  /// v2.2.7 修复（直播无声）：改用 media_kit / libmpv 软解。
  ///
  /// 这批 IPTV 源（`tsfile`）的音频是 MPEG Audio Layer II（MP2，stream_type
  /// 0x03/0x04），Android 的 ExoPlayer 只会调 MP3（Layer III）解码器，喂 MP2
  /// 帧直接失败 —— 表现就是「有画面没声音，换线路也没用」。libmpv 自带
  /// FFmpeg 软解，MP2/AC3/DTS 都能出声，与 PC 版（Chromium 自带 FFmpeg）一致。
  late final Player _player = Player();
  late final VideoController _videoController = VideoController(_player);
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<int?>? _widthSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  bool _inited = false;
  bool _buffering = false;
  bool _playing = false;
  String? _error;
  bool _showControls = true;
  Timer? _hideTimer;

  /// 首帧看门狗：死线路不会抛 error，只会一直缓冲，必须自己超时换线
  Timer? _watchdog;
  int _playToken = 0;
  DateTime? _lastFailAt;

  /// 起播后的卡死检测：位置长时间不前进 / 持续缓冲，同样要自动换线。
  /// 只看起播是 v2.2.7 的老逻辑，能解决「死线路连不上」，但解决不了
  /// 「连上了、有声音、画面冻住」—— 后者的 `playing` 一直是 true，
  /// 原来的 `_failCurrentLine` 会因 `_playing` 守卫而拒绝换线。
  Timer? _freezeTimer;
  final LiveStallDetector _stall = LiveStallDetector();
  bool _autoSwitching = false;
  String? _notice;
  Timer? _noticeTimer;

  /// 稳定播放一段时间后才算「这条线路确实健康」。
  /// 只在首帧就 markSuccess 会把「连得上但马上卡死」的线路误判为健康，
  /// 导致失败计数反复被清零、冷却永远升不上去。
  Timer? _healthTimer;
  static const Duration _healthConfirmAfter = Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    // 横屏全屏播放：沉浸式（隐藏状态栏/导航条），与 player_page.dart 口径一致。
    // v2.2.7 修复：此处原为 edgeToEdge，会让电量条常驻在直播画面上方。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    WakelockPlus.enable();
    _bindPlayerStreams();
    _play();
    WidgetsBinding.instance.addPostFrameCallback((_) => _armHide());
  }

  /// 订阅 media_kit 状态流（media_kit 没有 `value` 快照，一切以流为准）
  void _bindPlayerStreams() {
    _playingSub = _player.stream.playing.listen((v) {
      if (!mounted) return;
      setState(() => _playing = v);
      // v2.2.7：只要真的开始出声/出帧就算起播 —— 有些台首帧迟迟不到（码流慢或纯音频），
      // 只看 width/position 会让看门狗误判成死线，刚听到声音就被切走。
      if (v && !_inited) _markInited();
    });
    _bufferingSub = _player.stream.buffering.listen((v) {
      if (!mounted) return;
      _stall.onBuffering(v, DateTime.now());
      setState(() => _buffering = v);
    });
    _errorSub = _player.stream.error.listen((e) {
      // 已起播后的错误不换线：直播 TS 流偶发解析错误很常见（某段 PAT/PMT 损坏、
      // 音轨切换），media_kit 会继续播剩余数据。原先一报错就判死，会把正在出声的
      // 线路切走，线路耗尽后显示「播放失败」但音频还在响。
      if (_inited || _playing) return;
      _handlePlayerError(e);
    });
    _widthSub = _player.stream.width.listen((w) {
      if (w != null && w > 0 && mounted && !_inited) _markInited();
    });
    _positionSub = _player.stream.position.listen((p) {
      if (!mounted) return;
      if (p > Duration.zero && !_inited) _markInited();
      _stall.onPosition(p, DateTime.now());
    });
    _durationSub = _player.stream.duration.listen((d) {
      // 直播多为 0，但部分源会给一个窗口时长；能拿到也说明已起播
      if (d > Duration.zero && mounted && !_inited) _markInited();
    });
  }

  void _markInited() {
    if (_inited || !mounted) return;
    _watchdog?.cancel();
    setState(() {
      _inited = true;
      _buffering = false;
    });
    if (_idx < _lines.length) {
      // 稳定播放 20 秒才抹掉历史失败记录（冷却期后恢复的源也走这里）
      final url = _lines[_idx].url;
      _healthTimer?.cancel();
      _healthTimer = Timer(_healthConfirmAfter, () {
        if (!mounted ||
            _error != null ||
            !_inited ||
            !_playing ||
            _idx >= _lines.length ||
            _lines[_idx].url != url) {
          return;
        }
        LiveSourceHealth.markSuccess(url);
      });
    }
    _startFreezeWatch();
  }

  /// 起播后的卡死监测：
  /// - 播放位置连续 10 秒不前进（且此前确实前进过）；
  /// - 或持续缓冲 12 秒不恢复。
  ///
  /// 位置始终为 0 的源（部分纯直播流）拿不到进度，只靠缓冲状态兜底，
  /// 不会因为「没有位置信息」被误判。
  void _startFreezeWatch() {
    _freezeTimer?.cancel();
    _stall.reset(DateTime.now());

    _freezeTimer = Timer.periodic(LiveStallDetector.checkInterval, (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      // 起播阶段交给 20 秒看门狗；出错后不再判定
      if (!_inited || _error != null) return;

      final reason = _stall.check(
        DateTime.now(),
        playing: _playing,
        buffering: _buffering,
      );
      if (reason != null) {
        t.cancel();
        _switchBecauseStalled(reason);
      }
    });
  }

  /// 卡死换线：必须绕过 `_failCurrentLine` 的 `_playing` 守卫 ——
  /// 卡死时音频通常还在响，`_playing` 一直是 true。
  void _switchBecauseStalled(String reason) {
    if (!mounted || _error != null || _autoSwitching) return;
    _autoSwitching = true;
    _failCurrentLine(force: true, notice: reason);
  }

  void _handlePlayerError(String e) {
    if (!mounted || _error != null) return;
    _failCurrentLine();
  }

  /// 当前线路判死：自动切下一条；全部失败才报错。
  ///
  /// [force] 用于起播后卡死：音频还在响时 `_playing` 仍为 true，
  /// 必须强制换线；普通错误/超时路径保持原来的防误切守卫。
  void _failCurrentLine({bool force = false, String? notice}) {
    if (!mounted || _error != null) return;
    // 已经在出声就绝不判死（与 error 订阅里的 _inited/_playing 双保险，
    // 防止看门狗、catch 等其它路径在「有声音」时误切线路）
    if (_playing && !force) return;
    // 错误流可能连续触发，1 秒内只切一次，避免瞬间烧完所有线路
    final now = DateTime.now();
    if (_lastFailAt != null &&
        now.difference(_lastFailAt!).inMilliseconds < 1000) {
      return;
    }
    _lastFailAt = now;
    _watchdog?.cancel();
    _freezeTimer?.cancel();
    _healthTimer?.cancel();
    if (_idx < _lines.length) {
      LiveSourceHealth.markFailure(_lines[_idx].url);
    }
    if (_idx < _lines.length - 1) {
      _idx++;
      _lastFailAt = null; // v2.2.10：换线后不受上一轮 1 秒节流影响，避免卡在「正在连接」
      if (notice != null) _showNotice(notice);
      _play();
    } else {
      setState(() {
        _buffering = false;
        _error = '播放失败：全部 ${_lines.length} 条线路都连不上\n可稍后重试或换一台';
      });
    }
  }

  /// 临时提示（自动换线原因），3 秒后消失
  void _showNotice(String msg) {
    _noticeTimer?.cancel();
    setState(() => _notice = msg);
    _noticeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  Future<void> _play() async {
    if (_lines.isEmpty) {
      setState(() => _error = '该频道没有可用线路');
      return;
    }
    final token = ++_playToken;
    _watchdog?.cancel();
    _freezeTimer?.cancel();
    _healthTimer?.cancel();
    _autoSwitching = false;
    _stall.reset(DateTime.now());
    setState(() {
      _error = null;
      _buffering = true;
      _showControls = true;
      _inited = false;
    });
    // v2.2.10：看门狗提前武装——open() 快速抛错时也有兜底，
    // 不会出现「旧看门狗已取消、新看门狗还没建」而永久卡在正在连接。
    // v2.4.0（P1-3）：20 秒太长——8 条线路全卡时用户要等近 3 分钟且全程
    // 只有一个「线路N/M」字样。收紧到 12 秒，并在换线时给出明确原因。
    _watchdog = Timer(const Duration(seconds: 12), () async {
      if (!mounted || token != _playToken || _inited) return;
      if (_playing) return; // 已在出声，绝不换线
      if (await _netDown()) {
        if (!mounted || token != _playToken || _inited) return;
        setState(() {
          _buffering = false;
          _error = '网络未连接，请检查 Wi-Fi 或移动数据后重试';
        });
        return;
      }
      if (!mounted || token != _playToken || _inited) return;
      _failCurrentLine(notice: '线路${_idx + 1} 无响应，正在切换…');
    });
    try {
      // 复用同一个 Player 切线路：media_kit 会先停掉上一条流再打开新地址
      await _player.open(Media(_lines[_idx].url), play: true);
    } catch (_) {
      if (!mounted || token != _playToken) return;
      if (await _netDown()) {
        if (!mounted || token != _playToken) return;
        setState(() {
          _buffering = false;
          _error = '网络未连接，请检查 Wi-Fi 或移动数据后重试';
        });
        return;
      }
      _failCurrentLine(notice: '线路${_idx + 1} 连接失败，正在切换…');
      return;
    }
  }

  void _switchChan(int d) {
    final list = widget.all;
    if (list.isEmpty) return;
    final k = list.indexOf(_chan);
    // v2.2.10：找不到当前台时从 0 起算，避免负数取模跳到错误位置
    final i = (k < 0 ? 0 : k + d) % list.length;
    setState(() {
      _chan = list[i];
      _lines = LiveSourceHealth.orderLines(_chan.lines);
      _idx = 0;
    });
    _play();
  }

  /// 全部线路失败后的「重试」：从健康度最高的线路重新开始，
  /// 而不是傻等最后一条已经确认失败的线路。
  void _retryAll() {
    setState(() => _idx = 0);
    _play();
  }

  /// v2.4.0（P2-2）：断网时所有线路都会以同样方式失败，逐条试只是让用户
  /// 多等 N×12 秒。起播失败/看门狗超时后先做一次轻量 DNS 探测：确认断网
  /// 就直接给出网络提示，不再空转换线。
  Future<bool> _netDown() async {
    try {
      final r = await InternetAddress.lookup(
        'www.baidu.com',
      ).timeout(const Duration(seconds: 3));
      return r.isEmpty;
    } catch (_) {
      return true;
    }
  }

  /// 当前频道最快线路的实测值（0 = 全部未测速）
  int _fastestMs() {
    var best = 0;
    for (final l in _lines) {
      if (l.ms > 0 && (best == 0 || l.ms < best)) best = l.ms;
    }
    return best;
  }

  /// 线路面板：全部线路 + 实测速度，用户自选
  void _showLineSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: context.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: [
                  Text(
                    '线路选择 · ${_chan.name}',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_lines.length} 条',
                    style: TextStyle(fontSize: 12, color: ctx.tFaint),
                  ),
                ],
              ),
            ),
            for (var i = 0; i < _lines.length; i++)
              ListTile(
                dense: true,
                selected: i == _idx,
                selectedTileColor: ctx.brand.withValues(alpha: 0.08),
                leading: Icon(
                  i == _idx
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 18,
                  color: i == 0 ? ctx.brand : ctx.tFaint,
                ),
                title: Text(
                  '线路 ${i + 1}',
                  style: const TextStyle(fontSize: 13.5),
                ),
                subtitle: Text(
                  _lines[i].ms > 0
                      ? '实测 ${(_lines[i].ms / 1000).toStringAsFixed(2)} 秒'
                          '${_lines[i].ms == _fastestMs() ? ' · 最快' : ''}'
                      : '未测速',
                  style: TextStyle(fontSize: 11.5, color: ctx.tFaint),
                ),
                trailing: i == 0
                    ? Text(
                        '推荐',
                        style: TextStyle(fontSize: 11, color: ctx.brand),
                      )
                    : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  if (i == _idx) return;
                  setState(() => _idx = i);
                  _play();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showChanSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: context.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final c in widget.all)
              ListTile(
                dense: true,
                selected: c.name == _chan.name,
                title: Text(c.name, style: const TextStyle(fontSize: 13.5)),
                subtitle: Text(
                  '${c.top}${c.sub.isEmpty ? '' : ' · ${c.sub}'} · ${c.lines.length} 条线路',
                  style: TextStyle(fontSize: 11, color: ctx.tFaint),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  if (c.name == _chan.name) return;
                  setState(() {
                    _chan = c;
                    _lines = LiveSourceHealth.orderLines(c.lines);
                    _idx = 0;
                  });
                  _play();
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _watchdog?.cancel();
    _freezeTimer?.cancel();
    _healthTimer?.cancel();
    _noticeTimer?.cancel();
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _errorSub?.cancel();
    _widthSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    // media_kit 的 dispose 是异步的，State.dispose 里不能 await，直接 fire-and-forget
    _player.dispose();
    // 与 initState 成对恢复（参考 player_page.dart 的第 99-101 / 448-449 行）：
    // 不恢复会让调用方（直播列表页）从沉浸态变成「系统栏被藏」或方向错乱
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = _player.state.width ?? 0;
    final h = _player.state.height ?? 0;
    final aspect = (w > 0 && h > 0) ? w / h : 16 / 9;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() => _showControls = !_showControls);
          if (_showControls) _armHide();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: _error != null
                  ? _buildError()
                  : _inited
                  ? AspectRatio(
                      aspectRatio: aspect,
                      // 内置控件必须关掉（NoVideoControls），控制条由本页自己画，
                      // 否则会和下面 _buildControls() 叠加成两层按钮
                      child: Video(
                        controller: _videoController,
                        fit: BoxFit.contain,
                        controls: NoVideoControls,
                      ),
                    )
                  : _buildLoading(),
            ),
            // 已起播后的缓冲提示（切线路/网络抖动时不遮画面）
            if (_inited && _buffering)
              const Center(
                child: SizedBox(
                  width: 30,
                  height: 30,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: Colors.white70,
                  ),
                ),
              ),
            // 自动换线提示（卡死/持续缓冲），3 秒后消失
            if (_notice != null)
              Positioned(
                left: 24,
                right: 24,
                bottom: 76,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.66),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _notice!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (_showControls) _buildControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildLoading() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (_buffering)
        const SizedBox(
          width: 34,
          height: 34,
          child: CircularProgressIndicator(
            strokeWidth: 2.6,
            color: Colors.white70,
          ),
        ),
      const SizedBox(height: 12),
      Text(
        '正在连接 ${_chan.name} · 线路${_idx + 1}/${_lines.length}…',
        style: const TextStyle(color: Colors.white70, fontSize: 13),
      ),
    ],
  );

  Widget _buildError() => Padding(
    padding: const EdgeInsets.all(32),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, color: Colors.white38, size: 44),
        const SizedBox(height: 12),
        Text(
          _error!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.tonal(onPressed: _retryAll, child: const Text('重试')),
            const SizedBox(width: 10),
            OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white70),
              onPressed: () => _switchChan(1),
              child: const Text('下一台'),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _buildControls() {
    final playing = _playing;
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
          stops: [0, 0.18, 0.72, 1],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
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
                    '${_chan.name} · ${_chan.sub.isEmpty ? _chan.top : _chan.sub} · 线路${_idx + 1}/${_lines.length}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
                TextButton(
                  onPressed: _showLineSheet,
                  child: Text(
                    '线路(${_lines.length})',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: _showChanSheet,
                  child: Text(
                    '频道(${widget.all.length})',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: () => _switchChan(-1),
                  child: const Text(
                    '◀ 上一台',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
                const SizedBox(width: 16),
                IconButton(
                  icon: Icon(
                    playing ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 30,
                  ),
                  onPressed: () {
                    // 状态由 _player.stream.playing 回流到 _playing，这里只发指令
                    if (_playing) {
                      _player.pause();
                    } else {
                      _player.play();
                    }
                  },
                ),
                const SizedBox(width: 16),
                TextButton(
                  onPressed: () => _switchChan(1),
                  child: const Text(
                    '下一台 ▶',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
