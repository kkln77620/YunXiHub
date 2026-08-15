import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 好友简要信息
class FriendBrief {
  final int uid;
  final String nickname;
  final String avatar;
  final int level;
  final int isSponsor;
  final String createdAt;

  const FriendBrief({
    required this.uid,
    required this.nickname,
    required this.avatar,
    this.level = 0,
    this.isSponsor = 0,
    this.createdAt = '',
  });

  factory FriendBrief.fromJson(Map<String, dynamic> j) {
    return FriendBrief(
      uid: (j['uid'] as num?)?.toInt() ?? 0,
      nickname: j['nickname']?.toString() ?? '',
      avatar: j['avatar']?.toString() ?? '',
      level: (j['level'] as num?)?.toInt() ?? 0,
      isSponsor: (j['is_sponsor'] as num?)?.toInt() ?? 0,
      createdAt: j['created_at']?.toString() ?? '',
    );
  }
}

/// 好友列表结果（好友 / 待我处理 / 我发出的申请）
class FriendListResult {
  final List<FriendBrief> friends;
  final List<FriendBrief> requestsIn;
  final List<FriendBrief> requestsOut;

  const FriendListResult({
    this.friends = const [],
    this.requestsIn = const [],
    this.requestsOut = const [],
  });
}

/// 用户主页数据
class UserProfile {
  final Map<String, dynamic> user;
  final int relation; // 1=好友 2=我申请中 3=对方申请我 4=拒绝过 0=无
  final int showCollect;
  final int showHistory;
  final List<Map<String, dynamic>> collect;
  final List<Map<String, dynamic>> history;

  const UserProfile({
    required this.user,
    this.relation = 0,
    this.showCollect = 0,
    this.showHistory = 0,
    this.collect = const [],
    this.history = const [],
  });

  int get uid => (user['uid'] as num?)?.toInt() ?? 0;
  String get nickname => user['nickname']?.toString() ?? '';
  String get avatar => user['avatar']?.toString() ?? '';
  int get level => (user['level'] as num?)?.toInt() ?? 0;
  int get isSelf => (user['is_self'] as num?)?.toInt() ?? 0;
  int get isAdmin => (user['is_admin'] as num?)?.toInt() ?? 0;
  int get isSponsor => (user['vip_level'] as num?)?.toInt() ?? 0;
  String get createdAt => user['created_at']?.toString() ?? '';
}

/// 好友服务：申请 / 处理 / 列表 / 主页 / 隐私设置
class FriendsService {
  FriendsService._();

  static final FriendsService instance = FriendsService._();

  String get _baseUrl {
    var base =
        GStorage.getSetting(SettingsKeys.remoteResolverBaseUrl).trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  bool get _loggedIn =>
      GStorage.getSetting(SettingsKeys.authToken).trim().isNotEmpty;

  /// 好友列表（好友 + 申请）
  Future<FriendListResult> list() async {
    if (!_loggedIn) return const FriendListResult();
    try {
      final r = await _dio.get<dynamic>('$_baseUrl/api/friends/list');
      final d = _decode(r.data);
      if (d['code'] != 0) return const FriendListResult();
      List<FriendBrief> parse(String key) => [
            for (final it in (d[key] as List? ?? const []))
              if (it is Map) FriendBrief.fromJson(it.cast<String, dynamic>())
          ];
      return FriendListResult(
        friends: parse('friends'),
        requestsIn: parse('requests_in'),
        requestsOut: parse('requests_out'),
      );
    } catch (_) {
      return const FriendListResult();
    }
  }

  /// 发起好友申请：成功返回 null，失败返回错误信息
  Future<String?> request(int uid) => _post('/api/friends/request', {'uid': uid});

  Future<String?> accept(int uid) => _post('/api/friends/accept', {'uid': uid});

  Future<String?> reject(int uid) => _post('/api/friends/reject', {'uid': uid});

  Future<String?> remove(int uid) => _post('/api/friends/remove', {'uid': uid});

  /// 用户主页
  Future<UserProfile?> profile(int uid) async {
    if (!_loggedIn) return null;
    try {
      final r = await _dio.get<dynamic>(
        '$_baseUrl/api/users/profile',
        queryParameters: {'uid': uid},
      );
      final d = _decode(r.data);
      if (d['code'] != 0 || d['user'] is! Map) return null;
      return UserProfile(
        user: (d['user'] as Map).cast<String, dynamic>(),
        relation: (d['relation'] as num?)?.toInt() ?? 0,
        showCollect: (d['show_collect'] as num?)?.toInt() ?? 0,
        showHistory: (d['show_history'] as num?)?.toInt() ?? 0,
        collect: [
          for (final it in (d['collect'] as List? ?? const []))
            if (it is Map) it.cast<String, dynamic>()
        ],
        history: [
          for (final it in (d['history'] as List? ?? const []))
            if (it is Map) it.cast<String, dynamic>()
        ],
      );
    } catch (_) {
      return null;
    }
  }

  /// 社交展示设置（showCollect/showHistory：0 或 1）
  Future<String?> setPrivacy({bool? showCollect, bool? showHistory}) {
    return _post('/api/user/privacy', {
      if (showCollect != null) 'show_collect': showCollect ? 1 : 0,
      if (showHistory != null) 'show_history': showHistory ? 1 : 0,
    });
  }

  Future<String?> _post(String path, Map<String, dynamic> body) async {
    if (!_loggedIn) return '未登录';
    try {
      final r = await _dio.post<dynamic>('$_baseUrl$path', data: body);
      final d = _decode(r.data);
      if (d['code'] == 0) return null;
      return d['msg']?.toString() ?? '操作失败';
    } on DioException catch (e) {
      return '网络错误: ${e.message}';
    } catch (_) {
      return '请求失败';
    }
  }

  Map<String, dynamic> _decode(dynamic raw) {
    if (raw is String) {
      try {
        return (jsonDecode(raw) as Map).cast<String, dynamic>();
      } catch (_) {
        return <String, dynamic>{};
      }
    }
    if (raw is Map) return raw.cast<String, dynamic>();
    return <String, dynamic>{};
  }

  Dio get _dio {
    final token = GStorage.getSetting(SettingsKeys.authToken).trim();
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Content-Type': 'application/json',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      },
    ));
  }
}