package com.dianying.dianying_shijie

import android.annotation.SuppressLint
import android.app.RecoverableSecurityException
import android.content.ContentValues
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/// v1.6.0 下载存储通道：
/// - saveToMovies：把临时 mp4 写入公共 Movies 目录（Android 10+ 走 MediaStore，
///   7~9 直接写 /storage/emulated/0/Movies 并触发媒体扫描）
/// - deleteSaved：按 content:// URI 或文件路径删除
class MainActivity : FlutterActivity() {
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    // v1.9.5 本地视频播放：文件管理器「打开方式」进入时暂存视频地址（靳老师）
    @Volatile private var pendingLocalVideo: String? = null
    private var localVideoChannel: MethodChannel? = null

    // v2.0 删除链：系统授权弹窗的等待回调（靳老师 2026-09-24）
    companion object {
        private const val REQ_DELETE_AUTH = 9101
    }
    private var pendingDeleteResult: MethodChannel.Result? = null

    // v2.0 通知点击跳转：待处理的页面路由（download = 下载管理页）
    @Volatile private var pendingRoute: String? = null
    private var navChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        handleViewIntent(intent)
        handleRouteIntent(intent)
    }

    /// v2.0 系统「允许删除」授权结果回到这里
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_DELETE_AUTH) {
            val r = pendingDeleteResult
            pendingDeleteResult = null
            r?.success(mapOf("granted" to (resultCode == RESULT_OK)))
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleViewIntent(intent)
        handleRouteIntent(intent)
        // 热启动：App 已在运行，直接把视频地址推给 Flutter
        val v = pendingLocalVideo
        pendingLocalVideo = null // v1.9.6 修复：推送后清空，防 Activity 重建后取到旧地址
        if (v != null) {
            mainHandler.post { localVideoChannel?.invokeMethod("onLocalVideo", v) }
        }
        // v2.0 热启动：通知点击 → 推给 Flutter 跳转下载管理页
        val route = pendingRoute
        if (route != null) {
            pendingRoute = null
            mainHandler.post { navChannel?.invokeMethod("onRoute", route) }
        }
    }

    private fun handleViewIntent(intent: Intent?) {
        if (intent?.action == Intent.ACTION_VIEW && intent.data != null) {
            pendingLocalVideo = intent.data.toString()
        }
    }

    /// v2.0 通知点击进来的意图（extra: open_download）
    private fun handleRouteIntent(intent: Intent?) {
        if (intent?.getBooleanExtra("open_download", false) == true) {
            pendingRoute = "download"
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "movie_world/storage")
            .setMethodCallHandler { call, result ->
                executor.execute {
                    try {
                        when (call.method) {
                            "saveToMovies" -> {
                                val src = File(call.argument<String>("srcPath")!!)
                                val rel = call.argument<String>("relativePath")!!
                                val name = call.argument<String>("displayName")!!
                                val saved = saveToMovies(src, rel, name)
                                mainHandler.post { result.success(saved) }
                            }
                            // v2.0 删除链：返回 {ok, needAuth, uris, path, reason}
                            "deleteSaved" -> {
                                val target = call.argument<String>("target")!!
                                val r = deleteSaved(target)
                                mainHandler.post { result.success(r) }
                            }
                            // v2.0 删除链：目录级清理，返回 {ok, remaining}
                            "deleteMovieFolder" -> {
                                val rel = call.argument<String>("relativePath")!!
                                val r = deleteMovieFolderV2(rel)
                                mainHandler.post { result.success(r) }
                            }
                            // v2.0 删除链：请求系统「允许删除」授权（Android 10+ 强制）
                            "requestDeleteAuth" -> {
                                val raw = call.argument<List<String>>("uris") ?: emptyList()
                                requestDeleteAuth(raw, result)
                            }
                            // v1.9.6 查询系统 SDK 版本（恢复扫描前决定是否请求存储权限）
                            "sdkInt" -> {
                                mainHandler.post { result.success(Build.VERSION.SDK_INT) }
                            }
                            // v1.9.5 扫描已下载视频（恢复到下载列表用）
                            "scanSaved" -> {
                                val list = scanSavedMovies()
                                mainHandler.post { result.success(list) }
                            }
                            // v2.1 AES-128 加密 HLS：逐段解密（原地覆盖），返回 {ok, failed:[序号]}
                            // ivHex 为空时用「媒体序号」当 IV（HLS 标准规定：16 字节大端整数）
                            "aesDecryptSegments" -> {
                                // v2.1.1 按分段多密钥：keyHexes/ivHexes 与分段一一对应（空 key=未加密分段，跳过）
                                val dirPath = call.argument<String>("dir")!!
                                val count = call.argument<Number>("count")!!.toInt()
                                @Suppress("UNCHECKED_CAST")
                                val keyHexes = call.argument<ArrayList<String>>("keyHexes")!!
                                @Suppress("UNCHECKED_CAST")
                                val ivHexes = call.argument<ArrayList<String>>("ivHexes") ?: arrayListOf()
                                val failed = aesDecryptSegments(dirPath, count, keyHexes, ivHexes)
                                mainHandler.post { result.success(mapOf("ok" to failed.isEmpty(), "failed" to failed)) }
                            }
                            else -> mainHandler.post { result.notImplemented() }
                        }
                    } catch (e: Exception) {
                        mainHandler.post { result.error("SAVE_ERROR", e.message, null) }
                    }
                }
            }

        // v1.9.8 前台服务通道：下载期间通知栏常驻，防锁屏/切后台被系统冻结（靳老师 2026-09-23）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "movie_world/fg")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        DownloadForegroundService.start(applicationContext)
                        mainHandler.post { result.success(true) }
                    }
                    "stop" -> {
                        DownloadForegroundService.stop(applicationContext)
                        mainHandler.post { result.success(true) }
                    }
                    "update" -> {
                        DownloadForegroundService.instance
                            ?.updateText(call.argument<String>("text") ?: "正在下载视频…")
                        mainHandler.post { result.success(true) }
                    }
                    // v2.0 下载完成通知（点击进下载管理页）
                    "done" -> {
                        DownloadForegroundService.notifyDone(
                            applicationContext,
                            call.argument<String>("movie") ?: "",
                            call.argument<String>("ep") ?: ""
                        )
                        mainHandler.post { result.success(true) }
                    }
                    else -> mainHandler.post { result.notImplemented() }
                }
            }

        // v1.9.5 本地视频通道：takeLocalVideo 取走暂存地址（冷启动）；onLocalVideo 由原生推送（热启动）
        localVideoChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "movie_world/localvideo")
        localVideoChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeLocalVideo" -> {
                    val v = pendingLocalVideo
                    pendingLocalVideo = null
                    mainHandler.post { result.success(v) }
                }
                else -> mainHandler.post { result.notImplemented() }
            }
        }

        // v2.0 通知点击跳转通道：takePendingRoute 取走冷启动路由；onRoute 由原生推送（热启动）
        navChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "movie_world/nav")
        navChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "takePendingRoute" -> {
                    val r = pendingRoute
                    pendingRoute = null
                    mainHandler.post { result.success(r) }
                }
                else -> mainHandler.post { result.notImplemented() }
            }
        }
    }

    /// v1.9.5 扫描本应用下载目录 Movies/电影世界/ 下全部视频，
    /// 返回 [{movie: 片名, name: 文件名, uri: content:// 或绝对路径}]
    @SuppressLint("Range")
    private fun scanSavedMovies(): List<Map<String, String>> {
        val out = mutableListOf<Map<String, String>>()
        try {
            val resolver = applicationContext.contentResolver
            // v1.9.6 修复：getContentUri(String) 为 API 29+ 方法，Android 7~9 上会
            // NoSuchMethodError 崩溃，改用版本分支（靳老师代码审查 2026-09-22）
            val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            else
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            val isQ = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
            val proj = if (isQ)
                arrayOf(MediaStore.Video.Media._ID, MediaStore.Video.Media.DISPLAY_NAME, MediaStore.Video.Media.RELATIVE_PATH)
            else
                arrayOf(MediaStore.Video.Media._ID, MediaStore.Video.Media.DISPLAY_NAME, MediaStore.Video.Media.DATA)
            // 行收集器：把一条媒体记录解析成 {movie, name, uri}
            fun collect(sel: String?, args: Array<String>?) {
                resolver.query(collection, proj, sel, args, null)?.use { c ->
                    while (c.moveToNext()) {
                        try {
                            val uri = Uri.withAppendedPath(collection, c.getString(0))
                            val name = c.getString(1) ?: continue
                            val path = c.getString(2) ?: continue
                            val marker = "电影世界/"
                            val idx = path.indexOf(marker)
                            if (idx < 0) continue
                            val rel = path.substring(idx + marker.length).trimEnd('/')
                            if (rel.isEmpty()) continue
                            // v1.9.7：Android 7~9 的 DATA 带文件名，若「片名段」就是文件名本身
                            // → 散落在目录根的文件，不是 片名/集名 结构，跳过
                            if (rel == name || "$rel.mp4" == name) continue
                            val movie = rel.split("/").firstOrNull()?.trim() ?: continue
                            if (movie.isEmpty()) continue
                            out.add(mapOf("movie" to movie, "name" to name, "uri" to uri.toString()))
                        } catch (_: Throwable) {}
                    }
                }
            }
            val sel = if (isQ)
                "${MediaStore.Video.Media.RELATIVE_PATH} LIKE ?"
            else
                "${MediaStore.Video.Media.DATA} LIKE ?"
            val arg = if (isQ) "Movies/电影世界/%" else "%Movies/电影世界/%"
            collect(sel, arrayOf(arg))
            // v1.9.7 兜底：部分机型 MediaStore 对含中文的 LIKE 查询可能返回空，
            // 精确查询无结果时全量拉取再本地过滤（仅在找不到时触发一次）
            if (out.isEmpty()) collect(null, null)
        } catch (_: Throwable) {}
        return out
    }

    // ---------- v2.1 AES-128 加密 HLS 解密（靳老师 2026-09-24：加密视频改为可下载）----------

    /// 把 <dir>/seg_00000.ts .. seg_<count-1>.ts 逐段做 AES-128-CBC + PKCS7 解密（原地覆盖）。
    /// 返回解密失败的分段序号列表（空列表=全部成功）。
    // v2.1.1 按分段多密钥：keyHexes[i]/ivHexes[i] 对应 seg_0000i；keyHex 为空 = 未加密分段，原样保留
    private fun aesDecryptSegments(
        dirPath: String,
        count: Int,
        keyHexes: List<String>,
        ivHexes: List<String>
    ): List<Int> {
        val failed = mutableListOf<Int>()
        for (i in 0 until count) {
            try {
                val keyHex = if (i < keyHexes.size) keyHexes[i] else ""
                if (keyHex.isEmpty()) continue // 未加密分段，不动文件
                val key = hexToBytes(keyHex)
                if (key.size != 16) {
                    failed.add(i)
                    continue
                }
                val f = File(dirPath, String.format("seg_%05d.ts", i))
                if (!f.exists() || f.length() == 0L) {
                    failed.add(i)
                    continue
                }
                // IV 由 Dart 侧算好传入（清单指定 IV 或分段媒体序号大端）；空视为错误
                val ivHex = if (i < ivHexes.size) ivHexes[i] else ""
                if (ivHex.isEmpty()) {
                    failed.add(i)
                    continue
                }
                val iv = hexToBytes(ivHex)
                val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
                cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
                val plain = cipher.doFinal(f.readBytes())
                f.writeBytes(plain)
            } catch (_: Throwable) {
                failed.add(i)
            }
        }
        return failed
    }

    private fun hexToBytes(hex: String): ByteArray {
        val h = hex.trim().removePrefix("0x").removePrefix("0X")
        val out = ByteArray(h.length / 2)
        for (i in out.indices) {
            out[i] = h.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }
        return out
    }

    /// 保存到 Movies/<relativePath>/<displayName>，返回 content:// URI 或文件绝对路径
    @SuppressLint("Range")
    private fun saveToMovies(src: File, rel: String, name: String): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = applicationContext.contentResolver
            val collection =
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val relPath = "Movies/$rel"
            // 同名旧条目（本应用创建）→ 复用更新，避免重复堆积
            var oldUri: Uri? = null
            resolver.query(
                collection,
                arrayOf(MediaStore.Video.Media._ID),
                "${MediaStore.Video.Media.RELATIVE_PATH}=? AND ${MediaStore.Video.Media.DISPLAY_NAME}=?",
                arrayOf("$relPath/", name),
                null
            )?.use { c ->
                if (c.moveToFirst()) {
                    oldUri = Uri.withAppendedPath(collection, c.getString(0))
                }
            }

            val uri = oldUri ?: run {
                val values = ContentValues().apply {
                    put(MediaStore.Video.Media.DISPLAY_NAME, name)
                    put(MediaStore.Video.Media.RELATIVE_PATH, relPath)
                    put(MediaStore.Video.Media.IS_PENDING, 1)
                }
                resolver.insert(collection, values)!!
            }
            resolver.openOutputStream(uri)!!.use { os ->
                src.inputStream().use { it.copyTo(os) }
            }
            if (oldUri == null) {
                val done = ContentValues().apply {
                    put(MediaStore.Video.Media.IS_PENDING, 0)
                }
                resolver.update(uri, done, null, null)
            }
            uri.toString()
        } else {
            val dir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES),
                rel
            )
            dir.mkdirs()
            val dst = File(dir, name)
            src.copyTo(dst, overwrite = true)
            MediaScannerConnection.scanFile(
                applicationContext, arrayOf(dst.absolutePath),
                arrayOf("video/mp4"), null
            )
            dst.absolutePath
        }
    }

    /// v2.0 删除 Movies/<rel> 下本应用保存的全部视频（删除链 v2，靳老师 2026-09-24）：
    /// ① 媒体库按**前缀**匹配（兼容 RELATIVE_PATH 带/不带尾斜杠的两类机型，
    ///    旧版用 `= "Movies/<rel>/"` 精确匹配，部分机型无尾斜杠导致一条都匹配不上）；
    /// ② 逐条删除，失败按 DISPLAY_NAME 用 File API 兜底；
    /// ③ 目录级**递归**删除（含残留子目录），旧版只删顶层 isFile；
    /// ④ 删完真的去核对（媒体库残留 + 目录残留），把残余项回报给 Flutter，不再「假成功」。
    /// 返回 {ok: Boolean, remaining: List<String>}
    @SuppressLint("Range")
    private fun deleteMovieFolderV2(rel: String): Map<String, Any> {
        val remaining = mutableListOf<String>()
        try {
            val moviesDir =
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES)
            val dir = File(moviesDir, rel)
            val isQ = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
            if (isQ) {
                val resolver = applicationContext.contentResolver
                val collection =
                    MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                val rows = mutableListOf<Pair<String, String>>()
                resolver.query(
                    collection,
                    arrayOf(MediaStore.Video.Media._ID, MediaStore.Video.Media.DISPLAY_NAME),
                    "${MediaStore.Video.Media.RELATIVE_PATH} LIKE ?",
                    arrayOf("Movies/$rel/%"),
                    null
                )?.use { c ->
                    while (c.moveToNext()) {
                        val id = c.getString(0) ?: continue
                        rows.add(id to (c.getString(1) ?: ""))
                    }
                }
                for ((id, name) in rows) {
                    val uri = Uri.withAppendedPath(collection, id)
                    var deleted = try {
                        resolver.delete(uri, null, null) > 0
                    } catch (_: Exception) { false }
                    if (!deleted && name.isNotEmpty()) {
                        try { deleted = File(dir, name).delete() } catch (_: Exception) {}
                    }
                }
            }
            // 递归删除目录（含残留子目录），旧版只删顶层文件 → 目录删不掉却判「已删净」
            if (dir.isDirectory) {
                try {
                    dir.walkBottomUp().forEach { f ->
                        if (f != dir) {
                            try { f.delete() } catch (_: Exception) {}
                        }
                    }
                    dir.delete()
                } catch (_: Exception) {}
            }
            // 核对①：媒体库是否还有残留条目
            if (isQ) {
                val resolver = applicationContext.contentResolver
                val collection =
                    MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                resolver.query(
                    collection,
                    arrayOf(MediaStore.Video.Media.DISPLAY_NAME),
                    "${MediaStore.Video.Media.RELATIVE_PATH} LIKE ?",
                    arrayOf("Movies/$rel/%"),
                    null
                )?.use { c ->
                    while (c.moveToNext()) {
                        val n = c.getString(0)
                        remaining.add(
                            if (n.isNullOrEmpty()) "Movies/$rel/（未知文件）"
                            else "Movies/$rel/$n"
                        )
                    }
                }
            }
            // 核对②：目录是否还在（空目录也算残留）
            if (dir.exists()) {
                val left = dir.listFiles()
                if (left.isNullOrEmpty()) {
                    remaining.add("${dir.absolutePath}（空文件夹未删掉）")
                } else {
                    left.forEach { remaining.add(it.absolutePath) }
                }
            }
        } catch (_: Throwable) {}
        return mapOf("ok" to remaining.isEmpty(), "remaining" to remaining)
    }

    /// v2.0 删除已保存的视频（删除链 v2，靳老师 2026-09-24）
    /// ① 媒体库直删；
    /// ② 抛 SecurityException / RecoverableSecurityException 时判定「需要系统授权」
    ///    —— 安卓 10+ 删「非本应用归属」的媒体必须先经用户同意，旧版把异常吞掉
    ///    直接静默失败，这就是「有些电影删不掉」的主因。这里把 URI 回报给 Flutter，
    ///    由 requestDeleteAuth 弹系统「允许删除」框，授权后重试；
    /// ③ 其他失败按 DISPLAY_NAME 反查文件兜底删除 + 通知媒体库刷新。
    /// 返回 {ok, needAuth, uris, path, reason}
    @SuppressLint("Range")
    private fun deleteSaved(target: String): Map<String, Any> {
        val res = mutableMapOf<String, Any>()
        res["ok"] = false
        res["needAuth"] = false
        res["uris"] = emptyList<String>()
        res["path"] = ""
        res["reason"] = ""
        try {
            if (target.startsWith("content:")) {
                val uri = Uri.parse(target)
                res["path"] = displayPathOf(uri)
                var ok = false
                var needAuth = false
                var reason = ""
                try {
                    ok = applicationContext.contentResolver.delete(uri, null, null) > 0
                } catch (e: RecoverableSecurityException) {
                    needAuth = true // 安卓 10/11 删他人媒体：需用户授权
                    reason = "系统要求先授权才能删除"
                } catch (e: SecurityException) {
                    needAuth = true
                    reason = "系统要求先授权才能删除"
                } catch (e: Exception) {
                    reason = e.message ?: "删除失败"
                }
                // File 兜底：本应用贡献的文件在 Movies/电影世界/ 下，可直接删
                if (!ok && !needAuth) {
                    val f = findFileByUri(uri)
                    if (f != null && f.exists()) {
                        ok = try { f.delete() } catch (_: Exception) { false }
                        if (ok) refreshMedia(f)
                    }
                }
                res["ok"] = ok
                if (!ok && needAuth) {
                    res["needAuth"] = true
                    res["uris"] = listOf(target)
                }
                res["reason"] = if (ok) "" else reason.ifEmpty { "视频文件删除失败" }
            } else {
                val f = File(target)
                res["path"] = target
                val ok = try {
                    if (f.exists()) f.delete() else true
                } catch (_: Exception) { false }
                if (ok) refreshMedia(f)
                res["ok"] = ok
                res["reason"] = if (ok) "" else "文件不存在或无权删除"
            }
        } catch (e: Throwable) {
            res["reason"] = e.message ?: "删除异常"
        }
        return res
    }

    /// v2.0 按 content URI 反查「电影世界」目录下的同名文件（File 兜底用）
    @SuppressLint("Range")
    private fun findFileByUri(uri: Uri): File? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return try {
            val collection =
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val id = uri.lastPathSegment ?: return null
            var name: String? = null
            applicationContext.contentResolver.query(
                collection,
                arrayOf(MediaStore.Video.Media.DISPLAY_NAME),
                "${MediaStore.Video.Media._ID}=?",
                arrayOf(id),
                null
            )?.use { c -> if (c.moveToFirst()) name = c.getString(0) }
            val n = name ?: return null
            val root = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES),
                "电影世界"
            )
            if (!root.isDirectory) return null
            root.walkTopDown().firstOrNull { it.isFile && it.name == n }
        } catch (_: Throwable) {
            null
        }
    }

    /// v2.0 把 content URI 转成人类可读路径（Movies/电影世界/片名/第X集.mp4），
    /// 删除失败时列表展示 + 一键复制用
    @SuppressLint("Range")
    private fun displayPathOf(uri: Uri): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return ""
        return try {
            val collection =
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val id = uri.lastPathSegment ?: return ""
            var rel: String? = null
            var name: String? = null
            applicationContext.contentResolver.query(
                collection,
                arrayOf(
                    MediaStore.Video.Media.RELATIVE_PATH,
                    MediaStore.Video.Media.DISPLAY_NAME
                ),
                "${MediaStore.Video.Media._ID}=?",
                arrayOf(id),
                null
            )?.use { c ->
                if (c.moveToFirst()) {
                    rel = c.getString(0)
                    name = c.getString(1)
                }
            }
            val r = (rel ?: "").trimEnd('/')
            val n = name ?: return ""
            if (r.isEmpty()) n else "$r/$n"
        } catch (_: Throwable) {
            ""
        }
    }

    /// v2.0 删除后通知媒体库刷新（文件已不存在 → 系统会清掉对应条目）
    private fun refreshMedia(f: File) {
        try {
            MediaScannerConnection.scanFile(
                applicationContext, arrayOf(f.absolutePath), arrayOf("video/mp4"), null
            )
        } catch (_: Throwable) {}
    }

    /// v2.0 请求系统「允许删除」授权：
    /// 安卓 11+ 用 MediaStore.createDeleteRequest（可一次授权多个 URI）；
    /// 安卓 10 用 RecoverableSecurityException 的 userAction。
    /// 结果经 onActivityResult(REQ_DELETE_AUTH) 回传 {granted: Boolean}
    private fun requestDeleteAuth(raw: List<String>, result: MethodChannel.Result) {
        val uris = raw.mapNotNull { runCatching { Uri.parse(it) }.getOrNull() }
        if (uris.isEmpty()) {
            mainHandler.post { result.success(mapOf("granted" to false)) }
            return
        }
        mainHandler.post {
            try {
                pendingDeleteResult = result
                val sender = when {
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
                        MediaStore.createDeleteRequest(
                            applicationContext.contentResolver, uris
                        ).intentSender
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ->
                        recoverableSender(uris.first())
                    else -> null
                }
                if (sender == null) {
                    pendingDeleteResult = null
                    result.success(
                        mapOf("granted" to false, "reason" to "该系统版本不支持删除授权")
                    )
                } else {
                    startIntentSenderForResult(sender, REQ_DELETE_AUTH, null, 0, 0, 0)
                }
            } catch (e: Exception) {
                pendingDeleteResult = null
                result.success(
                    mapOf("granted" to false, "reason" to (e.message ?: "授权弹窗打开失败"))
                )
            }
        }
    }

    /// 安卓 10：试删一次拿到 RecoverableSecurityException，取其 userAction 的 IntentSender
    private fun recoverableSender(uri: Uri): android.content.IntentSender? {
        return try {
            applicationContext.contentResolver.delete(uri, null, null)
            null // 居然直接删成功了 → 无需授权
        } catch (e: RecoverableSecurityException) {
            e.userAction.actionIntent.intentSender
        } catch (_: Exception) {
            null
        }
    }
}
