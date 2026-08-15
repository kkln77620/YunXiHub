import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 消息类型
enum MessageType {
  all('all', '全部'),
  like('like', '点赞'),
  reply('reply', '回复'),
  mention('mention', '@我'),
  system('system', '系统消息'),
  friends('friends', '好友');

  const MessageType(this.value, this.label);

  final String value;
  final String label;
}

/// 私信会话（按对方聚合）
class DmConversation {
  final int peerUid;
  final String peerNickname;
  final String peerAvatar;
  final int peerLevel;
  final int isSponsor;
  final String lastContent;
  final String lastTime;
  final int unread;

  const DmConversation({
    required this.peerUid,
    required this.peerNickname,
    required this.peerAvatar,
    this.peerLevel = 0,
    this.isSponsor = 0,
    this.lastContent = '',
    this.lastTime = '',
    this.unread = 0,
  });

  factory DmConversation.fromJson(Map<String, dynamic> j) {
    return DmConversation(
      peerUid: (j['peer_uid'] as num?)?.toInt() ?? 0,
      peerNickname: j['peer_nickname']?.toString() ?? '',
      peerAvatar: j['peer_avatar']?.toString() ?? '',
      peerLevel: (j['peer_level'] as num?)?.toInt() ?? 0,
      isSponsor: (j['is_sponsor'] as num?)?.toInt() ?? 0,
      lastContent: j['last_content']?.toString() ?? '',
      lastTime: j['last_time']?.toString() ?? '',
      unread: (j['unread'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 站内消息条目
class AppMessage {
  final int id;
  final String type; // like | reply | mention
  final int actorId;
  final String actorNickname;
  final int commentId;
  final String content;
  final List<String> images; // 私信图片（dm）
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
    this.images = const [],
    this.kind = '',
    this.targetId = 0,
  });

  factory AppMessage.fromJson(Map<String, dynamic> j) {
    final isReadRaw = j['is_read'];
    final imagesRaw = j['images'];
    return AppMessage(
      id: (j['id'] as num?)?.toInt() ?? 0,
      type: j['type']?.toString() ?? 'like',
      actorId: (j['actor_id'] as num?)?.toInt() ?? 0,
      actorNickname: j['actor_nickname']?.toString() ?? '',
      commentId: (j['comment_id'] as num?)?.toInt() ?? 0,
      content: j['content']?.toString() ?? '',
      images: [
        for (final im in (imagesRaw is List ? imagesRaw : const []))
          im.toString()
      ],
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

  /// 账号数据变更通知（兑换码/登录/登出后触发，主页用于立即刷新未读徽章）
  static void Function()? onDataChanged;

  /// 已读水位：进入消息页时记录的服务器未读数。
  /// 主页图标显示 `服务器未读 - 水位`（看完消息后图标数字消失，
  /// 但消息列表内未读红点保留；新消息到达后数字重新出现）。
  static int viewedUnread = 0;

  /// 主页图标应显示的未读数
  static int badgeUnread(int serverUnread) {
    final v = serverUnread - viewedUnread;
    return v < 0 ? 0 : v;
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

  /// 私信会话列表（带 5 分钟内存缓存：进入消息页不重复加载）
  static List<DmConversation>? _convsCache;
  static DateTime? _convsCacheAt;

  Future<List<DmConversation>> cachedConversations() async {
    final cache = _convsCache;
    final at = _convsCacheAt;
    if (cache != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 5)) {
      return cache;
    }
    final convs = await conversations();
    _convsCache = convs;
    _convsCacheAt = DateTime.now();
    return convs;
  }

  /// 清空会话缓存（发私信/加好友后调用）
  void clearConversationCache() {
    _convsCache = null;
    _convsCacheAt = null;
  }

  /// 私信会话列表
  Future<List<DmConversation>> conversations() async {
    if (!_loggedIn) return const <DmConversation>[];
    try {
      final response = await _dio.get<dynamic>(
        '$_baseUrl/api/messages/conversations',
      );
      final data = _decode(response.data);
      if (data['code'] != 0 || data['items'] is! List) {
        return const <DmConversation>[];
      }
      return [
        for (final it in data['items'] as List)
          if (it is Map) DmConversation.fromJson(it.cast<String, dynamic>())
      ];
    } catch (_) {
      return const <DmConversation>[];
    }
  }

  /// 系统消息列表
  Future<List<AppMessage>> systemMessages({
    int offset = 0,
    int limit = 30,
  }) async {
    if (!_loggedIn) return const <AppMessage>[];
    try {
      final response = await _dio.get<dynamic>(
        '$_baseUrl/api/messages/detail',
        queryParameters: {'type': 'system', 'offset': offset, 'limit': limit},
      );
      final data = _decode(response.data);
      if (data['code'] != 0 || data['items'] is! List) {
        return const <AppMessage>[];
      }
      return [
        for (final it in data['items'] as List)
          if (it is Map) AppMessage.fromJson(it.cast<String, dynamic>())
      ];
    } catch (_) {
      return const <AppMessage>[];
    }
  }

  /// 与某人的私信聊天记录
  Future<List<AppMessage>> dmDetail({
    required int peerUid,
    int offset = 0,
    int limit = 50,
  }) async {
    if (!_loggedIn) return const <AppMessage>[];
    try {
      final response = await _dio.get<dynamic>(
        '$_baseUrl/api/messages/detail',
        queryParameters: {
          'peer_uid': peerUid,
          'offset': offset,
          'limit': limit,
        },
      );
      final data = _decode(response.data);
      if (data['code'] != 0 || data['items'] is! List) {
        return const <AppMessage>[];
      }
      return [
        for (final it in data['items'] as List)
          if (it is Map) AppMessage.fromJson(it.cast<String, dynamic>())
      ];
    } catch (_) {
      return const <AppMessage>[];
    }
  }

  /// 发送私信（仅好友；images 为已上传的图片地址列表，最多3张）
  Future<String?> sendDm({
    required int toUid,
    required String content,
    List<String> images = const [],
  }) async {
    if (!_loggedIn) return '未登录';
    try {
      final response = await _dio.post<dynamic>(
        '$_baseUrl/api/messages/send',
        data: {
          'to_uid': toUid,
          'content': content,
          if (images.isNotEmpty) 'images': images,
        },
      );
      final data = _decode(response.data);
      if (data['code'] == 0) return null;
      return data['msg']?.toString() ?? '发送失败';
    } catch (_) {
      return '网络异常，发送失败';
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