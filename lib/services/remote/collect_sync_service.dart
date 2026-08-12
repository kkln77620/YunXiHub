import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/services/remote/history_sync_service.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 追番收藏云同步（YunXiHub 服务器）
///
/// 登录账号或游客设备均可同步；登录后游客数据自动并入账号。
/// 合并策略：同一 bangumi id 取 time/updated_at 更新的记录。
class CollectSyncService {
  CollectSyncService._();

  static final CollectSyncService instance = CollectSyncService._();

  Timer? _debounceTimer;
  static const Duration _debounceDelay = Duration(seconds: 20);

  bool get _ready {
    return _baseUrl.isNotEmpty &&
        (AuthTokenHolder.token.isNotEmpty || deviceId.isNotEmpty);
  }

  bool get _enabled {
    return GStorage.getSetting(SettingsKeys.cloudCollectSyncEnable);
  }

  String get deviceId => HistorySyncService.instance.deviceId;

  String get _baseUrl {
    var base =
        GStorage.getSetting(SettingsKeys.remoteResolverBaseUrl).trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  /// 立即同步：先上传本地收藏，再拉取合并（失败静默）
  Future<void> syncNow() async {
    if (!_ready || !_enabled) return;
    try {
      final localItems = _serializeLocal();
      await _postSync(localItems);
      final remoteItems = await _pullRemote();
      if (remoteItems.isNotEmpty) {
        await _mergeRemote(remoteItems);
      }
    } catch (_) {
      // 静默失败：离线/服务器异常不影响本地使用
    }
  }

  /// 登录成功后把游客设备的追番收藏并入账号
  Future<void> mergeGuestToAccount() async {
    final token = AuthTokenHolder.token;
    if (token.isEmpty) return;
    try {
      await _dio.post<dynamic>(
        '$_baseUrl/api/collect/merge',
        data: {'device_id': deviceId},
      );
    } catch (_) {
      // 合并失败静默，下次登录可重试
    }
  }

  /// 收藏变化时调用：20 秒防抖后自动同步
  void scheduleSync() {
    if (!_ready || !_enabled) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDelay, () {
      unawaited(syncNow());
    });
  }

  /// 应用启动时同步一次
  Future<void> syncOnLaunch() async {
    if (!_ready || !_enabled) return;
    await syncNow();
  }

  // ---------- 序列化本地收藏 ----------
  List<Map<String, dynamic>> _serializeLocal() {
    final items = <Map<String, dynamic>>[];
    final box = GStorage.collectibles;
    for (final id in box.keys) {
      final c = box.get(id);
      if (c == null) continue;
      items.add({
        'bkey': c.key,
        'bangumi_id': c.bangumiItem.id,
        'name': c.bangumiItem.name,
        'bangumi_json': jsonEncode(_bangumiToJson(c.bangumiItem)),
        'collect_type': c.type,
        'updated_at': c.time.toIso8601String(),
      });
    }
    return items;
  }

  Map<String, dynamic> _bangumiToJson(BangumiItem b) {
    return {
      'id': b.id,
      'type': b.type,
      'name': b.name,
      'nameCn': b.nameCn,
      'summary': b.summary,
      'airDate': b.airDate,
      'airWeekday': b.airWeekday,
      'rank': b.rank,
      'images': b.images,
      'ratingScore': b.ratingScore,
      'votes': b.votes,
      'info': b.info,
    };
  }

  BangumiItem _bangumiFromJson(Map<String, dynamic> j) {
    return BangumiItem(
      id: (j['id'] as num?)?.toInt() ?? 0,
      type: (j['type'] as num?)?.toInt() ?? 2,
      name: j['name']?.toString() ?? '',
      nameCn: j['nameCn']?.toString() ?? '',
      summary: j['summary']?.toString() ?? '',
      airDate: j['airDate']?.toString() ?? '',
      airWeekday: (j['airWeekday'] as num?)?.toInt() ?? 0,
      rank: (j['rank'] as num?)?.toInt() ?? 0,
      images: (j['images'] is Map)
          ? (j['images'] as Map).map((k, v) => MapEntry(k.toString(), v.toString()))
          : const {},
      tags: const [],
      alias: const [],
      ratingScore: (j['ratingScore'] as num?)?.toDouble() ?? 0.0,
      votes: (j['votes'] as num?)?.toInt() ?? 0,
      votesCount: const [],
      info: j['info']?.toString() ?? '',
    );
  }

  // ---------- 网络 ----------
  Future<void> _postSync(List<Map<String, dynamic>> items) async {
    if (items.isEmpty) return;
    await _dio.post<dynamic>(
      '$_baseUrl/api/collect/sync',
      data: {'items': items},
    );
  }

  Future<List<Map<String, dynamic>>> _pullRemote() async {
    final response = await _dio.get<dynamic>('$_baseUrl/api/collect/pull');
    final raw = response.data;
    final data = raw is String
        ? (jsonDecode(raw) as Map).cast<String, dynamic>()
        : (raw as Map).cast<String, dynamic>();
    if (data['code'] != 0 || data['items'] is! List) return const [];
    return [
      for (final it in data['items'] as List)
        if (it is Map) it.cast<String, dynamic>()
    ];
  }

  // ---------- 合并回本地 ----------
  Future<void> _mergeRemote(List<Map<String, dynamic>> items) async {
    final box = GStorage.collectibles;
    for (final it in items) {
      final bkey = it['bkey']?.toString() ?? '';
      if (bkey.isEmpty) continue;
      final remoteTime = _parseTime(it['updated_at']?.toString() ?? '');
      if (remoteTime == null) continue;
      final local = box.get(bkey);
      if (local != null && remoteTime.isBefore(local.time)) continue;
      final bangumi = _buildBangumi(it);
      if (bangumi == null) continue;
      await GStorage.putCollectible(CollectedBangumi(
        bangumi,
        remoteTime,
        (it['collect_type'] as num?)?.toInt() ?? local?.type ?? 1,
      ));
    }
    await box.flush();
  }

  BangumiItem? _buildBangumi(Map<String, dynamic> it) {
    try {
      final bj = it['bangumi_json']?.toString() ?? '';
      if (bj.isNotEmpty) {
        return _bangumiFromJson(jsonDecode(bj) as Map<String, dynamic>);
      }
      return BangumiItem(
        id: (it['bangumi_id'] as num?)?.toInt() ?? 0,
        type: 2,
        name: it['name']?.toString() ?? '',
        nameCn: '',
        summary: '',
        airDate: '',
        airWeekday: 0,
        rank: 0,
        images: const {},
        tags: const [],
        alias: const [],
        ratingScore: 0,
        votes: 0,
        votesCount: const [],
        info: '',
      );
    } catch (_) {
      return null;
    }
  }

  DateTime? _parseTime(String s) {
    try {
      return DateTime.parse(s).toLocal();
    } catch (_) {
      return null;
    }
  }

  Dio get _dio {
    final token = AuthTokenHolder.token;
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Content-Type': 'application/json',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        'X-Device-Id': deviceId,
      },
    ));
  }
}