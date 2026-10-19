// v1.9.9（代码审查 3.4/六）DownloadTask JSON 往返与旧数据兼容测试
//
// 说明：DownloadTask 属纯数据模型，fromJson/toJson 不触网、不开 MethodChannel，
// 可在 flutter test 下直接构造与断言。
import 'package:flutter_test/flutter_test.dart';

import 'package:dianying_shijie/download_service.dart';

DownloadTask _task() => DownloadTask(
      id: '2|30019|0|3',
      sourceId: 2,
      sourceName: '暴风',
      vodId: '30019',
      movieName: '测试影片',
      groupIndex: 0,
      groupName: 'default',
      epIndex: 3,
      epName: '第04集',
      url: 'https://example.com/a.m3u8',
      state: 'running',
      progress: 0.42,
      segments: const ['seg0.ts', 'seg1.ts'],
      hls: true,
      parsed: true,
      attempts: 1,
      bytesDone: 123456,
      bytesTotal: 300000,
      speedBps: 204800.5,
      elapsedSec: 37,
      etaSec: 120,
      subcat: '动作片',
      doneAt: 1758600000000,
    );

void main() {
  test('新 JSON：toJson/fromJson 全字段往返（含 speedBps/etaSec）', () {
    final t = _task();
    final restored = DownloadTask.fromJson(t.toJson());
    expect(restored.id, t.id);
    expect(restored.sourceId, t.sourceId);
    expect(restored.vodId, t.vodId);
    expect(restored.movieName, t.movieName);
    expect(restored.epIndex, t.epIndex);
    expect(restored.epName, t.epName);
    expect(restored.state, 'running');
    expect(restored.progress, 0.42);
    expect(restored.segments, ['seg0.ts', 'seg1.ts']);
    expect(restored.hls, isTrue);
    expect(restored.parsed, isTrue);
    expect(restored.attempts, 1);
    expect(restored.bytesDone, 123456);
    expect(restored.bytesTotal, 300000);
    expect(restored.speedBps, 204800.5); // v1.9.9 新恢复的字段
    expect(restored.etaSec, 120); // v1.9.9 新恢复的字段
    expect(restored.elapsedSec, 37);
    expect(restored.subcat, '动作片');
    expect(restored.doneAt, 1758600000000);
  });

  test('旧 JSON：缺少 speedBps/etaSec/subcat/doneAt 等新字段时正常加载', () {
    // 模拟 v1.6.0 时代持久化的最小 JSON（当时还没有这些字段）
    final oldJson = <String, dynamic>{
      'id': '1|100|0|0',
      'sourceId': 1,
      'sourceName': '飘零',
      'vodId': '100',
      'movieName': '老任务',
      'groupIndex': 0,
      'groupName': 'default',
      'epIndex': 0,
      'epName': '第01集',
      'url': 'https://example.com/old.mp4',
      'state': 'done',
      'progress': 1,
      'hls': false,
    };
    final t = DownloadTask.fromJson(oldJson);
    expect(t.state, 'done');
    expect(t.speedBps, 0);
    expect(t.etaSec, 0);
    expect(t.subcat, '');
    expect(t.doneAt, 0);
    expect(t.segments, isEmpty);
  });

  test('字段类型漂移：数字存成字符串/浮点时不崩溃且值正确', () {
    final drifted = <String, dynamic>{
      'id': '1|100|0|0',
      'sourceId': '1', // String 漂移
      'sourceName': '飘零',
      'vodId': '100',
      'movieName': '漂移任务',
      'groupIndex': 0.0, // double 漂移
      'groupName': 'default',
      'epIndex': 2,
      'epName': '第03集',
      'url': 'https://example.com/x.m3u8',
      'state': 'waiting',
      'progress': '0.5', // String 漂移
      'attempts': '1',
      'bytesDone': '999',
      'speedBps': '321.5',
      'etaSec': '45',
      'hls': 'yes', // 非 bool → 走默认 true
      'parsed': 1, // 非 bool → 走默认 false
    };
    final t = DownloadTask.fromJson(drifted);
    expect(t.sourceId, 1);
    expect(t.groupIndex, 0);
    expect(t.progress, 0.5);
    expect(t.attempts, 1);
    expect(t.bytesDone, 999);
    expect(t.speedBps, 321.5);
    expect(t.etaSec, 45);
    expect(t.hls, isTrue); // 无法识别的类型回退默认值
    expect(t.parsed, isFalse);
  });
}
