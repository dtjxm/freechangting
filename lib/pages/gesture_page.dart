/// 播放手势说明页（v1.4.8）：从「我的」进入的独立二级页面
library;

import 'package:flutter/material.dart';

import '../theme.dart';

class GesturePage extends StatelessWidget {
  const GesturePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('播放手势')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 30),
        children: [
          Container(
            decoration: BoxDecoration(
              color: context.card,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(children: [
              _row(context, Icons.touch_app, '双击屏幕左侧 / 右侧',
                  '快退或快进 10 秒（双击中间：暂停 / 继续）'),
              _divider(context),
              _row(context, Icons.visibility_outlined, '单击屏幕',
                  '显示或隐藏播放控制栏'),
              _divider(context),
              _row(context, Icons.volume_up_outlined, '上下滑动屏幕左侧',
                  '调整音量'),
              _divider(context),
              _row(context, Icons.brightness_6_outlined, '上下滑动屏幕右侧',
                  '调整亮度'),
              _divider(context),
              _row(context, Icons.fast_forward, '按住屏幕左侧',
                  '倍速快退：先 3 倍，持续按住倍速逐级升高（最高 50 倍），松开完成定位'),
              _divider(context),
              _row(context, Icons.fast_rewind, '按住屏幕右侧',
                  '倍速快进：先 3 倍，持续按住倍速逐级升高（最高 50 倍），松开完成定位'),
              _divider(context),
              _row(context, Icons.speed_outlined, '长按屏幕中间',
                  '3 倍速播放（松开恢复正常倍速）'),
            ]),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '提示：以上手势在横屏播放时生效；画面比例与旋转可在播放界面顶部按钮切换。',
              style: TextStyle(fontSize: 12, color: context.tFaint),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, IconData icon, String title, String sub) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: context.brand.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, size: 21, color: context.brand),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: context.tMain)),
                const SizedBox(height: 3),
                Text(sub,
                    style: TextStyle(fontSize: 12.5, color: context.tSub)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Divider(height: 1, color: context.divider),
      );
}
