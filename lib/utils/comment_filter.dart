import 'package:kazumi/modules/comments/comment_item.dart';
import 'package:kazumi/services/remote/community_comments_service.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 播放器评论屏蔽（纯本地）：关键词 / 正则 / 等级（L0-L9）
///
/// - 关键词与正则：对 Bangumi 评论（a 区）与社区评论（b 区）都生效
/// - 等级过滤：仅对社区评论生效（L0-L9 等级体系）
class CommentFilter {
  CommentFilter._();

  static bool get enabled =>
      GStorage.getSetting(SettingsKeys.commentFilterEnabled);

  static String get keywords =>
      GStorage.getSetting(SettingsKeys.commentFilterKeywords);

  static String get regex => GStorage.getSetting(SettingsKeys.commentFilterRegex);

  static int get minLevel =>
      GStorage.getSetting(SettingsKeys.commentFilterMinLevel);

  /// 内容匹配：关键词（逗号分隔，包含即命中）或正则
  static bool matchContent(String content) {
    if (!enabled || content.isEmpty) return false;
    final kw = keywords.trim();
    if (kw.isNotEmpty) {
      for (final k in kw.split(',')) {
        final t = k.trim();
        if (t.isNotEmpty && content.contains(t)) return true;
      }
    }
    final rx = regex.trim();
    if (rx.isNotEmpty) {
      try {
        if (RegExp(rx).hasMatch(content)) return true;
      } catch (_) {}
    }
    return false;
  }

  /// 社区评论（b 区）是否应屏蔽
  static bool shouldFilterCommunity(CommunityComment c) {
    if (!enabled) return false;
    if (minLevel > 0 && c.level < minLevel) return true;
    return matchContent(c.content);
  }

  /// 过滤社区评论列表，返回 (可见列表, 屏蔽数)
  static (List<CommunityComment>, int) filterCommunityList(
      List<CommunityComment> items) {
    if (!enabled) return (items, 0);
    final visible = <CommunityComment>[];
    var hidden = 0;
    for (final c in items) {
      if (shouldFilterCommunity(c)) {
        hidden++;
      } else {
        visible.add(c);
      }
    }
    return (visible, hidden);
  }

  /// 过滤 Bangumi 评论（a 区）：仅内容关键词/正则
  static (List<EpisodeCommentItem>, int) filterBangumiList(
      List<EpisodeCommentItem> items) {
    if (!enabled) return (items, 0);
    final visible = <EpisodeCommentItem>[];
    var hidden = 0;
    for (final it in items) {
      if (matchContent(it.comment.comment)) {
        hidden++;
      } else {
        visible.add(it);
      }
    }
    return (visible, hidden);
  }
}