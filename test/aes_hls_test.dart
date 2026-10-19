// v2.1 新增能力测试（v2.1.1 升级）：AES-128 加密 HLS 改为可下载
// ① HlsKeyPlan.parse 清单解析：未加密 / 单密钥 / 密钥轮换 / 加密未加密混排 /
//    IV 指定与媒体序号 / 相对地址 / SAMPLE-AES 与缺密钥地址仍拒绝
// ② DownloadTask 加密字段（encKeyUrls/encKeyIvs/segKeys/encSeq）持久化
//    与旧数据兼容（v2.1 单密钥字段 → 全分段同钥匙；v2.1 之前 → 未加密）
// ③ hlsIvForSeq 媒体序号 IV 推导
//
// 说明：分段解密本体由原生 javax.crypto 完成（aesDecryptSegments），
// 单测环境无 MethodChannel 实现，按既定约定以真机验收（见交付报告「未自动化项」）。
import 'package:flutter_test/flutter_test.dart';

import 'package:dianying_shijie/download_service.dart';

const _base = 'https://example.com/hls/index.m3u8';

String _playlist({String? keyLine, String? seqLine, List<String> extra = const []}) =>
    [
      '#EXTM3U',
      '#EXT-X-VERSION:3',
      ?seqLine,
      '#EXT-X-TARGETDURATION:10',
      ...extra,
      ?keyLine,
      '#EXTINF:10.0,',
      'seg0.ts',
      '#EXTINF:10.0,',
      'seg1.ts',
      '#EXT-X-ENDLIST',
    ].join('\n');

void main() {
  group('HlsKeyPlan.parse（v2.1.1 按分段多密钥）', () {
    test('未加密清单（无 KEY 标签）→ 无钥匙、分段全 -1', () {
      final r = HlsKeyPlan.parse(_playlist(), Uri.parse(_base));
      expect(r.hasEncryption, isFalse);
      expect(r.keys, isEmpty);
      expect(r.segKeyIdx, [-1, -1]);
    });

    test('只有 METHOD=NONE 的 KEY 标签 → 仍视为未加密', () {
      final r = HlsKeyPlan.parse(
          _playlist(keyLine: '#EXT-X-KEY:METHOD=NONE'), Uri.parse(_base));
      expect(r.hasEncryption, isFalse);
    });

    test('AES-128 + URI + IV → 单钥匙、两段共用、IV 小写化', () {
      final r = HlsKeyPlan.parse(
        _playlist(
            keyLine:
                '#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0X9c7db8778570d05c3177c349fd9236aa'),
        Uri.parse(_base),
      );
      expect(r.hasEncryption, isTrue);
      expect(r.keys.length, 1);
      expect(r.keys.first.url, 'https://example.com/hls/key.bin'); // 相对地址按清单地址解析
      expect(r.keys.first.ivHex, '9c7db8778570d05c3177c349fd9236aa'); // 去前缀 + 小写
      expect(r.segKeyIdx, [0, 0]);
      expect(r.seqBase, 0);
    });

    test('AES-128 无 IV + MEDIA-SEQUENCE → ivHex 为空、seqBase 取清单值', () {
      final r = HlsKeyPlan.parse(
        _playlist(
          keyLine: '#EXT-X-KEY:METHOD=AES-128,URI="https://k.example.com/k"',
          seqLine: '#EXT-X-MEDIA-SEQUENCE:7',
        ),
        Uri.parse(_base),
      );
      expect(r.keys.first.ivHex, '');
      expect(r.seqBase, 7);
    });

    test('v2.1.1 核心场景：密钥轮换（分段间换钥匙）→ 两把钥匙、按下标分配', () {
      final text = [
        '#EXTM3U',
        '#EXT-X-KEY:METHOD=AES-128,URI="k1.bin"',
        '#EXTINF:10.0,',
        'a.ts',
        '#EXT-X-KEY:METHOD=AES-128,URI="https://other.example.com/k2.bin"',
        '#EXTINF:10.0,',
        'b.ts',
        '#EXT-X-KEY:METHOD=AES-128,URI="k1.bin"',
        '#EXTINF:10.0,',
        'c.ts',
      ].join('\n');
      final r = HlsKeyPlan.parse(text, Uri.parse(_base));
      expect(r.hasEncryption, isTrue);
      expect(r.keys.length, 2); // k1 重复出现 → 去重后 2 把
      expect(r.keys[0].url, 'https://example.com/hls/k1.bin');
      expect(r.keys[1].url, 'https://other.example.com/k2.bin');
      expect(r.segKeyIdx, [0, 1, 0]);
    });

    test('v2.1.1 核心场景：加密与未加密分段混排 → 未加密段 -1', () {
      final text = [
        '#EXTM3U',
        '#EXT-X-KEY:METHOD=AES-128,URI="k.bin",IV=0x00000000000000000000000000000001',
        '#EXTINF:10.0,',
        'a.ts',
        '#EXT-X-KEY:METHOD=NONE',
        '#EXTINF:10.0,',
        'b.ts',
      ].join('\n');
      final r = HlsKeyPlan.parse(text, Uri.parse(_base));
      expect(r.keys.length, 1);
      expect(r.segKeyIdx, [0, -1]);
    });

    test('SAMPLE-AES → 抛「不支持」', () {
      expect(
        () => HlsKeyPlan.parse(
            _playlist(keyLine: '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="k.bin"'),
            Uri.parse(_base)),
        throwsA(isA<String>()),
      );
    });

    test('AES-128 未给密钥地址 → 抛「不支持」', () {
      expect(
        () => HlsKeyPlan.parse(
            _playlist(keyLine: '#EXT-X-KEY:METHOD=AES-128'), Uri.parse(_base)),
        throwsA(isA<String>()),
      );
    });
  });

  group('hlsIvForSeq（媒体序号 → 16 字符大端 hex）', () {
    test('0 / 7 / 大数 左补零', () {
      expect(hlsIvForSeq(0), '0000000000000000');
      expect(hlsIvForSeq(7), '0000000000000007');
      expect(hlsIvForSeq(0x1234abcd), '000000001234abcd');
    });
  });

  group('DownloadTask 加密字段持久化（v2.1.1）', () {
    DownloadTask mkTask() => DownloadTask(
          id: '1|2|0|0',
          sourceId: 1,
          sourceName: '源',
          vodId: '2',
          movieName: '片',
          groupIndex: 0,
          groupName: '线路',
          epIndex: 0,
          epName: '第1集',
          url: 'https://example.com/a.m3u8',
        );

    test('toJson/fromJson 往返保留多密钥字段', () {
      final t = mkTask()
        ..encKeyUrls = ['https://example.com/k1.bin', 'https://example.com/k2.bin']
        ..encKeyIvs = ['', 'aabbccdd000000000000000000000001']
        ..segKeys = [0, 1, 0, -1]
        ..encSeq = 12;
      final back = DownloadTask.fromJson(t.toJson());
      expect(back.encKeyUrls, t.encKeyUrls);
      expect(back.encKeyIvs, t.encKeyIvs);
      expect(back.segKeys, t.segKeys);
      expect(back.encSeq, 12);
      expect(back.hasEncryption, isTrue);
    });

    test('v2.1 旧数据（单密钥字段）→ 自动转为全分段同钥匙', () {
      final back = DownloadTask.fromJson({
        'id': '1|2|0|0',
        'movieName': '片',
        'epIndex': 0,
        'url': 'https://example.com/a.m3u8',
        'segments': ['https://s/1.ts', 'https://s/2.ts', 'https://s/3.ts'],
        'encKeyUrl': 'https://example.com/key.bin',
        'encIvHex': '9c7db8778570d05c3177c349fd9236aa',
        'encSeq': 12,
      });
      expect(back.encKeyUrls, ['https://example.com/key.bin']);
      expect(back.encKeyIvs, ['9c7db8778570d05c3177c349fd9236aa']);
      expect(back.segKeys, [0, 0, 0]); // 与分段数对齐
      expect(back.hasEncryption, isTrue);
    });

    test('v2.1 之前的数据（无加密字段）→ 默认未加密', () {
      final back = DownloadTask.fromJson({
        'id': '1|2|0|0',
        'movieName': '片',
        'epIndex': 0,
        'url': 'https://example.com/a.m3u8',
      });
      expect(back.encKeyUrls, isEmpty);
      expect(back.segKeys, isEmpty);
      expect(back.hasEncryption, isFalse);
    });
  });
}
