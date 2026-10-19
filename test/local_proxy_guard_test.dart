// v2.2.2（E1）本地净化代理的纯逻辑护栏测试（无需真机 / 无需网络）。
//
// 目的：v2.2.0「全量点播播不出」的根因，是代理地址路径缺少 `.m3u8` 后缀，
// ExoPlayer 据此把 HLS 清单误判为渐进式媒体而无法播放。立住本护栏后，
// 同类「代理地址缺后缀」的回归事故不会再静默复发。
import 'package:dianying_shijie/local_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AdFilterProxy.isHlsUrl 边界', () {
    test('.m3u8 后缀 → HLS', () {
      expect(AdFilterProxy.isHlsUrl('https://a/b.m3u8'), isTrue);
    });

    test('大写 .M3U8 → HLS', () {
      expect(AdFilterProxy.isHlsUrl('https://a/b.M3U8'), isTrue);
    });

    test('带 ?query → HLS', () {
      expect(AdFilterProxy.isHlsUrl('https://a/b.m3u8?sign=1&t=2'), isTrue);
    });

    test('带 #fragment → HLS', () {
      expect(AdFilterProxy.isHlsUrl('https://a/b.m3u8#frag'), isTrue);
    });

    test('.mp4 直链 → 非 HLS', () {
      expect(AdFilterProxy.isHlsUrl('https://a/b.mp4'), isFalse);
    });

    test('空串 → 非 HLS', () {
      expect(AdFilterProxy.isHlsUrl(''), isFalse);
    });

    test('前后带空格（trim 后为 .m3u8）→ HLS', () {
      expect(AdFilterProxy.isHlsUrl('  https://a/b.m3u8  '), isTrue);
    });

    test('无后缀 → 非 HLS', () {
      expect(AdFilterProxy.isHlsUrl('https://a/b'), isFalse);
    });
  });

  group('buildProxyUrl 回归护栏：代理地址必带 .m3u8 后缀', () {
    test('path 恒为 /adfilter.m3u8', () {
      final uri = Uri.parse(
          AdFilterProxy.buildProxyUrl(1234, 'https://a/b.m3u8?x=1'));
      expect(uri.path, '/adfilter.m3u8');
    });

    test('path 以 .m3u8 结尾', () {
      final uri = Uri.parse(
          AdFilterProxy.buildProxyUrl(1234, 'https://a/b.m3u8?x=1'));
      expect(uri.path.endsWith('.m3u8'), isTrue);
    });

    test('回环地址 + 指定端口 + 原始地址编码进 u 参数', () {
      final uri = Uri.parse(
          AdFilterProxy.buildProxyUrl(8899, 'https://a/b.m3u8?x=1'));
      expect(uri.scheme, 'http');
      expect(uri.host, '127.0.0.1');
      expect(uri.port, 8899);
      expect(uri.queryParameters['u'], isNotNull);
    });
  });
}
