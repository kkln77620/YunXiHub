import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/services/remote/auth_service.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 社区评论条目（YunXiHub 自建评论库，b 区）
class CommunityComment {
  final int id;
  final String kind;
  final int targetId;
  final int parentId;
  final int userId;
  final String nickname;
  final String avatar;
  final String content;
  final List<String> images;
  final bool spoiler;
  final bool isSponsor;
  final String title; // 头衔：管理员 / 赞助用户 / 普通用户（服务器实时计算）
  final int level; // 用户等级 L0-L9（服务器实时计算，头衔旁展示）
  final int likeCount;
  final int replyCount;
  final int reportCount;
  final bool likedByMe;
  final String createdAt;
  final List<CommunityComment> replies; // 主评论附带的热度前3条回复
  final String parentNickname; // 回复所指向的父评论昵称（@ 展示用）

  const CommunityComment({
    required this.id,
    required this.kind,
    required this.targetId,
    required this.parentId,
    required this.userId,
    required this.nickname,
    required this.avatar,
    required this.content,
    required this.images,
    required this.spoiler,
    required this.isSponsor,
    required this.title,
    required this.likeCount,
    required this.replyCount,
    required this.reportCount,
    required this.likedByMe,
    required this.createdAt,
    this.replies = const [],
    this.parentNickname = '',
  });

  factory CommunityComment.fromJson(Map<String, dynamic> j) {
    return CommunityComment(
      id: _toInt(j['id']),
      kind: j['kind']?.toString() ?? 'subject',
      targetId: _toInt(j['target_id']),
      parentId: _toInt(j['parent_id']),
      userId: _toInt(j['user_id']),
      nickname: j['nickname']?.toString() ?? '',
      avatar: j['avatar']?.toString() ?? '',
      content: j['content']?.toString() ?? '',
      images: _toStrList(j['images']),
      spoiler: _toBool(j['spoiler']),
      isSponsor: _toBool(j['is_sponsor']),
      title: j['title']?.toString() ?? '',
      level: _toInt(j['level']),
      likeCount: _toInt(j['like_count']),
      replyCount: _toInt(j['reply_count']),
      reportCount: _toInt(j['report_count']),
      likedByMe: _toBool(j['liked_by_me']),
      createdAt: j['created_at']?.toString() ?? '',
      replies: [
        for (final r in _toList(j['replies']))
          if (r is Map) CommunityComment.fromJson(r.cast<String, dynamic>())
      ],
      parentNickname: j['parent_nickname']?.toString() ?? '',
    );
  }

  /// 兼容数字/字符串/布尔 → int
  static int _toInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is bool) return v ? 1 : 0;
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  /// 兼容数字/布尔/字符串 → bool
  static bool _toBool(dynamic v) {
    if (v is bool) return v;
    if (v is num) return v.toInt() == 1;
    return v?.toString() == '1' || v?.toString() == 'true';
  }

  /// 兼容 List / 字符串 / null → List<String>
  static List<String> _toStrList(dynamic v) {
    if (v is List) {
      return [for (final i in v) i.toString()];
    }
    if (v is String && v.trim().isNotEmpty) {
      return [v];
    }
    return const <String>[];
  }

  /// 兼容 List / null → List<dynamic>
  static List<dynamic> _toList(dynamic v) {
    if (v is List) return v;
    return const <dynamic>[];
  }

  CommunityComment copyWith({
    int? likeCount,
    bool? likedByMe,
    int? replyCount,
    List<CommunityComment>? replies,
  }) {
    return CommunityComment(
      id: id,
      kind: kind,
      targetId: targetId,
      parentId: parentId,
      userId: userId,
      nickname: nickname,
      avatar: avatar,
      content: content,
      images: images,
      spoiler: spoiler,
      isSponsor: isSponsor,
      title: title,
      level: level,
      likeCount: likeCount ?? this.likeCount,
      replyCount: replyCount ?? this.replyCount,
      reportCount: reportCount,
      likedByMe: likedByMe ?? this.likedByMe,
      createdAt: createdAt,
      replies: replies ?? this.replies,
      parentNickname: parentNickname,
    );
  }
}

/// 社区评论排序方式
enum CommunitySort {
  hotDesc('hot_desc', '热度高→低'),
  hotAsc('hot_asc', '热度低→高'),
  timeDesc('time_desc', '时间新→旧'),
  timeAsc('time_asc', '时间旧→新');

  const CommunitySort(this.value, this.label);

  final String value;
  final String label;
}

/// YunXiHub 社区评论服务（自建评论库，游客可读，登录可发）
class CommunityCommentsService {
  CommunityCommentsService._();

  static final CommunityCommentsService instance =
      CommunityCommentsService._();

  /// ---- 一级评论缓存（避免切换界面重复请求）----
  /// key = "kind:targetId:sort"，仅在退出视频页 / 主动刷新 / 排序切换时清除
  static final Map<String, ({List<CommunityComment> items, int total})> _cache =
      {};

  /// ---- 剧透展开状态（全局静态，跨视图实例保留）----
  /// 解决 a/b 区（bangumi/社区）切换或视图重建后剧透重新隐藏的问题
  static final Map<int, bool> revealedSpoilers = {};

  /// 读取某评论的剧透展开状态
  static bool isSpoilerRevealed(int commentId) =>
      revealedSpoilers[commentId] ?? false;

  /// 设置剧透展开状态
  static void setSpoilerRevealed(int commentId, bool revealed) {
    revealedSpoilers[commentId] = revealed;
  }

  /// 构造本地评论对象（发表成功后的乐观插入，不触发刷新）
  /// [id] 为服务器返回的新评论 id；其余字段用本地登录信息
  static CommunityComment buildLocalComment({
    required int id,
    required String kind,
    required int targetId,
    int parentId = 0,
    required String content,
    List<String> images = const [],
    bool spoiler = false,
    String? createdAt,
  }) {
    final nickname =
        GStorage.getSetting(SettingsKeys.authNickname).trim();
    final avatar = GStorage.getSetting(SettingsKeys.authAvatar).trim();
    return CommunityComment(
      id: id,
      kind: kind,
      targetId: targetId,
      parentId: parentId,
      userId: AuthService.instance.userId,
      nickname: nickname.isEmpty ? '我' : nickname,
      avatar: avatar,
      content: content,
      images: images,
      spoiler: spoiler,
      isSponsor: AuthService.instance.vipLevel > 0,
      title: AuthService.instance.title == '普通用户' ? '' : AuthService.instance.title,
      level: AuthService.instance.level,
      likeCount: 0,
      replyCount: 0,
      reportCount: 0,
      likedByMe: false,
      createdAt: createdAt ??
          _nowLocal(),
    );
  }

  /// 本地时间 yyyy-MM-dd HH:mm:ss（与服务器格式一致）
  static String _nowLocal() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  static String _cacheKey(String kind, int targetId, CommunitySort sort) =>
      '$kind:$targetId:${sort.value}';

  /// 读取缓存（无缓存返回 null）
  static ({List<CommunityComment> items, int total})? cached(
    String kind,
    int targetId,
    CommunitySort sort,
  ) {
    return _cache[_cacheKey(kind, targetId, sort)];
  }

  /// 写入缓存（仅主评论列表）
  static void cacheStore(
    String kind,
    int targetId,
    CommunitySort sort,
    List<CommunityComment> items,
    int total,
  ) {
    _cache[_cacheKey(kind, targetId, sort)] = (items: items, total: total);
  }

  /// 清除缓存：传 kind+targetId 只清该评论区；不传则全部清除
  static void clearCache({String? kind, int? targetId}) {
    if (kind == null || targetId == null) {
      _cache.clear();
      return;
    }
    _cache.removeWhere(
      (key, _) => key.startsWith('$kind:$targetId:'),
    );
  }

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

  /// 拉取评论列表（游客可读）
  /// [parentId] 为 0 时拉主评论（成功后写入一级缓存）；>0 时拉某条评论的回复
  Future<({List<CommunityComment> items, int total})> list({
    required String kind,
    required int targetId,
    int parentId = 0,
    CommunitySort sort = CommunitySort.hotDesc,
    int offset = 0,
    int limit = 20,
  }) async {
    final response = await _dio.get<dynamic>(
      '$_baseUrl/api/comments/list',
      queryParameters: {
        'kind': kind,
        'target_id': targetId,
        if (parentId > 0) 'parent_id': parentId,
        'sort': sort.value,
        'offset': offset,
        'limit': limit,
      },
    );
    final raw = response.data;
    final data = raw is String
        ? (jsonDecode(raw) as Map).cast<String, dynamic>()
        : (raw as Map).cast<String, dynamic>();
    if (data['code'] != 0 || data['items'] is! List) {
      return (items: const <CommunityComment>[], total: 0);
    }
    final items = [
      for (final it in data['items'] as List)
        if (it is Map) CommunityComment.fromJson(it.cast<String, dynamic>())
    ];
    final total = (data['total'] as num?)?.toInt() ?? 0;
    // 主评论列表写入一级缓存
    if (parentId == 0) {
      cacheStore(kind, targetId, sort, items, total);
    }
    return (items: items, total: total);
  }

  /// 发表评论/回复（需登录），返回新评论 id（乐观插入用）
  Future<int> postReturnId({
    required String kind,
    required int targetId,
    required String content,
    List<String> images = const [],
    bool spoiler = false,
    int parentId = 0,
  }) async {
    if (!_loggedIn) {
      throw Exception('请先登录账号');
    }
    final response = await _dio.post<dynamic>(
      '$_baseUrl/api/comments/post',
      data: {
        'kind': kind,
        'target_id': targetId,
        'content': content,
        'images': images,
        'spoiler': spoiler,
        if (parentId > 0) 'parent_id': parentId,
      },
    );
    final raw = response.data;
    final data = raw is String
        ? (jsonDecode(raw) as Map).cast<String, dynamic>()
        : (raw as Map).cast<String, dynamic>();
    if (data['code'] != 0) {
      throw Exception(data['msg']?.toString() ?? '评论失败');
    }
    return (data['id'] as num?)?.toInt() ?? 0;
  }

  /// 发表评论/回复（需登录）
  Future<void> post({
    required String kind,
    required int targetId,
    required String content,
    List<String> images = const [],
    bool spoiler = false,
    int parentId = 0,
  }) async {
    if (!_loggedIn) {
      throw Exception('请先登录账号');
    }
    final response = await _dio.post<dynamic>(
      '$_baseUrl/api/comments/post',
      data: {
        'kind': kind,
        'target_id': targetId,
        'content': content,
        'images': images,
        'spoiler': spoiler,
        if (parentId > 0) 'parent_id': parentId,
      },
    );
    final raw = response.data;
    final data = raw is String
        ? (jsonDecode(raw) as Map).cast<String, dynamic>()
        : (raw as Map).cast<String, dynamic>();
    if (data['code'] != 0) {
      throw Exception(data['msg']?.toString() ?? '评论失败');
    }
  }

  /// 点赞/取消点赞（需登录），返回最新 (liked, likeCount)
  Future<({bool liked, int likeCount})> like(int commentId) async {
    if (!_loggedIn) {
      throw Exception('请先登录账号');
    }
    final response = await _dio.post<dynamic>(
      '$_baseUrl/api/comments/like',
      data: {'comment_id': commentId},
    );
    final raw = response.data;
    final data = raw is String
        ? (jsonDecode(raw) as Map).cast<String, dynamic>()
        : (raw as Map).cast<String, dynamic>();
    if (data['code'] != 0) {
      throw Exception(data['msg']?.toString() ?? '操作失败');
    }
    return (
      liked: (data['liked'] as num?)?.toInt() == 1,
      likeCount: (data['like_count'] as num?)?.toInt() ?? 0,
    );
  }

  /// 举报评论（需登录）
  Future<void> report(int commentId) async {
    if (!_loggedIn) {
      throw Exception('请先登录账号');
    }
    final response = await _dio.post<dynamic>(
      '$_baseUrl/api/comments/report',
      data: {'comment_id': commentId},
    );
    final raw = response.data;
    final data = raw is String
        ? (jsonDecode(raw) as Map).cast<String, dynamic>()
        : (raw as Map).cast<String, dynamic>();
    if (data['code'] != 0) {
      throw Exception(data['msg']?.toString() ?? '举报失败');
    }
  }

  /// 删除评论（本人或管理员）
  Future<void> delete(int commentId) async {
    if (!_loggedIn) {
      throw Exception('请先登录账号');
    }
    final response = await _dio.post<dynamic>(
      '$_baseUrl/api/comments/delete',
      data: {'comment_id': commentId},
    );
    final raw = response.data;
    final data = raw is String
        ? (jsonDecode(raw) as Map).cast<String, dynamic>()
        : (raw as Map).cast<String, dynamic>();
    if (data['code'] != 0) {
      throw Exception(data['msg']?.toString() ?? '删除失败');
    }
  }

  /// 将服务器相对路径（/uploads/xxx）解析为完整 URL
  String resolveUrl(String pathOrUrl) {
    if (pathOrUrl.isEmpty) return '';
    if (pathOrUrl.startsWith('http')) return pathOrUrl;
    return '$_baseUrl$pathOrUrl';
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

/// 头像/昵称默认值辅助
String defaultNickname(String email) {
  if (email.isEmpty) return '游客';
  return email.split('@').first;
}

/// 上传图片并返回相对 URL（复用 AuthService）
Future<List<String>> uploadCommentImages(List<String> localPaths) async {
  final urls = <String>[];
  for (final p in localPaths) {
    urls.add(await AuthService.instance.uploadImage(p, use: 'comment'));
  }
  return urls;
}