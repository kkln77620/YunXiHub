import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 用户权益（服务器下发，客户端据此本地限制，不写死）
///
/// 字段含义：
/// - [commentEnabled]：能否发评论（L0 未考核 / 封禁 = false）
/// - [commentMaxLen]：评论最大字数（编辑时本地限制）
/// - [commentMaxImages]：评论图片上限（编辑时本地限制）
/// - [commentDaily]：每日评论条数
/// - [dmImageEnabled]：私信图片是否可用（注册满 24h）
class Entitlements {
  final int level;
  final bool isAdmin;
  final bool isBanned;
  final String banMsg;
  final bool examPassed;
  final bool commentEnabled;
  final int commentDaily;
  final int commentMaxLen;
  final int commentMaxImages;
  final bool dmEnabled;
  final bool dmImageEnabled;
  final int dmImageMax;
  final int dmImageRegHours;

  const Entitlements({
    this.level = 0,
    this.isAdmin = false,
    this.isBanned = false,
    this.banMsg = '',
    this.examPassed = false,
    this.commentEnabled = true,
    this.commentDaily = 999,
    this.commentMaxLen = 2000,
    this.commentMaxImages = 50,
    this.dmEnabled = true,
    this.dmImageEnabled = true,
    this.dmImageMax = 3,
    this.dmImageRegHours = 24,
  });

  factory Entitlements.fromJson(Map<String, dynamic> j) => Entitlements(
        level: (j['level'] as num?)?.toInt() ?? 0,
        isAdmin: (j['is_admin'] as num?)?.toInt() == 1,
        isBanned: (j['is_banned'] as num?)?.toInt() == 1,
        banMsg: j['ban_msg']?.toString() ?? '',
        examPassed: (j['exam_passed'] as num?)?.toInt() == 1,
        commentEnabled: j['comment_enabled'] == true ||
            (j['comment_enabled'] as num?)?.toInt() == 1,
        commentDaily: (j['comment_daily'] as num?)?.toInt() ?? 999,
        commentMaxLen: (j['comment_max_len'] as num?)?.toInt() ?? 2000,
        commentMaxImages:
            (j['comment_max_images'] as num?)?.toInt() ?? 50,
        dmEnabled: j['dm_enabled'] == true ||
            (j['dm_enabled'] as num?)?.toInt() == 1,
        dmImageEnabled: j['dm_image_enabled'] == true ||
            (j['dm_image_enabled'] as num?)?.toInt() == 1,
        dmImageMax: (j['dm_image_max'] as num?)?.toInt() ?? 3,
        dmImageRegHours: (j['dm_image_reg_hours'] as num?)?.toInt() ?? 24,
      );

  static const String cacheKey = 'entitlements_cache';

  Map<String, dynamic> toJson() => {
        'level': level,
        'is_admin': isAdmin ? 1 : 0,
        'is_banned': isBanned ? 1 : 0,
        'ban_msg': banMsg,
        'exam_passed': examPassed ? 1 : 0,
        'comment_enabled': commentEnabled ? 1 : 0,
        'comment_daily': commentDaily,
        'comment_max_len': commentMaxLen,
        'comment_max_images': commentMaxImages,
        'dm_enabled': dmEnabled ? 1 : 0,
        'dm_image_enabled': dmImageEnabled ? 1 : 0,
        'dm_image_max': dmImageMax,
        'dm_image_reg_hours': dmImageRegHours,
      };
}

/// 权益服务：内存 + 磁盘双缓存（**不自动删除**），每次打开 App / 登录时
/// 对比服务器差异自动同步（拉取成功即覆盖；失败用本地缓存兜底）
class EntitlementsService {
  EntitlementsService._();

  static final EntitlementsService instance = EntitlementsService._();

  static Entitlements? _mem;

  /// 当前权益（内存优先，磁盘兜底，绝不用默认值糊弄本地限制）
  static Entitlements get current {
    final mem = _mem;
    if (mem != null) return mem;
    return fromDisk();
  }

  static Entitlements fromDisk() {
    try {
      final raw = GStorage.getSetting(cacheKey).toString();
      if (raw.isNotEmpty) {
        final map = (jsonDecode(raw) as Map).cast<String, dynamic>();
        return Entitlements.fromJson(map);
      }
    } catch (_) {}
    return const Entitlements();
  }

  static void saveDisk(Entitlements e) {
    try {
      GStorage.putSetting(cacheKey, jsonEncode(e.toJson()));
    } catch (_) {}
  }

  /// 从服务器拉取并覆盖缓存（每次打开 App / 登录成功后调用）
  static Future<void> sync() async {
    final token = GStorage.getSetting(SettingsKeys.authToken).trim();
    if (token.isEmpty) {
      _mem = null;
      return;
    }
    try {
      final resp = await Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        headers: {'Authorization': 'Bearer $token'},
      )).get<dynamic>(_baseUrl + '/api/user/entitlements');
      final raw = resp.data;
      final data = raw is String
          ? (jsonDecode(raw) as Map).cast<String, dynamic>()
          : (raw as Map).cast<String, dynamic>();
      if (data['code'] == 0 && data['data'] is Map) {
        final e = Entitlements.fromJson(
            (data['data'] as Map).cast<String, dynamic>());
        _mem = e;
        saveDisk(e);
      }
    } catch (_) {
      // 网络失败：用磁盘缓存兜底（不打扰用户）
    }
  }

  static void invalidate() {
    _mem = null;
  }

  static String get _baseUrl {
    var base =
        GStorage.getSetting(SettingsKeys.remoteResolverBaseUrl).trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }
}