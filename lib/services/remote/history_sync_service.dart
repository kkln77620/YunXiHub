import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/services/remote/collect_sync_service.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 历史记录云同步（YunXiHub 服务器）
///
/// 登录后调用 [syncNow]：
/// 1. 本地全部历史序列化后 POST /api/history/sync（服务器按 hkey 合并）
/// 2. GET /api/history/pull 拉取服务器记录，按 lastWatchTime 取新者合并回本地
///
/// 合并策略：同一 hkey 取 lastWatchTime 更新的记录（时间戳秒级比较）。
class HistorySyncService {
  HistorySyncService._();

  static final HistorySyncService instance = HistorySyncService._();

  Timer? _debounceTimer;
  static const Duration _debounceDelay = Duration(seconds: 20);

  /// 未登录游客也可同步：需要本地设备标识
  bool get _ready {
    return _baseUrl.isNotEmpty && (AuthTokenHolder.token.isNotEmpty || deviceId.isNotEmpty);
  }

  /// 云历史同步总开关
  bool get _enabled {
    return GStorage.getSetting(SettingsKeys.cloudHistorySyncEnable);
  }

  /// 设备标识（游客维度；登录后作为 X-Device-Id 供 merge 使用）
  String get deviceId {
    var id = GStorage.getSetting(SettingsKeys.historySyncDeviceId).trim();
    if (id.isEmpty) {
      id = _generateDeviceId();
      GStorage.putSetting(SettingsKeys.historySyncDeviceId, id);
    }
    return id;
  }

  String _generateDeviceId() {
    final rand = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final salt = (0x1D2E3F4A + DateTime.now().millisecondsSinceEpoch % 0xFFFF)
        .toRadixString(16);
    return 'yh-$rand$salt';
  }

  String get _baseUrl {
    var base =
        GStorage.getSetting(SettingsKeys.remoteResolverBaseUrl).trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  /// 登录后调用：先上传本地，再拉取合并（失败静默，不阻塞登录）
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

  /// 登录成功后把游客设备数据并入账号（服务器按 hkey 合并取新）
  Future<void> mergeGuestToAccount() async {
    final token = AuthTokenHolder.token;
    if (token.isEmpty) return;
    try {
      final dev = deviceId;
      await _dio.post<dynamic>(
        '$_baseUrl/api/history/merge',
        data: {'device_id': dev},
      );
      await CollectSyncService.instance.mergeGuestToAccount();
    } catch (_) {
      // 合并失败静默，下次登录可重试
    }
  }

  /// 历史记录变化时调用：20 秒防抖后自动同步（登录/游客均可）
  void scheduleSync() {
    if (!_ready || !_enabled) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDelay, () {
      unawaited(syncNow());
    });
  }

  /// 应用启动/回到前台时调用：立即同步一次
  Future<void> syncOnLaunch() async {
    if (!_ready || !_enabled) return;
    await syncNow();
    // 之后进入防抖自动同步节奏
  }

  // ---------- 序列化本地 ----------
  List<Map<String, dynamic>> _serializeLocal() {
    final items = <Map<String, dynamic>>[];
    final histories = GStorage.histories;
    for (final key in histories.keys) {
      final h = histories.get(key);
      if (h == null) continue;
      items.add({
        'hkey': key.toString(),
        'bangumi_id': h.bangumiItem.id,
        'bangumi_name': h.bangumiItem.name,
        'bangumi_json': jsonEncode(_bangumiToJson(h.bangumiItem)),
        'adapter_name': h.adapterName,
        'last_episode': h.lastWatchEpisode,
        'last_src': h.lastSrc,
        'last_episode_name': h.lastWatchEpisodeName,
        'entry_kind': h.entryKind,
        'episode_page_url': h.episodePageUrl,
        'last_watch_time': h.lastWatchTime.toIso8601String(),
        // 隐私精简：云端只记录“看到第几集”，不上传分钟级播放进度
        'progresses': '{}',
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
      '$_baseUrl/api/history/sync',
      data: {'items': items},
    );
  }

  Future<List<Map<String, dynamic>>> _pullRemote() async {
    final response =
        await _dio.get<dynamic>('$_baseUrl/api/history/pull');
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
    final box = GStorage.histories;
    for (final it in items) {
      final hkey = it['hkey']?.toString() ?? '';
      if (hkey.isEmpty) continue;
      final remoteTime = _parseTime(it['last_watch_time']?.toString() ?? '');
      final local = box.get(hkey);
      if (local != null && remoteTime != null) {
        final localMs = local.lastWatchTime.millisecondsSinceEpoch;
        if (remoteTime.millisecondsSinceEpoch <= localMs) continue;
      }
      if (remoteTime == null) continue;
      final history = _buildHistory(it, remoteTime);
      if (history == null) continue;
      // 云端不存分钟进度：拉取合并时保留本地分钟级进度，避免覆盖“继续观看”位置
      if (history.progresses.isEmpty && local != null && local.progresses.isNotEmpty) {
        history.progresses = local.progresses;
      }
      await box.put(hkey, history);
    }
    await box.flush();
  }

  History? _buildHistory(Map<String, dynamic> it, DateTime lastWatchTime) {
    BangumiItem bangumi;
    try {
      final bj = it['bangumi_json']?.toString() ?? '';
      bangumi = bj.isNotEmpty
          ? _bangumiFromJson(jsonDecode(bj) as Map<String, dynamic>)
          : BangumiItem(
              id: (it['bangumi_id'] as num?)?.toInt() ?? 0,
              type: 2,
              name: it['bangumi_name']?.toString() ?? '',
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
    final progresses = <int, Progress>{};
    try {
      final pj = it['progresses']?.toString() ?? '{}';
      final pm = jsonDecode(pj) as Map<String, dynamic>;
      for (final e in pm.entries) {
        final v = e.value as Map<String, dynamic>;
        progresses[int.parse(e.key)] = Progress(
          (v['episode'] as num?)?.toInt() ?? 0,
          (v['road'] as num?)?.toInt() ?? 0,
          (v['progress_ms'] as num?)?.toInt() ?? 0,
          updatedAtMs: (v['updated_at_ms'] as num?)?.toInt() ?? 0,
        );
      }
    } catch (_) {
      // 进度解析失败时保留空进度
    }
    final h = History(
      bangumi,
      (it['last_episode'] as num?)?.toInt() ?? 0,
      it['adapter_name']?.toString() ?? '',
      lastWatchTime,
      it['last_src']?.toString() ?? '',
      it['last_episode_name']?.toString() ?? '',
      entryKind: it['entry_kind']?.toString() ?? HistoryEntryKind.online,
      episodePageUrl: it['episode_page_url']?.toString() ?? '',
    );
    h.progresses = progresses;
    return h;
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

/// token 读取辅助（避免与服务层循环依赖）
class AuthTokenHolder {
  static String get token => GStorage.getSetting(SettingsKeys.authToken).trim();
}