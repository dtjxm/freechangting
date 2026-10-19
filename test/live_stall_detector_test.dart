import 'package:flutter_test/flutter_test.dart';

import 'package:dianying_shijie/live_stall_detector.dart';

void main() {
  final t0 = DateTime(2026, 10, 19, 12);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  late LiveStallDetector detector;

  setUp(() {
    detector = LiveStallDetector();
    detector.reset(t0);
  });

  test('位置持续前进时不判卡死', () {
    for (var s = 0; s <= 30; s += LiveStallDetector.checkInterval.inSeconds) {
      detector.onPosition(Duration(seconds: s), at(s));
      expect(
        detector.check(at(s), playing: true, buffering: false),
        isNull,
        reason: '${s}s 时位置仍在前进',
      );
    }
  });

  test('此前前进过、停住 10 秒后判定卡死', () {
    detector.onPosition(const Duration(seconds: 5), at(0));

    expect(
      detector.check(at(9), playing: true, buffering: false),
      isNull,
      reason: '9 秒未达阈值',
    );
    expect(
      detector.check(at(10), playing: true, buffering: false),
      contains('画面停住'),
    );
  });

  test('位置始终为 0 时不按位置判定（拿不到进度的源）', () {
    detector.onPosition(Duration.zero, at(0));

    expect(
      detector.check(at(30), playing: true, buffering: false),
      isNull,
    );
  });

  test('直播窗口回退算活动、不算前进', () {
    detector.onPosition(const Duration(seconds: 10), at(0));
    detector.onPosition(const Duration(seconds: 5), at(5));

    expect(
      detector.check(at(14), playing: true, buffering: false),
      isNull,
      reason: '回退刷新了活动时间，只过了 9 秒',
    );
    expect(
      detector.check(at(15), playing: true, buffering: false),
      contains('画面停住'),
    );
  });

  test('持续缓冲 12 秒后判定卡死', () {
    detector.onBuffering(true, at(0));

    expect(
      detector.check(at(11), playing: true, buffering: true),
      isNull,
    );
    expect(
      detector.check(at(12), playing: true, buffering: true),
      contains('缓冲'),
    );
  });

  test('缓冲恢复后重新给满窗口', () {
    detector.onBuffering(true, at(0));
    detector.onBuffering(false, at(5));

    for (var s = 6; s <= 20; s += LiveStallDetector.checkInterval.inSeconds) {
      expect(
        detector.check(at(s), playing: true, buffering: false),
        isNull,
        reason: '缓冲已恢复，不应按持续缓冲判定',
      );
    }
  });

  test('暂停期间不计时，恢复后从暂停时刻重新计时', () {
    detector.onPosition(const Duration(seconds: 5), at(0));

    expect(
      detector.check(at(20), playing: false, buffering: false),
      isNull,
    );
    expect(
      detector.check(at(29), playing: true, buffering: false),
      isNull,
      reason: '恢复播放后只过了 9 秒',
    );
    expect(
      detector.check(at(30), playing: true, buffering: false),
      contains('画面停住'),
    );
  });
}
