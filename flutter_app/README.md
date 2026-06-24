# Flutter + FastAPI Push Notifications

Projeto de exemplo com app Flutter registrando `FCM token` no backend FastAPI, persistindo `users`, `devices`, `user_device` e `notification_events` em DuckDB, e enviando push via Firebase Cloud Messaging.

## Estrutura

```text
backend/
  app/
    __init__.py
    db.py
    firebase_service.py
    main.py
    schemas.py
  .env.example
  pyproject.toml
flutter_app/
  lib/
    firebase_options.dart
    main.dart
    services/
      api_service.dart
      notification_service.dart
```

## Backend

### Instalar dependencias

```bash
cd backend
uv sync
copy .env.example .env
```

### Configurar Firebase Admin

O backend aceita qualquer uma destas opcoes:

- `backend/firebase-service-account.json`
- um arquivo `*firebase-adminsdk*.json` dentro de `backend/`
- ou um caminho explicito em `FIREBASE_SERVICE_ACCOUNT_PATH`

Importante:

- O arquivo real nao deve ser commitado.
- O backend sobe mesmo sem credencial, mas o endpoint de envio retornara falha ao tentar mandar push.

### Rodar o servidor

```bash
cd backend
uv run python -m app.main
```

Para expor na rede local:

```bash
cd backend
uv run uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

### Endpoints

`GET /health`

```bash
curl http://localhost:8000/health
```

`POST /users/upsert-device`

```bash
curl -X POST http://localhost:8000/users/upsert-device ^
  -H "Content-Type: application/json" ^
  -d "{\"external_user_id\":\"user_123\",\"name\":\"Hanna\",\"email\":\"hanna@example.com\",\"device_uid\":\"install-uuid\",\"platform\":\"android\",\"fcm_token\":\"token\",\"app_version\":\"1.0.0+1\"}"
```

`GET /users/{external_user_id}/devices`

```bash
curl http://localhost:8000/users/user_123/devices
```

`POST /webhooks/send-notification`

```bash
curl -X POST http://localhost:8000/webhooks/send-notification ^
  -H "Content-Type: application/json" ^
  -H "X-API-Key: change-me" ^
  -d "{\"external_user_id\":\"user_123\",\"notification\":{\"title\":\"Pagamento aprovado\",\"body\":\"Seu pagamento foi confirmado.\",\"data\":{\"event\":\"payment_approved\",\"payment_id\":\"pay_123\",\"route\":\"/payments/pay_123\"}}}"
```

`POST /push/send`

Por `external_user_id`:

```bash
curl -X POST http://localhost:8000/push/send ^
  -H "Content-Type: application/json" ^
  -H "X-API-Key: change-me" ^
  -d "{\"external_user_id\":\"user_123\",\"title\":\"Teste manual\",\"body\":\"Push enviada pelo backend.\",\"data\":{\"source\":\"curl\"}}"
```

Por `fcm_token`:

```bash
curl -X POST http://localhost:8000/push/send ^
  -H "Content-Type: application/json" ^
  -H "X-API-Key: change-me" ^
  -d "{\"fcm_token\":\"SEU_FCM_TOKEN\",\"title\":\"Teste manual\",\"body\":\"Push enviada pelo backend.\",\"data\":{\"source\":\"curl\"}}"
```

## Flutter

### Dependencias e configuracao

```bash
cd flutter_app
flutter pub get
```

Antes de rodar o app:

1. Adicione `flutter_app/android/app/google-services.json`.
2. Adicione `flutter_app/ios/Runner/GoogleService-Info.plist`.
3. `lib/firebase_options.dart` ja foi preenchido com a configuracao Web e a VAPID key fornecidas.
4. Para Android/iOS, mantenha os arquivos nativos do Firebase, porque o `appId` Web nao substitui os IDs nativos.

### Base URL do backend

O app usa por padrao:

- Android emulator: `http://10.0.2.2:8000`
- iOS simulator: `http://localhost:8000`

Voce pode sobrescrever com `--dart-define`:

```bash
flutter run --dart-define=BACKEND_BASE_URL=http://192.168.1.10:8000
```

### Rodar

```bash
cd flutter_app
flutter run
```

### AndroidManifest

O projeto ja inclui:

- `android.permission.INTERNET`
- `android.permission.POST_NOTIFICATIONS`

## Fluxo esperado

1. O app inicializa o Firebase.
2. Solicita permissao de notificacao.
3. Obtem o FCM token.
4. Gera e persiste um `device_uid`.
5. Faz `POST /users/upsert-device`.
6. O backend persiste o usuario, device e vinculo.
7. Um webhook chama `POST /webhooks/send-notification`.
8. O backend envia push para todos os devices ativos e registra o evento em `notification_events`.

## Observacoes

- `backend/app.duckdb` esta no `.gitignore`.
- `backend/.venv` tambem esta no `.gitignore`.
- Se o FCM token mudar, o app envia um novo `upsert-device` automaticamente.
- Para iOS, habilite as capacidades de Push Notifications e Background Modes no Xcode antes de testar notificacoes remotas.
