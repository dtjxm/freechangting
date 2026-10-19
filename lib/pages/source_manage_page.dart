/// v2.2.4 片源管理（参考 PC 版「设置 → 片源管理」独立成页）
///
/// 布局与 PC 版一致：
///  · 顶部三按钮 —— 「立即测速」「关闭失效片源」「全部开启」；
///  · 下部片源列表 —— 片源名称 + 连接速度（延迟）+ 开关；
///  · 测速完成后按延迟**升序**重排（最快的在最上，未测速其后，失败垫底），
///    并把「默认片源」自动设为最快的那一个 —— 返回首页即按最快源加载。
///
/// 停用语义与 PC 版一致：停用的片源不再参与首页加载、下滑补数与检索，
/// 但已收藏 / 历史里的影片不受影响（至少保留 1 个启用片源）。
library;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../models.dart';
import '../network_signature.dart';
import '../store.dart';
import '../theme.dart';

class SourceManagePage extends StatefulWidget {
  const SourceManagePage({super.key});

  @override
  State<SourceManagePage> createState() => _SourceManagePageState();
}

class _SourceManagePageState extends State<SourceManagePage> {
  bool _testing = false;
  Map<int, int> _latency = <int, int>{};
  Set<int> _fail = <int>{};
  Set<int> _disabled = <int>{};

  @override
  void initState() {
    super.initState();
    final st = AppStore.instance;
    _latency = Map<int, int>.from(st.sourceLatency);
    _fail = st.sourceFail.toSet();
    _disabled = Set<int>.from(st.disabledSourceIds);
    // 兜底：确保运行时过滤集合与本地存储一致（冷启动路径已设，此处幂等）
    MacApi.instance.setDisabledSources(_disabled);
  }

  // ---------------------------------------------------------------- 排序
  /// 测速后按延迟升序；未测速的排在其后；测速失败的垫底。
  /// 尚未测速时保持 sources.json 的原始顺序。
  List<MovieSource> get _sorted {
    final srcs = <MovieSource>[...MacApi.instance.sources];
    if (_latency.isEmpty && _fail.isEmpty) return srcs;
    int rank(MovieSource s) {
      if (_fail.contains(s.id)) return 1 << 30; // 失败 → 垫底
      final ms = _latency[s.id];
      if (ms == null || ms <= 0) return 1 << 29; // 未测速 → 在其后
      return ms; // 已测速 → 延迟升序
    }

    srcs.sort((a, b) => rank(a).compareTo(rank(b)));
    return srcs;
  }

  // ---------------------------------------------------------------- 动作
  /// 立即测速：全量（含已停用源）探测 → 落盘 → 默认片源设为最快 → 通知首页重载
  Future<void> _bench() async {
    HapticFeedback.selectionClick();
    setState(() => _testing = true);
    final st = AppStore.instance;
    try {
      final lat = await MacApi.instance
          .benchmarkSources(force: true)
          .timeout(const Duration(seconds: 40));
      final fail = MacApi.instance.sources
          .map((s) => s.id)
          .where((id) => !lat.containsKey(id))
          .toList();

      st.sourceLatency = lat;
      st.sourceFail = fail;
      st.sourceLastTest = DateTime.now().millisecondsSinceEpoch;
      st.sourceLastTestNetwork = await currentNetworkSignature();

      // 需求：测速完成后把「默认片源」自动设为最快的源；
      // 同时清掉手选标记与手选记录，首页才会按最快源加载。
      final int? fastest = lat.isEmpty
          ? null
          : lat.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
      if (fastest != null) {
        st.fastSourceId = fastest;
        st.manualSource = false;
        st.lastSourceId = -1;
      }

      if (!mounted) return;
      setState(() {
        _latency = Map<int, int>.from(lat);
        _fail = fail.toSet();
        _testing = false;
      });
      st.bumpSourceRev(); // 首页据此重选源并重载

      if (lat.isEmpty) {
        _toast('测速完成：全部片源均不可用，请检查网络');
        return;
      }
      final name = _nameOf(fastest);
      _toast('测速完成：成功 ${lat.length} 个，失败 ${fail.length} 个'
          '${name == null ? '' : ' ｜ 最快：$name（${lat[fastest]}ms）'}');
    } catch (_) {
      if (mounted) setState(() => _testing = false);
      _toast('测速超时，请稍后再试');
    }
  }

  /// 关闭失效片源：把测速失败的全部停用（至少保留 1 个启用）
  Future<void> _closeFailed() async {
    if (_fail.isEmpty) {
      _toast('当前没有测速失败的片源');
      return;
    }
    final changed = _fail.where((id) => !_disabled.contains(id)).length;
    final next = Set<int>.from(_disabled)..addAll(_fail);
    if (next.length >= MacApi.instance.sources.length) {
      _toast('不能关闭全部片源（至少保留 1 个）');
      return;
    }
    await _applyDisabled(next);
    _toast(changed > 0
        ? '已关闭 $changed 个测速失败片源（共检测到 ${_fail.length} 个失败）'
        : '${_fail.length} 个测速失败片源本就已停用');
  }

  /// 全部开启：清空停用集合
  Future<void> _openAll() async {
    if (_disabled.isEmpty) {
      _toast('所有片源均已开启');
      return;
    }
    await _applyDisabled(<int>{});
    _toast('已全部开启（共 ${MacApi.instance.sources.length} 个片源）');
  }

  void _toggle(MovieSource s, bool on) {
    HapticFeedback.selectionClick();
    final next = Set<int>.from(_disabled);
    if (on) {
      next.remove(s.id);
    } else {
      // 停用后至少保留 1 个启用片源（与 PC 版口径一致）
      if (next.length + 1 >= MacApi.instance.sources.length) {
        _toast('至少保留 1 个启用片源');
        return;
      }
      next.add(s.id);
    }
    _applyDisabled(next);
  }

  Future<void> _applyDisabled(Set<int> next) async {
    final st = AppStore.instance;
    st.disabledSourceIds = next;
    MacApi.instance.setDisabledSources(next);
    // 被停用的恰好是「上次手选 / 最快」源 → 收敛到仍启用的源，避免首页指向停用源
    if (next.contains(st.lastSourceId)) st.lastSourceId = -1;
    if (next.contains(st.fastSourceId)) {
      final act = MacApi.instance.activeSources;
      st.fastSourceId = act.isNotEmpty ? act.first.id : -1;
    }
    if (!mounted) return;
    setState(() => _disabled = Set<int>.from(next));
    st.bumpSourceRev();
  }

  String? _nameOf(int? id) => id == null
      ? null
      : MacApi.instance.sources
          .where((s) => s.id == id)
          .map((s) => s.name)
          .firstOrNull;

  // ---------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    final total = MacApi.instance.sources.length;
    final onCount = total - _disabled.length;
    final fastest = _latency.isEmpty
        ? null
        : _latency.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
    final lastTest = AppStore.instance.sourceLastTest;

    return Scaffold(
      appBar: AppBar(title: const Text('片源管理')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 30),
        children: [
          // ---------- 顶部三按钮 ----------
          FilledButton.icon(
            onPressed: _testing ? null : _bench,
            icon: _testing
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.bolt, size: 18),
            label: Text(_testing ? '测速中，约需几秒…' : '立即测速',
                style: const TextStyle(fontSize: 14)),
            style: FilledButton.styleFrom(
              backgroundColor: context.brand,
              minimumSize: const Size.fromHeight(44),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _testing ? null : _closeFailed,
                icon: const Icon(Icons.block, size: 17),
                label: const Text('关闭失效片源', style: TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFE05A6D),
                  side: const BorderSide(color: Color(0x33E05A6D)),
                  minimumSize: const Size.fromHeight(40),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _testing ? null : _openAll,
                icon: const Icon(Icons.restart_alt, size: 17),
                label: const Text('全部开启', style: TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.tSub,
                  side: BorderSide(color: context.divider),
                  minimumSize: const Size.fromHeight(40),
                ),
              ),
            ),
          ]),

          // ---------- 概览 ----------
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 14, bottom: 8),
            child: Text(
              '已启用 $onCount / $total 个片源'
              '${fastest == null ? '' : ' ｜ 最快 ${_nameOf(fastest)} ${_latency[fastest]}ms'}'
              '${lastTest > 0 ? ' ｜ 上次测速 ${_hhmm(lastTest)}' : ' ｜ 尚未测速'}',
              style: TextStyle(fontSize: 11.5, color: context.tFaint),
            ),
          ),

          // ---------- 片源列表 ----------
          _card(context, [
            for (final (i, s) in _sorted.indexed) ...[
              if (i > 0) _divider(context),
              _srcRow(context, s),
            ],
          ]),

          Padding(
            padding: const EdgeInsets.only(left: 6, top: 8),
            child: Row(children: [
              Icon(Icons.warning_amber_rounded, size: 14, color: context.gold),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '停用片源后，该源的影片会从列表与搜索结果中移除（已收藏的影片不受影响）；'
                  '测速失败的片源建议直接关闭，避免拖慢加载。',
                  style: TextStyle(fontSize: 11.5, color: context.tFaint),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _srcRow(BuildContext context, MovieSource s) {
    final ms = _latency[s.id];
    final failed = _fail.contains(s.id);
    final on = !_disabled.contains(s.id);
    final fastestId = _latency.isEmpty
        ? -1
        : _latency.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
    final isFastest = s.id == fastestId;

    // 延迟文案与配色（<1s 绿 / <3s 橙 / 其余红），失败显示「测速失败」
    final Widget speed;
    if (failed) {
      speed = Text('测速失败',
          style: const TextStyle(fontSize: 12, color: Color(0xFFE05A6D)));
    } else if (ms != null && ms > 0) {
      final c = ms < 1000
          ? Colors.green
          : (ms < 3000 ? Colors.orange : Colors.red);
      speed = Text('$ms ms',
          style: TextStyle(fontSize: 12, color: c, fontWeight: FontWeight.w600));
    } else {
      speed = Text('未测速',
          style: TextStyle(fontSize: 12, color: context.tFaint));
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Flexible(
                  child: Text(s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: isFastest ? FontWeight.w700 : null,
                          color: on ? context.tMain : context.tFaint)),
                ),
                if (isFastest) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: context.gold.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('最快',
                        style: TextStyle(fontSize: 10, color: context.gold)),
                  ),
                ],
              ]),
              const SizedBox(height: 2),
              DefaultTextStyle.merge(
                style: TextStyle(fontSize: 11, color: context.tFaint),
                child: Row(children: [
                  speed,
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      s.library.isEmpty
                          ? (on ? 'MacCMS 采集接口' : '已停用 · 不参与加载与检索')
                          : '${s.library}${on ? '' : ' · 已停用'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ]),
              ),
            ],
          ),
        ),
        Switch(
          value: on,
          activeThumbColor: context.brand,
          onChanged: _testing ? null : (v) => _toggle(s, v),
        ),
      ]),
    );
  }

  static String _hhmm(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}';
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  Widget _card(BuildContext context, List<Widget> children) => Container(
        decoration: BoxDecoration(
          color: context.card,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(children: children),
      );

  Widget _divider(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Divider(height: 1, color: context.divider),
      );
}
