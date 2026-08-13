import 'dart:io';
import 'dart:ui' show ImageFilter;

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
/// v3 特性：
/// - 一级评论缓存：切换界面不重复请求；退出视频页 / 下拉刷新 / 排序切换才重新加载
/// - 一级列表统一分页加载（每次 20 条）
/// - 回复随主评论一并返回；B 被 C 回复时折叠区直接显示（@B 昵称）
/// - 二级页**内联展开**（对齐原版卡片风格，不弹窗）：B 转 A 展示 + C 列表，
///   C 有回复时可再内联展开（循环二级页）
/// - 主评论无"查看详情"按钮；折叠区回复行 / 二级页 C 行按需展开
/// - 剧透：内容前端已加载，文字/图片高度模糊展示（非隐藏），
///   点击整个模糊区立即清晰显示（无需重新加载）；模糊时图片不可点开原图
/// - 剧透展开状态页面级持久（滚动不丢）
/// - 评论显示头衔（管理员 / 赞助用户）
class CommunityCommentsView extends StatefulWidget {
  const CommunityCommentsView({
    super.key,
    required this.kind,
    required this.targetId,
    this.highlightCommentId,
    this.autoOpenRepliesCommentId,
  });

  /// subject | episode | character
  final String kind;
  final int targetId;

  /// 定位高亮（消息跳转用），加载后滚动到该评论并高亮（只执行一次）
  final int? highlightCommentId;

  /// 目标评论是回复时：加载后自动内联展开其所属主评论的二级页
  final int? autoOpenRepliesCommentId;

  @override
  State<CommunityCommentsView> createState() => _CommunityCommentsViewState();
}

class _CommunityCommentsViewState extends State<CommunityCommentsView> {
  List<CommunityComment> _items = [];
  bool _loading = true;
  bool _error = false;
  String _errorMsg = '';
  CommunitySort _sort = CommunitySort.hotDesc;
  int _total = 0;
  bool _hasMore = true;
  bool _loadingMore = false;

  /// 剧透展开状态（commentId → 已显示），页面级持久，滚动重建不丢失
  final Map<int, bool> _revealedSpoilers = {};

  /// 当前内联展开的二级页主评论 id（null = 全部收起）
  int? _expandedCommentId;

  /// 定位是否已执行（消息跳转只定位一次，避免退出二级页后循环）
  bool _highlightResolved = false;

  int? _highlightId;

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // 缓存优先：直接展示，不发请求
    final cached =
        CommunityCommentsService.cached(widget.kind, widget.targetId, _sort);
    if (cached != null) {
      _items = cached.items;
      _total = cached.total;
      _hasMore = cached.items.length < cached.total;
      _loading = false;
      _locateHighlight();
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 消息跳转定位：滚动到目标评论并高亮（仅首次）
  void _locateHighlight() {
    if (_highlightResolved) return;
    _highlightResolved = true;
    final targetId = widget.highlightCommentId;
    if (targetId == null || _items.isEmpty) return;
    var index = _items.indexWhere((c) => c.id == targetId);
    if (index >= 0) {
      _scrollToHighlight(index);
      return;
    }
    // 目标是回复：找到所属主评论，滚动高亮并自动内联展开其二级页
    for (var i = 0; i < _items.length; i++) {
      final parent = _items[i];
      if (parent.replies.any((r) => r.id == targetId) ||
          parent.id == widget.autoOpenRepliesCommentId) {
        _scrollToHighlight(i);
        setState(() => _expandedCommentId = parent.id);
        return;
      }
    }
  }

  void _scrollToHighlight(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scrollController.hasClients) {
        final max = _scrollController.position.maxScrollExtent;
        final target = (index * 140.0).clamp(0.0, max);
        _scrollController.jumpTo(target);
      }
      setState(() => _highlightId = widget.highlightCommentId);
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && _highlightId != null) {
          setState(() => _highlightId = null);
        }
      });
    });
  }

  Future<void> _load({bool refresh = false}) async {
    if (!refresh && !_loading) {
      final cached = CommunityCommentsService.cached(
          widget.kind, widget.targetId, _sort);
      if (cached != null) {
        if (mounted) {
          setState(() {
            _items = cached.items;
            _total = cached.total;
            _hasMore = cached.items.length < cached.total;
            _loading = false;
          });
          _locateHighlight();
        }
        return;
      }
    }
    setState(() {
      if (refresh) _loading = true;
      _error = false;
      _errorMsg = '';
    });
    try {
      final result = await CommunityCommentsService.instance.list(
        kind: widget.kind,
        targetId: widget.targetId,
        sort: _sort,
        offset: 0,
        limit: 20,
      );
      if (!mounted) return;
      setState(() {
        _items = result.items;
        _total = result.total;
        _hasMore = result.items.length < result.total;
        _loading = false;
      });
      _locateHighlight();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _errorMsg = e.toString();
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
        sort: _sort,
        offset: _items.length,
        limit: 20,
      );
      if (!mounted) return;
      setState(() {
        _items = [..._items, ...result.items];
        _total = result.total;
        _hasMore = _items.length < result.total;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  /// 主动刷新：清缓存 + 重新拉取
  Future<void> _refresh() async {
    CommunityCommentsService.clearCache(
        kind: widget.kind, targetId: widget.targetId);
    await _load(refresh: true);
  }

  void _changeSort(CommunitySort sort) {
    if (_sort == sort) return;
    setState(() => _sort = sort);
    CommunityCommentsService.clearCache(
        kind: widget.kind, targetId: widget.targetId);
    _load(refresh: true);
  }

  /// 发表/回复成功回调：清缓存并重载（二级页内变更也走这里）
  Future<void> _onPosted() async {
    CommunityCommentsService.clearCache(
        kind: widget.kind, targetId: widget.targetId);
    await _load(refresh: true);
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
        onPosted: _onPosted,
      ),
    );
  }

  /// 内联展开/收起二级页
  void _toggleExpand(int commentId) {
    setState(() {
      _expandedCommentId =
          _expandedCommentId == commentId ? null : commentId;
    });
  }

  /// 剧透点击：立即显示（内容已在前端，无需重新加载）
  void _toggleSpoiler(int commentId, bool revealed) {
    setState(() {
      _revealedSpoilers[commentId] = revealed;
    });
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
                '社区评论${_total > 0 ? '（$_total）' : ''}',
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
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GeneralErrorWidget(
                              errMsg: '社区评论加载失败',
                              actions: [
                                GeneralErrorButton(
                                    text: '重试', onPressed: _refresh),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _errorMsg,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : _items.isEmpty
                      ? RefreshIndicator(
                          onRefresh: _refresh,
                          child: ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: const [
                              SizedBox(height: 120),
                              Center(
                                child: Text('还没有社区评论，来抢沙发吧 (´▽`)'),
                              ),
                            ],
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _refresh,
                          child: ListView.separated(
                            controller: _scrollController,
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                            itemCount: _items.length + (_hasMore ? 1 : 0),
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              if (index >= _items.length) {
                                return Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
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
                              final comment = _items[index];
                              return _CommunityCommentTile(
                                key: ValueKey(comment.id),
                                comment: comment,
                                kind: widget.kind,
                                targetId: widget.targetId,
                                highlight: _highlightId == comment.id,
                                revealedSpoiler:
                                    _revealedSpoilers[comment.id] ?? false,
                                onToggleSpoiler: (r) =>
                                    _toggleSpoiler(comment.id, r),
                                revealedSpoilers: _revealedSpoilers,
                                expanded: _expandedCommentId == comment.id,
                                onToggleExpand: () =>
                                    _toggleExpand(comment.id),
                                onChanged: _onPosted,
                                onReply: () => _openComposer(
                                  parentId: comment.id,
                                  replyTo: comment.nickname,
                                ),
                              );
                            },
                          ),
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

/// 头衔徽标（管理员 / 赞助用户）
class _TitleBadge extends StatelessWidget {
  const _TitleBadge({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final Color bg;
    final Color fg;
    switch (title) {
      case '管理员':
        bg = const Color(0xFF7B1E1E);
        fg = const Color(0xFFFFD7A0);
        break;
      case '赞助用户':
        bg = colorScheme.primaryContainer;
        fg = colorScheme.onPrimaryContainer;
        break;
      default:
        bg = colorScheme.surfaceContainerHighest;
        fg = colorScheme.onSurfaceVariant;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

/// 单条社区评论（含折叠回复区 + 可内联展开的二级页）
class _CommunityCommentTile extends StatefulWidget {
  const _CommunityCommentTile({
    super.key,
    required this.comment,
    required this.kind,
    required this.targetId,
    required this.onChanged,
    required this.onReply,
    required this.revealedSpoiler,
    required this.onToggleSpoiler,
    required this.revealedSpoilers,
    required this.expanded,
    required this.onToggleExpand,
    this.highlight = false,
  });

  final CommunityComment comment;
  final String kind;
  final int targetId;
  final VoidCallback onChanged;
  final VoidCallback onReply;
  final bool revealedSpoiler;
  final ValueChanged<bool> onToggleSpoiler;
  final Map<int, bool> revealedSpoilers;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final bool highlight;

  @override
  State<_CommunityCommentTile> createState() => _CommunityCommentTileState();
}

class _CommunityCommentTileState extends State<_CommunityCommentTile> {
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
  void didUpdateWidget(covariant _CommunityCommentTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.comment.id != widget.comment.id ||
        oldWidget.comment.likeCount != widget.comment.likeCount ||
        oldWidget.comment.likedByMe != widget.comment.likedByMe ||
        oldWidget.comment.replies != widget.comment.replies) {
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
    final replies = comment.replies;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 600),
      decoration: widget.highlight
          ? BoxDecoration(
              color: colorScheme.primary.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
            )
          : null,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头像 + 昵称 + 头衔 + 时间（靠右）
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
              if (comment.title.isNotEmpty) ...[
                const SizedBox(width: 6),
                _TitleBadge(title: comment.title),
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
          // 内容（剧透模糊，含图片）
          if (comment.spoiler)
            _SpoilerContent(
              comment: comment,
              revealed: widget.revealedSpoiler,
              onReveal: () => widget.onToggleSpoiler(true),
            )
          else ...[
            Text(comment.content),
            if (comment.images.isNotEmpty) ...[
              const SizedBox(height: 8),
              _CommentImages(images: comment.images),
            ],
          ],
          const SizedBox(height: 6),
          // 操作行：点赞 / 回复 / 更多（无"查看详情"）
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
          // 折叠回复区（回复随主评论返回；B 被 C 回复时 C 显示 @B）
          if (replies.isNotEmpty || comment.replyCount > 0) ...[
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
                  for (final reply in replies) ...[
                    _ReplyLine(
                      comment: reply,
                      onTap: widget.onToggleExpand,
                    ),
                    if (reply != replies.last) const SizedBox(height: 4),
                  ],
                  if (comment.replyCount > replies.length)
                    InkWell(
                      onTap: widget.onToggleExpand,
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          widget.expanded
                              ? '收起回复'
                              : '查看全部 ${comment.replyCount} 条回复',
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
          // 内联二级页（B 转 A + C 列表；仅展开时显示，不弹窗）
          if (widget.expanded) ...[
            const SizedBox(height: 4),
            _InlineReplies(
              key: ValueKey('inline-${comment.id}'),
              kind: widget.kind,
              targetId: widget.targetId,
              parent: comment,
              revealedSpoilers: widget.revealedSpoilers,
              onToggleSpoiler: (id, r) => widget.onToggleSpoiler(r),
              onChanged: widget.onChanged,
            ),
          ],
        ],
      ),
    );
  }
}

/// 折叠区里的一行回复（B / C：C 显示为 "@B昵称 消息"）
class _ReplyLine extends StatelessWidget {
  const _ReplyLine({required this.comment, required this.onTap});

  final CommunityComment comment;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final name = comment.nickname.isEmpty ? '游客' : comment.nickname;
    final parentName =
        comment.parentNickname.isEmpty ? '' : comment.parentNickname;
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
              if (parentName.isNotEmpty)
                TextSpan(
                  text: '@$parentName ',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
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

/// 评论图片（点击放大；剧透模糊时 enabled=false 禁止点开原图）
class _CommentImages extends StatelessWidget {
  const _CommentImages({required this.images, this.enabled = true});

  final List<String> images;
  final bool enabled;

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
            onTap: enabled
                ? () => ImageViewer.show(
                      context,
                      imageUrls: urls,
                      initialIndex: i,
                    )
                : null,
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

/// 剧透内容：前端已加载，仅模糊展示；点击**整个模糊区**立即清晰（无需重新加载）
class _SpoilerContent extends StatelessWidget {
  const _SpoilerContent({
    required this.comment,
    required this.revealed,
    required this.onReveal,
  });

  final CommunityComment comment;
  final bool revealed;
  final VoidCallback onReveal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    if (revealed) {
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
    // 整个模糊区可点击（含文字 + 图片区域），点击立即显示
    return GestureDetector(
      onTap: onReveal,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.visibility_off_rounded,
                    size: 14, color: colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  '剧透内容 · 点击查看',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (comment.content.isNotEmpty) ...[
              const SizedBox(height: 6),
              // 文字高度模糊（可见轮廓不可读）
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                child: Text(
                  comment.content,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
            if (comment.images.isNotEmpty) ...[
              const SizedBox(height: 6),
              // 图片高度模糊 + 禁止点击原图
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 9, sigmaY: 9),
                child: _CommentImages(images: comment.images, enabled: false),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 内联二级页：B 转为主评论置顶，C 们作为回复列表（带 @B 昵称）
/// 在评论卡片内就地展开（对齐原版评论卡片风格），支持循环嵌套
class _InlineReplies extends StatefulWidget {
  const _InlineReplies({
    super.key,
    required this.kind,
    required this.targetId,
    required this.parent,
    required this.revealedSpoilers,
    required this.onToggleSpoiler,
    required this.onChanged,
  });

  final String kind;
  final int targetId;
  final CommunityComment parent; // B（展开时转 A 置顶）
  final Map<int, bool> revealedSpoilers;
  final void Function(int commentId, bool revealed) onToggleSpoiler;
  final VoidCallback onChanged;

  @override
  State<_InlineReplies> createState() => _InlineRepliesState();
}

class _InlineRepliesState extends State<_InlineReplies> {
  List<CommunityComment> _replies = []; // C 们
  bool _loading = true;
  bool _error = false;
  int _total = 0;
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
        _total = result.total;
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
        offset: _replies.length,
        limit: 20,
      );
      if (!mounted) return;
      setState(() {
        _replies = [..._replies, ...result.items];
        _total = result.total;
        _hasMore = _replies.length < result.total;
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
        onPosted: () {
          widget.onChanged();
          _load();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final parent = widget.parent;
    final parentName = parent.nickname.isEmpty ? '游客' : parent.nickname;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // B 转 A 置顶（剧透也模糊）
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 12,
                      backgroundColor: colorScheme.surfaceContainerHighest,
                      backgroundImage: parent.avatar.isNotEmpty
                          ? NetworkImage(
                              CommunityCommentsService.instance
                                  .resolveUrl(parent.avatar))
                          : null,
                      child: parent.avatar.isEmpty
                          ? const Icon(Icons.person_rounded, size: 14)
                          : null,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        parentName,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (parent.title.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      _TitleBadge(title: parent.title),
                    ],
                    const Spacer(),
                    Text(
                      parent.createdAt.length >= 16
                          ? parent.createdAt.substring(5, 16)
                          : parent.createdAt,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                if (parent.spoiler)
                  _SpoilerContent(
                    comment: parent,
                    revealed: widget.revealedSpoilers[parent.id] ?? false,
                    onReveal: () =>
                        widget.onToggleSpoiler(parent.id, true),
                  )
                else ...[
                  Text(parent.content),
                  if (parent.images.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _CommentImages(images: parent.images),
                  ],
                ],
              ],
            ),
          ),
          const Divider(height: 1, indent: 12, endIndent: 12),
          // C 们列表
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
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
              ),
            )
          else if (_replies.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: Text('还没有回复，来抢沙发吧')),
            )
          else ...[
            for (var i = 0; i < _replies.length; i++) ...[
              _ReplyTile(
                key: ValueKey(_replies[i].id),
                comment: _replies[i],
                kind: widget.kind,
                targetId: widget.targetId,
                revealedSpoiler:
                    widget.revealedSpoilers[_replies[i].id] ?? false,
                onToggleSpoiler: (r) =>
                    widget.onToggleSpoiler(_replies[i].id, r),
                revealedSpoilers: widget.revealedSpoilers,
                onChanged: () {
                  widget.onChanged();
                  _load();
                },
                onReply: () => _openComposer(
                  parentId: _replies[i].id,
                  replyTo: _replies[i].nickname,
                ),
              ),
              if (i < _replies.length - 1)
                const Divider(height: 1, indent: 56),
            ],
            if (_hasMore)
              Center(
                child: _loadingMore
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : TextButton(
                        onPressed: _loadMore,
                        child: const Text('加载更多回复'),
                      ),
              ),
          ],
          const Divider(height: 1, indent: 12, endIndent: 12),
          // 回复 B 按钮
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => _openComposer(),
                icon: const Icon(Icons.reply_rounded, size: 16),
                label: Text('回复 $parentName'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 二级页里的一条回复（C：显示 @B 昵称；C 被回复时可再内联展开循环二级页）
class _ReplyTile extends StatefulWidget {
  const _ReplyTile({
    super.key,
    required this.comment,
    required this.kind,
    required this.targetId,
    required this.onChanged,
    required this.onReply,
    required this.revealedSpoiler,
    required this.onToggleSpoiler,
    required this.revealedSpoilers,
  });

  final CommunityComment comment;
  final String kind;
  final int targetId;
  final VoidCallback onChanged;
  final VoidCallback onReply;
  final bool revealedSpoiler;
  final ValueChanged<bool> onToggleSpoiler;
  final Map<int, bool> revealedSpoilers;

  @override
  State<_ReplyTile> createState() => _ReplyTileState();
}

class _ReplyTileState extends State<_ReplyTile> {
  /// 本地可变副本（点赞乐观更新用）
  late CommunityComment _comment;

  /// 本行是否内联展开（C 被回复时点"查看详情"循环展开）
  bool _expanded = false;

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
          if (mounted) {
            KazumiDialog.showToast(message: '举报成功，我们会尽快处理');
          }
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
    final parentName =
        comment.parentNickname.isEmpty ? '' : comment.parentNickname;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: colorScheme.surfaceContainerHighest,
                backgroundImage: comment.avatar.isNotEmpty
                    ? NetworkImage(
                        CommunityCommentsService.instance
                            .resolveUrl(comment.avatar))
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
                        if (comment.title.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          _TitleBadge(title: comment.title),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    // C 显示：@B昵称 + 消息
                    if (comment.spoiler)
                      _SpoilerContent(
                        comment: comment,
                        revealed: widget.revealedSpoiler,
                        onReveal: () => widget.onToggleSpoiler(true),
                      )
                    else
                      Text.rich(
                        TextSpan(
                          children: [
                            if (parentName.isNotEmpty)
                              TextSpan(
                                text: '@$parentName ',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            TextSpan(
                              text: comment.content,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                    if (!comment.spoiler && comment.images.isNotEmpty) ...[
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
                        // C 被回复（有 D）时：查看详情 → 循环内联展开
                        if (comment.replyCount > 0) ...[
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: () => setState(() => _expanded = !_expanded),
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              child: Text(
                                _expanded ? '收起' : '查看详情',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
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
        ),
        // 循环嵌套二级页（C 转 A + D 们）
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(left: 40, right: 8, bottom: 8),
            child: _InlineReplies(
              key: ValueKey('inline-sub-${comment.id}'),
              kind: widget.kind,
              targetId: widget.targetId,
              parent: comment,
              revealedSpoilers: widget.revealedSpoilers,
              onToggleSpoiler: (id, r) => widget.onToggleSpoiler(r),
              onChanged: widget.onChanged,
            ),
          ),
      ],
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
        KazumiDialog.showToast(message: '图片上传中…');
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
                          onTap: () => setState(() => _localImages.remove(p)),
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