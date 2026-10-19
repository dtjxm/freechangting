/// v2.2.7（优化版，不升版本号）电视直播页
///
/// 口径（靳老师定稿）：
///   · 一级固定四类：央视频道 / 卫视频道 / 地方频道 / 港澳台·国际，**没有「全部」**
///   · 央视频道、卫视频道**取消二级**，按台名自然序整类平铺
///   · 港澳台·国际二级 = 香港 / 澳门 / 台湾 / 国际 / 其他
///   · 地方频道二级按省份（判不出的台已在数据侧联网查证补齐）
///   · 打开默认第一个一级 + 其第一个二级；切换一级默认其第一个二级
///   · 台数固定、线路实测可播、线路优先按本机健康度、同权重按实测速度排序
///   · 搜索框移到一级分类**上方**，高度略降、圆角加大
///   · 播放器提供「线路」面板：列出全部线路及其实测速度，用户自选
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../live_tv.dart';
import '../logo_cache.dart';
import '../theme.dart';
import 'live_player_page.dart';
import 'live_widgets.dart';
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
      itemBuilder: (_, i) => LiveChannelTile(
        channel: shown[i],
        onTap: () => _openChannel(shown[i], shown),
      ),
    );
  }

  /// 打开频道播放页；返回本页后重新进入沉浸态。
  ///
  /// 播放页 dispose 时会把系统栏恢复成 edgeToEdge；不重新沉浸的话，
  /// 「返回后顶部又多出状态栏」的老问题会复现。
  Future<void> _openChannel(TvChannel c, List<TvChannel> all) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LivePlayerPage(channel: c, all: all, lines: c.lines),
      ),
    );
    if (mounted && widget.active) _enterImmersive();
  }
}
