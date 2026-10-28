import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'api.dart';
import 'download_service.dart';
import 'live_source_health.dart';
import 'local_proxy.dart';
import 'models.dart';
import 'network_signature.dart';
import 'pages/download_page.dart';
import 'pages/home_page.dart';
import 'pages/latest_page.dart';
import 'pages/live_page.dart';
import 'pages/mine_page.dart';
import 'pages/player_page.dart';
import 'store.dart';
import 'theme.dart';
import 'update_service.dart';
import 'logo_cache.dart';
import 'update_sheet.dart';
import 'vod_source_health.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // v2.2.7 修复（直播无声）：media_kit（libmpv 软解）必须在创建 Player 之前初始化。
  // 这批 IPTV 源音频是 MP2，ExoPlayer 解不了；libmpv 自带 FFmpeg，MP2/AC3/DTS 都能出声。
  MediaKit.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // v1.2.0 图片修复①：限制单主机并发连接数，避免 30+ 并发请求把图片床打挂
  HttpOverrides.global = _LimitedHttpOverrides();
  // v2.2.0：启动本地「清单净化」代理，在线播放先经它删掉 HLS 广告分片。
  // 失败不影响启动 —— 代理不可用时播放页会退回直连原地址。
  try {
    await AdFilterProxy.instance.start();
  } catch (_) {}
  // v2.2.7 优化：电视台台标本地缓存目录（进直播页前就建好）
  try {
    await LogoCache.init();
  } catch (_) {}
  // 源健康度记忆：失败过的直播线路 / 点播片源排在后面。
  // 两个 Key 互不影响，并行读取；读盘失败不阻塞启动。
  try {
    await Future.wait([
      LiveSourceHealth.load(),
      VodSourceHealth.load(),
    ]).timeout(const Duration(seconds: 2));
  } catch (_) {}
  // 先把界面画出来，数据在首页后台加载 —— 避免 splash 永久卡死
  runApp(const MovieApp());
}

class _LimitedHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    // v1.9.9（代码审查 3.1）：移除全局 HTTPS 证书放行回调（此前无条件接受
    // 任意证书）。片源/播放地址/图片请求都可能被中间人伪造，现恢复系统证书
    // 校验；确有个别图片床证书不规范时，后续在此加「明确的域名白名单」逐域
    // 放行（核对 host 后返回，经实测确认域名再加，不全局放行）。
    // 风险范围说明：证书不合规的站点其请求会直接失败，由上层重试/换线路兜底。
    return super.createHttpClient(context)
      ..maxConnectionsPerHost = 6
      ..connectionTimeout = const Duration(seconds: 15);
  }
}

/// 首页启动加载器：并行初始化本地存储与片源，均带超时与容错。
/// 初始化成功后自动测速，选出最快片源作为默认（用户手动选过则尊重用户选择）。
Future<String?> bootstrap({void Function(String)? onProgress}) async {
  String? err;
  final results = await Future.wait<String?>([
    AppStore.instance
        .init()
        .timeout(const Duration(seconds: 8))
        .then<String?>((_) => null)
        .catchError((Object e) => '存储初始化失败: $e'),
    MacApi.instance
        .loadSources()
        .timeout(const Duration(seconds: 10))
        .then<String?>((_) => null)
        .catchError((Object e) => '片源加载失败: $e'),
    // v1.6.0：加载下载任务，中断的任务自动续传
    DownloadService.instance
        .init()
        .timeout(const Duration(seconds: 5))
        .then<String?>((_) => null)
        .catchError((Object e) => '下载任务加载失败: $e'),
  ]);
  for (final r in results) {
    if (r != null) err = r;
  }
  // v2.2.4：先同步「片源管理」里停用的片源 —— 加载 / 检索 / 换源统一只看已启用源
  MacApi.instance.setDisabledSources(AppStore.instance.disabledSourceIds);
  if (err == null && MacApi.instance.sources.isNotEmpty) {
    final store = AppStore.instance;
    final now = DateTime.now();
    final last = store.sourceLastTest;
    final lastAt =
        last > 0 ? DateTime.fromMillisecondsSinceEpoch(last) : null;
    // 本地时区的“同一天”：跨天即视为当天第一次打开
    final sameDay = lastAt != null &&
        lastAt.year == now.year &&
        lastAt.month == now.month &&
        lastAt.day == now.day;
    // 与上次测速时的网络指纹比较；旧版本没有指纹（空串）时补测一次
    final sig = await currentNetworkSignature();
    final netChanged = sig.isNotEmpty && sig != store.sourceLastTestNetwork;
    // 需求：每天第一次打开测速；换网后第一次打开也测速。其余启动直接用缓存。
    final needTest = last == 0 || !sameDay || netChanged;

    var lat = store.sourceLatency;
    if (needTest) {
      onProgress?.call('正在测速，为你挑选最快片源…');
      try {
        // v2.2.1：测速预算 15s → 9s。测速本身已改为「单源 5s 超时 + 并发 20」，
        // 并在探测时顺便把分类树写进分类缓存（首页因此少一轮请求）。
        // v2.2.4：只测已启用片源（停用源不必再花时间）。
        final fresh = await MacApi.instance
            .benchmarkSources(activeOnly: true)
            .timeout(const Duration(seconds: 9));
        if (fresh.isNotEmpty) {
          lat = fresh;
          store.sourceLatency = fresh;
          store.sourceLastTest = now.millisecondsSinceEpoch;
          store.sourceLastTestNetwork = sig;
          // 失败源也落盘，片源管理页可直接显示“失败”，无需重测
          final active = MacApi.instance.activeSources.map((s) => s.id).toSet();
          store.sourceFail =
              active.where((id) => !fresh.containsKey(id)).toList();
        }
      } catch (_) {
        /* 测速失败不影响使用，下次启动会重试 */
      }
    }

    // 用户手选过片源时只更新延迟数据，不覆盖他的选择
    if (!store.manualSource && lat.isNotEmpty) {
      final active = MacApi.instance.activeSources.map((s) => s.id).toSet();
      final usable = lat.entries.where((e) => active.contains(e.key));
      if (usable.isNotEmpty) {
        store.fastSourceId =
            usable.reduce((a, b) => a.value <= b.value ? a : b).key;
      }
    }
  }
  return err;
}

/// v1.2.0：主题外观跟随设置页切换（浅色 / 深色 / 跟随系统），即时生效
class MovieApp extends StatefulWidget {
  const MovieApp({super.key});

  @override
  State<MovieApp> createState() => _MovieAppState();
}

class _MovieAppState extends State<MovieApp> {
  @override
  void initState() {
    super.initState();
    AppStore.instance.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    AppStore.instance.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final mode = switch (AppStore.instance.themeModeIndex) {
      1 => ThemeMode.light,
      2 => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    return MaterialApp(
      title: '电影世界',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: mode,
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  bool _booting = true;
  String? _bootError;
  String _bootTip = '正在加载…';

  // v1.9.5 本地视频播放：文件管理器选视频 →「打开方式」→ 电影世界（靳老师）
  static const _lvChannel = MethodChannel('movie_world/localvideo');
  String? _pendingLocal;

  // v2.0 通知点击跳转：打开 App 并直达「下载管理」页（冷/热启动都生效）
  static const _navChannel = MethodChannel('movie_world/nav');
  String? _pendingRoute;

  @override
  void initState() {
    super.initState();
    _setupLocalVideo();
    _setupNav();
    bootstrap(
      onProgress: (t) {
        if (mounted) setState(() => _bootTip = t);
      },
    ).then((err) {
      if (!mounted) return;
      setState(() {
        _booting = false;
        _bootError = err;
      });
      _maybeOpenPendingLocal();
      _maybeOpenPendingRoute();
      _notifyRestored();
      _checkUpdateSilently();
    });
  }

  /// v2.2.5 启动静默检查更新：拉不到 / 已最新 / 已点过「稍后」都完全不出声；
  /// 发现新版才弹更新卡片。
  Future<void> _checkUpdateSilently() async {
    final (state, info) = await UpdateService.instance.check(silent: true);
    if (state != CheckResult.available || info == null || !mounted) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF14171C)
          : Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => UpdateSheet(info: info),
    );
  }

  void _reboot() {
    setState(() => _booting = true);
    bootstrap(
      onProgress: (t) {
        if (mounted) setState(() => _bootTip = t);
      },
    ).then((err) {
      if (!mounted) return;
      setState(() {
        _booting = false;
        _bootError = err;
      });
      _maybeOpenPendingLocal();
      _maybeOpenPendingRoute();
      _notifyRestored();
    });
  }

  /// v2.0：与原生对接 —— 冷启动取 pending 路由；热启动由原生推 onRoute
  Future<void> _setupNav() async {
    _navChannel.setMethodCallHandler((call) async {
      if (call.method == 'onRoute' && call.arguments is String) {
        _handleRoute(call.arguments as String);
      }
    });
    try {
      final r = await _navChannel.invokeMethod<String>('takePendingRoute');
      if (r != null && r.isNotEmpty) {
        if (_booting) {
          _pendingRoute = r;
        } else {
          _handleRoute(r);
        }
      }
    } catch (_) {}
  }

  void _maybeOpenPendingRoute() {
    final r = _pendingRoute;
    _pendingRoute = null;
    if (r == null || r.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _handleRoute(r);
    });
  }

  /// 通知点击 → 切到「我的」并打开下载管理页
  void _handleRoute(String route) {
    if (route != 'download') return;
    if (_booting) {
      _pendingRoute = route;
      return;
    }
    if (!mounted) return;
    setState(() => _index = 3);
    Navigator.of(
      context,
      rootNavigator: true,
    ).push(MaterialPageRoute(builder: (_) => const DownloadPage()));
  }

  /// v1.9.5：与原生对接 —— 冷启动取 pending 地址；热启动由原生推 onLocalVideo
  Future<void> _setupLocalVideo() async {
    _lvChannel.setMethodCallHandler((call) async {
      if (call.method == 'onLocalVideo' && call.arguments is String) {
        final u = call.arguments as String;
        if (_booting) {
          _pendingLocal = u;
        } else {
          _openLocalVideo(u);
        }
      }
    });
    try {
      final p = await _lvChannel.invokeMethod<String>('takeLocalVideo');
      if (p != null && p.isNotEmpty) {
        if (_booting) {
          _pendingLocal = p;
        } else {
          _openLocalVideo(p);
        }
      }
    } catch (_) {}
  }

  void _maybeOpenPendingLocal() {
    final p = _pendingLocal;
    _pendingLocal = null;
    if (p != null && p.isNotEmpty) _openLocalVideo(p);
  }

  /// v1.9.7：启动时自动找回成功后给个提示，让用户知道视频找回来了
  void _notifyRestored() {
    final n = DownloadService.instance.lastRestoreCount;
    if (n <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已自动找回 $n 个已下载视频，在「下载管理」点「离线播放」继续看')),
      );
    });
  }

  void _openLocalVideo(String uri) {
    if (!mounted) return;
    var title = '本地视频';
    final segs = Uri.parse(uri).pathSegments;
    if (segs.isNotEmpty) {
      final raw = segs.last;
      // MediaStore 的 content:// 末段是数字 id，展示不出文件名就用默认标题
      if (!RegExp(r'^\d+$').hasMatch(raw) && raw.contains('.')) {
        title = raw.substring(0, raw.lastIndexOf('.'));
      }
    }
    final src = const MovieSource(
      id: LocalKeys.localSourceId,
      name: '本地',
      url: '',
    );
    final item = VideoItem(
      vodId: LocalKeys.externalVodId(uri),
      name: title,
      sourceId: LocalKeys.localSourceId,
      sourceName: '本地视频',
      typeName: '本地视频',
    );
    final detail = VideoDetail(
      item: item,
      groups: [
        PlayGroup('本地', [Episode(title, uri)]),
      ],
    );
    // v2.2.4：外部本地视频同样按观看历史续播（vodId = external_<uri> 为稳定 Key）
    final h = AppStore.instance.findHistory(item);
    final startSec = h?.positionSec ?? 0;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          source: src,
          detail: detail,
          groupIndex: 0,
          epIndex: 0,
          initialPosition: startSec > 0 ? Duration(seconds: startSec) : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_booting) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.asset(
                  'assets/icon.png',
                  width: 84,
                  height: 84,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 28),
              const SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: 16),
              Text(
                _bootTip,
                style: TextStyle(color: context.tSub, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      body: Column(
        children: [
          if (_bootError != null)
            Material(
              color: context.brandWeak,
              child: SafeArea(
                bottom: false,
                child: ListTile(
                  dense: true,
                  leading: const Icon(
                    Icons.warning_amber_rounded,
                    color: kGold,
                  ),
                  title: Text(
                    _bootError!,
                    style: TextStyle(color: context.tSub, fontSize: 13),
                  ),
                  trailing: TextButton(
                    onPressed: _reboot,
                    child: const Text('重试'),
                  ),
                ),
              ),
            ),
          Expanded(
            child: IndexedStack(
              index: _index,
              // v2.2.7（10-15）：取消「影视点播」导航页 —— 用户反馈影视直播取消，
              //   底部导航回到 首页 / 电视 / 我的 三个 tab。
              // v2.2.7 修复：直播页改成「可见才沉浸」。IndexedStack 里三个页面常驻不销毁，
              //   把当前 tab 传给 LivePage，它才能在切走时把系统状态栏还回去。
              children: [
                const HomePage(),
                LatestPage(active: _index == 1),
                LivePage(active: _index == 2),
                const MinePage(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.whatshot_outlined),
            selectedIcon: Icon(Icons.whatshot),
            label: '最新',
          ),
          NavigationDestination(
            icon: Icon(Icons.tv_outlined),
            selectedIcon: Icon(Icons.tv),
            label: '电视',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_circle_outlined),
            selectedIcon: Icon(Icons.account_circle),
            label: '我的',
          ),
        ],
      ),
    );
  }
}
