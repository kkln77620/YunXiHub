import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/utils/constants.dart';

/// 随机番剧服务（与搜索同源：Bangumi 搜索接口，客户端镜像通道）
///
/// - 用选中的 tag 作为搜索词（与搜索页同接口，稳定）
/// - 读取结果条目自身的 tags，符合的标记为备选
/// - 每次随机 = 对备选池随机排序
class RandomAnimeService {
  RandomAnimeService._();

  static final RandomAnimeService instance = RandomAnimeService._();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 20),
    headers: {'User-Agent': 'YunXiHub/3.3.0 (https://yunxi.yunxiapp.eu.cc)'},
  ));

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
    try {
      for (final word in searchWords) {
        for (var i = 0; i < pagesPerWord; i++) {
          final page = 1 + Random().nextInt(6);
          try {
            final resp = await _dio.get<dynamic>(
              '${ApiEndpoints.bangumiAPIDomain}/v0/search/subjects',
              queryParameters: {
                'keyword': word,
                'limit': 25,
                'offset': (page - 1) * 25,
              },
            );
            final data = resp.data;
            final list = data is String
                ? _decodeList(data)
                : ((data as Map)['data'] as List? ?? const []);
            for (final s in list) {
              if (s is! Map) continue;
              try {
                final item = BangumiItem.fromJson(Map<String, dynamic>.from(s));
                pool[item.id] = item;
              } catch (_) {}
            }
          } catch (_) {
            // 单页失败忽略
          }
        }
      }
    } catch (_) {}

    // 读取条目自身 tag：包含任一选中 tag 的标记为备选（未选 tag 全通过）
    // 兼容：名称/别名含 tag 也视为相关
    final candidates = pool.values.where((item) {
      if (tags.isNotEmpty) {
        final itemTags = item.tags.map((t) => t.name).toSet();
        final hit = tags.any((t) =>
            itemTags.contains(t) ||
            item.name.contains(t) ||
            item.nameCn.contains(t));
        if (!hit) return false;
      }
      final year = _yearOf(item.airDate);
      if (yearMin > 0 && (year == 0 || year < yearMin)) return false;
      if (yearMax > 0 && (year == 0 || year > yearMax)) return false;
      return true;
    }).toList();

    candidates.shuffle(Random());
    return candidates.take(count.clamp(1, 40)).toList();
  }

  int _yearOf(String date) {
    if (date.length < 4) return 0;
    final y = int.tryParse(date.substring(0, 4));
    return y ?? 0;
  }

  List<dynamic> _decodeList(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['data'] is List) {
        return decoded['data'] as List;
      }
      if (decoded is List) return decoded;
    } catch (_) {}
    return const [];
  }
}