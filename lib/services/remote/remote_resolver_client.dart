import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/storage/settings_keys.dart';

/// 远程解析客户端（YunXiHub 服务器化解析）
///
/// 将 Plugin 规则 JSON 与关键字/剧集链接发送到服务器，
/// 由服务器端的 KazumiResolver（kazumi_resolver.py）执行
/// XPath/API 规则解析，返回结构化结果。
///
/// 设计：远程优先、本地回退。调用方（Plugin.queryBangumi /
/// queryChapterRoads）在远程解析失败时回退到本地 RuleEngine。
class RemoteResolverClient {
  RemoteResolverClient._();

  static final RemoteResolverClient instance = RemoteResolverClient._();

  bool get isConfigured {
    final baseUrl = GStorage.getSetting(SettingsKeys.remoteResolverBaseUrl);
    return baseUrl.trim().isNotEmpty;
  }

  bool get isEnabled {
    return GStorage.getSetting(SettingsKeys.remoteResolverEnable) &&
        isConfigured;
  }

  String get _baseUrl {
    var base = GStorage
        .getSetting(SettingsKeys.remoteResolverBaseUrl)
        .trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  /// 健康检查
  Future<bool> ping() async {
    try {
      final response = await _dio.get('$_baseUrl/api/kazumi/ping');
      final data = response.data;
      if (data is String) {
        final decoded = jsonDecode(data);
        return decoded is Map && decoded['code'] == 0;
      }
      return data is Map && data['code'] == 0;
    } catch (_) {
      return false;
    }
  }

  /// 服务器端搜索。异常语义与本地 RuleEngine 一致：
  /// - [CaptchaRequiredException] 源站要求验证码
  /// - [NoResultException] 无搜索结果
  /// - [SearchErrorException] 搜索失败
  Future<PluginSearchResponse> search(
    Map<String, dynamic> pluginJson,
    String keyword,
  ) async {
    final data = await _post('/api/kazumi/search', {
      'plugin': pluginJson,
      'keyword': keyword,
    });
    final code = data['code'];
    if (code == 4) {
      throw CaptchaRequiredException(
        data['pluginName']?.toString() ?? pluginJson['name']?.toString() ?? '',
      );
    }
    if (code == 5) {
      throw NoResultException(
        data['pluginName']?.toString() ?? pluginJson['name']?.toString() ?? '',
      );
    }
    if (code != 0) {
      throw SearchErrorException(
        pluginJson['name']?.toString() ?? '',
        cause: data['msg']?.toString() ?? 'remote resolver error',
      );
    }
    final result = data['data'];
    final items = <SearchItem>[];
    if (result is Map && result['items'] is List) {
      for (final item in result['items'] as List) {
        if (item is Map) {
          items.add(SearchItem(
            name: item['name']?.toString() ?? '',
            src: item['src']?.toString() ?? '',
          ));
        }
      }
    }
    return PluginSearchResponse(
      pluginName: pluginJson['name']?.toString() ?? '',
      data: items,
    );
  }

  /// 服务器端章节查询。异常语义与本地 RuleEngine 一致：
  /// - [CaptchaRequiredException] 源站要求验证码
  /// - [ChapterErrorException] 章节查询失败
  Future<List<Road>> queryChapters(
    Map<String, dynamic> pluginJson,
    String source,
  ) async {
    final data = await _post('/api/kazumi/chapters', {
      'plugin': pluginJson,
      'source': source,
    });
    final code = data['code'];
    if (code == 4) {
      throw CaptchaRequiredException(
        data['pluginName']?.toString() ?? pluginJson['name']?.toString() ?? '',
      );
    }
    if (code != 0) {
      throw ChapterErrorException(
        pluginJson['name']?.toString() ?? '',
        cause: data['msg']?.toString() ?? 'remote resolver error',
      );
    }
    final result = data['data'];
    final roads = <Road>[];
    if (result is Map && result['roads'] is List) {
      for (final roadJson in result['roads'] as List) {
        if (roadJson is! Map) continue;
        roads.add(Road(
          name: roadJson['name']?.toString() ?? '',
          data: [
            for (final u in (roadJson['data'] as List? ?? []))
              u?.toString() ?? ''
          ],
          identifier: [
            for (final i in (roadJson['identifier'] as List? ?? []))
              i?.toString() ?? ''
          ],
        ));
      }
    }
    return roads;
  }

  /// 同步验证码 cookie 到服务器（客户端 WebView 验证后调用）
  Future<void> syncCookie(String pluginName, String cookie) async {
    try {
      await _post('/api/kazumi/cookie', {
        'pluginName': pluginName,
        'cookie': cookie,
      });
    } catch (_) {
      // cookie 同步失败不阻塞主流程
    }
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      final response = await _dio.post<dynamic>(
        '$_baseUrl$path',
        data: body,
      );
      final raw = response.data;
      if (raw is String) {
        return (jsonDecode(raw) as Map).cast<String, dynamic>();
      }
      if (raw is Map) {
        return raw.cast<String, dynamic>();
      }
      throw const SearchErrorException('', cause: 'invalid remote response');
    } on DioException catch (e) {
      throw SearchErrorException(
        body['pluginName']?.toString() ?? '',
        cause: 'remote request failed: ${e.message}',
      );
    }
  }

  Dio get _dio {
    final token = GStorage.getSetting(SettingsKeys.authToken).trim();
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Content-Type': 'application/json',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      },
    ));
  }
}
