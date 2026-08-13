import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/pages/comments/community_comments_view.dart';
import 'package:kazumi/services/remote/community_comments_service.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 消息跳转页：打开目标评论所在的评论区并定位高亮
///
/// 流程：
/// 1. 调 /api/comments/detail 拿到评论的顶层主评论 id
/// 2. 分页加载主评论列表直到包含目标（最多 8 页）
/// 3. 打开 CommunityCommentsView 定位高亮；目标是回复时自动展开二级页
class CommentJumpPage extends StatefulWidget {
  const CommentJumpPage({
    super.key,
    required this.kind,
    required this.targetId,
    required this.commentId,
  });

  final String kind;
  final int targetId;
  final int commentId;

  @override
  State<CommentJumpPage> createState() => _CommentJumpPageState();
}

class _CommentJumpPageState extends State<CommentJumpPage> {
  bool _loading = true;
  String? _errorMsg;
  int? _topParentId;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  String get _baseUrl {
    var base =
        GStorage.getSetting(SettingsKeys.remoteResolverBaseUrl).trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  Future<void> _resolve() async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      ));
      final resp = await dio.get<dynamic>(
        '$_baseUrl/api/comments/detail',
        queryParameters: {'id': widget.commentId},
      );
      final raw = resp.data;
      final data = raw is String
          ? (jsonDecode(raw) as Map).cast<String, dynamic>()
          : (raw as Map).cast<String, dynamic>();
      if (data['code'] != 0 || data['data'] is! Map) {
        throw Exception(data['msg']?.toString() ?? '评论不存在');
      }
      final detail = (data['data'] as Map).cast<String, dynamic>();
      final top = (detail['top_parent_id'] as num?)?.toInt() ?? 0;
      // 预热主评论列表（让缓存命中，定位页直接展示）
      await _warmCache(top > 0 ? top : widget.commentId);
      if (!mounted) return;
      setState(() {
        _topParentId = top > 0 ? top : widget.commentId;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMsg = e.toString();
        _loading = false;
      });
    }
  }

  /// 分页预热：确保目标主评论在缓存中（最多 8 页）
  Future<void> _warmCache(int topParentId) async {
    var offset = 0;
    for (var page = 0; page < 8; page++) {
      final result = await CommunityCommentsService.instance.list(
        kind: widget.kind,
        targetId: widget.targetId,
        sort: CommunitySort.hotDesc,
        offset: offset,
        limit: 20,
      );
      final found = result.items.any((c) => c.id == topParentId);
      if (found || result.items.isEmpty ||
          result.items.length >= result.total) {
        return;
      }
      offset += result.items.length;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('评论详情')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _errorMsg != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.forum_outlined, size: 48),
                        const SizedBox(height: 12),
                        Text(
                          _errorMsg!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.tonal(
                          onPressed: () {
                            setState(() {
                              _loading = true;
                              _errorMsg = null;
                            });
                            _resolve();
                          },
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                )
              : CommunityCommentsView(
                  kind: widget.kind,
                  targetId: widget.targetId,
                  highlightCommentId: widget.commentId,
                  autoOpenRepliesCommentId: _topParentId,
                ),
    );
  }
}