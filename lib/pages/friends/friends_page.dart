import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/pages/friends/user_profile_page.dart';
import 'package:kazumi/services/remote/friends_service.dart';
import 'package:kazumi/utils/image_url.dart';

/// 好友列表页：好友 / 待处理申请（同意/拒绝）
class FriendsPage extends StatefulWidget {
  const FriendsPage({super.key});

  @override
  State<FriendsPage> createState() => _FriendsPageState();
}

class _FriendsPageState extends State<FriendsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);
  FriendListResult? _result;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    final r = await FriendsService.instance.list();
    if (!mounted) return;
    setState(() {
      _result = r;
      _loading = false;
    });
  }

  Future<void> _act(Future<String?> Function() fn, String okMsg) async {
    final err = await fn();
    if (!mounted) return;
    if (err != null) {
      KazumiDialog.showToast(message: err);
    } else {
      KazumiDialog.showToast(message: okMsg);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final result = _result;
    return Scaffold(
      appBar: AppBar(
        title: const Text('好友'),
        bottom: TabBar(
          controller: _tab,
          tabs: [
            Tab(text: '好友 ${result?.friends.length ?? ''}'),
            Tab(text: '申请 ${(result?.requestsIn.length ?? 0) + (result?.requestsOut.length ?? 0)}'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('加载失败'),
                      const SizedBox(height: 8),
                      FilledButton.tonal(
                        onPressed: _load,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : TabBarView(
                  controller: _tab,
                  children: [
                    _FriendList(
                      friends: result?.friends ?? const [],
                      onTap: (f) => _openProfile(f.uid),
                      onRemove: (f) => _confirmRemove(f),
                      onRefresh: _load,
                    ),
                    _RequestList(
                      requestsIn: result?.requestsIn ?? const [],
                      requestsOut: result?.requestsOut ?? const [],
                      onAccept: (f) => _act(
                          () => FriendsService.instance.accept(f.uid), '已添加好友'),
                      onReject: (f) => _act(
                          () => FriendsService.instance.reject(f.uid), '已拒绝'),
                      onTap: (f) => _openProfile(f.uid),
                    ),
                  ],
                ),
    );
  }

  void _openProfile(int uid) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => UserProfilePage(uid: uid)),
    );
    _load();
  }

  void _confirmRemove(FriendBrief f) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除好友'),
        content: Text('确定删除好友「${f.nickname}」吗？删除后对方无法查看你的追番与历史。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              '取消',
              style: TextStyle(color: Theme.of(ctx).colorScheme.outline),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _act(() => FriendsService.instance.remove(f.uid), '已删除好友');
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}

/// 好友列表
class _FriendList extends StatelessWidget {
  const _FriendList({
    required this.friends,
    required this.onTap,
    required this.onRemove,
    required this.onRefresh,
  });

  final List<FriendBrief> friends;
  final void Function(FriendBrief) onTap;
  final void Function(FriendBrief) onRemove;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    if (friends.isEmpty) {
      return Center(
        child: Text(
          '还没有好友，去评论区点头像加好友吧',
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: friends.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
        itemBuilder: (context, index) {
          final f = friends[index];
          final name = f.nickname.isEmpty ? '用户' : f.nickname;
          return ListTile(
            onTap: () => onTap(f),
            leading: CircleAvatar(
              radius: 20,
              backgroundColor: colorScheme.surfaceContainerHighest,
              backgroundImage: f.avatar.isNotEmpty
                  ? NetworkImage(resolveImageUrl(f.avatar))
                  : null,
              child: f.avatar.isEmpty
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
                if (f.level > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'L${f.level}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                ],
                if (f.isSponsor == 1) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.workspace_premium_rounded,
                      size: 15, color: colorScheme.tertiary),
                ],
              ],
            ),
            subtitle: Text(
              'UID ${f.uid} · ${f.createdAt.length >= 10 ? f.createdAt.substring(0, 10) : ''}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            trailing: IconButton(
              tooltip: '删除好友',
              icon: Icon(Icons.person_remove_rounded,
                  color: colorScheme.onSurfaceVariant),
              onPressed: () => onRemove(f),
            ),
          );
        },
      ),
    );
  }
}

/// 申请列表（待我处理 + 我发出的）
class _RequestList extends StatelessWidget {
  const _RequestList({
    required this.requestsIn,
    required this.requestsOut,
    required this.onAccept,
    required this.onReject,
    required this.onTap,
  });

  final List<FriendBrief> requestsIn;
  final List<FriendBrief> requestsOut;
  final void Function(FriendBrief) onAccept;
  final void Function(FriendBrief) onReject;
  final void Function(FriendBrief) onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    if (requestsIn.isEmpty && requestsOut.isEmpty) {
      return Center(
        child: Text(
          '暂无好友申请',
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (requestsIn.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              '待处理',
              style: theme.textTheme.labelMedium?.copyWith(
                color: colorScheme.primary,
              ),
            ),
          ),
          for (final f in requestsIn) _requestTile(context, f, incoming: true),
        ],
        if (requestsOut.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '我发出的',
              style: theme.textTheme.labelMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final f in requestsOut) _requestTile(context, f, incoming: false),
        ],
      ],
    );
  }

  Widget _requestTile(BuildContext context, FriendBrief f,
      {required bool incoming}) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final name = f.nickname.isEmpty ? '用户' : f.nickname;
    return ListTile(
      onTap: () => onTap(f),
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: colorScheme.surfaceContainerHighest,
        backgroundImage: f.avatar.isNotEmpty
            ? NetworkImage(resolveImageUrl(f.avatar))
            : null,
        child: f.avatar.isEmpty
            ? Text(
                name.characters.first,
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              )
            : null,
      ),
      title: Text(
        name,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        'UID ${f.uid}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: incoming
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => onReject(f),
                  child: Text(
                    '拒绝',
                    style: TextStyle(color: colorScheme.outline),
                  ),
                ),
                FilledButton(
                  onPressed: () => onAccept(f),
                  child: const Text('同意'),
                ),
              ],
            )
          : Text(
              '等待验证',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
    );
  }
}