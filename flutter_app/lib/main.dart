import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import 'services/api_service.dart';
import 'services/notification_service.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint('Background message received: ${message.messageId}');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  runApp(const PushDemoApp());
}

class PushDemoApp extends StatelessWidget {
  const PushDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF0A7D69),
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: const Color(0xFFF3F7F5),
      useMaterial3: true,
    );

    return MaterialApp(
      title: 'FCM Device Register',
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: const NotificationHomePage(),
    );
  }
}

class NotificationHomePage extends StatefulWidget {
  const NotificationHomePage({super.key});

  @override
  State<NotificationHomePage> createState() => _NotificationHomePageState();
}

class _NotificationHomePageState extends State<NotificationHomePage> {
  late ApiService _apiService;
  late final NotificationService _notificationService;
  late final TextEditingController _externalUserIdController;
  late final TextEditingController _nameController;
  late final TextEditingController _emailController;
  late final TextEditingController _backendUrlController;
  late final TextEditingController _webhookApiKeyController;
  late final TextEditingController _delaySecondsController;

  String _status = 'Inicializando Firebase Messaging...';
  String _fcmToken = 'Aguardando token...';
  String _lastMessage = 'Nenhuma mensagem recebida ainda.';
  String _lastSync = 'Nenhum sync executado.';
  String _lastWebhook = 'Nenhum webhook enviado.';
  bool _isSyncing = false;
  bool _isSendingWebhook = false;

  @override
  void initState() {
    super.initState();
    _apiService = ApiService();
    _notificationService = NotificationService();
    _externalUserIdController = TextEditingController();
    _nameController = TextEditingController();
    _emailController = TextEditingController();
    _backendUrlController = TextEditingController();
    _webhookApiKeyController = TextEditingController();
    _delaySecondsController = TextEditingController(text: '10');
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await _apiService.loadConfiguredBaseUrl();
      _backendUrlController.text = _apiService.baseUrl;
      _webhookApiKeyController.text = _apiService.webhookApiKey;
      final profile = await _apiService.getStoredUserProfile();
      _externalUserIdController.text = profile.externalUserId;
      _nameController.text = profile.name;
      _emailController.text = profile.email;

      _notificationService.registerMessageListeners(
        onMessage: (message) async {
          await _notificationService.showForegroundNotification(message);
          _updateLastMessage('Foreground: ${_describeMessage(message)}');
        },
        onMessageOpenedApp: (message) {
          _updateLastMessage('Opened app: ${_describeMessage(message)}');
        },
      );

      _notificationService.registerTokenRefreshListener((token) async {
        if (!mounted) {
          return;
        }
        setState(() {
          _fcmToken = token;
          _status = 'Token atualizado pelo Firebase. Sincronizando backend...';
        });
        await _syncDevice(tokenOverride: token);
      });

      final initialMessage = await _notificationService.getInitialMessage();
      if (initialMessage != null) {
        _updateLastMessage(
          'Initial message: ${_describeMessage(initialMessage)}',
        );
      }

      final bootstrap = await _notificationService.initAndGetToken();
      final token = bootstrap.token;

      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Permissao: ${bootstrap.settings.authorizationStatus.name}.';
        _fcmToken = token ?? 'Token indisponivel.';
      });

      if (token != null && token.isNotEmpty) {
        await _syncDevice(tokenOverride: token);
      } else {
        setState(() {
          _lastSync = 'Nao foi possivel obter o FCM token.';
        });
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Erro ao inicializar notificacoes: $error';
      });
    }
  }

  String _describeMessage(RemoteMessage message) {
    final title = message.notification?.title ?? 'Sem titulo';
    final body = message.notification?.body ?? 'Sem corpo';
    return '$title | $body | data=${message.data}';
  }

  void _updateLastMessage(String value) {
    if (!mounted) {
      return;
    }
    setState(() {
      _lastMessage = value;
    });
  }

  Future<void> _syncDevice({String? tokenOverride}) async {
    final externalUserId = _externalUserIdController.text.trim().isEmpty
        ? 'user_123'
        : _externalUserIdController.text.trim();
    final name = _nameController.text.trim().isEmpty
        ? 'Hanna'
        : _nameController.text.trim();
    final email = _emailController.text.trim().isEmpty
        ? 'hanna@example.com'
        : _emailController.text.trim();
    final token = tokenOverride ?? _fcmToken;

    if (token.isEmpty ||
        token == 'Aguardando token...' ||
        token == 'Token indisponivel.') {
      if (!mounted) {
        return;
      }
      setState(() {
        _lastSync = 'Sem token valido para enviar ao backend.';
      });
      return;
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _isSyncing = true;
      _status = 'Registrando device no backend...';
    });

    try {
      final result = await _apiService.upsertUserDevice(
        externalUserId: externalUserId,
        name: name,
        email: email,
        fcmToken: token,
      );

      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Device sincronizado com sucesso.';
        _lastSync =
            'user_id=${result.userId} | device_id=${result.deviceId} | device_uid=${result.deviceUid}';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Falha ao registrar device no backend.';
        _lastSync = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
        });
      }
    }
  }

  Future<void> _saveBackendUrl() async {
    final value = _backendUrlController.text.trim();
    if (value.isEmpty) {
      setState(() {
        _status = 'Informe a URL do backend.';
      });
      return;
    }

    if (!ApiService.isValidBaseUrl(value)) {
      setState(() {
        _status = 'URL invalida. Exemplo: http://192.168.1.10:8000';
      });
      return;
    }

    try {
      await _apiService.setBaseUrl(value);
      await _apiService.setWebhookApiKey(_webhookApiKeyController.text);
      await _apiService.checkHealth();
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Backend acessivel e configurado.';
        _lastSync = 'Backend configurado para ${_apiService.baseUrl}';
      });
      await _syncDevice();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Falha ao salvar a URL do backend.';
        _lastSync = error.toString();
      });
    }
  }

  Future<void> _scheduleSimulatedWebhook() async {
    final externalUserId = _externalUserIdController.text.trim().isEmpty
        ? 'user_123'
        : _externalUserIdController.text.trim();
    final delaySeconds = int.tryParse(_delaySecondsController.text.trim());

    if (delaySeconds == null || delaySeconds < 0 || delaySeconds > 300) {
      setState(() {
        _status = 'Delay invalido. Use um valor entre 0 e 300 segundos.';
      });
      return;
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _isSendingWebhook = true;
      _status = 'Agendando webhook no backend...';
    });

    try {
      await _apiService.setWebhookApiKey(_webhookApiKeyController.text);
      final result = await _apiService.scheduleTestNotification(
        externalUserId: externalUserId,
        title: 'Teste de push',
        body: 'Push agendada pelo backend para entrega via Firebase.',
        delaySeconds: delaySeconds,
      );

      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Webhook agendado no backend.';
        _lastWebhook =
            'scheduled=${result.scheduled} | delay=${result.delaySeconds}s | user=${result.externalUserId}';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Falha ao agendar webhook.';
        _lastWebhook = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSendingWebhook = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _externalUserIdController.dispose();
    _nameController.dispose();
    _emailController.dispose();
    _backendUrlController.dispose();
    _webhookApiKeyController.dispose();
    _delaySecondsController.dispose();
    _notificationService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFE9F7F2), Color(0xFFF9FCFB)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                'FCM Device Register',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF0F3D36),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Sincroniza o token do device com o backend FastAPI e deixa o webhook pronto para enviar push.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: const Color(0xFF44635B),
                ),
              ),
              const SizedBox(height: 20),
              _InfoCard(
                title: 'Status',
                content: _status,
                accent: const Color(0xFF0A7D69),
              ),
              const SizedBox(height: 16),
              _InfoCard(
                title: 'Backend',
                content: _apiService.baseUrl,
                accent: const Color(0xFF1E5FA8),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _backendUrlController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Backend URL',
                  hintText: 'http://192.168.1.10:8000',
                  border: OutlineInputBorder(),
                  helperText:
                      'No Android fisico, use o IP do PC na rede local.',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _webhookApiKeyController,
                decoration: const InputDecoration(
                  labelText: 'Webhook API Key',
                  hintText: 'change-me',
                  border: OutlineInputBorder(),
                  helperText:
                      'Use a mesma key configurada no backend. Pode ficar vazio se o backend nao exigir.',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _delaySecondsController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Delay do webhook (segundos)',
                  hintText: '10',
                  border: OutlineInputBorder(),
                  helperText:
                      'Toque no botao, minimize a app e espere o backend disparar via Firebase.',
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _saveBackendUrl,
                icon: const Icon(Icons.dns),
                label: const Text('Salvar backend, testar e registrar'),
              ),
              const SizedBox(height: 16),
              _InfoCard(
                title: 'FCM Token',
                content: _fcmToken,
                accent: const Color(0xFF6D4CC2),
              ),
              const SizedBox(height: 16),
              _InfoCard(
                title: 'Ultima mensagem',
                content: _lastMessage,
                accent: const Color(0xFFAF5F00),
              ),
              const SizedBox(height: 16),
              _InfoCard(
                title: 'Ultimo sync',
                content: _lastSync,
                accent: const Color(0xFF8A2E52),
              ),
              const SizedBox(height: 16),
              _InfoCard(
                title: 'Ultimo webhook',
                content: _lastWebhook,
                accent: const Color(0xFF944A00),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _externalUserIdController,
                decoration: const InputDecoration(
                  labelText: 'external_user_id',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Nome',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _isSyncing ? null : () => _syncDevice(),
                icon: _isSyncing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: Text(
                  _isSyncing
                      ? 'Sincronizando...'
                      : 'Reenviar / atualizar device no backend',
                ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  backgroundColor: const Color(0xFF0A7D69),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _isSendingWebhook ? null : _scheduleSimulatedWebhook,
                icon: _isSendingWebhook
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.notifications_active),
                label: Text(
                  _isSendingWebhook
                      ? 'Agendando webhook...'
                      : 'Agendar webhook no backend para disparar push',
                ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  backgroundColor: const Color(0xFF1E5FA8),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.title,
    required this.content,
    required this.accent,
  });

  final String title;
  final String content;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SelectableText(content),
        ],
      ),
    );
  }
}
