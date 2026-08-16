import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:kazumi/pages/friends/user_profile_page.dart';
import 'package:kazumi/services/remote/auth_service.dart';
import 'package:kazumi/services/remote/dm_local_store.dart';
import 'package:kazumi/services/remote/entitlements_service.dart';
import 'package:kazumi/services/remote/messages_service.dart';
import 'package:kazumi/utils/image_url.dart';

/// 私信聊天页：与好友的一对一对话（气泡布局，底部输入框）
///
/// 架构（服务器不存聊天记录）：
/// - 消息**完全本地加密存储**（DmLocalStore），服务器只做转发
/// - 每 2 秒推送式轮询：有新消息 → **增量追加**（只加新 msgId，不动旧内容）
/// - 无新消息 → 零 UI 更新（不打扰）
/// - 点击对方头像 → 打开好友主页
/// - 发图片：本地先校验权益（注册满24h/张数），通过才上传
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.peerUid,
    required this.peerNickname,
    required this.peerAvatar,
  });

  final int peerUid;
  final String peerNickname;
  final String peerAvatar;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  List<DmMessage> _messages = [];
  bool _loading = true;
  bool _sending = false;
  Timer? _pollTimer;
  bool _polling = false;

  int get _myId => AuthService.instance.userId;

  @override
  void initState() {
    super.initState();
    _load();
    // 每 2 秒推送式轮询（有新消息才加载，无则零打扰）
    _pollTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _silentPoll());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 首次加载：本地秒显（加密存储读取）→ 本地空时从服务器迁移历史
  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      var items = await DmLocalStore.instance.messages(widget.peerUid);
      if (items.isEmpty) {
        // 首次迁移服务器历史（一次性写入本地，之后不再请求）
        final remote = await MessagesService.instance
            .dmDetail(peerUid: widget.peerUid, limit: 100);
        if (remote.isNotEmpty) {
          await DmLocalStore.instance.importHistory(widget.peerUid, remote);
          items = await DmLocalStore.instance.messages(widget.peerUid);
        }
      }
      if (!mounted) return;
      setState(() {
        _messages = items;
        _loading = false;
      });
      _scrollToBottom();
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// 推送式轮询：只有新消息才加载（增量追加到本地 + UI），无则不动
  Future<void> _silentPoll() async {
    if (_polling || !mounted) return;
    _polling = true;
    try {
      final relay =
          await MessagesService.instance.pollDm(peerUid: widget.peerUid);
      if (relay.isEmpty || !mounted) return; // 无新消息：零 UI 更新
      final have = _messages.map((m) => m.dedupKey).toSet();
      final fresh = <DmMessage>[];
      for (final r in relay) {
        if (have.contains(r.msgId)) continue;
        fresh.add(DmMessage(
          msgId: r.msgId,
          peerUid: widget.peerUid,
          mine: false,
          peerNickname: r.senderNickname.isEmpty
              ? widget.peerNickname
              : r.senderNickname,
          content: r.content,
          images: r.images,
          createdAt: r.createdAt,
          sent: true,
        ));
      }
      if (fresh.isEmpty) return; // 全是已见过的：不更新
      for (final m in fresh) {
        await DmLocalStore.instance.append(m); // 落本地加密存储
      }
      if (!mounted) return;
      setState(() => _messages = [..._messages, ...fresh]); // 增量追加
      _scrollToBottom();
      MessagesService.instance.clearConversationCache();
    } catch (_) {
      // 静默失败
    } finally {
      _polling = false;
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  /// 选择并上传图片（压缩）：**先本地校验权益**（注册满24h/张数）再上传
  Future<String?> _pickAndUploadImage() async {
    final ent = EntitlementsService.current;
    if (!ent.dmImageEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('注册满 ${ent.dmImageRegHours} 小时后可发送图片'),
        duration: const Duration(seconds: 2),
      ));
      return null;
    }
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      if (picked == null) return null;
      final url =
          await AuthService.instance.uploadImage(picked.path, use: 'comment');
      return url;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('图片上传失败: $e'),
              duration: const Duration(seconds: 2)),
        );
      }
      return null;
    }
  }

  Future<void> _send({List<String> images = const []}) async {
    final text = _input.text.trim();
    if ((text.isEmpty && images.isEmpty) || _sending) return;
    setState(() => _sending = true);
    // 本地先落一条（乐观显示），发送失败也保留本地记录
    final local = DmMessage(
      msgId: 'l${DateTime.now().microsecondsSinceEpoch}',
      peerUid: widget.peerUid,
      mine: true,
      peerNickname: widget.peerNickname,
      content: text,
      images: images,
      createdAt: _nowText(),
      sent: true,
    );
    await DmLocalStore.instance.append(local);
    if (mounted) {
      setState(() {
        _messages = [..._messages, local];
        _input.clear();
      });
      _scrollToBottom();
    }
    MessagesService.instance.clearConversationCache();
    final result = await MessagesService.instance.sendDm(
      toUid: widget.peerUid,
      content: text,
      images: images,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (result.err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(result.err!), duration: const Duration(seconds: 2)),
      );
    }
  }

  String _nowText() {
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${p(n.month)}-${p(n.day)} ${p(n.hour)}:${p(n.minute)}:${p(n.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.peerNickname)),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? Center(
                        child: Text(
                          '还没有消息，打个招呼吧',
                          style: TextStyle(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(12),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final m = _messages[index];
                          final mine = m.mine;
                          return _Bubble(
                            mine: mine,
                            avatar: mine ? '' : widget.peerAvatar,
                            nickname: mine ? '' : widget.peerNickname,
                            content: m.content,
                            images: m.images,
                            time: m.createdAt,
                            onAvatarTap:
                                mine ? null : () => _openPeerProfile(),
                          );
                        },
                      ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerLow,
                border: Border(
                  top: BorderSide(color: colorScheme.outlineVariant),
                ),
              ),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '发送图片',
                    onPressed: _sending ? null : _pickAndSendImage,
                    icon: const Icon(Icons.image_rounded),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: '发送给 ${widget.peerNickname}...',
                        isDense: true,
                        filled: true,
                        fillColor: colorScheme.surface,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : () => _send(),
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded, size: 20),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndSendImage() async {
    final url = await _pickAndUploadImage();
    if (url == null || !mounted) return;
    await _send(images: [url]);
  }

  void _openPeerProfile() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserProfilePage(uid: widget.peerUid),
      ),
    );
  }
}

/// 聊天气泡
class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.mine,
    required this.avatar,
    required this.nickname,
    required this.content,
    required this.time,
    this.images = const [],
    this.onAvatarTap,
  });

  final bool mine;
  final String avatar;
  final String nickname;
  final String content;
  final String time;
  final List<String> images;
  final VoidCallback? onAvatarTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final timeText = time.length >= 16 ? time.substring(11, 16) : '';
    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.68,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: mine ? colorScheme.primary : colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(14),
          topRight: const Radius.circular(14),
          bottomLeft: Radius.circular(mine ? 14 : 4),
          bottomRight: Radius.circular(mine ? 4 : 14),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (images.isNotEmpty) ...[
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final img in images.take(3))
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      resolveImageUrl(img),
                      width: 140,
                      height: 140,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 140,
                        height: 140,
                        color: colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.broken_image_rounded),
                      ),
                    ),
                  ),
              ],
            ),
            if (content.isNotEmpty) const SizedBox(height: 6),
          ],
          if (content.isNotEmpty)
            Text(
              content,
              style: TextStyle(
                color: mine ? colorScheme.onPrimary : colorScheme.onSurface,
              ),
            ),
          if (timeText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                timeText,
                style: TextStyle(
                  fontSize: 10,
                  color: mine
                      ? colorScheme.onPrimary.withOpacity(0.7)
                      : colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );

    if (mine) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [bubble],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          GestureDetector(
            onTap: onAvatarTap,
            child: CircleAvatar(
              radius: 16,
              backgroundColor: colorScheme.surfaceContainerHighest,
              backgroundImage: avatar.isNotEmpty
                  ? NetworkImage(resolveImageUrl(avatar))
                  : null,
              child: avatar.isEmpty
                  ? Icon(Icons.person_rounded,
                      size: 18, color: colorScheme.onSurfaceVariant)
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (nickname.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3, left: 2),
                  child: Text(
                    nickname,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              bubble,
            ],
          ),
        ],
      ),
    );
  }
}