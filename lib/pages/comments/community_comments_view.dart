import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:image_picker/image_picker.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/error_widget.dart';
import 'package:kazumi/services/remote/auth_service.dart';
import 'package:kazumi/services/remote/community_comments_service.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// YunXiHub 社区评论视图（b 区）
///
/// 支持：游客浏览、登录发表（文字 + 图片 + 剧透标记）、赞助用户标识、
/// 剧透内容默认遮挡（点击显示）。
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

  Future<void> _openComposer() async {
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
        onPosted: _load,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
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
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          itemCount: _items.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1),
                          itemBuilder: (context, index) {
                            return _CommunityCommentTile(
                              comment: _items[index],
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
              icon: const Icon(Icons.edit_rounded),
              label: const Text('写评论'),
            ),
          ),
        ),
      ],
    );
  }
}

/// 单条社区评论
class _CommunityCommentTile extends StatelessWidget {
  const _CommunityCommentTile({required this.comment});

  final CommunityComment comment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                  comment.nickname.isEmpty ? '游客' : comment.nickname,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
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
          if (comment.spoiler)
            _SpoilerText(content: comment.content)
          else
            Text(comment.content),
          if (comment.images.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final img in comment.images.take(3))
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      CommunityCommentsService.instance.resolveUrl(img),
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
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 剧透内容：默认模糊遮挡，点击显示
class _SpoilerText extends StatefulWidget {
  const _SpoilerText({required this.content});

  final String content;

  @override
  State<_SpoilerText> createState() => _SpoilerTextState();
}

class _SpoilerTextState extends State<_SpoilerText> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    if (_revealed) {
      return Text(widget.content);
    }
    return GestureDetector(
      onTap: () => setState(() => _revealed = true),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.visibility_off_rounded,
                size: 14,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              '剧透内容 · 点击查看',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 评论发布面板（文字 + 图片 + 剧透标记）
class _CommentComposerSheet extends StatefulWidget {
  const _CommentComposerSheet({
    required this.kind,
    required this.targetId,
    required this.onPosted,
  });

  final String kind;
  final int targetId;
  final VoidCallback onPosted;

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
          Text('发表评论', style: theme.textTheme.titleMedium),
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