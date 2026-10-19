/// 直播「起播后卡死」判定（纯逻辑，无 Flutter / Timer 依赖，便于单测）。
///
/// 解决的问题：死线路在起播阶段由 20 秒看门狗兜底；但有些线路连得上、
/// 有声音、画面/播放时钟却冻住，`playing` 一直是 true，起播看门狗不会再管。
/// 这里用两个信号判断：
/// - 播放位置此前确实前进过，随后连续 10 秒不前进；
/// - 或持续缓冲 12 秒不恢复。
///
/// 位置始终为 0 的源（部分直播流不给进度）不会触发位置判定，只靠缓冲兜底，
/// 避免把「拿不到位置信息」误判成卡死。
class LiveStallDetector {
  static const Duration checkInterval = Duration(seconds: 2);
  static const Duration positionStallAfter = Duration(seconds: 10);
  static const Duration rebufferStallAfter = Duration(seconds: 12);

  Duration _lastPos = Duration.zero;
  bool _advanced = false;
  DateTime _lastAdvanceAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _bufferSince;

  /// 每次开播/切线路时调用，清空上一轮采样。
  void reset(DateTime now) {
    _lastPos = Duration.zero;
    _advanced = false;
    _lastAdvanceAt = now;
    _bufferSince = null;
  }

  /// 每收到一次播放位置事件调用。
  ///
  /// 直播窗口重置时位置会回退；回退也算播放器仍在走，只重新采样，
  /// 不作为「前进过」的证据。
  void onPosition(Duration pos, DateTime now) {
    if (pos == _lastPos) return;
    _lastAdvanceAt = now;
    if (pos > _lastPos) _advanced = true;
    _lastPos = pos;
  }

  /// 每次缓冲状态变化时调用。
  void onBuffering(bool buffering, DateTime now) {
    if (buffering) {
      _bufferSince ??= now;
    } else {
      _bufferSince = null;
      // 缓冲恢复也算有进展，重新给满一个判定窗口
      _lastAdvanceAt = now;
    }
  }

  /// 周期性调用（建议 [checkInterval]）。返回非空字符串表示判定卡死。
  String? check(
    DateTime now, {
    required bool playing,
    required bool buffering,
  }) {
    // 暂停时不计时；恢复播放后重新给满窗口
    if (!playing) {
      _lastAdvanceAt = now;
      _bufferSince = null;
      return null;
    }

    if (buffering) {
      final since = _bufferSince ?? now;
      _bufferSince = since;
      // 缓冲期间位置不动是正常的，按「持续缓冲」单独判定
      _lastAdvanceAt = now;
      if (now.difference(since) >= rebufferStallAfter) {
        return '缓冲超过 ${rebufferStallAfter.inSeconds} 秒，自动切换线路';
      }
      return null;
    }

    _bufferSince = null;
    if (_advanced &&
        now.difference(_lastAdvanceAt) >= positionStallAfter) {
      return '画面停住超过 ${positionStallAfter.inSeconds} 秒，自动切换线路';
    }
    return null;
  }
}
