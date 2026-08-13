import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 消息类型
enum MessageType {
  all('all', '全部'),
  like('like', '点赞'),
  reply('reply', '回复'),
  mention('mention', '@我');

  const MessageType(this.value, this.label);

  final String value;
  final String label;
}

/// 站内消息条目
class AppMessage {
  final int id;
  final String type; // like | reply | mention
  final int actorId;
  final String actorNickname;
  final int commentId;
  final String content;
  final bool isRead;
  final String createdAt;
  final String kind; // 关联评论的 kind（subject/episode/character），供跳转
  final int targetId; // 关联评论的 target_id，供跳转

  const AppMessage({
    required this.id,
    required this.type,
    required this.actorId,
    required this.actorNickname,
    required this.commentId,
    required this.content,
    required this.isRead,
    required this.createdAt,
    this.kind = '',
    this.targetId = 0,
  });

  factory AppMessage.fromJson(Map<String, dynamic> j) {
    final isReadRaw = j['is_read'];
    return AppMessage(
      id: (j['id'] as num?)?.toInt() ?? 0,
      type: j['type']?.toString() ?? 'like',
      actorId: (j['actor_id'] as num?)?.toInt() ?? 0,
      actorNickname: j['actor_nickname']?.toString() ?? '',
      commentId: (j['comment_id'] as num?)?.toInt() ?? 0,
      content: j['content']?.toString() ?? '',
      isRead: isReadRaw == true || (isReadRaw as num?)?.toInt() == 1,
      createdAt: j['created_at']?.toString() ?? '',
      kind: j['kind']?.toString() ?? '',
      targetId: (j['target_id'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 消息服务：列表 / 已读 / 未读数
class MessagesService {
  MessagesService._();

  static final MessagesService instance = MessagesService._();

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

  /// 拉取消息列表（需登录）
  Future<({List<AppMessage> items, int unreadCount})> list({
    MessageType type = MessageType.all,
    int offset = 0,
    int limit = 20,
  }) async {
    if (!_loggedIn) {
      return (items: const <AppMessage>[], unreadCount: 0);
    }
    final response = await _dio.get<dynamic>(
      '$_baseUrl/api/messages/list',
      queryParameters: {
        'type': type.value,
        'offset': offset,
        'limit': limit,
      },
    );
    final raw = response.data;
    final data = raw is String
        ? (jsonDecode(raw) as Map).cast<String, dynamic>()
        : (raw as Map).cast<String, dynamic>();
    if (data['code'] != 0 || data['items'] is! List) {
      return (items: const <AppMessage>[], unreadCount: 0);
    }
    return (
      items: [
        for (final it in data['items'] as List)
          if (it is Map) AppMessage.fromJson(it.cast<String, dynamic>())
      ],
      unreadCount: (data['unread_count'] as num?)?.toInt() ?? 0,
    );
  }

  /// 标记已读（缺省全部）
  Future<void> markRead({int? id}) async {
    if (!_loggedIn) return;
    try {
      await _dio.post<dynamic>(
        '$_baseUrl/api/messages/read',
        data: {if (id != null) 'id': id},
      );
    } catch (_) {
      // 静默
    }
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

/// 消息类型 → 图标/文案辅助
String messageTypeLabel(String type) {
  switch (type) {
    case 'like':
      return '赞了你的评论';
    case 'reply':
      return '回复了你的评论';
    case 'mention':
      return '@了你';
    default:
      return '新消息';
  }
}