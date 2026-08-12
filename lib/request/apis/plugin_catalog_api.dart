import 'dart:convert';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/clients/rules_repo_client.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/modules/plugin/plugin_http_module.dart';

class PluginCatalogApi {
  static final RulesRepoClient _client = RulesRepoClient.instance;

  /// 从 YunXiHub 云服务器拉取规则目录（服务器权威规则仓库 /api/kazumi/rules）
  static Future<List<PluginHTTPItem>> getPluginList() async {
    final raw = await _client.getText('${ApiEndpoints.yunxiBase}/api/kazumi/rules');
    final jsonData = json.decode(raw);
    if (jsonData is! Map || jsonData['code'] != 0 || jsonData['data'] is! List) {
      throw const FormatException('Invalid rule catalog response');
    }
    final items = <PluginHTTPItem>[];
    for (final value in jsonData['data'] as List) {
      if (value is! Map) continue;
      final m = Map<String, dynamic>.from(value);
      items.add(PluginHTTPItem(
        name: m['name']?.toString() ?? '',
        version: m['version']?.toString() ?? '1.0',
        useNativePlayer: false,
        author: 'YunXiHub',
        lastUpdate: 0,
        antiCrawlerEnabled: false,
      ));
    }
    return items;
  }

  static PluginCatalogParseResult parsePluginList(String raw) {
    final jsonData = json.decode(raw);
    if (jsonData is! List) {
      throw const FormatException('Rule catalog root must be a JSON array');
    }
    final items = <PluginHTTPItem>[];
    var skippedItems = 0;
    for (var index = 0; index < jsonData.length; index++) {
      try {
        items.add(_parsePluginListItem(jsonData[index], index));
      } on FormatException {
        skippedItems++;
      }
    }
    if (jsonData.isNotEmpty && items.isEmpty) {
      throw const FormatException('Rule catalog contains no valid items');
    }
    return PluginCatalogParseResult(
      items: List.unmodifiable(items),
      skippedItems: skippedItems,
    );
  }

  static PluginHTTPItem _parsePluginListItem(Object? value, int index) {
    if (value is! Map) {
      throw FormatException('Rule catalog item $index must be an object');
    }
    try {
      return PluginHTTPItem.fromJson(Map<String, dynamic>.from(value));
    } catch (error) {
      throw FormatException('Invalid rule catalog item $index: $error');
    }
  }

  static Future<Plugin> getPlugin(String name) async {
    final raw = await _client.getText('${ApiEndpoints.yunxiBase}/api/kazumi/rules/$name');
    final jsonData = json.decode(raw);
    // 服务器返回 {code:0, data:{规则对象}} 或直接规则对象
    if (jsonData is Map && jsonData['data'] is Map) {
      return Plugin.fromJson(Map<String, dynamic>.from(jsonData['data'] as Map));
    }
    if (jsonData is Map && jsonData['name'] != null) {
      return Plugin.fromJson(Map<String, dynamic>.from(jsonData));
    }
    throw FormatException('Rule $name must be a JSON object');
  }
}

class PluginCatalogParseResult {
  const PluginCatalogParseResult({
    required this.items,
    required this.skippedItems,
  });

  final List<PluginHTTPItem> items;
  final int skippedItems;
}
