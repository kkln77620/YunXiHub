import 'package:dio/dio.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_error_mapper.dart';
import 'package:kazumi/utils/dandan_credentials.dart';
import 'package:kazumi/utils/http_headers.dart';
import 'package:kazumi/utils/crypto.dart';

class DanmakuClient {
  DanmakuClient._();

  static final DanmakuClient instance = DanmakuClient._();

  Future<dynamic> get(
    String url, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic> headers = const {},
    CancelToken? cancelToken,
  }) async {
    try {
      return await _getOnce(
        url,
        queryParameters: queryParameters,
        headers: headers,
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      // 代理域名不可达时回退官方域名（国内网络偶发/Worker未部署场景）
      final uri = Uri.tryParse(url);
      if (uri != null &&
          uri.host == Uri.parse(ApiEndpoints.dandanAPIDomain).host &&
          ApiEndpoints.dandanAPIOfficialDomain.isNotEmpty) {
        try {
          return await _getOnce(
            url.replaceFirst(
                ApiEndpoints.dandanAPIDomain, ApiEndpoints.dandanAPIOfficialDomain),
            queryParameters: queryParameters,
            headers: headers,
            cancelToken: cancelToken,
          );
        } on DioException {
          // 回退也失败：抛原始异常
        }
      }
      throw await NetworkErrorMapper.mapException(e);
    }
  }

  Future<dynamic> _getOnce(
    String url, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic> headers = const {},
    CancelToken? cancelToken,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final uri = Uri.parse(url);
    final requestHeaders = <String, dynamic>{
      'user-agent': getRandomUA(),
      'referer': '',
      'X-Auth': 1,
      'X-AppId': dandanCredentials['id'],
      'X-Timestamp': timestamp,
      'X-Signature': generateDandanSignature(uri.path, timestamp),
      ...headers,
    };

    final response = await DioFactory.apiDio.get(
      url,
      queryParameters: queryParameters,
      options: Options(headers: requestHeaders),
      cancelToken: cancelToken,
    );
    return response.data;
  }
}
