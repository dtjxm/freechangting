// v2.2.4 本地影片（已下载 / 外部文件）观看记录 Key 约定防回归
//
// 本地内容没有片源，统一用 sourceId == -1 + 带前缀的 vodId 标识；
// 「观看历史」要按 vodId + sourceId 去重和查进度，所以下载页、历史页、
// 外部文件入口必须共用同一套 Key —— 本测试锁死这套约定。
import 'package:dianying_shijie/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const taskId = '2|12345|0|3';

  group('LocalKeys 下载成片 Key', () {
    test('任务 id → 本地条目 vodId', () {
      expect(LocalKeys.taskVodId(taskId), 'local_2|12345|0|3');
    });

    test('本地条目 vodId → 任务 id（可反查 DownloadTask）', () {
      final vod = LocalKeys.taskVodId(taskId);
      expect(LocalKeys.taskIdOf(vod), taskId);
    });

    test('vodId 内嵌的 | 不被破坏（任务 id 原样还原）', () {
      const weird = '1||0|0';
      expect(LocalKeys.taskIdOf(LocalKeys.taskVodId(weird)), weird);
    });

    test('非下载条目不会误判为下载条目', () {
      expect(LocalKeys.taskIdOf('external_content://x'), isNull);
      expect(LocalKeys.taskIdOf('12345'), isNull);
      expect(LocalKeys.taskIdOf(''), isNull);
    });
  });

  group('LocalKeys 外部文件 Key', () {
    test('uri → vodId → uri 往返一致', () {
      const uri = 'content://media/external/video/media/1234';
      expect(LocalKeys.externalVodId(uri),
          'external_content://media/external/video/media/1234');
      expect(LocalKeys.externalUriOf(LocalKeys.externalVodId(uri)), uri);
    });

    test('file:// 路径往返一致', () {
      const uri = 'file:///storage/emulated/0/Movies/a b.mp4';
      expect(LocalKeys.externalUriOf(LocalKeys.externalVodId(uri)), uri);
    });

    test('外部与前缀互不串台', () {
      expect(LocalKeys.externalUriOf(LocalKeys.taskVodId(taskId)), isNull);
      expect(LocalKeys.taskIdOf(LocalKeys.externalVodId('file:///a.mp4')), isNull);
    });
  });

  group('历史进度 Key 与片源无关', () {
    test('本地条目的 sourceId 为 -1（片源表里不存在，故历史页要单独分支）', () {
      const item = VideoItem(
        vodId: 'local_2|12345|0|3',
        name: '某片 · 第1集',
        sourceId: LocalKeys.localSourceId,
        sourceName: '本地下载',
      );
      expect(item.sourceId, -1);
      expect(LocalKeys.taskIdOf(item.vodId), taskId);
    });

    test('同一集反复播放 Key 稳定（去重后历史只剩一条、进度可覆盖）', () {
      final k1 = LocalKeys.taskVodId(taskId);
      final k2 = LocalKeys.taskVodId(taskId);
      expect(k1, k2);
    });
  });
}
