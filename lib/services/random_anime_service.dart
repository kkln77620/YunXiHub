import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/request/config/api_endpoints.dart';

/// 随机番剧服务（客户端直连 Bangumi 镜像代理，不依赖手机服务器）
///
/// - 按 tag（多选）/ 年份区间筛选
/// - 从随机页拉取候选 → 年份过滤 → 随机打乱
class RandomAnimeService {
  RandomAnimeService._();

  static final RandomAnimeService instance = RandomAnimeService._();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 20),
    headers: {'User-Agent': 'YunXiHub/3.3.0 (https://yunxi.yunxiapp.eu.cc)'},
  ));

  /// 拉取随机番剧
  ///
  /// [tags] 为空表示不限 tag（热门榜随机）
  /// [yearMin]/[yearMax] 为 0 表示不限
  /// [count] 返回条数（最多 40）
  Future<List<BangumiItem>> fetch({
    List<String> tags = const [],
    int yearMin = 0,
    int yearMax = 0,
    int count = 30,
  }) async {
    final candidates = <int, BangumiItem>{};
    try {
      final effectiveTags = tags.isEmpty ? <String>[''] : tags;
      for (final tag in effectiveTags) {
        // 每个 tag 随机抽 3 页
        for (var i = 0; i < 3; i++) {
          final page = 1 + Random().nextInt(8);
          try {
            final resp = await _dio.get<dynamic>(
              '${ApiEndpoints.bangumiAPIDomain}/v0/subjects',
              queryParameters: {
                'type': 2,
                'sort': 'rank',
                'limit': 25,
                'page': page,
                if (tag.isNotEmpty) 'tag': tag,
              },
            );
            final data = resp.data;
            final list = data is String
                ? (jsonDecodeCompat(data))
                : ((data as Map)['data'] as List? ?? const []);
            for (final s in list) {
              if (s is! Map) continue;
              try {
                final item = BangumiItem.fromJson(Map<String, dynamic>.from(s));
                candidates[item.id] = item;
              } catch (_) {}
            }
          } catch (_) {
            // 单页失败忽略，继续其他页
          }
        }
      }
    } catch (_) {}

    // 年份过滤 + 随机打乱
    final filtered = candidates.values.where((item) {
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
    final head = date.substring(0, 4);
    final y = int.tryParse(head);
    return y ?? 0;
  }
}

/// 兼容 String 响应体的 JSON 解析
List<dynamic> jsonDecodeCompat(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map && decoded['data'] is List) {
      return decoded['data'] as List;
    }
    if (decoded is List) return decoded;
  } catch (_) {}
  return const [];
}