// 临时探针：打印 LiveCats 对一批输入的真实返回值（用于校正测试断言）
// 跑完即删。
import 'lib/live_cats.dart';

void main() {
  void cat(String group, [String name = '', String tvg = '']) {
    final c = LiveCats.catOf(group, name, tvg);
    final s = LiveCats.subOf(c, group, name, tvg);
    print('catOf(${_q(group)}, ${_q(name)}, ${_q(tvg)}) = $c'
        '${s.isEmpty ? '' : '  / sub=$s'}');
  }

  print('===== 旧断言涉及的分组名（当 group 传）=====');
  for (final g in [
    'CCTV-1综合', '央视', 'CGTN', '湖南卫视',
    '🌊港·澳·台', '凤凰中文', '北京', '广东电信',
    'General', 'News', 'Movies', 'Sports', 'Documentary', 'Undefined',
    'Movies;Comedy', '其他频道', '其他',
  ]) {
    cat(g);
  }

  print('');
  print('===== 逐频道判定（group + name）=====');
  for (final p in [
    ['😄央视专享', 'CCTV-1'],
    ['高速专享频道', 'CCTV5'],
    ['高速专享频道', '北京卫视'],
    ['🎎动漫直播', '网球王子'],
    ['🏠地方频道', '泸州公共频道'],
    ['📻收音广播', '东广新闻台'],
    ['🚀国际频道', 'CNN'],
    ['国际频道', ''],
  ]) {
    cat(p[0], p[1]);
  }

  print('');
  print('===== 国际（tvg-id 国家识别）=====');
  for (final t in ['CNN.us@SD', 'NHK.jp@SD', 'Rai1.it', 'CNA.sg@SD', '', 'xx.zz']) {
    cat('Undefined', 'SomeChannel', t);
  }

  print('');
  print('===== 常量 =====');
  print('catOrder(${LiveCats.catOrder.length}) = ${LiveCats.catOrder}');
  print('radioCat = ${LiveCats.radioCat}');
  print('intlUnknown = ${LiveCats.intlUnknown}');
  print('vodOrder(${LiveCats.vodOrder.length}) = ${LiveCats.vodOrder}');
  print('hmtOrder = ${LiveCats.hmtOrder}');
  print('provinces(${LiveCats.provinces.length}) = ${LiveCats.provinces}');
}

String _q(String s) => "'$s'";
