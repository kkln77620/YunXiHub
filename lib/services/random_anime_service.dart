import 'dart:math';

import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/utils/constants.dart';

/// 随机番剧服务（与搜索页**完全同源**：同一 Bangumi 搜索通道）
///
/// 修复说明：旧实现直连 `GET /v0/search/subjects`（镜像 404 → 候选池永远为空），
/// 现改为调用 `BangumiApi.bangumiSearch`（搜索页同款 POST 通道，实测稳定）。
///
/// - 用选中的 tag 作为搜索词（与搜索页同接口）
/// - 读取结果条目自身 tags，符合的标记备选；名称/别名含 tag 也算
/// - 每次随机 = 对备选池随机排序
class RandomAnimeService {
  RandomAnimeService._();

  static final RandomAnimeService instance = RandomAnimeService._();

  /// 拉取随机番剧（与搜索同数据源）
  ///
  /// [tags] 为空时用默认热门 tag 轮询搜索作为候选
  /// [yearMin]/[yearMax] 为 0 表示不限
  /// [count] 返回条数（最多 40）
  Future<List<BangumiItem>> fetch({
    List<String> tags = const [],
    int yearMin = 0,
    int yearMax = 0,
    int count = 30,
  }) async {
    final pool = <int, BangumiItem>{};
    // 搜索词：选中 tags；未选时用默认 tag 列表（各搜 1 页，保证池子够大）
    final searchWords = tags.isNotEmpty
        ? tags
        : (defaultAnimeTags.length > 8
            ? defaultAnimeTags.sublist(0, 8)
            : defaultAnimeTags);
    final pagesPerWord = tags.isNotEmpty ? 2 : 1;
    for (final word in searchWords) {
      for (var i = 0; i < pagesPerWord; i++) {
        // 随机翻页（0-4），尽量扩大候选多样性；失败静默忽略
        final page = Random().nextInt(5);
        try {
          final result = await BangumiApi.bangumiSearch(
            word,
            limit: 25,
            offset: page * 25,
          );
          if (result == null) continue;
          for (final item in result.items) {
            if (item.id != null) pool[item.id] = item;
          }
        } catch (_) {
          // 单页失败忽略
        }
      }
    }

    // 读取条目自身 tag：包含任一选中 tag 的标记为备选（未选 tag 全通过）
    // 兼容：名称/别名含 tag 也视为相关；
    // 兜底：全部不命中时保留全部结果（搜索词本身就是 tag，结果已相关）
    final raw = pool.values.toList();
    List<BangumiItem> candidates;
    if (tags.isEmpty) {
      candidates = raw;
    } else {
      final hit = raw.where((item) {
        final itemTags = item.tags.map((t) => t.name).toSet();
        return tags.any((t) =>
            itemTags.contains(t) ||
            item.name.contains(t) ||
            item.nameCn.contains(t) ||
            item.alias.any((a) => a.contains(t)));
      }).toList();
      candidates = hit.isEmpty ? raw : hit; // 兜底：不因 tags 匹配导致全空
    }

    // 年份过滤
    final filtered = candidates.where((item) {
      final year = _yearOf(item.airDate);
      if (yearMin > 0 && (year == 0 || year < yearMin)) return false;
      if (yearMax > 0 && (year == 0 || year > yearMax)) return false;
      return true;
    }).toList();

    filtered.shuffle(Random());
    return filtered.take(count.clamp(1, 40)).toList();
  }

  int _yearOf(String date) {
    if (date.length < 4) return 0;
    final y = int.tryParse(date.substring(0, 4));
    return y ?? 0;
  }
}