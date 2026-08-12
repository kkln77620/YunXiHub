import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/services/remote/history_sync_service.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 积分信息
class PointsInfo {
  final int points;
  final String lastCheckin;
  final String today;

  const PointsInfo({
    required this.points,
    required this.lastCheckin,
    required this.today,
  });

  bool get checkedInToday => lastCheckin == today && today.isNotEmpty;
}

/// YunXiHub 积分服务（每日签到 +10，兑换功能预留）
class PointsService {
  PointsService._();

  static final PointsService instance = PointsService._();

  /// 最近一次查询的积分缓存：页面切换时秒显，不重复转圈
  PointsInfo? cached;

  bool get _loggedIn =>
      GStorage.getSetting(SettingsKeys.authToken).trim().isNotEmpty;

  String get _baseUrl {
    var base =
        GStorage.getSetting(SettingsKeys.remoteResolverBaseUrl).trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  /// 查询当前积分（未登录返回 null；已登录但网络失败抛异常，由页面区分展示）
  Future<PointsInfo?> me() async {
    if (!_loggedIn) return null;
    final response = await _dio.get<dynamic>('$_baseUrl/api/points/me');
    final raw = response.data;
    final data = raw is String
        ? (jsonDecode(raw) as Map).cast<String, dynamic>()
        : (raw as Map).cast<String, dynamic>();
    if (data['code'] != 0) return null;
    final info = PointsInfo(
      points: (data['points'] as num?)?.toInt() ?? 0,
      lastCheckin: data['last_checkin']?.toString() ?? '',
      today: data['today']?.toString() ?? '',
    );
    cached = info;
    return info;
  }

  /// 每日签到：成功返回新积分；已签到返回 null（msg 区分）；未登录抛异常
  Future<({int? points, String msg})> checkin() async {
    if (!_loggedIn) {
      throw Exception('请先登录账号');
    }
    final response = await _dio.post<dynamic>(
      '$_baseUrl/api/points/checkin',
    );
    final raw = response.data;
    final data = raw is String
        ? (jsonDecode(raw) as Map).cast<String, dynamic>()
        : (raw as Map).cast<String, dynamic>();
    if (data['code'] != 0) {
      return (points: (data['points'] as num?)?.toInt(), msg: data['msg']?.toString() ?? '');
    }
    return (
      points: (data['points'] as num?)?.toInt(),
      msg: data['msg']?.toString() ?? '签到成功',
    );
  }

  Dio get _dio {
    final token = GStorage.getSetting(SettingsKeys.authToken).trim();
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Content-Type': 'application/json',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        'X-Device-Id': HistorySyncService.instance.deviceId,
      },
    ));
  }
}