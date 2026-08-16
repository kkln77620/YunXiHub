import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:dio/dio.dart';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:image_picker/image_picker.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/error_widget.dart';
import 'package:kazumi/bean/widget/image_preview.dart';
import 'package:kazumi/pages/friends/user_profile_page.dart';
import 'package:kazumi/services/remote/auth_service.dart';
import 'package:kazumi/services/remote/community_comments_service.dart';
import 'package:kazumi/services/remote/entitlements_service.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/comment_filter.dart';

/// 社区评论外部控制器：供页面 FAB 等外部入口触发"写评论"
class CommunityCommentsController {
  void Function()? _compose;

  /// 打开写评论弹窗（FAB 用）
  void openComposer() => _compose?.call();
}

/// 统一错误转中文提示：DioException 优先取服务器 msg（等级限制等），网络错误给通用提示
String _commentErrText(Object e) {
  if (e is DioException) {
    final resp = e.response;
    if (resp?.data != null) {
      try {
        final m = resp!.data is String
            ? (jsonDecode(resp.data as String) as Map)
            : (resp.data as Map);
        final msg = m['msg']?.toString();
        if (msg != null && msg.isNotEmpty) return msg;
      } catch (_) {}
    }
    return '网络错误，请稍后重试';
  }
  return e.toString();
}

/// YunXiHub 社区评论视图（b 区）v5
///
/// 模型：**区域级二级页（页面栈）**
/// - 一级：主评论列表（每条主评论下方显示前 3 条回复预览）
/// - 点击任意回复行 / "查看全部" → 评论区区域内切换为二级视图：
///   被点评论转 A 置顶 + 它的回复列表 + 顶部返回箭头
/// - 二级页内再点回复 → 继续转二级（循环嵌套，栈式返回）
/// - 切换仅发生在评论区区域，tab 与其他界面不动；系统返回键 = 弹栈
///
/// 其他特性：
/// - 发表评论/回复：**乐观插入**（前端立即显示，不刷新列表；后台上传）
/// - 一级缓存 + 剧透状态（全局静态，a/b 区切换不丢）
/// - 剧透：前端已加载，模糊展示，点击整个模糊区立即显示；模糊图片不可点开原图
/// - 头衔 / 分页 / 排序 / @父级昵称
class CommunityCommentsView extends StatefulWidget {
  const CommunityCommentsView({
    super.key,
    required this.kind,
    required this.targetId,
    this.controller,
    this.highlightCommentId,
    this.autoOpenRepliesCommentId,
    this.hideComposerButton = false,
  });

  /// subject | episode | character
  final String kind;
  final int targetId;

  /// 外部控制器（FAB 触发写评论）
  final CommunityCommentsController? controller;

  /// 隐藏底部"写评论"按钮（详情页吐槽区由 FAB 承担，避免重复入口）
  final bool hideComposerButton;

  /// 定位高亮（消息跳转用），只执行一次
  final int? highlightCommentId;

  /// 目标评论是回复时：加载后自动压栈其父链二级视图
  final int? autoOpenRepliesCommentId;

  @override
  State<CommunityCommentsView> createState() => _CommunityCommentsViewState();
}

class _CommunityCommentsViewState extends State<CommunityCommentsView> {
  // ---- 一级列表 ----
  List<CommunityComment> _items = [];
  bool _loading = true;
  bool _error = false;
  String _errorMsg = '';
  CommunitySort _sort = CommunitySort.hotDesc;
  int _total = 0;
  bool _hasMore = true;
  bool _loadingMore = false;

  /// 二级视图栈（元素 = 被点击转 A 的评论）；空 = 一级
  final List<CommunityComment> _stack = [];

  bool _highlightResolved = false;
  int? _highlightId;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller?._compose = () => _openComposer();
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

  // ==================== 页面栈 ====================

  /// 进入二级视图（把该评论转 A）
  void _openLevel(CommunityComment comment) {
    setState(() => _stack.add(comment));
  }

  /// 返回上一级
  void _popLevel() {
    if (_stack.isEmpty) return;
    setState(() => _stack.removeLast());
  }

  /// 系统返回键：栈非空时弹栈（不退出页面）
  void _handlePop(bool didPop) {
    if (!didPop && _stack.isNotEmpty) {
      _popLevel();
    }
  }

  // ==================== 数据加载 ====================

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
        _errorMsg = _commentErrText(e);
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

  Future<void> _refresh() async {
    CommunityCommentsService.clearCache(
        kind: widget.kind, targetId: widget.targetId);
    await _load(refresh: true);
  }

  /// 评论屏蔽过滤后的可见列表（缓存保持原样，展示层过滤）
  List<CommunityComment> get _visibleItems =>
      CommentFilter.filterCommunityList(_items).$1;

  int get _hiddenCount => CommentFilter.filterCommunityList(_items).$2;

  void _changeSort(CommunitySort sort) {
    if (_sort == sort) return;
    setState(() => _sort = sort);
    CommunityCommentsService.clearCache(
        kind: widget.kind, targetId: widget.targetId);
    _load(refresh: true);
  }

  /// 本地数据变更后同步一级缓存（切走再回来不丢）
  void _syncCache() {
    CommunityCommentsService.cacheStore(
        widget.kind, widget.targetId, _sort, _items, _total);
  }

  // ==================== 乐观插入 / 删除 ====================

  /// 一级：发表主评论成功 → 前端直接插入顶部（不刷新）
  void _insertLocalMain(CommunityComment comment) {
    setState(() {
      _items = [comment, ..._items];
      _total += 1;
    });
    _syncCache();
  }

  /// 一级：删除主评论 → 前端直接移除（不刷新）
  void _removeLocalMain(int commentId) {
    setState(() {
      _items = _items.where((c) => c.id != commentId).toList();
      _total = _total > 0 ? _total - 1 : 0;
    });
    _syncCache();
  }

  /// 二级视图内回复/删除后：沿栈修正父评论的 reply_count（本地，不请求）
  void _bumpReplyCount(int anchorId, int delta) {
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].id == anchorId) {
        final c = _items[i];
        _items[i] = c.copyWith(
          replyCount: (c.replyCount + delta) < 0 ? 0 : c.replyCount + delta,
        );
        break;
      }
    }
    _syncCache();
  }

  // ==================== 消息跳转定位 ====================

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
    // 目标是回复：找到所属主评论 → 压栈该主评论的二级视图（目标在其回复列表中）
    for (var i = 0; i < _items.length; i++) {
      final parent = _items[i];
      if (parent.replies.any((r) => r.id == targetId) ||
          parent.id == widget.autoOpenRepliesCommentId) {
        _scrollToHighlight(i);
        _openLevel(parent);
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

  // ==================== 剧透 ====================

  void _toggleSpoiler(int commentId, bool revealed) {
    CommunityCommentsService.setSpoilerRevealed(commentId, revealed);
    setState(() {});
  }

  // ==================== 发布 ====================

  Future<void> _openComposer({int parentId = 0, String? replyTo}) async {
    final loggedIn =
        GStorage.getSetting(SettingsKeys.authToken).trim().isNotEmpty;
    if (!loggedIn) {
      KazumiDialog.showToast(message: '请先登录账号');
      await context.pushNamed('/settings/account/');
      return;
    }
    // 权益本地校验（服务器下发，不写死）：封禁 / 未通过考核 → 拦截
    final ent = EntitlementsService.current;
    if (ent.isBanned) {
      KazumiDialog.showToast(
          message: ent.banMsg.isEmpty ? '账号已被封禁' : ent.banMsg);
      return;
    }
    if (!ent.commentEnabled) {
      KazumiDialog.showToast(message: '未通过入站考核（L0），暂不能发表评论');
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
        onPosted: (id, content, images, spoiler) {
          // 乐观插入：前端直接显示，不刷新列表
          final local = CommunityCommentsService.buildLocalComment(
            id: id,
            kind: widget.kind,
            targetId: widget.targetId,
            parentId: parentId,
            content: content,
            images: images,
            spoiler: spoiler,
          );
          if (parentId > 0) {
            // 回复：插入对应主评论的回复预览（嵌套展示）+ replyCount+1；
            // 父评论不在当前页（分页边界）时兜底插入主列表顶部
            setState(() {
              var found = false;
              for (var i = 0; i < _items.length; i++) {
                if (_items[i].id == parentId) {
                  final c = _items[i];
                  _items[i] = c.copyWith(
                    replyCount: c.replyCount + 1,
                    replies: [local, ...c.replies],
                  );
                  found = true;
                  break;
                }
              }
              if (!found) {
                _items = [local, ..._items];
                _total += 1;
              }
            });
            _syncCache();
          } else {
            _insertLocalMain(local);
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _stack.isEmpty,
      onPopInvokedWithResult: (didPop, _) => _handlePop(didPop),
      child: Column(
        children: [
          // 排序栏（仅一级显示）
          if (_stack.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Row(
                children: [
                  Text(
                    '社区评论${_total > 0 ? '（$_total）' : ''}',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
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
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _stack.isEmpty
                  ? _buildMainList()
                  : _ReplyLevelView(
                      key: ValueKey('lv-${_stack.length}-${_stack.last.id}'),
                      kind: widget.kind,
                      targetId: widget.targetId,
                      anchor: _stack.last,
                      onBack: _popLevel,
                      onOpen: _openLevel,
                      onReply: (parentId, replyTo) => _openComposer(
                        parentId: parentId,
                        replyTo: replyTo,
                      ),
                      onToggleSpoiler: _toggleSpoiler,
                      onInsertLocal: (comment) {
                        // 二级内回复成功：当前层列表已由视图内部插入，
                        // 这里只需修正上级（栈中上一元素）的 reply_count
                        if (_stack.length >= 1) {
                          final anchorId = _stack.last.id;
                          _bumpReplyCount(anchorId, 1);
                        }
                      },
                      onRemoveLocal: (commentId) {
                        if (_stack.length >= 1) {
                          _bumpReplyCount(_stack.last.id, -1);
                        }
                      },
                      highlightCommentId: widget.highlightCommentId,
                    ),
            ),
          ),
          // 底部写评论（一级显示；吐槽区由 FAB 承担时隐藏）
          if (_stack.isEmpty && !widget.hideComposerButton)
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
      ),
    );
  }

  Widget _buildMainList() {
    final theme = Theme.of(context);
    return _loading
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
                        Center(child: Text('还没有社区评论，来抢沙发吧 (´▽`)')),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView.separated(
                      controller: _scrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      itemCount: _visibleItems.length + (_hasMore ? 1 : 0),
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        if (index >= _visibleItems.length) {
                          return Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 12),
                            child: Center(
                              child: _loadingMore
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
                        final comment = _visibleItems[index];
                        return _CommunityCommentTile(
                          key: ValueKey(comment.id),
                          comment: comment,
                          kind: widget.kind,
                          targetId: widget.targetId,
                          highlight: _highlightId == comment.id,
                          onChanged: () {
                            // 点赞/删除等操作后的本地同步
                            _syncCache();
                          },
                          onReply: () => _openComposer(
                            parentId: comment.id,
                            replyTo: comment.nickname,
                          ),
                          onOpenReplies: (anchor) => _openLevel(anchor),
                          onRemoveLocal: () => _removeLocalMain(comment.id),
                          onToggleSpoiler: _toggleSpoiler,
                        );
                      },
                    ),
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

/// 等级徽标（L0-L9，L0 不显示）
class _LevelBadge extends StatelessWidget {
  const _LevelBadge({required this.level});

  final int level;

  @override
  Widget build(BuildContext context) {
    if (level <= 0) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'L$level',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colorScheme.onTertiaryContainer,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

/// 单条主评论（一级）：内容 + 操作行 + 回复预览（前3条）
class _CommunityCommentTile extends StatefulWidget {
  const _CommunityCommentTile({
    super.key,
    required this.comment,
    required this.kind,
    required this.targetId,
    required this.onChanged,
    required this.onReply,
    required this.onOpenReplies,
    required this.onRemoveLocal,
    required this.onToggleSpoiler,
    this.highlight = false,
  });

  final CommunityComment comment;
  final String kind;
  final int targetId;
  final VoidCallback onChanged;
  final VoidCallback onReply;

  /// 打开二级视图（anchor：被点击的回复，或主评论本身=查看全部）
  final ValueChanged<CommunityComment> onOpenReplies;
  final VoidCallback onRemoveLocal;
  final void Function(int commentId, bool revealed) onToggleSpoiler;
  final bool highlight;

  @override
  State<_CommunityCommentTile> createState() => _CommunityCommentTileState();
}

class _CommunityCommentTileState extends State<_CommunityCommentTile> {
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
        oldWidget.comment.replyCount != widget.comment.replyCount) {
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
      KazumiDialog.showToast(message: _commentErrText(e));
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
      KazumiDialog.showToast(message: _commentErrText(e));
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
      widget.onRemoveLocal();
    } catch (e) {
      if (!mounted) return;
      KazumiDialog.showToast(message: _commentErrText(e));
    }
  }

  /// 点击头像打开用户主页
  void _openProfile() {
    final uid = _comment.uid;
    if (uid <= 0) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => UserProfilePage(uid: uid)),
    );
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
          // 头像 + 昵称 + 头衔 + 时间
          Row(
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(19),
                onTap: _comment.uid > 0 ? _openProfile : null,
                child: CircleAvatar(
                  radius: 19,
                  backgroundColor: colorScheme.surfaceContainerHighest,
                  backgroundImage: comment.avatar.isNotEmpty
                      ? NetworkImage(
                          CommunityCommentsService.instance
                              .resolveUrl(comment.avatar))
                      : null,
                  child: comment.avatar.isEmpty
                      ? const Icon(Icons.person_rounded, size: 22)
                      : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  runSpacing: 2,
                  children: [
                    Text(
                      displayName,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (_isMine)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
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
                    if (comment.title.isNotEmpty)
                      _TitleBadge(title: comment.title),
                    if (comment.level > 0)
                      _LevelBadge(level: comment.level),
                  ],
                ),
              ),
              const SizedBox(width: 8),
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
          // 内容（剧透模糊）
          if (comment.spoiler)
            _SpoilerContent(
              comment: comment,
              revealed: CommunityCommentsService.isSpoilerRevealed(comment.id),
              onReveal: () => widget.onToggleSpoiler(comment.id, true),
            )
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
          // 回复预览（前3条，点击行 → 打开该回复的二级视图）
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
                      onTap: () => widget.onOpenReplies(reply),
                    ),
                    if (reply != replies.last) const SizedBox(height: 4),
                  ],
                  if (comment.replyCount > replies.length)
                    InkWell(
                      onTap: () => widget.onOpenReplies(comment),
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          '查看全部 ${comment.replyCount} 条回复',
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

/// 折叠区里的一行回复（点击 → 打开该回复的二级视图）
class _ReplyLine extends StatelessWidget {
  const _ReplyLine({required this.comment, required this.onTap});

  final CommunityComment comment;
  final VoidCallback onTap;

  /// 点击头像打开用户主页
  void _openProfile(BuildContext context) {
    final uid = comment.uid;
    if (uid <= 0) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => UserProfilePage(uid: uid)),
    );
  }

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
        child: Row(
          children: [
            Expanded(
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
            if (comment.replyCount > 0)
              Icon(Icons.chevron_right_rounded,
                  size: 16, color: colorScheme.onSurfaceVariant),
          ],
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

/// 剧透内容：前端已加载，仅模糊展示；点击整个模糊区立即清晰
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

/// 二级视图：anchor（被点评论）转 A 置顶 + 它的回复列表
/// 回复行可继续点击 → 打开更深二级视图（循环）
class _ReplyLevelView extends StatefulWidget {
  const _ReplyLevelView({
    super.key,
    required this.kind,
    required this.targetId,
    required this.anchor,
    required this.onBack,
    required this.onOpen,
    required this.onReply,
    required this.onInsertLocal,
    required this.onRemoveLocal,
    required this.onToggleSpoiler,
    this.highlightCommentId,
  });

  final String kind;
  final int targetId;
  final CommunityComment anchor;
  final VoidCallback onBack;
  final ValueChanged<CommunityComment> onOpen;
  final void Function(int parentId, String? replyTo) onReply;
  final ValueChanged<CommunityComment> onInsertLocal;
  final ValueChanged<int> onRemoveLocal;
  final void Function(int commentId, bool revealed) onToggleSpoiler;
  final int? highlightCommentId;

  @override
  State<_ReplyLevelView> createState() => _ReplyLevelViewState();
}

class _ReplyLevelViewState extends State<_ReplyLevelView> {
  List<CommunityComment> _replies = [];
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
        parentId: widget.anchor.id,
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
        parentId: widget.anchor.id,
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

  /// 回复成功：乐观插入列表顶部（不刷新）
  void _insertLocal(CommunityComment comment) {
    setState(() {
      _replies = [comment, ..._replies];
      _total += 1;
    });
    widget.onInsertLocal(comment);
  }

  /// 删除回复：本地移除（不刷新）
  void _removeLocal(int commentId) {
    setState(() {
      _replies = _replies.where((c) => c.id != commentId).toList();
      _total = _total > 0 ? _total - 1 : 0;
    });
    widget.onRemoveLocal(commentId);
  }

  Future<void> _openComposer() async {
    final loggedIn =
        GStorage.getSetting(SettingsKeys.authToken).trim().isNotEmpty;
    if (!loggedIn) {
      KazumiDialog.showToast(message: '请先登录账号');
      return;
    }
    final anchor = widget.anchor;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CommentComposerSheet(
        kind: widget.kind,
        targetId: widget.targetId,
        parentId: anchor.id,
        replyTo: anchor.nickname,
        onPosted: (id, content, images, spoiler) {
          final local = CommunityCommentsService.buildLocalComment(
            id: id,
            kind: widget.kind,
            targetId: widget.targetId,
            parentId: anchor.id,
            content: content,
            images: images,
            spoiler: spoiler,
          );
          _insertLocal(local);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final anchor = widget.anchor;
    final anchorName = anchor.nickname.isEmpty ? '游客' : anchor.nickname;
    return Column(
      children: [
        // 顶部：返回 + 标题
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 8, 4),
          child: Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_back_rounded, size: 20),
                tooltip: '返回',
                onPressed: widget.onBack,
              ),
              Expanded(
                child: Text(
                  '${anchorName} 的回复${_total > 0 ? '（$_total）' : ''}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // anchor 转 A 置顶（剧透也模糊，点击整个模糊区立即显示）
        Container(
          width: double.infinity,
          color: colorScheme.surfaceContainerLow,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    backgroundImage: anchor.avatar.isNotEmpty
                        ? NetworkImage(
                            CommunityCommentsService.instance
                                .resolveUrl(anchor.avatar))
                        : null,
                    child: anchor.avatar.isEmpty
                        ? const Icon(Icons.person_rounded, size: 14)
                        : null,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      anchorName,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (anchor.title.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    _TitleBadge(title: anchor.title),
                  ],
                  const Spacer(),
                  Text(
                    anchor.createdAt.length >= 16
                        ? anchor.createdAt.substring(5, 16)
                        : anchor.createdAt,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (anchor.spoiler)
                _SpoilerContent(
                  comment: anchor,
                  revealed:
                      CommunityCommentsService.isSpoilerRevealed(anchor.id),
                  onReveal: () => widget.onToggleSpoiler(anchor.id, true),
                )
              else ...[
                Text(anchor.content),
                if (anchor.images.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _CommentImages(images: anchor.images),
                ],
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        // 回复列表
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
                      ? const Center(child: Text('还没有回复，来抢沙发吧'))
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: _replies.length + (_hasMore ? 1 : 0),
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1, indent: 56),
                          itemBuilder: (context, index) {
                            if (index >= _replies.length) {
                              return Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                child: Center(
                                  child: _loadingMore
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
                            final reply = _replies[index];
                            return _ReplyTile(
                              key: ValueKey(reply.id),
                              comment: reply,
                              kind: widget.kind,
                              targetId: widget.targetId,
                              highlight:
                                  widget.highlightCommentId == reply.id,
                              onOpen: () => widget.onOpen(reply),
                              onRemoveLocal: () => _removeLocal(reply.id),
                              onReply: () => widget.onReply(
                                reply.id,
                                reply.nickname,
                              ),
                              onToggleSpoiler: widget.onToggleSpoiler,
                            );
                          },
                        ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton.icon(
              onPressed: _openComposer,
              icon: const Icon(Icons.reply_rounded),
              label: Text('回复 $anchorName'),
            ),
          ),
        ),
      ],
    );
  }
}

/// 二级视图里的一条回复（点击主体 → 继续转二级）
class _ReplyTile extends StatefulWidget {
  const _ReplyTile({
    super.key,
    required this.comment,
    required this.kind,
    required this.targetId,
    required this.onOpen,
    required this.onRemoveLocal,
    required this.onReply,
    required this.onToggleSpoiler,
    this.highlight = false,
  });

  final CommunityComment comment;
  final String kind;
  final int targetId;
  final VoidCallback onOpen;
  final VoidCallback onRemoveLocal;
  final VoidCallback onReply;
  final void Function(int commentId, bool revealed) onToggleSpoiler;
  final bool highlight;

  @override
  State<_ReplyTile> createState() => _ReplyTileState();
}

class _ReplyTileState extends State<_ReplyTile> {
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
      KazumiDialog.showToast(message: _commentErrText(e));
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
          if (mounted) KazumiDialog.showToast(message: _commentErrText(e));
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
          widget.onRemoveLocal();
        } catch (e) {
          if (mounted) KazumiDialog.showToast(message: _commentErrText(e));
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
    return InkWell(
      onTap: widget.onOpen,
      child: Container(
        width: double.infinity,
        color: widget.highlight
            ? colorScheme.primary.withOpacity(0.08)
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _comment.uid > 0
                  ? () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              UserProfilePage(uid: _comment.uid),
                        ),
                      )
                  : null,
              child: CircleAvatar(
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
                      if (comment.level > 0) ...[
                        const SizedBox(width: 6),
                        _LevelBadge(level: comment.level),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  // 内容：@父级昵称 + 剧透模糊
                  if (comment.spoiler)
                    _SpoilerContent(
                      comment: comment,
                      revealed:
                          CommunityCommentsService.isSpoilerRevealed(comment.id),
                      onReveal: () =>
                          widget.onToggleSpoiler(comment.id, true),
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
                      if (comment.replyCount > 0) ...[
                        const SizedBox(width: 8),
                        Text(
                          '${comment.replyCount}条回复 ›',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
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
    );
  }
}

/// 评论发布面板（文字 + 图片 + 剧透标记；支持回复）
/// 发布成功后通过 [onPosted] 回调 (id, content, images, spoiler)，
/// 由调用方**乐观插入**（前端立即显示，不刷新列表）
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

  /// 发布成功回调：返回服务器 id 与本地内容，供乐观插入
  final void Function(int id, String content, List<String> images, bool spoiler)
      onPosted;
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
  bool _uploadOriginal = false; // 原图模式（仅管理员可开启，默认关闭）

  /// 权益（服务器下发）：字数/图片上限动态读取
  Entitlements get _ent => EntitlementsService.current;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickImages() async {
    final maxImg = _ent.commentMaxImages;
    if (_localImages.length >= maxImg) {
      KazumiDialog.showToast(message: '最多$maxImg张图片');
      return;
    }
    try {
      // 默认压缩到最长边1920/质量85；原图模式（仅管理员）不压缩
      final original = _uploadOriginal && AuthService.instance.isAdmin;
      final files = await _picker.pickMultiImage(
        limit: maxImg - _localImages.length,
        maxWidth: original ? null : 1920,
        maxHeight: original ? null : 1920,
        imageQuality: original ? null : 85,
      );
      if (files.isEmpty) return;
      // 本地先计数：超出权益上限直接拦截（不选入，更不上传）
      final room = maxImg - _localImages.length;
      final take = files.take(room).toList();
      if (files.length > room) {
        KazumiDialog.showToast(message: '最多$maxImg张图片');
      }
      setState(() {
        _localImages.addAll(take.map((f) => f.path));
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
    // 编辑时本地校验（服务器下发权益，不写死）：字数 + 图片数
    final ent = _ent;
    if (content.length > ent.commentMaxLen) {
      KazumiDialog.showToast(message: '评论最多 ${ent.commentMaxLen} 字');
      return;
    }
    if (_localImages.length > ent.commentMaxImages) {
      KazumiDialog.showToast(
          message: '最多 ${ent.commentMaxImages} 张图片');
      return;
    }
    setState(() => _submitting = true);
    try {
      // 先本地校验通过，再逐张上传（顺序：本地计数 → 权益达标 → 上传）
      final imageUrls = <String>[];
      for (final p in _localImages) {
        KazumiDialog.showToast(message: '图片上传中…');
        imageUrls.add(await AuthService.instance.uploadImage(p, use: 'comment'));
      }
      final id = await CommunityCommentsService.instance.postReturnId(
        kind: widget.kind,
        targetId: widget.targetId,
        content: content,
        images: imageUrls,
        spoiler: _spoiler,
        parentId: widget.parentId,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onPosted(id, content, imageUrls, _spoiler);
      KazumiDialog.showToast(message: '评论成功');
    } catch (e) {
      if (!mounted) return;
      KazumiDialog.showToast(message: _commentErrText(e));
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
            maxLength: _ent.commentMaxLen,
            decoration: const InputDecoration(
              hintText: '分享你的看法…',
              border: OutlineInputBorder(),
            ),
          ),
          if (_localImages.isNotEmpty) ...[
            const SizedBox(height: 8),
            // 图片预览：固定高度横向滑动（避免图片多时把发送键顶出屏幕）
            SizedBox(
              height: 88,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _localImages.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, i) {
                  final p = _localImages[i];
                  return Stack(
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
                  );
                },
              ),
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
              if (_localImages.isNotEmpty) ...[
                const SizedBox(width: 4),
                // 原图开关：紧凑样式（同剧透区），不挤压发布按钮
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    if (!AuthService.instance.isAdmin) {
                      KazumiDialog.showToast(message: '该功能暂未开放');
                      return;
                    }
                    setState(() => _uploadOriginal = !_uploadOriginal);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _uploadOriginal
                              ? Icons.hd_rounded
                              : Icons.hd_outlined,
                          size: 16,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          _uploadOriginal ? '原图:开' : '原图',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
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