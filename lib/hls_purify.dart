/// HLS 播放清单去广告净化器（电影世界 · 手机版）
///
/// 判据与安全红线移植自「TV 版去广告方案 v4」， TV 版已在真机真实源上验证通过；
/// 权威设计文档见 `E:\008自己写的软件\电影世界程序\公共\去广告方案\`。
///
/// ## 改代码前务必读懂的三条铁律
///
/// 1. **宁可漏杀，不可误杀**。判不准就返回 `null`，调用方回退 307 直连原地址，
///    绝不能为了让「代码看起来生效」而冒险删掉可能是正片的分片。
/// 2. **只删「一对一」标签，不碰「范围状态」标签**（这是最容易写错的地方）：
///    - `#EXTINF` 是**一对一**标签，只描述紧随的那一个分片 → 分片被删时必须同删，
///      否则 EXTINF 会悬空并污染下一个分片，属**结构性错误**。
///    - `#EXT-X-KEY` 是**范围状态**标签，对其后所有分片生效直到下一条 KEY →
///      **必须原样保留**。只要不删 KEY、不重排 KEY，保留分片的密钥上下文就不变，零影响。
///    - `#EXT-X-BYTERANGE` 与 `#EXTINF` 真正同构 → 出现即触发红线放弃（当前能力不支持）。
/// 3. 分片 URI 与 KEY 的 URI **一律改写为绝对地址**。因为本清单由本地代理返回，
///    相对路径会被播放器按 `127.0.0.1` 解析从而 404。
class HlsPurifier {
  HlsPurifier._();

  // ---------- 安全闸常量（与 TV 版 RemoteServer.java 取值保持一致） ----------

  /// 目录切换型：外来目录分片数上限，超过即怀疑「正片本就跨目录」或「纯编码分界源」
  static const int maxForeignSegments = 60;

  /// 目录切换型：外来分片占比上限（百分比）
  static const int maxForeignPercent = 20;

  /// 夹心岛型：单个岛最多允许的段数
  static const int maxIslandSegs = 8;

  /// 夹心岛型：单个岛允许的最长 / 最短时长（秒）
  static const double maxIslandSeconds = 45.0;
  static const double minIslandSeconds = 12.0;

  /// 夹心岛型：整份清单最多允许命中的岛数
  static const int maxIslandCount = 6;

  /// 合计删除段数占比上限（百分比）
  static const double maxTotalRemovePercent = 2.0;

  /// 日志钩子（默认走 Flutter 的 debugPrint，可在 App 初始化时换成写文件）
  static void Function(String msg)? onLog;

  static void _log(String msg) {
    final f = onLog;
    if (f != null) f('[adfilter] $msg');
  }

  /// 是否为主清单（含多个码率变体）
  static bool isMasterPlaylist(String body) => body.contains('#EXT-X-STREAM-INF');

  // ---------- 主入口 ----------

  /// 净化 media 清单。
  ///
  /// [body] 清单原文；[baseUrl] 该清单自身的绝对地址（用于把相对 URI 解析成绝对地址）。
  ///
  /// 返回净化后的清单文本；**返回 `null` 表示「放弃净化」**，调用方应改走 307 直连原地址。
  /// —— 本接口刻意让「删不动」成为一个正常的、常见的返回值，而不是异常。
  static String? purifyMedia(String body, String baseUrl) {
    try {
      return _purifyMediaInner(body, baseUrl);
    } catch (e) {
      _log('异常 → 放弃净化 原因=$e');
      return null; // 红线 7：解析异常一律放弃
    }
  }

  static String? _purifyMediaInner(String body, String baseUrl) {
    final Uri base;
    try {
      base = Uri.parse(baseUrl);
    } catch (_) {
      return null;
    }

    final nodes = _parse(body, base);
    if (nodes == null) return null;

    final segNodes = nodes.where((n) => n.segment).toList();
    final totalSeg = segNodes.length;
    if (totalSeg == 0) {
      _log('跳过 原因=非 media 清单（无分片行）');
      return null;
    }

    // ===== 红线 1：非点播一律不动（直播滑窗绝不可改） =====
    // 这是**全局**红线，两种判据都不能突破：直播清单在不断滚动，删掉任何一段
    // 都会让播放器的时间轴与实际内容错位，后果远比播一点广告严重。
    if (!_isVod(body)) {
      _log('跳过 原因=非点播（无 ENDLIST 或 PLAYLIST-TYPE:EVENT）');
      return null;
    }

    // ===== 能力边界 / 红线：碰到当前解析不了的语义一律整单放弃 =====
    if (body.contains('#EXT-X-DISCONTINUITY-SEQUENCE')) {
      _log('跳过 原因=含 EXT-X-DISCONTINUITY-SEQUENCE（序列号语义不确定）');
      return null;
    }
    if (body.contains('#EXT-X-BYTERANGE')) {
      _log('跳过 原因=含 EXT-X-BYTERANGE（当前不支持，避免结构错误）');
      return null;
    }
    if (body.contains('#EXT-X-MAP:')) {
      _log('跳过 原因=含 EXT-X-MAP（fMP4 初始化段，当前不支持）');
      return null;
    }
    if (body.contains('SAMPLE-AES')) {
      _log('跳过 原因=SAMPLE-AES 加密（密钥上下文敏感，不动）');
      return null;
    }
    if (body.contains('#EXT-X-KEY') && _keyVaries(nodes)) {
      _log('跳过 原因=KEY 多变（密钥上下文不确定）');
      return null;
    }

    // ===== 第一遍：先把全部广告分片标记出来 =====
    // 必须与「输出」分开 —— 否则输出到「广告块前侧那条的 DISCONTINUITY」时，
    // 它后面的广告分片还没被标记，前侧分界就会漏删。
    final dirHit = _markByDirectory(nodes, totalSeg);
    final islandHit = _markDiscIslands(nodes, body);

    if (!dirHit && islandHit == 0) {
      _log('放弃净化 → 307 原因=两型均未命中 totalSeg=$totalSeg');
      return null;
    }

    // ===== 第二遍：输出 =====
    final out = StringBuffer();
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      if (n.isExtinfLine) {
        // EXTINF 是一对一标签：它描述的后随分片被删 ⇒ 它跟着删
        if (_nextSegIsAd(nodes, i)) continue;
        out.writeln(n.text);
        continue;
      }
      if (n.segment) {
        if (n.ad) continue;
        out.writeln(n.uri); // 已是绝对地址
        continue;
      }
      if (n.isDiscontinuity) {
        if (_shouldDropDiscontinuity(nodes, i)) continue;
        out.writeln(n.text);
        continue;
      }
      if (n.isKeyLine) {
        // KEY 保留，只把它的 URI 绝对化
        out.writeln(_absolutizeKey(n.text, base));
        continue;
      }
      out.writeln(n.text);
    }

    final keptSeg = nodes.where((n) => n.segment && !n.ad).length;
    if (keptSeg == 0) {
      _log('放弃净化 原因=删除后无剩余分片（异常）');
      return null;
    }

    _log('净化完成 删岛=$islandHit 目录命中=${dirHit ? 1 : 0} '
        '原始段=$totalSeg 保留段=$keptSeg 实际删除=${totalSeg - keptSeg}');

    return out.toString();
  }

  // ---------- 解析 ----------

  static List<_Node>? _parse(String body, Uri base) {
    final nodes = <_Node>[];
    double lastDur = 0.0;
    for (final raw in body.split(RegExp(r'\r?\n'))) {
      final t = raw.trim();
      final n = _Node(text: raw);
      if (t.isEmpty) {
        nodes.add(n);
        continue;
      }
      if (!t.startsWith('#')) {
        n.segment = true;
        try {
          n.uri = base.resolve(t).toString();
          n.dir = _dirOf(n.uri);
        } catch (_) {
          return null; // 解析异常 → 红线 7
        }
        n.dur = lastDur;
        lastDur = 0.0;
      } else if (t.startsWith('#EXTINF')) {
        n.isExtinfLine = true;
        lastDur = _parseExtinf(t);
      } else if (t.startsWith('#EXT-X-DISCONTINUITY') &&
          !t.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE')) {
        n.isDiscontinuity = true;
      } else if (t.startsWith('#EXT-X-KEY')) {
        n.isKeyLine = true;
      }
      nodes.add(n);
    }
    return nodes;
  }

  static double _parseExtinf(String line) {
    try {
      final v = line.substring(line.indexOf(':') + 1);
      final numPart = v.split(',').first.trim();
      return double.tryParse(numPart) ?? 0.0;
    } catch (_) {
      return 0.0;
    }
  }

  static String _dirOf(String uri) {
    final i = uri.lastIndexOf('/');
    return i <= 0 ? uri : uri.substring(0, i);
  }

  // ---------- 红线 1：点播判定 ----------

  static bool _isVod(String body) {
    if (body.contains('#EXT-X-PLAYLIST-TYPE:EVENT')) return false;
    return body.contains('#EXT-X-ENDLIST');
  }

  // ---------- 红线 6：KEY 是否多变 ----------

  static bool _keyVaries(List<_Node> nodes) {
    final keys = <String>{};
    for (final n in nodes) {
      if (n.isKeyLine) keys.add(n.text.trim());
    }
    return keys.length > 1;
  }

  // ---------- 判据 A：目录切换型 ----------

  /// 广告分片来自「与正片不同的目录」。取分片最多的目录为正片基线，其余判为外来。
  /// 返回是否命中。
  static bool _markByDirectory(List<_Node> nodes, int totalSeg) {
    final dirCount = <String, int>{};
    for (final n in nodes) {
      if (!n.segment) continue;
      dirCount[n.dir] = (dirCount[n.dir] ?? 0) + 1;
    }
    if (dirCount.isEmpty) return false;

    var dominant = '';
    var dominantCount = -1;
    for (final e in dirCount.entries) {
      if (e.value > dominantCount) {
        dominantCount = e.value;
        dominant = e.key;
      }
    }
    final foreign = totalSeg - dominantCount;

    // 安全闸：外来分片过多 → 更像「正片本就跨目录」或「纯编码分界源」
    if (foreign > maxForeignSegments ||
        foreign * 100 > totalSeg * maxForeignPercent) {
      _log('目录判据放弃 原因=超限 foreign=$foreign dominant=$dominant');
      return false;
    }
    if (foreign == 0) return false;

    for (final n in nodes) {
      if (n.segment && n.dir != dominant) n.ad = true;
    }
    _log('目录判据 命中 totalSeg=$totalSeg foreign=$foreign dominant=$dominant');
    return true;
  }

  // ---------- 判据 B：同目录「DISCONTINUITY 夹心岛」型 ----------

  /// 岛定义：连续 N 个分片，其**紧前**一条 DISCONTINUITY、**紧后**一条 DISCONTINUITY。
  /// 返回命中的岛数。
  static int _markDiscIslands(List<_Node> nodes, String body) {
    final segIdx = <int>[];
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].segment) segIdx.add(i);
    }
    final totalSeg = segIdx.length;
    if (totalSeg < 3) return 0;

    final totalDur = nodes.fold<double>(0.0, (s, n) => s + (n.segment ? n.dur : 0.0));
    if (totalDur <= 0) {
      _log('岛判据跳过 原因=总时长未知');
      return 0;
    }

    // 找出全部「被成对分界夹住」的 run：opener 表示分界之后的第一个分片序号
    final islands = <_Island>[];
    var opener = -1;
    for (var k = 0; k < totalSeg; k++) {
      final prevSegNodeIdx = k > 0 ? segIdx[k - 1] : -1;
      final hasDiscBefore = _hasDiscontinuityBetween(nodes, prevSegNodeIdx, segIdx[k]);
      if (hasDiscBefore) {
        if (opener >= 0) {
          final run = _Island(opener, k - 1);
          if (run.count > 0) islands.add(run);
        }
        opener = k;
      }
    }
    // 末尾没有收尾分界的 run 不算岛（I1 不满足）→ 自动丢弃

    if (islands.isEmpty) {
      _log('岛判据跳过 原因=无成对分界');
      return 0;
    }

    // 指纹统计（★核心置信特征 S1）：
    // 同一支广告被反复插播，它每次出现的分段时长序列必然逐字节相同。
    final sigMap = <String, List<_Island>>{};
    for (final isl in islands) {
      final sig = _islandSignature(nodes, segIdx, isl);
      sigMap.putIfAbsent(sig, () => <_Island>[]).add(isl);
    }

    final hits = <_Island>[];
    for (final entry in sigMap.entries) {
      final repeat = entry.value.length >= 2; // S1
      for (final isl in entry.value) {
        final n = isl.count;
        final dur = _islandDuration(nodes, segIdx, isl);

        if (n < 1 || n > maxIslandSegs) continue; // I3
        if (dur < minIslandSeconds || dur > maxIslandSeconds) continue; // I4
        if (dur * 100 / totalDur > 2.0) continue; // I5
        if (isl.start <= 0 || isl.end >= totalSeg - 1) continue; // I2 非首非尾
        if (!repeat) continue; // S1 高置信

        hits.add(isl);
      }
    }

    if (hits.isEmpty) {
      _log('岛判据结论 命中=0');
      return 0;
    }

    // 安全闸：岛数超限 / 合计删除超限 → 整单放弃
    if (hits.length > maxIslandCount) {
      _log('岛判据放弃 原因=岛数超限 命中=${hits.length}');
      return 0;
    }
    final removedDur = hits.fold<double>(0.0, (s, i) => s + _islandDuration(nodes, segIdx, i));
    if (removedDur * 100 / totalDur > 5.0) {
      _log('岛判据放弃 原因=删除时长超限 删=${removedDur.toStringAsFixed(1)}s');
      return 0;
    }
    final removedSeg = hits.fold<int>(0, (s, i) => s + i.count);
    if (removedSeg * 100.0 > totalSeg * maxTotalRemovePercent) {
      _log('岛判据放弃 原因=删除段数占比超限 删段=$removedSeg / $totalSeg');
      return 0;
    }

    for (final isl in hits) {
      for (var k = isl.start; k <= isl.end; k++) {
        nodes[segIdx[k]].ad = true;
      }
      _log('岛命中 段数=${isl.count} '
          '时长=${_islandDuration(nodes, segIdx, isl).toStringAsFixed(2)}s '
          '位置=${isl.start}..${isl.end}');
    }
    return hits.length;
  }

  /// 两个分片之间是否存在 DISCONTINUITY（prev 为 -1 表示清单开头之前）
  static bool _hasDiscontinuityBetween(List<_Node> nodes, int prevSegNodeIdx, int curSegNodeIdx) {
    for (var i = prevSegNodeIdx + 1; i < curSegNodeIdx && i < nodes.length; i++) {
      if (nodes[i].isDiscontinuity) return true;
    }
    return false;
  }

  static String _islandSignature(List<_Node> nodes, List<int> segIdx, _Island isl) {
    final parts = <String>[];
    for (var k = isl.start; k <= isl.end; k++) {
      parts.add(nodes[segIdx[k]].dur.toStringAsFixed(3));
    }
    return '${isl.count}:${parts.join(',')}';
  }

  static double _islandDuration(List<_Node> nodes, List<int> segIdx, _Island isl) {
    var d = 0.0;
    for (var k = isl.start; k <= isl.end; k++) {
      d += nodes[segIdx[k]].dur;
    }
    return d;
  }

  // ---------- 输出辅助 ----------

  /// 该位置处的 EXTINF 所描述的下一个分片是否被标记为广告
  static bool _nextSegIsAd(List<_Node> nodes, int from) {
    for (var i = from + 1; i < nodes.length; i++) {
      if (nodes[i].segment) return nodes[i].ad;
    }
    return false;
  }

  /// DISCONTINUITY 是否该删：两侧紧邻的分片只要有一侧是广告（或不存在）就删。
  /// 这样保留下来的分界必然夹在两个正片分片之间。
  static bool _shouldDropDiscontinuity(List<_Node> nodes, int i) {
    _Node? prevSeg;
    for (var k = i - 1; k >= 0; k--) {
      if (nodes[k].segment) {
        prevSeg = nodes[k];
        break;
      }
    }
    if (prevSeg == null || prevSeg.ad) return true;

    _Node? nextSeg;
    for (var k = i + 1; k < nodes.length; k++) {
      if (nodes[k].segment) {
        nextSeg = nodes[k];
        break;
      }
    }
    if (nextSeg == null || nextSeg.ad) return true;

    return false;
  }

  /// KEY 标签保留，只把它的 URI 换成绝对地址。
  /// （为什么不删 KEY：它是范围状态标签，删除 / 重排会让保留分片解不出密钥。）
  static String _absolutizeKey(String line, Uri base) {
    final m = RegExp('URI="([^"]*)"').firstMatch(line);
    if (m == null) return line;
    final u = m.group(1)!;
    if (u.isEmpty) return line;
    if (u.startsWith('http://') ||
        u.startsWith('https://') ||
        u.startsWith('data:')) {
      return line;
    }
    final abs = base.resolve(u).toString();
    return line.replaceFirst('URI="$u"', 'URI="$abs"');
  }

  // ---------- 主清单改写 ----------

  /// 改写 master 清单：把每个码率变体的地址包一层本地代理，
  /// 这样播放器选中某一码率后，其子清单仍会走我们的净化。
  ///
  /// [localUrl] 把绝对地址包装成本地代理地址的函数。
  static String rewriteMaster(
    String body,
    String baseUrl,
    String Function(String absoluteUrl) localUrl,
  ) {
    final base = Uri.parse(baseUrl);
    final out = StringBuffer();
    for (final raw in body.split(RegExp(r'\r?\n'))) {
      final l = raw.trim();
      if (l.isEmpty) {
        out.writeln(raw);
        continue;
      }
      if (l.startsWith('#')) {
        // v2.2.0 修复：master 里的 #EXT-X-MEDIA / #EXT-X-I-FRAME-STREAM-INF 等
        // 可能带相对 URI="..."，原样返回会被播放器按代理地址(127.0.0.1)解析而 404。
        // 这里把这些 URI 也绝对化（m3u8 会再包一层代理，保持链路一致）。
        out.writeln(_absolutizeTagUri(raw, base, localUrl));
        continue;
      }
      final abs = base.resolve(l).toString();
      out.writeln(localUrl(abs));
    }
    return out.toString();
  }

  /// 把标签行里的相对 `URI="..."` 绝对化（绝对地址 / data: 原样保留）。
  /// 无 URI 属性的标签行原样返回，行为与改动前完全一致。
  static String _absolutizeTagUri(
    String line,
    Uri base,
    String Function(String absoluteUrl) localUrl,
  ) {
    final m = RegExp('URI="([^"]*)"').firstMatch(line);
    if (m == null) return line;
    final u = m.group(1)!;
    if (u.isEmpty) return line;
    if (u.startsWith('http://') ||
        u.startsWith('https://') ||
        u.startsWith('data:')) {
      return line;
    }
    final abs = base.resolve(u).toString();
    return line.replaceFirst('URI="$u"', 'URI="${localUrl(abs)}"');
  }
}

/// 一个被分界夹住的连续分片串（下标以分片序号计，非节点序号）
class _Island {
  final int start;
  final int end;
  const _Island(this.start, this.end);
  int get count => end - start + 1;
}

class _Node {
  final String text;
  bool segment = false;
  bool isExtinfLine = false;
  bool isDiscontinuity = false;
  bool isKeyLine = false;
  bool ad = false;
  double dur = 0.0;
  String uri = '';
  String dir = '';

  _Node({required this.text});
}
