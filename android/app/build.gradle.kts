import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// v2.2.5/v2.2.6 修复版：固定 release 签名，读取 android/key.properties（与音乐软件同一套做法）。
// ⚠️ 换电脑打包只要带上 keystore/dysj-release.jks + key.properties，签名就一致，老用户可直接覆盖安装。
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) load(FileInputStream(f))
}

android {
    namespace = "com.dianying.dianying_shijie"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // v2.2.7 瘦身：`defaultConfig.ndk.abiFilters` 只作用于 NDK 自编译产物，
    // 不会过滤以 jar 形式预置的 .so（media_kit 的 libmpv 就是 jar 塞进来的），
    // 必须在打包阶段显式排除，否则 x86_64 的 15MB libmpv 会一起进包。
    packaging {
        jniLibs {
            // v2.2.9 瘦身：只留 arm64-v8a。media_kit / ffmpeg 的 .so 是以 AAR/JAR
            // 形式预置的，`defaultConfig.ndk.abiFilters` 管不到，必须在打包阶段
            // 显式排除 32 位（armeabi-v7a）与模拟器（x86/x86_64）目录。
            excludes += listOf("lib/armeabi-v7a/**", "lib/x86_64/**", "lib/x86/**")
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.dianying.dianying_shijie"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24  // Android 7.0
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // v2.2.9 瘦身：只保留 arm64-v8a。
        // media_kit（libmpv）+ ffmpeg 每个 ABI 的 .so 都有十几 MB；用户明确
        // 「可以不考虑老版本手机，体积越小越好」，故不再打 32 位 armeabi-v7a。
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    signingConfigs {
        create("release") {
            if (keystoreProperties.isNotEmpty()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                // storeFile 相对 android/ 解析（key.properties 在 android/ 下）
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // v2.2.5/v2.2.6 修复版起用固定 release 签名（dysj-release.jks）。
            // 老版本（原 debug 签名）升上来需卸载重装一次（一次性代价）；修复版 2.2.5/2.2.6 之间同签名可平滑覆盖。
            // v2.2.7 修复：R8 会把 kotlin.coroutines.Continuation 混淆成 Lrd;，
            // 而 shared_preferences_android 2.5.0 改为走 JNI 按原始签名反射调用，
            // 结果启动即 PlatformException: NoSuchMethodError ...getAll(...Continuation;)。
            // 个人版优先可用性，release 关闭 R8/资源压缩（体积约 +20MB）。
            isMinifyEnabled = false
            isShrinkResources = false
            signingConfig = if (keystoreProperties.isNotEmpty())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
