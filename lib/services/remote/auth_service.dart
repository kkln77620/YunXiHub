import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/services/remote/history_sync_service.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// YunXiHub 账号服务（邮箱验证码登录体系）
///
/// 与服务器 /api/auth/* 接口对接：
/// - sendCode   发送验证码（60秒限流）
/// - register   注册（邮箱+验证码+密码）→ 返回 token
/// - login      登录（邮箱+密码）→ 返回新 token
/// - reset      忘记密码（邮箱+验证码+新密码）
/// - me         查询当前用户（赞助用户状态）
///
/// 登录/注册成功后 token 与用户信息持久化到 GStorage，
/// 远程解析请求会自动携带 Authorization: Bearer <token>。
class AuthService {
  AuthService._();

  static final AuthService instance = AuthService._();

  /// 服务器地址（与远程解析共用同一个配置）
  String get _baseUrl {
    var base =
        GStorage.getSetting(SettingsKeys.remoteResolverBaseUrl).trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  bool get isLoggedIn {
    return GStorage.getSetting(SettingsKeys.authToken).trim().isNotEmpty;
  }

  String get email => GStorage.getSetting(SettingsKeys.authEmail);
  int get vipLevel => GStorage.getSetting(SettingsKeys.authVipLevel);
  String get vipExpire => GStorage.getSetting(SettingsKeys.authVipExpire);

  /// 发送验证码：purpose = register（注册）| reset（重置密码）
  Future<String> sendCode(String email, {String purpose = 'register'}) async {
    final data = await _post('/api/auth/send_code', {
      'email': email.trim(),
      'purpose': purpose,
    });
    return data['msg']?.toString() ?? '验证码已发送';
  }

  /// 注册：成功返回提示信息，失败抛 [AuthException]
  Future<void> register({
    required String email,
    required String code,
    required String password,
  }) async {
    final data = await _post('/api/auth/register', {
      'email': email.trim(),
      'code': code.trim(),
      'password': password,
    });
    await _applyAuth(data);
  }

  /// 登录：成功返回提示信息，失败抛 [AuthException]
  Future<void> login({
    required String email,
    required String password,
  }) async {
    final data = await _post('/api/auth/login', {
      'email': email.trim(),
      'password': password,
    });
    await _applyAuth(data);
  }

  /// 忘记密码：验证码重置密码
  Future<void> reset({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    await _post('/api/auth/reset', {
      'email': email.trim(),
      'code': code.trim(),
      'new_password': newPassword,
    });
  }

  /// 刷新当前用户信息（VIP 状态），失败静默
  Future<void> refreshMe() async {
    final token = GStorage.getSetting(SettingsKeys.authToken).trim();
    if (token.isEmpty) return;
    try {
      final response = await _dio.get<dynamic>(
        '$_baseUrl/api/auth/me',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final raw = response.data;
      final map = raw is String
          ? (jsonDecode(raw) as Map).cast<String, dynamic>()
          : (raw as Map).cast<String, dynamic>();
      if (map['code'] == 0 && map['data'] is Map) {
        final user = map['data'] as Map;
        await GStorage.putSetting(
          SettingsKeys.authVipLevel,
          (user['vip_level'] as num?)?.toInt() ?? 0,
        );
        await GStorage.putSetting(
          SettingsKeys.authVipExpire,
          user['vip_expire']?.toString() ?? '',
        );
      }
    } catch (_) {
      // 静默失败：离线时不影响使用
    }
  }

  /// 退出登录：清空本地账号信息
  Future<void> logout() async {
    await GStorage.putSetting(SettingsKeys.authToken, '');
    await GStorage.putSetting(SettingsKeys.authEmail, '');
    await GStorage.putSetting(SettingsKeys.authVipLevel, 0);
    await GStorage.putSetting(SettingsKeys.authVipExpire, '');
  }

  /// 保存 token 与用户信息，随后触发历史记录云同步
  Future<void> _applyAuth(Map<String, dynamic> data) async {
    final token = data['token']?.toString() ?? '';
    if (token.isEmpty) {
      throw AuthException(data['msg']?.toString() ?? '登录失败');
    }
    final user = data['user'];
    await GStorage.putSetting(SettingsKeys.authToken, token);
    if (user is Map) {
      await GStorage.putSetting(
        SettingsKeys.authEmail,
        user['email']?.toString() ?? '',
      );
      await GStorage.putSetting(
        SettingsKeys.authVipLevel,
        (user['vip_level'] as num?)?.toInt() ?? 0,
      );
      await GStorage.putSetting(
        SettingsKeys.authVipExpire,
        user['vip_expire']?.toString() ?? '',
      );
    }
    // 登录/注册成功即同步历史记录，并把游客设备数据并入账号（失败静默）
    unawaited(HistorySyncService.instance.syncNow());
    unawaited(HistorySyncService.instance.mergeGuestToAccount());
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      final response = await _dio.post<dynamic>('$_baseUrl$path', data: body);
      final raw = response.data;
      final data = raw is String
          ? (jsonDecode(raw) as Map).cast<String, dynamic>()
          : (raw as Map).cast<String, dynamic>();
      if (data['code'] != 0) {
        throw AuthException(data['msg']?.toString() ?? '请求失败');
      }
      return data;
    } on DioException catch (e) {
      throw AuthException('网络错误: ${e.message}');
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException('请求失败: $e');
    }
  }

  Dio get _dio {
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {'Content-Type': 'application/json'},
    ));
  }
}

/// 账号操作异常（含服务器返回的业务错误信息）
class AuthException implements Exception {
  AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}
