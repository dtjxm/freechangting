// v1.9.9（代码审查 3.1/六）全局 HTTPS 证书校验绕过防回归检查
//
// 静态扫描 lib/main.dart：确保不再出现 badCertificateCallback 无条件放行
// （`=> true`）。若未来确需为个别证书不合规域名放行，必须走「域名白名单」
// 形式（核对 host 后返回），本测试将拦截任何全局 `=> true` 的回归。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('main.dart 不得包含全局 badCertificateCallback => true', () {
    final src = File('lib/main.dart').readAsStringSync();
    expect(src.contains('badCertificateCallback'), isFalse,
        reason: '出现 badCertificateCallback：请改用明确的域名白名单，'
            '禁止无条件放行任意证书（中间人风险）');
    // 双保险：即使回调换名字，也不允许出现 "=> true" 的证书放行惯用写法
    final certLineRe = RegExp(r'badCertificate|CertificateCallback');
    if (certLineRe.hasMatch(src)) {
      expect(src.contains('=> true'), isFalse,
          reason: '证书回调不得无条件返回 true');
    }
  });

  test('_LimitedHttpOverrides 仍保留连接数与超时设置', () {
    final src = File('lib/main.dart').readAsStringSync();
    expect(src.contains('maxConnectionsPerHost = 6'), isTrue,
        reason: '图片床并发限流不能随证书修复一起丢掉');
    expect(src.contains('connectionTimeout'), isTrue);
  });
}
