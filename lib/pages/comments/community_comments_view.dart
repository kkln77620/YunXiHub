import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:image_picker/image_picker.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/error_widget.dart';
import 'package:kazumi/bean/widget/image_preview.dart';
import 'package:kazumi/services/remote/auth_service.dart';
import 'package:kazumi/services/remote/community_comments_service.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// YunXiHub 社区评论视图（b 区）
///
/// 支持：游客浏览、登录发表（文字 + 图片 + 剧透标记）、点赞、回复（折叠）、
/// 更多（举报/删除）、四种排序、图片放大、剧透内容/图片遮挡、时间靠右。
class CommunityCommentsView extends StatefulWidget {
  const CommunityCommentsView({
    super.key,
    required this.kind,
    required this.targetId,
  });

  /// subject | episode | character
  final String kind;
  final int targetId;

  @override
  State<CommunityCommentsView> createState() => _CommunityCommentsViewState();
}

class _CommunityCommentsViewState extends State<CommunityCommentsView> {
  List<CommunityComment> _items = [];
  bool _loading = true;
  bool _error = false;
  CommunitySort _sort = CommunitySort.hotDesc;

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
    try {
      final result = await CommunityCommentsService.instance.list(
        kind: widget.kind,
        targetId: widget.targetId,
        sort: _sort,
      );
      if (!mounted) return;
      setState(() {
        _items = result.items;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _loading = false;
      });
    }
  }

  void _changeSort(CommunitySort sort) {
    if (_sort == sort) return;
    setState(() => _sort = sort);
    _load();
  }

  Future<void> _openComposer({int parentId = 0, String? replyTo}) async {
    final loggedIn =
        GStorage.getSetting(SettingsKeys.authToken).trim().isNotEmpty;
    if (!loggedIn) {
      KazumiDialog.showToast(message: '请先登录账号');
      await context.pushNamed('/settings/account/');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CommentComposerSheet(
        kind: widget.kind,
        targetId: widget.targetId,
        parentId: parentId,
        replyTo: replyTo,
        onPosted: _load,
      ),
    );
  }

  Future<void> _openReplies(CommunityComment comment) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _RepliesPage(
          kind: widget.kind,
          targetId: widget.targetId,
          parent: comment,
        ),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        // 排序栏
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            children: [
              Text(
                '社区评论',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              PopupMenuButton<CommunitySort>(
                initialValue: _sort,
                tooltip: '排序',
                icon: const Icon(Icons.sort_rounded, size: 20),
                onSelected: _changeSort,
                itemBuilder: (_) => [
                  for (final s in CommunitySort.values)
                    PopupMenuItem(value: s, child: Text(s.label)),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error
                  ? Center(
                      child: GeneralErrorWidget(
                        errMsg: '社区评论加载失败',
                        actions: [
                          GeneralErrorButton(text: '重试', onPressed: _load),
                        ],
                      ),
                    )
                  : _items.isEmpty
                      ? const Center(
                          child: Text('还没有社区评论，来抢沙发吧 (´▽`)'),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                          itemCount: _items.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final comment = _items[index];
                            return _CommunityCommentTile(
                              key: ValueKey(comment.id),
                              comment: comment,
                              kind: widget.kind,
                              targetId: widget.targetId,
                              onChanged: _load,
                              onReply: () => _openComposer(
                                parentId: comment.id,
                                replyTo: comment.nickname,
                              ),
                              onOpenReplies: () => _openReplies(comment),
                            );
                          },
                        ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton.icon(
              onPressed: () => _openComposer(),
              icon: const Icon(Icons.edit_rounded),
              label: const Text('写评论'),
            ),
          ),
        ),
      ],
    );
  }
}

/// 单条社区评论（含折叠回复区）
class _CommunityCommentTile extends StatefulWidget {
  const _CommunityCommentTile({
    super.key,
    required this.comment,
    required this.kind,
    required this.targetId,
    required this.onChanged,
    required this.onReply,
    required this.onOpenReplies,
  });

  final CommunityComment comment;
  final String kind;
  final int targetId;
  final VoidCallback onChanged;
  final VoidCallback onReply;
  final VoidCallback onOpenReplies;

  @override
  State<_CommunityCommentTile> createState() => _CommunityCommentTileState();
}

class _CommunityCommentTileState extends State<_CommunityCommentTile> {
  /// 本地可变副本（点赞乐观更新用）
  late CommunityComment _comment;

  /// 折叠展示的回复（热度前3）
  List<CommunityComment> _replies = [];
  bool _repliesLoaded = false;
  int _totalReplies = 0;

  bool get _isMine =>
      _comment.userId > 0 && _comment.userId == AuthService.instance.userId;

  bool get _canDelete => _isMine || AuthService.instance.isAdmin;

  @override
  void initState() {
    super.initState();
    _comment = widget.comment;
    _loadReplies();
  }

  @override
  void didUpdateWidget(covariant _CommunityCommentTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.comment.id != widget.comment.id ||
        oldWidget.comment.likeCount != widget.comment.likeCount ||
        oldWidget.comment.likedByMe != widget.comment.likedByMe) {
      _comment = widget.comment;
    }
  }

  Future<void> _loadReplies() async {
    if (_repliesLoaded) return;
    try {
      final result = await CommunityCommentsService.instance.list(
        kind: widget.kind,
        targetId: widget.targetId,
        parentId: widget.comment.id,
        sort: CommunitySort.hotDesc,
        limit: 3,
      );
      if (!mounted) return;
      setState(() {
        _replies = result.items;
        _totalReplies = result.total;
        _repliesLoaded = true;
      });
    } catch (_) {
      // 回复加载失败静默
    }
  }

  Future<void> _toggleLike() async {
    final loggedIn =
        GStorage.getSetting(SettingsKeys.authToken).trim().isNotEmpty;
    if (!loggedIn) {
      KazumiDialog.showToast(message: '请先登录账号');
      return;
    }
    final old = _comment;
    setState(() {
      _comment = old.copyWith(
        likedByMe: !old.likedByMe,
        likeCount: old.likeCount + (old.likedByMe ? -1 : 1),
      );
    });
    try {
      final result = await CommunityCommentsService.instance.like(old.id);
      if (!mounted) return;
      setState(() {
        _comment = old.copyWith(
          likedByMe: result.liked,
          likeCount: result.likeCount,
        );
      });
    } catch (e) {
      if (!mounted) return;
      // 失败回滚
      setState(() {
        _comment = old;
      });
      KazumiDialog.showToast(message: e.toString());
    }
  }

  Future<void> _showMoreMenu() async {
    final loggedIn =
        GStorage.getSetting(SettingsKeys.authToken).trim().isNotEmpty;
    if (!loggedIn) {
      KazumiDialog.showToast(message: '请先登录账号');
      return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.report_gmailerrorred_rounded),
              title: const Text('举报评论'),
              onTap: () => Navigator.of(sheetContext).pop('report'),
            ),
            if (_canDelete)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('删除评论'),
                onTap: () => Navigator.of(sheetContext).pop('delete'),
              ),
            ListTile(
              leading: const Icon(Icons.close_rounded),
              title: const Text('取消'),
              onTap: () => Navigator.of(sheetContext).pop(),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'report') {
      await _confirmAndReport();
    } else if (action == 'delete') {
      await _confirmAndDelete();
    }
  }

  Future<void> _confirmAndReport() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('举报评论'),
        content: const Text('确认举报这条评论？我们会尽快处理。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('举报'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await CommunityCommentsService.instance.report(_comment.id);
      if (!mounted) return;
      KazumiDialog.showToast(message: '举报成功，我们会尽快处理');
    } catch (e) {
      if (!mounted) return;
      KazumiDialog.showToast(message: e.toString());
    }
  }

  Future<void> _confirmAndDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除评论'),
        content: const Text('删除后不可恢复，确认删除？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await CommunityCommentsService.instance.delete(_comment.id);
      if (!mounted) return;
      KazumiDialog.showToast(message: '已删除');
      widget.onChanged();
    } catch (e) {
      if (!mounted) return;
      KazumiDialog.showToast(message: e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final comment = _comment;
    final displayName = comment.nickname.isEmpty ? '游客' : comment.nickname;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头像 + 昵称 + 标识 + 时间（靠右）
          Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: colorScheme.surfaceContainerHighest,
                backgroundImage: comment.avatar.isNotEmpty
                    ? NetworkImage(
                        CommunityCommentsService.instance
                            .resolveUrl(comment.avatar))
                    : null,
                child: comment.avatar.isEmpty
                    ? const Icon(Icons.person_rounded, size: 16)
                    : null,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  displayName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_isMine) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '我',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
              if (comment.isSponsor) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '赞助用户',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              Text(
                comment.createdAt.length >= 16
                    ? comment.createdAt.substring(5, 16)
                    : comment.createdAt,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // 内容（剧透遮挡，含图片）
          if (comment.spoiler)
            _SpoilerContent(comment: comment)
          else ...[
            Text(comment.content),
            if (comment.images.isNotEmpty) ...[
              const SizedBox(height: 8),
              _CommentImages(images: comment.images),
            ],
          ],
          const SizedBox(height: 6),
          // 操作行：点赞 / 回复 / 更多
          Row(
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: _toggleLike,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        comment.likedByMe
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 18,
                        color: comment.likedByMe
                            ? colorScheme.error
                            : colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${comment.likeCount}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: comment.likedByMe
                              ? colorScheme.error
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: widget.onReply,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.chat_bubble_outline_rounded,
                        size: 18,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '回复',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.more_horiz_rounded, size: 20),
                color: colorScheme.onSurfaceVariant,
                onPressed: _showMoreMenu,
              ),
            ],
          ),
          // 折叠回复区（最多显示热度前3）
          if (_repliesLoaded && (_replies.isNotEmpty || _totalReplies > 0)) ...[
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final reply in _replies) ...[
                    _ReplyLine(comment: reply, onTap: widget.onOpenReplies),
                    if (reply != _replies.last)
                      const SizedBox(height: 4),
                  ],
                  if (_totalReplies > _replies.length)
                    InkWell(
                      onTap: widget.onOpenReplies,
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          '查看全部 $_totalReplies 条回复',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 折叠区里的一行回复
class _ReplyLine extends StatelessWidget {
  const _ReplyLine({required this.comment, required this.onTap});

  final CommunityComment comment;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final name = comment.nickname.isEmpty ? '游客' : comment.nickname;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '$name：',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              TextSpan(
                text: comment.content,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurface,
                ),
              ),
            ],
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/// 评论图片（点击放大；剧透时不展示）
class _CommentImages extends StatelessWidget {
  const _CommentImages({required this.images});

  final List<String> images;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final urls = [
      for (final img in images)
        CommunityCommentsService.instance.resolveUrl(img)
    ];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < urls.length; i++)
          GestureDetector(
            onTap: () => ImageViewer.show(
              context,
              imageUrls: urls,
              initialIndex: i,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                urls[i],
                width: 100,
                height: 100,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  width: 100,
                  height: 100,
                  color: colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.broken_image_outlined),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 剧透内容：文字 + 图片整体遮挡，点击显示
class _SpoilerContent extends StatefulWidget {
  const _SpoilerContent({required this.comment});

  final CommunityComment comment;

  @override
  State<_SpoilerContent> createState() => _SpoilerContentState();
}

class _SpoilerContentState extends State<_SpoilerContent> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final comment = widget.comment;
    if (_revealed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(comment.content),
          if (comment.images.isNotEmpty) ...[
            const SizedBox(height: 8),
            _CommentImages(images: comment.images),
          ],
        ],
      );
    }
    return GestureDetector(
      onTap: () => setState(() => _revealed = true),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.visibility_off_rounded,
                size: 14, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              '剧透内容 · 点击查看${comment.images.isNotEmpty ? '（含图片）' : ''}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 回复二级页：主评论 + 全部回复（分页）
class _RepliesPage extends StatefulWidget {
  const _RepliesPage({
    required this.kind,
    required this.targetId,
    required this.parent,
  });

  final String kind;
  final int targetId;
  final CommunityComment parent;

  @override
  State<_RepliesPage> createState() => _RepliesPageState();
}

class _RepliesPageState extends State<_RepliesPage> {
  List<CommunityComment> _replies = [];
  bool _loading = true;
  bool _error = false;
  int _offset = 0;
  bool _hasMore = true;
  bool _loadingMore = false;

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
    try {
      final result = await CommunityCommentsService.instance.list(
        kind: widget.kind,
        targetId: widget.targetId,
        parentId: widget.parent.id,
        sort: CommunitySort.hotDesc,
        offset: 0,
        limit: 20,
      );
      if (!mounted) return;
      setState(() {
        _replies = result.items;
        _offset = result.items.length;
        _hasMore = result.items.length < result.total;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final result = await CommunityCommentsService.instance.list(
        kind: widget.kind,
        targetId: widget.targetId,
        parentId: widget.parent.id,
        sort: CommunitySort.hotDesc,
        offset: _offset,
        limit: 20,
      );
      if (!mounted) return;
      setState(() {
        _replies = [..._replies, ...result.items];
        _offset += result.items.length;
        _hasMore = _replies.length < result.total ||
            (result.items.length == 20);
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  Future<void> _openComposer({int parentId = 0, String? replyTo}) async {
    final loggedIn =
        GStorage.getSetting(SettingsKeys.authToken).trim().isNotEmpty;
    if (!loggedIn) {
      KazumiDialog.showToast(message: '请先登录账号');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CommentComposerSheet(
        kind: widget.kind,
        targetId: widget.targetId,
        parentId: parentId > 0 ? parentId : widget.parent.id,
        replyTo: replyTo,
        onPosted: _load,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('回复')),
      body: Column(
        children: [
          // 主评论置顶
          Container(
            width: double.infinity,
            color: colorScheme.surfaceContainerLow,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 12,
                      backgroundColor: colorScheme.surfaceContainerHighest,
                      backgroundImage: widget.parent.avatar.isNotEmpty
                          ? NetworkImage(
                              CommunityCommentsService.instance
                                  .resolveUrl(widget.parent.avatar))
                          : null,
                      child: widget.parent.avatar.isEmpty
                          ? const Icon(Icons.person_rounded, size: 14)
                          : null,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        widget.parent.nickname.isEmpty
                            ? '游客'
                            : widget.parent.nickname,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (widget.parent.isSponsor) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '赞助用户',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    Text(
                      widget.parent.createdAt.length >= 16
                          ? widget.parent.createdAt.substring(5, 16)
                          : widget.parent.createdAt,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(widget.parent.content),
                if (widget.parent.images.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _CommentImages(images: widget.parent.images),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('回复加载失败'),
                            const SizedBox(height: 8),
                            FilledButton.tonal(
                              onPressed: _load,
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      )
                    : _replies.isEmpty
                        ? const Center(child: Text('还没有回复'))
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            itemCount: _replies.length + (_hasMore ? 1 : 0),
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              if (index >= _replies.length) {
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 12),
                                  child: Center(
                                    child: _loadingMore
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child:
                                                CircularProgressIndicator(
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
                              return _ReplyTile(
                                comment: _replies[index],
                                kind: widget.kind,
                                targetId: widget.targetId,
                                onChanged: _load,
                                onReply: () => _openComposer(
                                  parentId: _replies[index].id,
                                  replyTo: _replies[index].nickname,
                                ),
                              );
                            },
                          ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton.icon(
                onPressed: () => _openComposer(),
                icon: const Icon(Icons.reply_rounded),
                label: const Text('回复'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 二级页里的一条回复
class _ReplyTile extends StatefulWidget {
  const _ReplyTile({
    required this.comment,
    required this.kind,
    required this.targetId,
    required this.onChanged,
    required this.onReply,
  });

  final CommunityComment comment;
  final String kind;
  final int targetId;
  final VoidCallback onChanged;
  final VoidCallback onReply;

  @override
  State<_ReplyTile> createState() => _ReplyTileState();
}

class _ReplyTileState extends State<_ReplyTile> {
  /// 本地可变副本（点赞乐观更新用）
  late CommunityComment _comment;

  bool get _isMine =>
      _comment.userId > 0 && _comment.userId == AuthService.instance.userId;

  bool get _canDelete => _isMine || AuthService.instance.isAdmin;

  @override
  void initState() {
    super.initState();
    _comment = widget.comment;
  }

  @override
  void didUpdateWidget(covariant _ReplyTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.comment.id != widget.comment.id ||
        oldWidget.comment.likeCount != widget.comment.likeCount ||
        oldWidget.comment.likedByMe != widget.comment.likedByMe) {
      _comment = widget.comment;
    }
  }

  Future<void> _toggleLike() async {
    final loggedIn =
        GStorage.getSetting(SettingsKeys.authToken).trim().isNotEmpty;
    if (!loggedIn) {
      KazumiDialog.showToast(message: '请先登录账号');
      return;
    }
    final old = _comment;
    setState(() {
      _comment = old.copyWith(
        likedByMe: !old.likedByMe,
        likeCount: old.likeCount + (old.likedByMe ? -1 : 1),
      );
    });
    try {
      final result = await CommunityCommentsService.instance.like(old.id);
      if (!mounted) return;
      setState(() {
        _comment = old.copyWith(
          likedByMe: result.liked,
          likeCount: result.likeCount,
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _comment = old);
      KazumiDialog.showToast(message: e.toString());
    }
  }

  Future<void> _showMoreMenu() async {
    final loggedIn =
        GStorage.getSetting(SettingsKeys.authToken).trim().isNotEmpty;
    if (!loggedIn) {
      KazumiDialog.showToast(message: '请先登录账号');
      return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.report_gmailerrorred_rounded),
              title: const Text('举报评论'),
              onTap: () => Navigator.of(sheetContext).pop('report'),
            ),
            if (_canDelete)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('删除评论'),
                onTap: () => Navigator.of(sheetContext).pop('delete'),
              ),
            ListTile(
              leading: const Icon(Icons.close_rounded),
              title: const Text('取消'),
              onTap: () => Navigator.of(sheetContext).pop(),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'report') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('举报评论'),
          content: const Text('确认举报这条回复？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('举报'),
            ),
          ],
        ),
      );
      if (ok == true && mounted) {
        try {
          await CommunityCommentsService.instance.report(_comment.id);
          if (mounted) KazumiDialog.showToast(message: '举报成功，我们会尽快处理');
        } catch (e) {
          if (mounted) KazumiDialog.showToast(message: e.toString());
        }
      }
    } else if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('删除回复'),
          content: const Text('删除后不可恢复，确认删除？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (ok == true && mounted) {
        try {
          await CommunityCommentsService.instance.delete(_comment.id);
          if (!mounted) return;
          KazumiDialog.showToast(message: '已删除');
          widget.onChanged();
        } catch (e) {
          if (mounted) KazumiDialog.showToast(message: e.toString());
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final comment = _comment;
    final name = comment.nickname.isEmpty ? '游客' : comment.nickname;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: colorScheme.surfaceContainerHighest,
            backgroundImage: comment.avatar.isNotEmpty
                ? NetworkImage(
                    CommunityCommentsService.instance.resolveUrl(comment.avatar))
                : null,
            child: comment.avatar.isEmpty
                ? const Icon(Icons.person_rounded, size: 14)
                : null,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
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
                    if (_isMine) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '我',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                    ],
                    if (comment.isSponsor) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '赞助用户',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(comment.content),
                if (comment.images.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _CommentImages(images: comment.images),
                ],
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      comment.createdAt.length >= 16
                          ? comment.createdAt.substring(5, 16)
                          : comment.createdAt,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 12),
                    InkWell(
                      onTap: _toggleLike,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              comment.likedByMe
                                  ? Icons.favorite_rounded
                                  : Icons.favorite_border_rounded,
                              size: 15,
                              color: comment.likedByMe
                                  ? colorScheme.error
                                  : colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '${comment.likeCount}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: comment.likedByMe
                                    ? colorScheme.error
                                    : colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: widget.onReply,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        child: Text(
                          '回复',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.more_horiz_rounded, size: 18),
            color: colorScheme.onSurfaceVariant,
            onPressed: _showMoreMenu,
          ),
        ],
      ),
    );
  }
}

/// 评论发布面板（文字 + 图片 + 剧透标记；支持回复）
class _CommentComposerSheet extends StatefulWidget {
  const _CommentComposerSheet({
    required this.kind,
    required this.targetId,
    required this.onPosted,
    this.parentId = 0,
    this.replyTo,
  });

  final String kind;
  final int targetId;
  final VoidCallback onPosted;
  final int parentId;
  final String? replyTo;

  @override
  State<_CommentComposerSheet> createState() => _CommentComposerSheetState();
}

class _CommentComposerSheetState extends State<_CommentComposerSheet> {
  final _controller = TextEditingController();
  final _picker = ImagePicker();
  final List<String> _localImages = [];
  bool _spoiler = false;
  bool _submitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickImages() async {
    if (_localImages.length >= 3) {
      KazumiDialog.showToast(message: '最多3张图片');
      return;
    }
    try {
      final files = await _picker.pickMultiImage(limit: 3 - _localImages.length);
      if (files.isEmpty) return;
      setState(() {
        _localImages.addAll(files.map((f) => f.path));
      });
    } catch (_) {
      KazumiDialog.showToast(message: '选择图片失败');
    }
  }

  Future<void> _submit() async {
    final content = _controller.text.trim();
    if (content.isEmpty && _localImages.isEmpty) {
      KazumiDialog.showToast(message: '写点什么吧');
      return;
    }
    setState(() => _submitting = true);
    try {
      final imageUrls = <String>[];
      for (final p in _localImages) {
        imageUrls.add(await AuthService.instance.uploadImage(p, use: 'comment'));
      }
      await CommunityCommentsService.instance.post(
        kind: widget.kind,
        targetId: widget.targetId,
        content: content,
        images: imageUrls,
        spoiler: _spoiler,
        parentId: widget.parentId,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onPosted();
      KazumiDialog.showToast(message: '评论成功');
    } catch (e) {
      if (!mounted) return;
      KazumiDialog.showToast(message: e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.parentId > 0
                ? '回复 ${widget.replyTo ?? ''}'
                : '发表评论',
            style: theme.textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            maxLines: 4,
            maxLength: 2000,
            decoration: const InputDecoration(
              hintText: '分享你的看法…',
              border: OutlineInputBorder(),
            ),
          ),
          if (_localImages.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final p in _localImages)
                  Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(
                          File(p),
                          width: 80,
                          height: 80,
                          fit: BoxFit.cover,
                        ),
                      ),
                      Positioned(
                        top: 2,
                        right: 2,
                        child: GestureDetector(
                          onTap: () => setState(
                              () => _localImages.remove(p)),
                          child: Container(
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.close,
                                size: 16, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _pickImages,
                icon: const Icon(Icons.image_rounded, size: 18),
                label: const Text('图片'),
              ),
              const SizedBox(width: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('剧透'),
                  Switch(
                    value: _spoiler,
                    onChanged: (v) => setState(() => _spoiler = v),
                  ),
                ],
              ),
              const Spacer(),
              FilledButton(
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('发布'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}