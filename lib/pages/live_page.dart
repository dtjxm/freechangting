/// v2.2.7（优化版，不升版本号）电视直播页
///
/// 口径（靳老师定稿）：
///   · 一级固定四类：央视频道 / 卫视频道 / 地方频道 / 港澳台·国际，**没有「全部」**
///   · 央视频道、卫视频道**取消二级**，按台名自然序整类平铺
///   · 港澳台·国际二级 = 香港 / 澳门 / 台湾 / 国际 / 其他
///   · 地方频道二级按省份（判不出的台已在数据侧联网查证补齐）
///   · 打开默认第一个一级 + 其第一个二级；切换一级默认其第一个二级
///   · 台数固定、线路实测可播、线路按实测速度排序（第 1 条最快）
///   · 搜索框移到一级分类**上方**，高度略降、圆角加大
///   · 播放器提供「线路」面板：列出全部线路及其实测速度，用户自选
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../live_tv.dart';
import '../logo_cache.dart';
import '../theme.dart';
import 'widgets.dart';

class LivePage extends StatefulWidget {
  /// 兼容旧调用（v2.2.4 曾用于「影视点播」页，现已下线）
  final String? lockedTop;
  final String title;

  /// 是否为**当前可见**的底部 Tab（由 HomeShell 按 selectedIndex 传入）
  ///
  /// v2.2.7 修复（直播页顶部出现手机电量条）：本页在 IndexedStack 里常驻不销毁，
  /// 所以不能只在 initState 里切系统 UI —— 必须由可见性驱动：
  /// 可见 → immersiveSticky（沉浸全屏，状态栏隐藏，顶部不再留出电量条那块空白）；
  /// 切走 → 立刻恢复 edgeToEdge，否则「首页 / 我的」也会跟着没有状态栏。
  final bool active;

  const LivePage({
    super.key,
    this.lockedTop,
    this.title = '电视',
    this.active = true,
  });

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  String? _error;
  bool _loading = true;
  TvCatalog _cat = TvCatalog.empty;

  /// 一级大类（默认第一个：央视频道）
  String _top = TvCatalog.tops.first;

  /// 二级分类（央视/卫视为空；其余默认第一个）
  String _sub = '';

  String _kw = '';
  final _kwCtrl = TextEditingController();
  Timer? _kwDebounce;
  final _listCtrl = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.active) _enterImmersive();
    _load();
  }

  @override
  void didUpdateWidget(covariant LivePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      if (widget.active) {
        _enterImmersive();
      } else {
        _exitImmersive();
      }
    }
  }

  /// 从后台回到前台时 Android 可能已把系统栏放回来 —— 重新沉浸一次
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.active) _enterImmersive();
  }

  /// 进入沉浸式全屏：状态栏/导航条隐藏，顶部不再占状态栏高度；
  /// 用户从屏幕边缘下滑仍可临时拉出通知栏（immersiveSticky 的语义）
  void _enterImmersive() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  /// 恢复常驻系统栏（离开本页**必须**调用，否则其它页面全都没有状态栏）
  void _exitImmersive() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await LogoCache.init();
      final cat = await TvCatalog.load();
      if (!mounted) return;
      setState(() {
        _cat = cat;
        _error = cat.all.isEmpty ? '未找到可播电视台' : null;
        _syncSelection();
        _loading = false;
      });
      _prefetchLogos();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '电视台清单读取失败';
        _loading = false;
      });
    }
  }

  /// 默认第一个一级 + 其第一个二级；切一级时也落到其第一个二级
  void _syncSelection() {
    if (!TvCatalog.tops.contains(_top)) _top = TvCatalog.tops.first;
    final subs = _cat.subsOf(_top);
    if (subs.isEmpty) {
      _sub = '';
    } else if (!subs.contains(_sub)) {
      _sub = subs.first;
    }
  }

  void _prefetchLogos() {
    try {
      LogoCache.instance.prefetch(_cat.all.take(80).map((c) => c.logo));
    } catch (_) {}
  }

  List<TvChannel> get _shown {
    var list = _cat.subset(_top, _sub);
    if (_kw.isNotEmpty) {
      final k = _kw.toUpperCase();
      list = list.where((c) => c.name.toUpperCase().contains(k)).toList();
    }
    return list;
  }

  void _onKwChanged(String v) {
    _kwDebounce?.cancel();
    _kwDebounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      final t = v.trim();
      if (t != _kw) setState(() => _kw = t);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _kwDebounce?.cancel();
    _kwCtrl.dispose();
    _listCtrl.dispose();
    // 兜底：页面销毁时一定要把系统状态栏还回去（沉浸态不能泄漏到其它页面）
    _exitImmersive();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final shown = _shown;
    // 沉浸式下 MediaQuery.padding.top = 0（状态栏已隐藏，顶部不留空白），
    // 但挖孔屏的「屏幕安全区」仍在 viewPadding 里 —— 取两者差值做额外内边距，
    // 避免刘海/挖孔盖住标题与首行内容（普通机型差值为 0，不会多出空白）。
    final mq = MediaQuery.of(context);
    final cutTop = (mq.viewPadding.top - mq.padding.top)
        .clamp(0.0, 48.0)
        .toDouble();
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(kToolbarHeight + cutTop),
        child: Padding(
          padding: EdgeInsets.only(top: cutTop),
          child: AppBar(
            title: Text(widget.title),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Center(
                  child: Text(
                    '${_cat.all.length} 个台 · ${_cat.lineCount} 条线路',
                    style: TextStyle(fontSize: 11.5, color: context.tFaint),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          if (_loading)
            const Expanded(
              child: Center(
                child: SizedBox(
                  width: 30,
                  height: 30,
                  child: CircularProgressIndicator(strokeWidth: 2.6),
                ),
              ),
            ),
          if (!_loading && _error != null)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.live_tv_outlined,
                      size: 44,
                      color: context.tFaint,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(fontSize: 13, color: context.tSub),
                    ),
                    const SizedBox(height: 14),
                    FilledButton(onPressed: _load, child: const Text('重试')),
                  ],
                ),
              ),
            ),
          if (!_loading && _error == null) ...[
            // ── 分类区：搜索框在上（高度略降 + 大圆角），一级 chips 在下 ──
            Container(
              width: double.infinity,
              color: context.card,
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _kwCtrl,
                    onChanged: _onKwChanged,
                    textInputAction: TextInputAction.search,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '筛选频道，如 CCTV、湖南卫视',
                      hintStyle: TextStyle(fontSize: 12, color: context.tFaint),
                      prefixIcon: Icon(
                        Icons.search,
                        size: 18,
                        color: context.tFaint,
                      ),
                      suffixIcon: _kw.isEmpty
                          ? null
                          : IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: Icon(
                                Icons.cancel,
                                size: 16,
                                color: context.tFaint,
                              ),
                              onPressed: () {
                                _kwDebounce?.cancel();
                                _kwCtrl.clear();
                                setState(() => _kw = '');
                              },
                            ),
                      filled: true,
                      fillColor: context.chipBg,
                      // 高度比原来略降（vertical 8 → 5），圆角 20 → 26
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 5,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(26),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final t in TvCatalog.tops)
                          _chip(
                            t,
                            _top == t,
                            onSel: () {
                              if (_top == t) return;
                              setState(() {
                                _top = t;
                                final subs = _cat.subsOf(t);
                                _sub = subs.isEmpty ? '' : subs.first;
                                if (_listCtrl.hasClients) _listCtrl.jumpTo(0);
                              });
                            },
                          ),
                      ],
                    ),
                  ),
                  if (_cat.subsOf(_top).length > 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: _buildSubBar(_cat.subsOf(_top)),
                    ),
                ],
              ),
            ),
            Expanded(child: _buildList(shown)),
          ],
        ],
      ),
    );
  }

  /// 二级 chips 单行排版：按实测文字宽度铺，放不下就截断并给「更多 N ▾」
  ///
  /// 口径对齐 PC 版 `live.js` 的两趟排版：先量总宽，放得下就全铺；
  /// 放不下才重排，并在末尾预留「更多」的位置。**当前选中的二级必须可见** ——
  /// 若它落在被截断的部分，把它补到可见列表最后一位（必要时挤掉前面的项）。
  Widget _buildSubBar(List<String> subs) {
    const fontSize = 11.5;
    // ChoiceChip 实际水平占用 ≈ 文本 + 28（label/tile padding），再加本页 6dp 右间距；
    // 估宽留 2dp 余量（宁可早一点出现「更多」，也不要 RenderFlex 溢出）
    const chipExtra = 36.0;
    const moreWidth = 92.0; // 「更多 NN ▾」整颗 chip 的预留宽度

    double textWidth(String s) {
      final tp = TextPainter(
        text: TextSpan(
          text: s,
          style: const TextStyle(fontSize: fontSize),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      return tp.width;
    }

    return LayoutBuilder(
      builder: (context, cons) {
        final maxW = cons.maxWidth;
        final widths = <String, double>{
          for (final s in subs) s: textWidth(s) + chipExtra,
        };
        double sumOf(Iterable<String> xs) =>
            xs.fold<double>(0, (a, s) => a + (widths[s] ?? 0));

        final visible = <String>[];
        if (sumOf(subs) <= maxW) {
          visible.addAll(subs); // 一行放得下 → 不出现「更多」
        } else {
          final limit = maxW - moreWidth;
          var used = 0.0;
          for (final s in subs) {
            final w = widths[s] ?? 0;
            if (used + w > limit) break;
            visible.add(s);
            used += w;
          }
          if (visible.isEmpty) visible.add(subs.first);
          if (!visible.contains(_sub) && subs.contains(_sub)) {
            visible.add(_sub);
            // 补进来的选中项可能把最后一格挤出去，逐个回退直到放得下
            while (visible.length > 1 && sumOf(visible) > limit) {
              visible.removeAt(visible.length - 2);
            }
          }
        }
        final hidden = subs.where((s) => !visible.contains(s)).toList();

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // 已按宽度截断，正常不需要滚动；关掉手势避免误触时抖动
          physics: const NeverScrollableScrollPhysics(),
          child: Row(
            children: [
              for (final g in visible)
                _chip(
                  g,
                  _sub == g,
                  small: true,
                  onSel: () {
                    if (_sub == g) return;
                    setState(() {
                      _sub = g;
                      if (_listCtrl.hasClients) _listCtrl.jumpTo(0);
                    });
                  },
                ),
              if (hidden.isNotEmpty)
                _chip(
                  '更多 ${hidden.length} ▾',
                  false,
                  small: true,
                  onSel: () => _showSubSheet(subs),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 「更多」面板：4 列网格、当前项高亮、每格带台数
  ///
  /// 台数只在打开面板时算一次（subset 要过滤 + 排序，不能放进 build 循环）。
  void _showSubSheet(List<String> subs) {
    final counts = <String, int>{
      for (final s in subs) s: _cat.subset(_top, s).length,
    };
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.55,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
              child: Row(
                children: [
                  Text(
                    '$_top·全部二级',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.close, size: 20, color: ctx.tFaint),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 18),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  // 固定行高：窄屏（360dp）4 列的格宽只有 ~78dp，
                  // childAspectRatio 2.2 会把格高压到 ~35dp，装不下
                  // 「省份 14sp + 2 + 台数 11sp」；54dp 跨屏都稳。
                  mainAxisExtent: 54,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemCount: subs.length,
                itemBuilder: (_, i) {
                  final s = subs[i];
                  final sel = s == _sub;
                  return InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      if (s == _sub) return;
                      setState(() => _sub = s);
                      if (_listCtrl.hasClients) _listCtrl.jumpTo(0);
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: sel
                            ? ctx.brand.withValues(alpha: 0.10)
                            : ctx.chipBg,
                        borderRadius: BorderRadius.circular(10),
                        border: sel
                            ? Border.all(color: ctx.brand, width: 1.2)
                            : null,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            s,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: sel
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              color: sel ? ctx.brand : ctx.tSub,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${counts[s] ?? 0} 台',
                            maxLines: 1,
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 11, color: ctx.tFaint),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(
    String label,
    bool selected, {
    bool small = false,
    required VoidCallback onSel,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(
          label,
          style: TextStyle(
            fontSize: small ? 11.5 : 12.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        selected: selected,
        selectedColor: context.brand,
        backgroundColor: context.chipBg,
        labelStyle: TextStyle(color: selected ? Colors.white : context.tSub),
        side: BorderSide.none,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        onSelected: (_) => onSel(),
      ),
    );
  }

  Widget _buildList(List<TvChannel> shown) {
    if (shown.isEmpty) {
      return const EmptyView(icon: Icons.live_tv_outlined, message: '该分类暂无频道');
    }
    return ListView.separated(
      controller: _listCtrl,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 20),
      itemCount: shown.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (_, i) => _chanTile(shown[i], shown),
    );
  }

  /// 频道行：台标优先「随包内置 → 本地缓存 → 网络 → 高对比首字色块」
  Widget _chanTile(TvChannel c, List<TvChannel> all) {
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
            // 否则深灰图上会多出一圈浅色边；无台标时由 _logoFallback 自己铺色块。
            color: Colors.transparent,
            alignment: Alignment.center,
            child: _logoBox(c),
          ),
        ),
        title: Text(
          c.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${c.sub.isEmpty ? c.top : c.sub} · ${c.lines.length} 条线路${_speedText(c)}',
          style: TextStyle(fontSize: 11, color: context.tFaint),
        ),
        trailing: Icon(
          Icons.play_circle_outline,
          size: 24,
          color: context.brand.withValues(alpha: 0.8),
        ),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  LivePlayerPage(channel: c, all: all, lines: c.lines),
            ),
          );
          // 播放页 dispose 时会把系统栏恢复成 edgeToEdge；返回本页要重新沉浸，
          // 否则「返回后顶部又多出状态栏」的老问题会复现
          if (mounted && widget.active) _enterImmersive();
        },
      ),
    );
  }

  /// 台标本体：随包内置（`asset:cctv1.png`）→ 本地缓存命中 → 网络 → 占位
  Widget _logoBox(TvChannel c) {
    final col = _logoColor(c.name);
    final img = LogoCache.instance.provider(c.logo);
    if (img != null) {
      // v2.2.7 第二轮：内置台标现在是高分辨率（≥160px 高），要缩到 56×42 显示，
      // 默认 FilterQuality.low（双线性）缩小时会有阶梯感；medium 走 mipmap 采样，边缘更干净。
      return Image(
        image: img,
        width: 56,
        height: 42,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      );
    }
    if (c.logo.isEmpty) return _logoFallback(c.name, col);
    // 有网络地址但还没下好：先给占位，同时后台缓存（下好后滚动/重建即出图）
    return Image.network(
      c.logo,
      width: 56,
      height: 42,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => _logoFallback(c.name, col),
    );
  }

  /// 高对比首字色块（v2.2.7 修复 缺陷 6）：
  /// 原先是 `品牌色 alpha 0.14 + 同色字`，深色底上几乎看不见；
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

  /// 副标题带上最快线路的实测速度
  static String _speedText(TvChannel c) {
    var best = -1;
    for (final l in c.lines) {
      if (l.ms > 0 && (best < 0 || l.ms < best)) best = l.ms;
    }
    return best > 0 ? ' · 最快 ${(best / 1000).toStringAsFixed(2)}s' : '';
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
  late List<TvLine> _lines = widget.lines;
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
      if (mounted) setState(() => _buffering = v);
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
      if (p > Duration.zero && mounted && !_inited) _markInited();
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
  }

  void _handlePlayerError(String e) {
    if (!mounted || _error != null) return;
    _failCurrentLine();
  }

  /// 当前线路判死：自动切下一条；全部失败才报错
  void _failCurrentLine() {
    if (!mounted || _error != null) return;
    // 已经在出声就绝不判死（与 error 订阅里的 _inited/_playing 双保险，
    // 防止看门狗、catch 等其它路径在「有声音」时误切线路）
    if (_playing) return;
    // 错误流可能连续触发，1 秒内只切一次，避免瞬间烧完所有线路
    final now = DateTime.now();
    if (_lastFailAt != null &&
        now.difference(_lastFailAt!).inMilliseconds < 1000) {
      return;
    }
    _lastFailAt = now;
    _watchdog?.cancel();
    if (_idx < _lines.length - 1) {
      _idx++;
      _play();
    } else {
      setState(() {
        _buffering = false;
        _error = '播放失败：全部 ${_lines.length} 条线路都连不上';
      });
    }
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
    setState(() {
      _error = null;
      _buffering = true;
      _showControls = true;
      _inited = false;
    });
    try {
      // 复用同一个 Player 切线路：media_kit 会先停掉上一条流再打开新地址
      await _player.open(Media(_lines[_idx].url), play: true);
    } catch (_) {
      if (!mounted || token != _playToken) return;
      _failCurrentLine();
      return;
    }
    if (!mounted || token != _playToken) return;
    // 20 秒还没起播 → 视为死线（curl 实测都在 1 秒内，留足余量；
    // 部分频道首帧慢/纯音频，12 秒会误杀，所以放宽到 20 秒）
    _watchdog = Timer(const Duration(seconds: 20), () {
      if (!mounted || token != _playToken || _inited) return;
      if (_playing) return; // 已在出声，绝不换线
      _failCurrentLine();
    });
  }

  void _switchChan(int d) {
    final list = widget.all;
    if (list.isEmpty) return;
    final i = (list.indexOf(_chan) + d) % list.length;
    setState(() {
      _chan = list[i];
      _lines = _chan.lines;
      _idx = 0;
    });
    _play();
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
                      ? '实测 ${(_lines[i].ms / 1000).toStringAsFixed(2)} 秒${i == 0 ? ' · 最快' : ''}'
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
                    _lines = c.lines;
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
            FilledButton.tonal(onPressed: _play, child: const Text('重试')),
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
