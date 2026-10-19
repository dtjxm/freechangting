/// 当前网络指纹。
///
/// 用途：启动测速节流 —— 每天第一次打开、或换网后第一次打开才测速。
/// 不引入额外插件：直接读本机网卡名称 + IPv4 地址，Wi-Fi 优先，其次蜂窝。
/// 同一 Wi-Fi 下 DHCP 续租导致 IP 变化时会多测一次，属于可接受的误判。
library;

import 'dart:io';

Future<String> currentNetworkSignature() async {
  try {
    final all = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    bool isWifi(String n) =>
        RegExp(r'^(wlan|ap|eth|en)', caseSensitive: false).hasMatch(n);
    bool isCell(String n) => RegExp(
      r'^(rmnet|ccmni|pdp|v4-|clat)',
      caseSensitive: false,
    ).hasMatch(n);

    var picked = all.where((i) => isWifi(i.name)).toList();
    if (picked.isEmpty) picked = all.where((i) => isCell(i.name)).toList();
    if (picked.isEmpty) picked = all;

    final parts = <String>[];
    for (final i in picked) {
      final ips = i.addresses
          .where((a) => !a.isLoopback && !a.isLinkLocal)
          .map((a) => a.address)
          .toList()
        ..sort();
      if (ips.isNotEmpty) parts.add('${i.name}:${ips.first}');
    }
    parts.sort();
    return parts.join('|');
  } catch (_) {
    return '';
  }
}
