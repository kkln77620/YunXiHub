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
  final int likeCount;
  final int replyCount;
  final int reportCount;
  final bool likedByMe;
  final String createdAt;

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
    required this.likeCount,
    required this.replyCount,
    required this.reportCount,
    required this.likedByMe,
    required this.createdAt,
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
      likeCount: _toInt(j['like_count']),
      replyCount: _toInt(j['reply_count']),
      reportCount: _toInt(j['report_count']),
      likedByMe: _toBool(j['liked_by_me']),
      createdAt: j['created_at']?.toString() ?? '',
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

  CommunityComment copyWith({
    int? likeCount,
    bool? likedByMe,
    int? replyCount,
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
      likeCount: likeCount ?? this.likeCount,
      replyCount: replyCount ?? this.replyCount,
      reportCount: reportCount,
      likedByMe: likedByMe ?? this.likedByMe,
      createdAt: createdAt,
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
  /// [parentId] 为 0 时拉主评论；>0 时拉某条评论的回复
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
    return (
      items: [
        for (final it in data['items'] as List)
          if (it is Map) CommunityComment.fromJson(it.cast<String, dynamic>())
      ],
      total: (data['total'] as num?)?.toInt() ?? 0,
    );
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