/// 数据模型：片源 / 影片条目 / 详情 / 选集
library;

// ---- v1.9.9（代码审查 3.5）持久化数据字段类型漂移的兼容转换 ----
// 收藏/历史是旧版本写进本机的 JSON，字段可能从 String 漂成 num 等；
// 逐字段兼容转换，避免单条旧记录让整个存储初始化失败。
int _mToInt(dynamic v, [int def = 0]) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v) ?? def;
  return def;
}

double _mToDouble(dynamic v, [double def = 0]) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? def;
  return def;
}

String _mToStr(dynamic v, [String def = '']) {
  if (v is String) return v;
  if (v == null) return def;
  return '$v';
}

class MovieSource {
  final int id;
  final String name;
  final String url;
  final String ac;
  final String library;

  const MovieSource({
    required this.id,
    required this.name,
    required this.url,
    this.ac = 'detail',
    this.library = '',
  });

  // v2.2.2（D8）：逐字段容错 —— sources.json 某源字段类型异常时不再让
  // loadSources() 整体抛错（原实现硬 `as String` / `as num` 会崩掉全站片源加载）。
  factory MovieSource.fromJson(Map<String, dynamic> j) => MovieSource(
        id: int.tryParse('${j['id'] ?? ''}') ?? -1,
        name: _mToStr(j['name']),
        url: _mToStr(j['url']),
        ac: _mToStr(j['ac'], 'detail'),
        library: _mToStr(j['library']),
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'url': url, 'ac': ac, 'library': library};
}

class VideoItem {
  final String vodId;
  final String name;
  final String pic;
  final String remarks;
  final String typeId;
  final String typeName;
  final String vodClass; // 风格标签（如「喜剧,爱情」）
  final String time;
  final int sourceId;
  final String sourceName;
  final String year; // v1.6.3 年份（vod_year）
  final String actor; // v1.6.3 主演（vod_actor，空则导演）
  final double score; // v1.7.0 评分（vod_score，排序用）
  final int hits; // v1.7.0 热度（vod_hits，排序用）
  final String area; // v1.7.0 地区（vod_area，筛选用）
  final String director; // v1.9.5 导演（vod_director，检索用）

  const VideoItem({
    required this.vodId,
    required this.name,
    this.pic = '',
    this.remarks = '',
    this.typeId = '',
    this.typeName = '',
    this.vodClass = '',
    this.time = '',
    required this.sourceId,
    required this.sourceName,
    this.year = '',
    this.actor = '',
    this.score = 0,
    this.hits = 0,
    this.area = '',
    this.director = '',
  });

  Map<String, dynamic> toMap() => {
        'vodId': vodId,
        'name': name,
        'pic': pic,
        'remarks': remarks,
        'typeId': typeId,
        'typeName': typeName,
        'vodClass': vodClass,
        'time': time,
        'sourceId': sourceId,
        'sourceName': sourceName,
        'year': year,
        'actor': actor,
        'score': score,
        'hits': hits,
        'area': area,
        'director': director,
      };

  factory VideoItem.fromMap(Map<String, dynamic> m) => VideoItem(
        vodId: _mToStr(m['vodId']),
        name: _mToStr(m['name']),
        pic: _mToStr(m['pic']),
        remarks: _mToStr(m['remarks']),
        typeId: _mToStr(m['typeId']),
        typeName: _mToStr(m['typeName']),
        vodClass: _mToStr(m['vodClass']),
        time: _mToStr(m['time']),
        sourceId: _mToInt(m['sourceId']),
        sourceName: _mToStr(m['sourceName']),
        year: _mToStr(m['year']),
        actor: _mToStr(m['actor']),
        score: _mToDouble(m['score']),
        hits: _mToInt(m['hits']),
        area: _mToStr(m['area']),
        director: _mToStr(m['director']),
      );
}

class Episode {
  final String name;
  final String url;
  const Episode(this.name, this.url);
}

class PlayGroup {
  final String from;
  final List<Episode> episodes;
  const PlayGroup(this.from, this.episodes);
}

class VideoDetail {
  final VideoItem item;
  final String year;
  final String area;
  final String actor;
  final String director;
  final String content;
  final List<PlayGroup> groups;

  const VideoDetail({
    required this.item,
    this.year = '',
    this.area = '',
    this.actor = '',
    this.director = '',
    this.content = '',
    this.groups = const [],
  });

  bool get playable => groups.any((g) => g.episodes.isNotEmpty);
}

/// 分类
class Category {
  final String id;
  final String name;
  final String pid; // 父分类 id，'0' 为顶级
  const Category(this.id, this.name, {this.pid = '0'});
  bool get isTop => pid == '0' || pid.isEmpty;
}

/// v2.2.4：本地播放条目的 Key 约定（单一事实源）。
///
/// 本地内容没有片源，统一用 `sourceId == -1` + 特殊 `vodId` 前缀标识，
/// 并且**必须**与「观看历史」用同一个 Key —— 进度记录、历史回放、续播定位
/// 全靠它对齐。下载页、历史页、外部文件入口都从这里取前缀，避免各写一份字面量。
///
/// - `local_<任务id>`：下载成片（任务 id 形如 `sourceId|vodId|groupIndex|epIndex`）
/// - `external_<uri>`：外部本地文件（分享 / 「打开方式」进入）
class LocalKeys {
  LocalKeys._();

  static const taskPrefix = 'local_';
  static const externalPrefix = 'external_';

  /// 本地条目的固定片源 id（片源表里不存在 -1）
  static const localSourceId = -1;

  /// 下载任务 → 本地条目 vodId
  static String taskVodId(String taskId) => '$taskPrefix$taskId';

  /// 本地条目 vodId → 下载任务 id（非下载条目返回 null）
  static String? taskIdOf(String vodId) => vodId.startsWith(taskPrefix)
      ? vodId.substring(taskPrefix.length)
      : null;

  /// 本地条目 vodId → 外部文件 uri（非外部条目返回 null）
  static String? externalUriOf(String vodId) =>
      vodId.startsWith(externalPrefix)
          ? vodId.substring(externalPrefix.length)
          : null;

  /// 外部文件 uri → 本地条目 vodId
  static String externalVodId(String uri) => '$externalPrefix$uri';
}
