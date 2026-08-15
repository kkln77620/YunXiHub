import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:kazumi/pages/friends/user_profile_page.dart';
import 'package:kazumi/services/remote/auth_service.dart';
import 'package:kazumi/services/remote/messages_service.dart';
import 'package:kazumi/utils/image_url.dart';

/// 私信聊天页：与好友的一对一对话（气泡布局，底部输入框）
/// - 每 2 秒静默轮询新消息（不打扰、不转圈）
/// - 点击对方头像 → 打开好友主页
/// - 支持发送图片（最多 3 张，服务器校验 24 小时注册限制）
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
  List<AppMessage> _messages = [];
  bool _loading = true;
  bool _sending = false;
  Timer? _pollTimer;
  bool _polling = false;

  int get _myId => AuthService.instance.userId;

  @override
  void initState() {
    super.initState();
    _load();
    // 每 2 秒静默轮询新消息
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _silentPoll());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await MessagesService.instance
        .dmDetail(peerUid: widget.peerUid, limit: 100);
    if (!mounted) return;
    // 服务器返回最新在前，反转成旧→新（最新在底部）
    setState(() {
      _messages = items.reversed.toList();
      _loading = false;
    });
    _scrollToBottom();
  }

  /// 静默轮询：拉取最新消息，只追加新条目（无 UI 打扰）
  Future<void> _silentPoll() async {
    if (_polling || !mounted) return;
    _polling = true;
    try {
      final items = await MessagesService.instance
          .dmDetail(peerUid: widget.peerUid, limit: 20);
      if (!mounted) return;
      final have = _messages.map((m) => m.id).toSet();
      final fresh = items.reversed.where((m) => !have.contains(m)).toList();
      if (fresh.isNotEmpty) {
        setState(() => _messages = [..._messages, ...fresh]);
        _scrollToBottom();
      }
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

  /// 选择并上传图片（压缩），返回服务器图片地址
  Future<String?> _pickAndUploadImage() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      if (picked == null) return null;
      final url = await AuthService.instance
          .uploadImage(picked.path, use: 'comment');
      return url;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('图片上传失败: $e'), duration: const Duration(seconds: 2)),
        );
      }
      return null;
    }
  }

  Future<void> _send({List<String> images = const []}) async {
    final text = _input.text.trim();
    if ((text.isEmpty && images.isEmpty) || _sending) return;
    setState(() => _sending = true);
    final err = await MessagesService.instance.sendDm(
      toUid: widget.peerUid,
      content: text,
      images: images,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err), duration: const Duration(seconds: 2)),
      );
      return;
    }
    setState(() {
      _messages.add(AppMessage(
        id: 0,
        type: 'dm',
        actorId: _myId,
        actorNickname: AuthService.instance.nickname,
        commentId: 0,
        content: text,
        images: images,
        isRead: true,
        createdAt: _nowText(),
      ));
      _input.clear();
    });
    MessagesService.instance.clearConversationCache();
    _scrollToBottom();
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
                          final mine = m.actorId == _myId && _myId > 0;
                          return _Bubble(
                            mine: mine,
                            avatar: mine ? '' : widget.peerAvatar,
                            nickname: mine ? '' : widget.peerNickname,
                            content: m.content,
                            images: m.images,
                            time: m.createdAt,
                            onAvatarTap: mine
                                ? null
                                : () => _openPeerProfile(),
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
              backgroundImage:
                  avatar.isNotEmpty ? NetworkImage(resolveImageUrl(avatar)) : null,
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