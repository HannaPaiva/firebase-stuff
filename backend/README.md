# Backend

Este backend sobe com:

```bash
uv run python -m app.main
```

Ou, se preferir explicitar o host:

```bash
uv run uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

O backend procura automaticamente a credencial Firebase em:

- `backend/firebase-service-account.json`
- qualquer arquivo `*firebase-adminsdk*.json` dentro de `backend/`
- ou o caminho definido em `FIREBASE_SERVICE_ACCOUNT_PATH`

As instrucoes completas do projeto estao em `../README.md`.
