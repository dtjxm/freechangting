// 版本号一致性防回归检查
//
// 历史坑：关于页头部/版本信息、`我的`页脚曾各自硬编码版本号，发新版后
// 界面仍显示老版本（v1.5.7 修过一次「关于页停留在 v1.5.2」）。
// 现统一到 lib/version.dart 的 kAppVersion，本测试锁定三件事：
//   1) kAppVersion 与 pubspec.yaml 的版本名一致；
//   2) 关于页版本表首行（决定头部与「当前」徽标）取自 kAppVersion；
//   3) 不再有第二处硬编码的 'vX.Y.Z' 版本常量。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _fileVersionName() {
  final src = File('lib/version.dart').readAsStringSync();
  final m = RegExp(r"kAppVersion\s*=\s*'([^']+)'").firstMatch(src);
  expect(m, isNotNull, reason: 'lib/version.dart 未找到 kAppVersion 定义');
  return m!.group(1)!;
}

void main() {
  test('kAppVersion 与 pubspec.yaml 版本名一致', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)', multiLine: true)
        .firstMatch(pubspec);
    expect(m, isNotNull, reason: 'pubspec.yaml 未找到 version:');
    final expected = 'v${m!.group(1)}';
    expect(_fileVersionName(), expected,
        reason: '界面显示的版本号与 pubspec 不一致（发新版时两处要一起改）');
  });

  test('关于页版本表首行取自 kAppVersion', () {
    final src = File('lib/pages/about_page.dart').readAsStringSync();
    expect(src.contains('_Ver(kAppVersion,'), isTrue,
        reason: '版本表首行应写 kAppVersion —— 它既驱动关于页头部，'
            '也决定「版本信息」里的「当前」徽标，写死会显示老版本');
  });

  test('不得存在第二处硬编码版本常量', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.path.endsWith('version.dart')) continue;
      final re = RegExp(r"""(?:^|\s)(?:const|final)\s+\w*[Vv]ersion\w*\s*=\s*'v[0-9]""");
      if (re.hasMatch(f.readAsStringSync())) offenders.add(f.path);
    }
    expect(offenders, isEmpty,
        reason: '版本号只允许定义在 lib/version.dart，'
            '其他文件请 import 后复用：$offenders');
  });
}
