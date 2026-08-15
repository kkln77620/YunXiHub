import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/pages/messages/chat_page.dart';
import 'package:kazumi/services/remote/auth_service.dart';
import 'package:kazumi/services/remote/friends_service.dart';

/// 用户主页：资料 + 追番/历史（好友+对方开启才可见）+ 关系操作
class UserProfilePage extends StatefulWidget {
  const UserProfilePage({super.key, required this.uid});

  final int uid;

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  UserProfile? _profile;
  bool _loading = true;
  bool _error = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    final p = await FriendsService.instance.profile(widget.uid);
    if (!mounted) return;
    setState(() {
      _profile = p;
      _loading = false;
      _error = p == null;
    });
  }

  Future<void> _act(Future<String?> Function() fn, String okMsg) async {
    if (_busy) return;
    setState(() => _busy = true);
    final err = await fn();
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      KazumiDialog.showToast(message: err);
    } else {
      KazumiDialog.showToast(message: okMsg);
      await _load();
    }
  }

  void _openChat() {
    final p = _profile;
    if (p == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatPage(
          peerUid: p.uid,
          peerNickname: p.nickname.isEmpty ? '用户' : p.nickname,
          peerAvatar: p.avatar,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('用户主页')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('用户不存在或加载失败'),
                      const SizedBox(height: 8),
                      FilledButton.tonal(
                        onPressed: _load,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 32),
                    children: [
                      _buildHeader(theme, colorScheme),
                      const Divider(),
                      _buildRelationBar(theme, colorScheme),
                      const Divider(),
                      _sectionTitle('追番', _profile!.showCollect == 1),
                      ..._buildCollect(),
                      const Divider(),
                      _sectionTitle('观看历史', _profile!.showHistory == 1),
                      ..._buildHistory(),
                    ],
                  ),
                ),
    );
  }

  Widget _buildHeader(ThemeData theme, ColorScheme colorScheme) {
    final p = _profile!;
    final name = p.nickname.isEmpty ? '用户' : p.nickname;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Row(
        children: [
          CircleAvatar(
            radius: 34,
            backgroundColor: colorScheme.surfaceContainerHighest,
            backgroundImage: p.avatar.isNotEmpty ? NetworkImage(p.avatar) : null,
            child: p.avatar.isEmpty
                ? Icon(Icons.person_rounded,
                    size: 36, color: colorScheme.onSurfaceVariant)
                : null,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (p.isAdmin == 1) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.admin_panel_settings_rounded,
                          size: 18, color: colorScheme.primary),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (p.level > 0) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          'L${p.level}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    if (p.isSponsor > 0) ...[
                      Icon(Icons.workspace_premium_rounded,
                          size: 16, color: colorScheme.tertiary),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      'UID ${p.uid}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                if (p.createdAt.length >= 10)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      '加入于 ${p.createdAt.substring(0, 10)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 关系操作栏
  Widget _buildRelationBar(ThemeData theme, ColorScheme colorScheme) {
    final p = _profile!;
    if (p.isSelf == 1) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(
          '这是你的主页',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final Widget action;
    switch (p.relation) {
      case 1:
        action = Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : _openChat,
                icon: const Icon(Icons.chat_rounded, size: 18),
                label: const Text('发私信'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _act(
                        () => FriendsService.instance.remove(p.uid), '已删除好友'),
                icon: const Icon(Icons.person_remove_rounded, size: 18),
                label: const Text('删除好友'),
              ),
            ),
          ],
        );
        break;
      case 2:
        action = OutlinedButton.icon(
          onPressed: null,
          icon: const Icon(Icons.hourglass_top_rounded, size: 18),
          label: const Text('等待对方验证'),
        );
        break;
      case 3:
        action = Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => _act(
                        () => FriendsService.instance.accept(p.uid), '已添加好友'),
                icon: const Icon(Icons.person_add_rounded, size: 18),
                label: const Text('同意申请'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _act(
                        () => FriendsService.instance.reject(p.uid), '已拒绝'),
                icon: const Icon(Icons.person_off_rounded, size: 18),
                label: const Text('拒绝'),
              ),
            ),
          ],
        );
        break;
      case 4:
        action = OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => _act(
                  () => FriendsService.instance.request(p.uid), '好友申请已发送'),
          icon: const Icon(Icons.person_add_rounded, size: 18),
          label: const Text('重新申请'),
        );
        break;
      default:
        action = FilledButton.icon(
          onPressed: _busy
              ? null
              : () => _act(
                  () => FriendsService.instance.request(p.uid), '好友申请已发送'),
          icon: const Icon(Icons.person_add_rounded, size: 18),
          label: const Text('加好友'),
        );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: SizedBox(width: double.infinity, child: action),
    );
  }

  Widget _sectionTitle(String title, bool visible) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    if (!visible) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Text(
          '$title未公开',
          style: theme.textTheme.labelMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.labelMedium?.copyWith(
          color: colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  List<Widget> _buildCollect() {
    final p = _profile!;
    if (p.showCollect != 1) return const [];
    if (p.collect.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '暂无追番',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ];
    }
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in p.collect.take(30))
              Chip(
                label: Text(
                  c['name']?.toString() ?? '未知番剧',
                  style: const TextStyle(fontSize: 12),
                ),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _buildHistory() {
    final p = _profile!;
    if (p.showHistory != 1) return const [];
    if (p.history.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '暂无观看记录',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ];
    }
    return [
      for (final h in p.history.take(30))
        ListTile(
          dense: true,
          leading: Icon(
            Icons.play_circle_outline_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: Text(
            h['name']?.toString() ?? '未知番剧',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14),
          ),
          subtitle: Text(
            h['episode_name']?.toString().isNotEmpty == true
                ? '看到第 ${h['episode']} 话 · ${h['episode_name']}'
                : '看到第 ${h['episode']} 话',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
    ];
  }
}