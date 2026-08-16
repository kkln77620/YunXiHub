import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/services/remote/auth_service.dart';
import 'package:kazumi/services/remote/messages_service.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 本地私信消息（服务器不存聊天记录，完全本地加密存储）
class DmMessage {
  final String msgId; // 唯一标识（本地时间戳 / 服务器消息 id 迁移为 h<id>）
  final int peerUid; // 对方 uid
  final bool mine; // 是否我发出
  final String peerNickname; // 对方昵称（快照）
  final String content;
  final List<String> images;
  final String createdAt;
  final bool sent; // 发送状态：true=已送达，false=待重发/失败

  const DmMessage({
    required this.msgId,
    required this.peerUid,
    required this.mine,
    this.peerNickname = '',
    this.content = '',
    this.images = const [],
    this.createdAt = '',
    this.sent = true,
  });

  Map<String, dynamic> toJson() => {
        'msgId': msgId,
        'peerUid': peerUid,
        'mine': mine ? 1 : 0,
        'peerNickname': peerNickname,
        'content': content,
        'images': images,
        'createdAt': createdAt,
        'sent': sent ? 1 : 0,
      };

  factory DmMessage.fromJson(Map<String, dynamic> j) => DmMessage(
        msgId: j['msgId']?.toString() ?? '',
        peerUid: (j['peerUid'] as num?)?.toInt() ?? 0,
        mine: (j['mine'] as num?)?.toInt() == 1,
        peerNickname: j['peerNickname']?.toString() ?? '',
        content: j['content']?.toString() ?? '',
        images: [
          for (final im in (j['images'] is List ? j['images'] as List : const []))
            im.toString()
        ],
        createdAt: j['createdAt']?.toString() ?? '',
        sent: (j['sent'] as num?)?.toInt() == 1,
      );

  /// 本地去重键：服务器历史消息用 h<id>，转发消息用 msgId
  String get dedupKey => msgId;
}

/// 私信本地加密存储（hive_ce + AES）
///
/// - 密钥 = SHA-256(登录 token)，按账号隔离（重新登录后各自独立）
/// - 结构：box['convs'] = { 'peerUid': [消息JSON...] }
/// - 不自动删除：消息与权益缓存一样长期保留，仅在退出登录时可选清空
class DmLocalStore {
  DmLocalStore._();

  static final DmLocalStore instance = DmLocalStore._();

  Box? _box;
  String _keyTag = '';

  Future<Box> _open() async {
    final token = GStorage.getSetting(SettingsKeys.authToken).trim();
    final tag = token.isEmpty ? 'guest' : token;
    if (_box != null && _keyTag == tag) return _box!;
    _keyTag = tag;
    if (token.isEmpty) {
      _box = await Hive.openBox('dm_guest');
      return _box!;
    }
    final digest = sha256.convert(utf8.encode(tag));
    final key = Uint8List.fromList(digest.bytes);
    final boxName = 'dm_' + digest.toString().substring(0, 16);
    // 加密打开（数据落盘为密文）
    _box = await Hive.openBox(boxName, encryptionCipher: AesCipher(key));
    return _box!;
  }

  Map<String, dynamic>? _convsOf(Box box) {
    final raw = box.get('convs');
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }
    return null;
  }

  /// 追加一条消息（按 peer 分组，增量写回）
  Future<void> append(DmMessage m) async {
    if (m.peerUid <= 0) return;
    final box = await _open();
    final convs = _convsOf(box) ?? <String, dynamic>{};
    final key = m.peerUid.toString();
    final list = [
      for (final it in (convs[key] is List ? convs[key] as List : const []))
        if (it is Map) DmMessage.fromJson(it.cast<String, dynamic>())
    ];
    list.removeWhere((e) => e.dedupKey == m.dedupKey);
    list.add(m);
    convs[key] = [for (final e in list) e.toJson()];
    await box.put('convs', convs);
  }

  /// 读取某会话全部消息（旧→新）
  Future<List<DmMessage>> messages(int peerUid) async {
    final box = await _open();
    final convs = _convsOf(box);
    if (convs == null) return const [];
    final list = convs[peerUid.toString()];
    if (list is! List) return const [];
    final out = <DmMessage>[];
    for (final it in list) {
      if (it is Map) {
        try {
          out.add(DmMessage.fromJson(it.cast<String, dynamic>()));
        } catch (_) {}
      }
    }
    out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return out;
  }

  /// 本地会话聚合（peerUid → 最后一条消息/昵称）
  Future<List<DmConversation>> conversations() async {
    final box = await _open();
    final convs = _convsOf(box);
    if (convs == null) return const [];
    final result = <DmConversation>[];
    for (final entry in convs.entries) {
      final peerUid = int.tryParse(entry.key) ?? 0;
      if (peerUid <= 0) continue;
      final list = entry.value;
      if (list is! List || list.isEmpty) continue;
      DmMessage? last;
      String? nick;
      for (final it in list) {
        if (it is! Map) continue;
        try {
          final m = DmMessage.fromJson(it.cast<String, dynamic>());
          if (last == null || m.createdAt.compareTo(last!.createdAt) >= 0) {
            last = m;
          }
          if (m.peerNickname.isNotEmpty) nick = m.peerNickname;
        } catch (_) {}
      }
      if (last == null) continue;
      result.add(DmConversation(
        peerUid: peerUid,
        peerNickname: nick ?? '',
        lastContent: last.content.isEmpty && last.images.isNotEmpty
            ? '[图片]'
            : last.content,
        lastTime: last.createdAt,
        unread: 0, // 私信无已读机制
      ));
    }
    result.sort((a, b) => b.lastTime.compareTo(a.lastTime));
    return result;
  }

  /// 迁移服务器历史（仅首次：本地无数据时一次性拉取写入）
  Future<void> importHistory(int peerUid, List<AppMessage> items) async {
    final box = await _open();
    final convs = _convsOf(box) ?? <String, dynamic>{};
    final key = peerUid.toString();
    final list = [
      for (final it in (convs[key] is List ? convs[key] as List : const []))
        if (it is Map) DmMessage.fromJson(it.cast<String, dynamic>())
    ];
    final have = list.map((e) => e.dedupKey).toSet();
    for (final m in items) {
      final msgId = 'h${m.id}';
      if (have.contains(msgId)) continue;
      list.add(DmMessage(
        msgId: msgId,
        peerUid: peerUid,
        mine: m.actorId == AuthService.instance.userId,
        peerNickname: m.actorNickname,
        content: m.content,
        images: m.images,
        createdAt: m.createdAt,
        sent: true,
      ));
    }
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    convs[key] = [for (final e in list) e.toJson()];
    await box.put('convs', convs);
  }

  /// 是否有本地数据
  Future<bool> hasAny() async {
    final box = await _open();
    final convs = _convsOf(box);
    if (convs == null || convs.isEmpty) return false;
    return convs.values.any((v) => v is List && v.isNotEmpty);
  }

  /// 退出登录时清空当前账号本地私信
  Future<void> clearAll() async {
    try {
      final box = await _open();
      await box.delete('convs');
    } catch (_) {}
  }
}
