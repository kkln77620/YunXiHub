import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/services/remote/dm_local_store.dart';
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

/// 公告条目
class AnnouncementItem {
  final int id;
  final String title;
  final String content;
  final String createdAt;

  const AnnouncementItem({
    required this.id,
    this.title = '',
    this.content = '',
    this.createdAt = '',
  });

  factory AnnouncementItem.fromJson(Map<String, dynamic> j) =>
      AnnouncementItem(
        id: (j['id'] as num?)?.toInt() ?? 0,
        title: j['title']?.toString() ?? '',
        content: j['content']?.toString() ?? '',
        createdAt: j['created_at']?.toString() ?? '',
      );
}

/// 转发队列消息（服务器只转发，不存储）
class DmRelayMessage {
  final String msgId;
  final int senderUid;
  final String senderNickname;
  final String content;
  final List<String> images;
  final String createdAt;

  const DmRelayMessage({
    required this.msgId,
    required this.senderUid,
    this.senderNickname = '',
    this.content = '',
    this.images = const [],
    this.createdAt = '',
  });

  factory DmRelayMessage.fromJson(Map<String, dynamic> j) {
    final imagesRaw = j['images'];
    return DmRelayMessage(
      msgId: j['msg_id']?.toString() ?? '',
      senderUid: (j['sender_uid'] as num?)?.toInt() ?? 0,
      senderNickname: j['sender_nickname']?.toString() ?? '',
      content: j['content']?.toString() ?? '',
      images: [
        for (final im in (imagesRaw is List ? imagesRaw : const []))
          im.toString()
      ],
      createdAt: j['created_at']?.toString() ?? '',
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'actor_id': actorId,
        'actor_nickname': actorNickname,
        'comment_id': commentId,
        'content': content,
        'images': images,
        'is_read': isRead ? 1 : 0,
        'created_at': createdAt,
        'kind': kind,
        'target_id': targetId,
      };
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

  /// 私信会话列表（**本地优先**：本地加密存储聚合；服务器仅作首次历史迁移）
  ///
  /// 首次（本地无任何会话）：拉服务器 conversations 一次性写入本地（迁移），
  /// 之后全部以本地为准（服务器不存储聊天记录）
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

  /// 私信会话列表：本地聚合为主
  Future<List<DmConversation>> conversations() async {
    if (!_loggedIn) return const <DmConversation>[];
    try {
      // 本地加密存储聚合（权威）
      final local = await DmLocalStore.instance.conversations();
      if (local.isNotEmpty) {
        // 本地昵称缺失时用服务器会话信息补全（仅补元数据，消息仍以本地为准）
        try {
          final remote = await _conversationsRemote();
          if (remote.isNotEmpty) {
            final byUid = {for (final c in remote) c.peerUid: c};
            final merged = <DmConversation>[];
            for (final c in local) {
              final r = byUid[c.peerUid];
              merged.add(r == null
                  ? c
                  : DmConversation(
                      peerUid: c.peerUid,
                      peerNickname:
                          c.peerNickname.isEmpty ? r.peerNickname : c.peerNickname,
                      peerAvatar: r.peerAvatar,
                      peerLevel: r.peerLevel,
                      isSponsor: r.isSponsor,
                      lastContent: c.lastContent,
                      lastTime: c.lastTime,
                      unread: 0,
                    ));
            }
            return merged;
          }
        } catch (_) {}
        return local;
      }
      // 首次迁移：服务器历史会话一次性导入本地
      final remote = await _conversationsRemote();
      if (remote.isNotEmpty) {
        for (final c in remote) {
          final items = await dmDetail(peerUid: c.peerUid, limit: 100);
          if (items.isNotEmpty) {
            await DmLocalStore.instance.importHistory(c.peerUid, items);
          }
        }
        return await DmLocalStore.instance.conversations();
      }
      return const <DmConversation>[];
    } catch (_) {
      return const <DmConversation>[];
    }
  }

  /// 服务器会话接口（仅首次迁移 / 补全元数据用）
  Future<List<DmConversation>> _conversationsRemote() async {
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

  /// 系统消息持久缓存（**不自动删除**；进入页面先显缓存，后台静默刷新）
  static const String sysCacheKey = 'system_messages_cache';

  static List<AppMessage> _sysCacheDisk() {
    try {
      final raw = GStorage.getSetting(sysCacheKey).toString();
      if (raw.isNotEmpty) {
        final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        return [
          for (final m in list) AppMessage.fromJson(m)
        ];
      }
    } catch (_) {}
    return const [];
  }

  static void _sysCacheSave(List<AppMessage> items) {
    try {
      GStorage.putSetting(sysCacheKey,
          jsonEncode([for (final m in items) m.toJson()]));
    } catch (_) {}
  }

  /// 系统消息列表（带磁盘缓存：先返回缓存，同时后台拉服务器刷新）
  Future<List<AppMessage>> cachedSystemMessages({int limit = 30}) async {
    if (!_loggedIn) return const <AppMessage>[];
    final cached = _sysCacheDisk();
    // 后台静默刷新（不阻塞）
    unawaited(_refreshSysCache(limit));
    if (cached.isNotEmpty) return cached.take(limit).toList();
    return _sysCacheDisk();
  }

  Future<void> _refreshSysCache(int limit) async {
    try {
      final items = await systemMessages(limit: limit);
      if (items.isNotEmpty) {
        // 与现有缓存去重合并（缓存最多 100 条）
        final merged = <int, AppMessage>{};
        for (final m in [..._sysCacheDisk(), ...items]) {
          merged[m.id] = m;
        }
        final list = merged.values.toList()
          ..sort((a, b) => b.id.compareTo(a.id));
        _sysCacheSave(list.take(100).toList());
      }
    } catch (_) {}
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
      final items = [
        for (final it in data['items'] as List)
          if (it is Map) AppMessage.fromJson(it.cast<String, dynamic>())
      ];
      if (offset == 0 && items.isNotEmpty) {
        _sysCacheSave(items);
      }
      return items;
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
  /// 服务器只转发（写入队列），返回 (错误信息?, msgId)
  Future<({String? err, String? msgId})> sendDm({
    required int toUid,
    required String content,
    List<String> images = const [],
  }) async {
    if (!_loggedIn) return (err: '未登录', msgId: null);
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
      if (data['code'] == 0) {
        return (err: null, msgId: data['msg_id']?.toString());
      }
      return (err: data['msg']?.toString() ?? '发送失败', msgId: null);
    } catch (_) {
      return (err: '网络异常，发送失败', msgId: null);
    }
  }

  /// 拉取公告列表（公开接口，无需登录）
  Future<List<AnnouncementItem>> announcements() async {
    try {
      final response = await _dio.get<dynamic>('$_baseUrl/api/announcements');
      final data = _decode(response.data);
      if (data['code'] != 0 || data['items'] is! List) {
        return const <AnnouncementItem>[];
      }
      return [
        for (final it in data['items'] as List)
          if (it is Map) AnnouncementItem.fromJson(it.cast<String, dynamic>())
      ];
    } catch (_) {
      return const <AnnouncementItem>[];
    }
  }

  /// 拉取转发队列（推送式）：有返回新消息，无则空列表（零打扰）
  /// [peerUid] 可选：只取某会话
  Future<List<DmRelayMessage>> pollDm({int? peerUid}) async {
    if (!_loggedIn) return const <DmRelayMessage>[];
    try {
      final response = await _dio.get<dynamic>(
        '$_baseUrl/api/messages/poll',
        queryParameters: {if (peerUid != null && peerUid > 0) 'peer_uid': peerUid},
      );
      final data = _decode(response.data);
      if (data['code'] != 0 || data['items'] is! List) {
        return const <DmRelayMessage>[];
      }
      return [
        for (final it in data['items'] as List)
          if (it is Map) DmRelayMessage.fromJson(it.cast<String, dynamic>())
      ];
    } catch (_) {
      return const <DmRelayMessage>[];
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