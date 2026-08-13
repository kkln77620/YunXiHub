import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/pages/comments/comment_jump_page.dart';
import 'package:kazumi/services/remote/auth_service.dart';
import 'package:kazumi/services/remote/messages_service.dart';

/// YunXiHub 消息中心 v2
///
/// - 顶部三个快捷按钮（点赞 / @我 / 回复），点击进入对应类型二级页
/// - 下方为全部消息列表
/// - 点击消息 → 标记已读并跳转到评论区该评论位置（高亮定位）
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

  @override
  void initState() {
    super.initState();
    _ensureLoaded(MessageType.all);
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
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error[type] = true;
        _loading[type] = false;
      });
    }
  }

  Future<void> _refresh() async {
    _cache.clear();
    await _ensureLoaded(MessageType.all);
  }

  Future<void> _markAllRead() async {
    await MessagesService.instance.markRead();
    if (!mounted) return;
    setState(() {
      _unreadCount = 0;
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

  /// 点击消息：标记已读 + 跳转评论区定位
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
    if (mounted) _refresh();
  }

  Future<void> _openTypePage(MessageType type) async {
    // 二级页：先确保该类型已加载
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
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('消息'),
        actions: [
          IconButton(
            tooltip: '全部已读',
            onPressed: _unreadCount > 0 ? _markAllRead : null,
            icon: const Icon(Icons.done_all_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          // 顶部三个快捷按钮
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
              ],
            ),
          ),
          const SizedBox(height: 4),
          // 全部消息列表
          Expanded(child: _buildList(MessageType.all)),
        ],
      ),
    );
  }

  Widget _buildList(MessageType type) {
    final loading = _loading[type] ?? false;
    final error = _error[type] ?? false;
    final items = _cache[type];
    if (loading && items == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error && items == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('消息加载失败'),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () => _ensureLoaded(type),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final list = items ?? const <AppMessage>[];
    if (list.isEmpty) {
      return Center(
        child: Text(
          AuthService.instance.isLoggedIn ? '暂无消息' : '登录后查看消息',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: list.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
        itemBuilder: (context, index) => _MessageTile(
          message: list[index],
          onTap: () => _openMessage(list[index], type),
        ),
      ),
    );
  }
}

/// 顶部类型快捷按钮（点赞 / @我 / 回复）
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
      default:
        icon = Icons.notifications_rounded;
    }
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
                type.label,
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

/// 消息类型二级页（点赞 / @我 / 回复 列表）
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