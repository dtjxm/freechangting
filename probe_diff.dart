// 差分对拍：Python(merge_classify.cat_of) vs Dart(LiveCats.catOf)
// 跑完即删。
import 'dart:convert';
import 'dart:io';

import 'lib/live_cats.dart';

void main() {
  final rows = (jsonDecode(File('live_cats_sample.json').readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  var same = 0;
  final diffKey = <String, int>{};
  final diffSamples = <String, List<String>>{};
  final extraCats = <String, int>{}; // Dart 侧出现的表外类
  final valid = {...LiveCats.catOrder, LiveCats.radioCat};

  for (final r in rows) {
    final name = r['name'] as String;
    final group = r['group'] as String;
    final py = r['py'] as String;
    final dart = LiveCats.catOf(group, name, '');
    if (!valid.contains(dart)) extraCats[dart] = (extraCats[dart] ?? 0) + 1;
    if (dart == py) {
      same++;
    } else {
      final k = '$py → $dart';
      diffKey[k] = (diffKey[k] ?? 0) + 1;
      final l = diffSamples.putIfAbsent(k, () => []);
      if (l.length < 8) l.add('$name  [组:$group]');
    }
  }

  print('样本 ${rows.length} 条');
  print('一致 ${same} 条（${(100.0 * same / rows.length).toStringAsFixed(1)}%）');
  print('不一致 ${rows.length - same} 条');
  print('');
  print('===== Dart 侧表外类（必须为空）=====');
  if (extraCats.isEmpty) {
    print('  ✅ 无');
  } else {
    extraCats.forEach((k, v) => print('  ❌ $k  $v'));
  }
  print('');
  print('===== 差异矩阵（Python → Dart）=====');
  final ks = diffKey.keys.toList()..sort((a, b) => diffKey[b]!.compareTo(diffKey[a]!));
  for (final k in ks.take(20)) {
    print('  ${k.padRight(22)} ${diffKey[k]}');
  }
  print('');
  print('===== 差异样本 =====');
  for (final k in ks.take(12)) {
    print('[$k]  共 ${diffKey[k]} 条');
    for (final s in diffSamples[k]!) {
      print('    $s');
    }
  }
}
