import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class ApiException implements Exception {
  ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UserProfile {
  const UserProfile({
    required this.externalUserId,
    required this.name,
    required this.email,
  });

  final String externalUserId;
  final String name;
  final String email;
}

class UpsertDeviceResult {
  const UpsertDeviceResult({
    required this.userId,
    required this.deviceId,
    required this.externalUserId,
    required this.deviceUid,
  });

  final String userId;
  final String deviceId;
  final String externalUserId;
  final String deviceUid;

  factory UpsertDeviceResult.fromJson(Map<String, dynamic> json) {
    return UpsertDeviceResult(
      userId: json['user_id'] as String,
      deviceId: json['device_id'] as String,
      externalUserId: json['external_user_id'] as String,
      deviceUid: json['device_uid'] as String,
    );
  }
}

class WebhookSendResult {
  const WebhookSendResult({
    required this.externalUserId,
    required this.devicesFound,
    required this.sentCount,
    required this.failedCount,
  });

  final String externalUserId;
  final int devicesFound;
  final int sentCount;
  final int failedCount;

  factory WebhookSendResult.fromJson(Map<String, dynamic> json) {
    return WebhookSendResult(
      externalUserId: json['external_user_id'] as String,
      devicesFound: json['devices_found'] as int,
      sentCount: json['sent_count'] as int,
      failedCount: json['failed_count'] as int,
    );
  }
}

class ScheduledWebhookResult {
  const ScheduledWebhookResult({
    required this.externalUserId,
    required this.delaySeconds,
    required this.scheduled,
  });

  final String externalUserId;
  final int delaySeconds;
  final bool scheduled;

  factory ScheduledWebhookResult.fromJson(Map<String, dynamic> json) {
    return ScheduledWebhookResult(
      externalUserId: json['external_user_id'] as String,
      delaySeconds: json['delay_seconds'] as int,
      scheduled: json['scheduled'] as bool,
    );
  }
}

class ApiService {
  ApiService({String? baseUrl, http.Client? client})
    : _baseUrl = _normalizeBaseUrl(baseUrl ?? _defaultBaseUrl()),
      _client = client ?? http.Client();

  static const _externalUserIdKey = 'external_user_id';
  static const _nameKey = 'name';
  static const _emailKey = 'email';
  static const _deviceUidKey = 'device_uid';
  static const _backendBaseUrlKey = 'backend_base_url';
  static const _webhookApiKeyKey = 'webhook_api_key';
  static const _requestTimeout = Duration(seconds: 12);

  String _baseUrl;
  String _webhookApiKey = 'change-me';
  final http.Client _client;
  final Uuid _uuid = const Uuid();

  String get baseUrl => _baseUrl;
  String get webhookApiKey => _webhookApiKey;

  static String _normalizeBaseUrl(String value) {
    return value.replaceFirst(RegExp(r'/+$'), '');
  }

  static String _defaultBaseUrl() {
    const override = String.fromEnvironment('BACKEND_BASE_URL');
    if (override.isNotEmpty) {
      return override;
    }

    if (Platform.isAndroid) {
      return 'http://10.0.2.2:8000';
    }

    return 'http://localhost:8000';
  }

  static bool isValidBaseUrl(String value) {
    final uri = Uri.tryParse(_normalizeBaseUrl(value));
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  Future<void> loadConfiguredBaseUrl() async {
    const override = String.fromEnvironment('BACKEND_BASE_URL');
    if (override.isNotEmpty) {
      _baseUrl = _normalizeBaseUrl(override);
    } else {
      final preferences = await SharedPreferences.getInstance();
      final stored = preferences.getString(_backendBaseUrlKey);
      if (stored != null && stored.trim().isNotEmpty) {
        _baseUrl = _normalizeBaseUrl(stored.trim());
      }
    }

    final preferences = await SharedPreferences.getInstance();
    final storedApiKey = preferences.getString(_webhookApiKeyKey);
    if (storedApiKey != null) {
      _webhookApiKey = storedApiKey;
    }
  }

  Future<void> setBaseUrl(String value) async {
    final normalized = _normalizeBaseUrl(value.trim());
    if (!isValidBaseUrl(normalized)) {
      throw ApiException(
        'URL invalida. Use algo como http://192.168.1.10:8000',
      );
    }

    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_backendBaseUrlKey, normalized);
    _baseUrl = normalized;
  }

  Future<void> setWebhookApiKey(String value) async {
    final normalized = value.trim();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_webhookApiKeyKey, normalized);
    _webhookApiKey = normalized;
  }

  Future<void> checkHealth() async {
    late final http.Response response;
    try {
      response = await _client
          .get(Uri.parse('$_baseUrl/health'))
          .timeout(_requestTimeout);
    } on TimeoutException {
      throw ApiException(
        'Timeout ao conectar em $_baseUrl. Confirma se o backend esta rodando e acessivel pela rede.',
      );
    } on SocketException catch (error) {
      throw ApiException(
        'Nao foi possivel acessar $_baseUrl (${error.message}). Em Android fisico, use o IP do PC na rede local.',
      );
    } on http.ClientException catch (error) {
      throw ApiException(
        'Falha de rede ao acessar $_baseUrl: ${error.message}',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        'Healthcheck falhou ${response.statusCode}: ${response.body}',
      );
    }
  }

  Future<String> getOrCreateDeviceUid() async {
    final preferences = await SharedPreferences.getInstance();
    final current = preferences.getString(_deviceUidKey);
    if (current != null && current.isNotEmpty) {
      return current;
    }

    final deviceUid = _uuid.v4();
    await preferences.setString(_deviceUidKey, deviceUid);
    return deviceUid;
  }

  Future<UserProfile> getStoredUserProfile() async {
    final preferences = await SharedPreferences.getInstance();
    return UserProfile(
      externalUserId: preferences.getString(_externalUserIdKey) ?? 'user_123',
      name: preferences.getString(_nameKey) ?? 'Hanna',
      email: preferences.getString(_emailKey) ?? 'hanna@example.com',
    );
  }

  Future<void> persistUserProfile({
    required String externalUserId,
    required String name,
    required String email,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_externalUserIdKey, externalUserId);
    await preferences.setString(_nameKey, name);
    await preferences.setString(_emailKey, email);
  }

  Future<String> _getAppVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    return '${packageInfo.version}+${packageInfo.buildNumber}';
  }

  String _platformName() {
    if (Platform.isAndroid) {
      return 'android';
    }
    if (Platform.isIOS) {
      return 'ios';
    }
    return Platform.operatingSystem;
  }

  Future<UpsertDeviceResult> upsertUserDevice({
    required String externalUserId,
    required String name,
    required String email,
    required String fcmToken,
  }) async {
    final deviceUid = await getOrCreateDeviceUid();
    final appVersion = await _getAppVersion();

    await persistUserProfile(
      externalUserId: externalUserId,
      name: name,
      email: email,
    );

    late final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$_baseUrl/users/upsert-device'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'external_user_id': externalUserId,
              'name': name,
              'email': email,
              'device_uid': deviceUid,
              'platform': _platformName(),
              'fcm_token': fcmToken,
              'app_version': appVersion,
            }),
          )
          .timeout(_requestTimeout);
    } on TimeoutException {
      throw ApiException(
        'Timeout ao conectar em $_baseUrl. Em Android fisico, use a URL do PC na rede local, por exemplo http://192.168.1.10:8000.',
      );
    } on SocketException catch (error) {
      throw ApiException(
        'Nao foi possivel acessar $_baseUrl (${error.message}). Em Android fisico, 10.0.2.2 so funciona no emulador.',
      );
    } on http.ClientException catch (error) {
      throw ApiException(
        'Falha de rede ao acessar $_baseUrl: ${error.message}',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        'Backend error ${response.statusCode}: ${response.body}',
      );
    }

    return UpsertDeviceResult.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<WebhookSendResult> sendTestNotification({
    required String externalUserId,
    required String title,
    required String body,
  }) async {
    late final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$_baseUrl/webhooks/send-notification'),
            headers: {
              'Content-Type': 'application/json',
              if (_webhookApiKey.isNotEmpty) 'X-API-Key': _webhookApiKey,
            },
            body: jsonEncode({
              'external_user_id': externalUserId,
              'notification': {
                'title': title,
                'body': body,
                'data': {'source': 'flutter_app', 'kind': 'simulated_webhook'},
              },
            }),
          )
          .timeout(_requestTimeout);
    } on TimeoutException {
      throw ApiException('Timeout ao chamar o webhook em $_baseUrl.');
    } on SocketException catch (error) {
      throw ApiException(
        'Nao foi possivel chamar o webhook em $_baseUrl (${error.message}).',
      );
    } on http.ClientException catch (error) {
      throw ApiException('Falha de rede ao chamar o webhook: ${error.message}');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        'Webhook error ${response.statusCode}: ${response.body}',
      );
    }

    return WebhookSendResult.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<ScheduledWebhookResult> scheduleTestNotification({
    required String externalUserId,
    required String title,
    required String body,
    required int delaySeconds,
  }) async {
    late final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$_baseUrl/webhooks/send-notification-scheduled'),
            headers: {
              'Content-Type': 'application/json',
              if (_webhookApiKey.isNotEmpty) 'X-API-Key': _webhookApiKey,
            },
            body: jsonEncode({
              'external_user_id': externalUserId,
              'delay_seconds': delaySeconds,
              'notification': {
                'title': title,
                'body': body,
                'data': {
                  'source': 'flutter_app',
                  'kind': 'scheduled_simulated_webhook',
                },
              },
            }),
          )
          .timeout(_requestTimeout);
    } on TimeoutException {
      throw ApiException('Timeout ao agendar o webhook em $_baseUrl.');
    } on SocketException catch (error) {
      throw ApiException(
        'Nao foi possivel agendar o webhook em $_baseUrl (${error.message}).',
      );
    } on http.ClientException catch (error) {
      throw ApiException(
        'Falha de rede ao agendar o webhook: ${error.message}',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        'Scheduled webhook error ${response.statusCode}: ${response.body}',
      );
    }

    return ScheduledWebhookResult.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }
}
