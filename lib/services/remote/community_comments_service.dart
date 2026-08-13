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
  final String nickname;
  final String avatar;
  final String content;
  final List<String> images;
  final bool spoiler;
  final bool isSponsor;
  final String createdAt;

  const CommunityComment({
    required this.id,
    required this.kind,
    required this.targetId,
    required this.nickname,
    required this.avatar,
    required this.content,
    required this.images,
    required this.spoiler,
    required this.isSponsor,
    required this.createdAt,
  });

  factory CommunityComment.fromJson(Map<String, dynamic> j) {
    return CommunityComment(
      id: (j['id'] as num?)?.toInt() ?? 0,
      kind: j['kind']?.toString() ?? 'subject',
      targetId: (j['target_id'] as num?)?.toInt() ?? 0,
      nickname: j['nickname']?.toString() ?? '',
      avatar: j['avatar']?.toString() ?? '',
      content: j['content']?.toString() ?? '',
      images: [
        for (final i in (j['images'] as List?) ?? <dynamic>[]) i.toString()
      ],
      spoiler: (j['spoiler'] as num?)?.toInt() == 1,
      isSponsor: (j['is_sponsor'] as num?)?.toInt() == 1,
      createdAt: j['created_at']?.toString() ?? '',
    );
  }
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
  Future<({List<CommunityComment> items, int total})> list({
    required String kind,
    required int targetId,
    int offset = 0,
    int limit = 20,
  }) async {
    final response = await _dio.get<dynamic>(
      '$_baseUrl/api/comments/list',
      queryParameters: {
        'kind': kind,
        'target_id': targetId,
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

  /// 发表评论（需登录）
  Future<void> post({
    required String kind,
    required int targetId,
    required String content,
    List<String> images = const [],
    bool spoiler = false,
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
