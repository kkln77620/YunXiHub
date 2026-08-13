import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/remote/auth_service.dart';
import 'package:kazumi/services/remote/messages_service.dart';

/// YunXiHub 消息中心（点赞 / 回复 / @我）
class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key});

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final Map<MessageType, List<AppMessage>> _cache = {};
  final Map<MessageType, bool> _loading = {};
  final Map<MessageType, bool> _error = {};
  int _unreadCount = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: MessageType.values.length, vsync: this)
      ..addListener(() {
        if (!_tabController.indexIsChanging) return;
        _ensureLoaded(MessageType.values[_tabController.index]);
      });
    _ensureLoaded(MessageType.all);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _ensureLoaded(MessageType type) async {
    if (_cache.containsKey(type) && !_loading[type]!) return;
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
    await _ensureLoaded(MessageType.values[_tabController.index]);
    // 顺带刷新全部 tab 未读数
    try {
      final result = await MessagesService.instance.list(type: MessageType.all);
      if (mounted) setState(() => _unreadCount = result.unreadCount);
    } catch (_) {}
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
              )
          ];
        }
      }
    });
    KazumiDialog.showToast(message: '已全部标记为已读');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            for (final type in MessageType.values)
              Tab(text: type.label),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          for (final type in MessageType.values) _buildList(type),
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
          onTap: () async {
            if (!list[index].isRead) {
              await MessagesService.instance.markRead(id: list[index].id);
              if (mounted) {
                setState(() {
                  final target = _cache[type];
                  if (target != null) {
                    _cache[type] = [
                      for (final m in target)
                        m.id == list[index].id
                            ? AppMessage(
                                id: m.id,
                                type: m.type,
                                actorId: m.actorId,
                                actorNickname: m.actorNickname,
                                commentId: m.commentId,
                                content: m.content,
                                isRead: true,
                                createdAt: m.createdAt,
                              )
                            : m
                    ];
                  }
                  _unreadCount = (_unreadCount - 1).clamp(0, 1 << 31);
                });
              }
            }
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