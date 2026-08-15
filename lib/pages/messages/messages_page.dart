import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/pages/comments/comment_jump_page.dart';
import 'package:kazumi/pages/friends/friends_page.dart';
import 'package:kazumi/pages/messages/chat_page.dart';
import 'package:kazumi/services/remote/auth_service.dart';
import 'package:kazumi/services/remote/messages_service.dart';

/// YunXiHub 消息中心 v3
///
/// - 顶部快捷按钮：点赞 / @我 / 回复 / 好友
/// - 平铺消息流：系统消息（最新一条）+ 好友私信会话
/// - 点击系统消息 → 系统消息列表；点击会话 → 私信聊天页（可回复）
class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key});

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  final Map<MessageType, List<AppMessage>> _cache = {};
  final Map<MessageType, bool> _loading = {};
  final Map<MessageType, bool> _error = {};
  int _unreadCount = 0;

  // v3 平铺流数据
  List<DmConversation> _convs = [];
  AppMessage? _sysLatest;
  int _sysUnread = 0;
  bool _streamLoading = true;
  bool _streamError = false;

  /// 已读水位是否已记录（进入消息页首次加载时记一次）
  bool _baselineSet = false;

  @override
  void initState() {
    super.initState();
    _ensureLoaded(MessageType.all);
    _loadStream();
  }

  Future<void> _ensureLoaded(MessageType type) async {
    if (_cache.containsKey(type) && !(_loading[type] ?? false)) return;
    setState(() {
      _loading[type] = true;
      _error[type] = false;
    });
    try {
      final result = await MessagesService.instance.list(type: type);
      if (!mounted) return;
      setState(() {
        _cache[type] = result.items;
        _unreadCount = result.unreadCount;
        _loading[type] = false;
      });
      if (!_baselineSet) {
        _baselineSet = true;
        MessagesService.viewedUnread = result.unreadCount;
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error[type] = true;
        _loading[type] = false;
      });
    }
  }

  /// 加载平铺流：系统消息最新一条 + 私信会话列表
  Future<void> _loadStream() async {
    setState(() {
      _streamLoading = true;
      _streamError = false;
    });
    try {
      final sys = await MessagesService.instance.systemMessages(limit: 1);
      final sysUnread = await MessagesService.instance
          .list(type: MessageType.system)
          .then((r) => r.unreadCount);
      final convs = await MessagesService.instance.conversations();
      if (!mounted) return;
      setState(() {
        _sysLatest = sys.isNotEmpty ? sys.first : null;
        _sysUnread = sysUnread;
        _convs = convs;
        _streamLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _streamError = true;
        _streamLoading = false;
      });
    }
  }

  Future<void> _refresh() async {
    _cache.clear();
    await Future.wait([_ensureLoaded(MessageType.all), _loadStream()]);
  }

  Future<void> _markAllRead() async {
    await MessagesService.instance.markRead();
    if (!mounted) return;
    setState(() {
      _unreadCount = 0;
      _sysUnread = 0;
      for (final type in MessageType.values) {
        final list = _cache[type];
        if (list != null) {
          _cache[type] = [
            for (final m in list)
              AppMessage(
                id: m.id,
                type: m.type,
                actorId: m.actorId,
                actorNickname: m.actorNickname,
                commentId: m.commentId,
                content: m.content,
                isRead: true,
                createdAt: m.createdAt,
                kind: m.kind,
                targetId: m.targetId,
              )
          ];
        }
      }
    });
    KazumiDialog.showToast(message: '已全部标记为已读');
  }

  /// 点击互动消息：标记已读 + 跳转评论区定位
  Future<void> _openMessage(AppMessage message, MessageType type) async {
    if (!message.isRead) {
      await MessagesService.instance.markRead(id: message.id);
      if (!mounted) return;
      setState(() {
        final target = _cache[type];
        if (target != null) {
          _cache[type] = [
            for (final m in target)
              m.id == message.id
                  ? AppMessage(
                      id: m.id,
                      type: m.type,
                      actorId: m.actorId,
                      actorNickname: m.actorNickname,
                      commentId: m.commentId,
                      content: m.content,
                      isRead: true,
                      createdAt: m.createdAt,
                      kind: m.kind,
                      targetId: m.targetId,
                    )
                  : m
          ];
        }
        if (_unreadCount > 0) _unreadCount -= 1;
      });
    }
    if (!mounted) return;
    final kind = message.kind.isEmpty ? 'subject' : message.kind;
    final targetId = message.targetId;
    if (targetId <= 0 || message.commentId <= 0) {
      KazumiDialog.showToast(message: '该消息关联的评论已被删除');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CommentJumpPage(
          kind: kind,
          targetId: targetId,
          commentId: message.commentId,
        ),
      ),
    );
  }

  Future<void> _openTypePage(MessageType type) async {
    await _ensureLoaded(type);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _MessageTypeListPage(
          type: type,
          initialItems: _cache[type] ?? const <AppMessage>[],
          onOpen: (m) => _openMessage(m, type),
        ),
      ),
    );
  }

  /// 系统消息列表二级页
  Future<void> _openSystemPage() async {
    if (_sysUnread > 0) {
      await MessagesService.instance.markRead();
      if (mounted) setState(() => _sysUnread = 0);
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const _SystemMessageListPage()),
    );
    _loadStream();
  }

  /// 私信聊天二级页
  Future<void> _openChat(DmConversation conv) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatPage(
          peerUid: conv.peerUid,
          peerNickname: conv.peerNickname,
          peerAvatar: conv.peerAvatar,
        ),
      ),
    );
    _loadStream();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('消息'),
        actions: [
          IconButton(
            tooltip: '全部已读',
            onPressed: (_unreadCount > 0 || _sysUnread > 0)
                ? _markAllRead
                : null,
            icon: const Icon(Icons.done_all_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          // 顶部快捷按钮：点赞 / @我 / 回复 / 好友
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                for (final type in [
                  MessageType.like,
                  MessageType.mention,
                  MessageType.reply,
                ]) ...[
                  Expanded(
                    child: _TypeButton(
                      type: type,
                      onTap: () => _openTypePage(type),
                    ),
                  ),
                  if (type != MessageType.reply) const SizedBox(width: 10),
                ],
                const SizedBox(width: 10),
                Expanded(
                  child: _TypeButton(
                    type: MessageType.friends,
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const FriendsPage(),
                        ),
                      );
                      _loadStream();
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(child: _buildStream()),
        ],
      ),
    );
  }

  /// 平铺消息流：系统消息 + 好友私信会话
  Widget _buildStream() {
    if (_streamLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_streamError) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('消息加载失败'),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: _loadStream,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final hasSys = _sysLatest != null || _sysUnread > 0;
    final loggedIn = AuthService.instance.isLoggedIn;
    if (!loggedIn) {
      return Center(
        child: Text(
          '登录后查看消息',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    if (!hasSys && _convs.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 120),
            Center(child: Text('暂无消息')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: (hasSys ? 1 : 0) + _convs.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
        itemBuilder: (context, index) {
          if (hasSys && index == 0) {
            return _SystemTile(
              latest: _sysLatest,
              unread: _sysUnread,
              onTap: _openSystemPage,
            );
          }
          final convIndex = hasSys ? index - 1 : index;
          final conv = _convs[convIndex];
          return _ConversationTile(
            conv: conv,
            onTap: () => _openChat(conv),
          );
        },
      ),
    );
  }
}

/// 系统消息条目（固定第一位）
class _SystemTile extends StatelessWidget {
  const _SystemTile({
    required this.latest,
    required this.unread,
    required this.onTap,
  });

  final AppMessage? latest;
  final int unread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: colorScheme.primaryContainer,
        child: Icon(
          Icons.campaign_rounded,
          color: colorScheme.onPrimaryContainer,
          size: 20,
        ),
      ),
      title: Row(
        children: [
          Text(
            '系统消息',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (unread > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: colorScheme.error,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                unread > 99 ? '99+' : '$unread',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.onError,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          latest == null
              ? '系统公告与通知'
              : (latest!.content.isEmpty ? '（无内容）' : latest!.content),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      trailing: Text(
        (latest?.createdAt ?? '').length >= 16
            ? latest!.createdAt.substring(5, 16)
            : '',
        style: theme.textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 好友私信会话条目
class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.conv, required this.onTap});

  final DmConversation conv;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final name = conv.peerNickname.isEmpty ? '用户' : conv.peerNickname;
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: colorScheme.surfaceContainerHighest,
        backgroundImage:
            conv.peerAvatar.isNotEmpty ? NetworkImage(conv.peerAvatar) : null,
        child: conv.peerAvatar.isEmpty
            ? Text(
                name.characters.first,
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              )
            : null,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              name,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (conv.peerLevel > 0) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'L${conv.peerLevel}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
          if (conv.isSponsor == 1) ...[
            const SizedBox(width: 6),
            Icon(Icons.workspace_premium_rounded,
                size: 15, color: colorScheme.tertiary),
          ],
          if (conv.unread > 0) ...[
            const SizedBox(width: 6),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: colorScheme.error,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          conv.lastContent.isEmpty ? '（暂无内容）' : conv.lastContent,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            conv.lastTime.length >= 16 ? conv.lastTime.substring(5, 16) : '',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (conv.unread > 0) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: colorScheme.error,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                conv.unread > 99 ? '99+' : '${conv.unread}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.onError,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 系统消息列表二级页
class _SystemMessageListPage extends StatefulWidget {
  const _SystemMessageListPage();

  @override
  State<_SystemMessageListPage> createState() => _SystemMessageListPageState();
}

class _SystemMessageListPageState extends State<_SystemMessageListPage> {
  List<AppMessage> _items = [];
  bool _loading = false;
  bool _hasMore = true;
  int _offset = 0;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    final items =
        await MessagesService.instance.systemMessages(offset: _offset);
    if (!mounted) return;
    setState(() {
      _items = [..._items, ...items];
      _offset = _items.length;
      _hasMore = items.length == 30;
      _loading = false;
    });
  }

  Future<void> _refresh() async {
    setState(() {
      _items = [];
      _offset = 0;
      _hasMore = true;
    });
    await _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('系统消息')),
      body: _items.isEmpty
          ? (_loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 120),
                      Center(child: Text('暂无系统消息')),
                    ],
                  ),
                ))
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: _items.length + (_hasMore ? 1 : 0),
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, indent: 72),
                itemBuilder: (context, index) {
                  if (index >= _items.length) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Center(
                        child: _loading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : TextButton(
                                onPressed: _loadMore,
                                child: const Text('加载更多'),
                              ),
                      ),
                    );
                  }
                  final m = _items[index];
                  return ListTile(
                    leading: CircleAvatar(
                      radius: 20,
                      backgroundColor: colorScheme.primaryContainer,
                      child: Icon(
                        Icons.campaign_rounded,
                        color: colorScheme.onPrimaryContainer,
                        size: 20,
                      ),
                    ),
                    title: Text(
                      '系统消息',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        m.content.isEmpty ? '（无内容）' : m.content,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    trailing: Text(
                      m.createdAt.length >= 16
                          ? m.createdAt.substring(5, 16)
                          : m.createdAt,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

/// 顶部类型快捷按钮（点赞 / @我 / 回复 / 好友）
class _TypeButton extends StatelessWidget {
  const _TypeButton({required this.type, required this.onTap});

  final MessageType type;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final IconData icon;
    switch (type) {
      case MessageType.like:
        icon = Icons.favorite_rounded;
        break;
      case MessageType.mention:
        icon = Icons.alternate_email_rounded;
        break;
      case MessageType.reply:
        icon = Icons.reply_rounded;
        break;
      case MessageType.friends:
        icon = Icons.group_rounded;
        break;
      default:
        icon = Icons.notifications_rounded;
    }
    final label = type == MessageType.friends ? '好友' : type.label;
    return Material(
      color: colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            children: [
              Icon(icon, color: colorScheme.primary, size: 22),
              const SizedBox(height: 4),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 互动消息类型二级页（点赞 / @我 / 回复 列表）
class _MessageTypeListPage extends StatefulWidget {
  const _MessageTypeListPage({
    required this.type,
    required this.initialItems,
    required this.onOpen,
  });

  final MessageType type;
  final List<AppMessage> initialItems;
  final void Function(AppMessage) onOpen;

  @override
  State<_MessageTypeListPage> createState() => _MessageTypeListPageState();
}

class _MessageTypeListPageState extends State<_MessageTypeListPage> {
  List<AppMessage> _items = [];
  bool _loading = false;
  bool _hasMore = true;
  int _offset = 0;

  @override
  void initState() {
    super.initState();
    _items = widget.initialItems;
    _offset = _items.length;
    if (_items.isEmpty) _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      final result = await MessagesService.instance.list(
        type: widget.type,
        offset: _offset,
        limit: 20,
      );
      if (!mounted) return;
      setState(() {
        _items = [..._items, ...result.items];
        _offset = _items.length;
        _hasMore = result.items.length == 20;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _items = [];
      _offset = 0;
      _hasMore = true;
    });
    await _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.type.label)),
      body: _items.isEmpty
          ? (_loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 120),
                      Center(child: Text('暂无消息')),
                    ],
                  ),
                ))
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: _items.length + (_hasMore ? 1 : 0),
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, indent: 72),
                itemBuilder: (context, index) {
                  if (index >= _items.length) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Center(
                        child: _loading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : TextButton(
                                onPressed: _loadMore,
                                child: const Text('加载更多'),
                              ),
                      ),
                    );
                  }
                  final message = _items[index];
                  return _MessageTile(
                    message: message,
                    onTap: () => widget.onOpen(message),
                  );
                },
              ),
            ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message, required this.onTap});

  final AppMessage message;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final typeLabel = messageTypeLabel(message.type);
    final displayName =
        message.actorNickname.isEmpty ? '用户' : message.actorNickname;
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: colorScheme.primaryContainer,
        child: Text(
          displayName.characters.first,
          style: TextStyle(
            color: colorScheme.onPrimaryContainer,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              displayName,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            typeLabel,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (!message.isRead) ...[
            const SizedBox(width: 6),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: colorScheme.error,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          message.content.isEmpty ? '（无内容）' : message.content,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: message.isRead
                ? colorScheme.onSurfaceVariant
                : colorScheme.onSurface,
          ),
        ),
      ),
      trailing: Text(
        message.createdAt.length >= 16
            ? message.createdAt.substring(5, 16)
            : message.createdAt,
        style: theme.textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}