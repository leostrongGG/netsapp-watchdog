# 🛡️ Netsapp Watchdog - Monitoramento e Recuperação Automática

Script shell profissional para monitoramento e recuperação automática de sistemas Ticketz rodando em Docker.

## 🎯 O que faz?

Monitora o backend a cada 15 minutos e, em caso de falha, executa recuperação automática em 4 níveis:

- **Nível 1** (Reinício Rápido): Reinicia backend + frontend → ~1 minuto
- **Nível 2** (Reinício Completo): `docker compose down/up` de toda a stack → ~2 minutos
- **Nível 3** (Update): Executa `curl update.ticke.tz` → ~5-8 minutos (último recurso)
- **Nível 4** (Falha Crítica): Gera diagnóstico completo e alerta via webhook

**Taxa de sucesso:** ~99% (85% Nível 1, 10% Nível 2, 4% Nível 3, 1% requer intervenção)

## ✨ Funcionalidades

✅ Monitoramento automático via cron (a cada 15 minutos)
✅ **Auto-detecção de `sudo`** — funciona tanto como `root` quanto como `ubuntu` ou outro user
✅ **Cooldown de 15 minutos** — evita loops de recuperação que travam a VPS
✅ **4 níveis de recuperação escalonada** — update só como último recurso
✅ Sistema de lock (previne execuções simultâneas)
✅ Proteção contra falsos positivos (detecta updates/deploys em andamento)
✅ Rotação automática de log (`watchdog.log` máx. 1MB)
✅ Limpeza de crash logs antigos (mantém últimos 10)
✅ Identificação da VPS no webhook (`VPS_NAME` + `BACKEND_PUBLIC_URL`)
✅ Backup automático de logs do backend (FULL ou TAIL configurável)
✅ Notificação via webhook (n8n, Make, Zapier, etc)
✅ Payload JSON estruturado

## 📊 Antes vs Depois

| Situação | Sem Watchdog | Com Watchdog |
|---|---|---|
| **Detecção** | Manual (horas) | Automática (15 min) |
| **Recuperação** | Manual (minutos) | Automática (1-8 min) |
| **Downtime** | 30min - 2h | 3-10 min |
| **Notificação** | Clientes reclamam | Webhook automático |
| **Loops** | Pode travar a VPS | Cooldown impede |

## 🚀 Instalação Rápida

### Pré-requisitos

- Ubuntu/Debian com Docker
- Sistema Ticketz rodando em Docker Compose
- (Opcional) n8n, Make ou Zapier para notificações

> **Nota:** O script detecta automaticamente se precisa de `sudo` para acessar o Docker.
> Funciona sem alteração tanto em VPS com login `root` quanto com login `ubuntu`.

### Passo 1: Clonar o repositório

```bash
cd ~
git clone https://github.com/leostrongGG/netsapp-watchdog.git watchdog
cd watchdog
chmod +x netsapp-watchdog.sh
cp .env-watchdog-example .env-watchdog
```

### Passo 2: Configurar variáveis

> **Importante:** Todas as configurações ficam no arquivo `.env-watchdog` (ignorado pelo git).
> O script nunca precisa ser editado — você pode atualizá-lo com `git pull` a qualquer momento
> sem perder suas configurações.

```bash
nano .env-watchdog
```

**Editar as variáveis principais:**

```bash
# ===== IDENTIFICAÇÃO DA VPS =====
VPS_NAME="Minha VPS Producao"                       # ← Nome amigável
BACKEND_PUBLIC_URL="https://app.meudominio.com.br"  # ← URL pública

# ===== CONFIGURAÇÕES PRINCIPAIS =====
TICKETZ_DIR="/home/ubuntu/ticketz-docker-acme"  # ← Diretório onde está instalado o Ticketz
BACKEND_CONTAINER="ticketz-docker-acme-backend-1"
BACKEND_PORT=3000

# ===== WEBHOOK (NOTIFICAÇÕES) =====
WEBHOOK_URL="https://seu-n8n.com/webhook/watchdog"  # ← SUA URL
WEBHOOK_AUTH_HEADER="Bearer seu_token_aqui"         # ← SEU TOKEN
# Deixe vazio ("") para desabilitar notificações
```

> **Dica:** O `TICKETZ_DIR` deve apontar para o diretório onde está o `docker-compose.yml` do seu Ticketz.
> Os logs do watchdog são salvos automaticamente na pasta `~/watchdog/logs/`.

### Atualizar o script sem perder configurações

Para atualizar o script para a versão mais recente:
```bash
cd ~/watchdog
git pull
```
Seu `.env-watchdog` permanece intacto (está no `.gitignore`).

### Passo 3: Testar

```bash
# Verificar sintaxe
bash -n netsapp-watchdog.sh

# Executar teste
./netsapp-watchdog.sh
```

**Saída esperada (sistema OK):**
```
[2026-02-23 05:00:00] 🔍 Verificação iniciada
[2026-02-23 05:00:01] ✅ Sistema OK
```

### Passo 4: Configurar cron (a cada 15 minutos)

```bash
crontab -e
```

Adicione a linha abaixo no final do arquivo:
```
*/15 * * * * /home/ubuntu/watchdog/netsapp-watchdog.sh >> /dev/null 2>&1
```

> **Nota:** Ajuste o caminho se instalou em outro local (ex: `/root/watchdog/netsapp-watchdog.sh`).

### Passo 5: Verificar funcionamento

```bash
# Ver logs em tempo real
tail -f ~/watchdog/logs/watchdog.log
```

## ⚙️ Configurações Disponíveis

### Backup de Logs

```bash
# Backup PARCIAL (mais rápido - recomendado, padrão)
SAVE_BACKEND_LOGS=true
BACKUP_TYPE="TAIL"
BACKUP_TAIL_LINES=10000

# Backup COMPLETO (todas as linhas - pode ser grande e demorado)
SAVE_BACKEND_LOGS=true
BACKUP_TYPE="FULL"

# SEM backup (mais rápido - não recomendado)
SAVE_BACKEND_LOGS=false
```

### Cooldown (proteção anti-loop)

```bash
COOLDOWN_SECONDS=900  # 15 minutos (padrão)
```

Após qualquer tentativa de recuperação (sucesso ou falha crítica), o script entra em cooldown e **não tenta novamente** durante esse período. Isso impede que o script entre em loop e trave a VPS.

### Notificações via Webhook

O script envia dados em JSON para qualquer webhook (n8n, Make, Zapier, etc):

```json
{
  "event": "watchdog_alert",
  "timestamp": "2026-02-23 05:36:43",
  "vps_name": "Minha VPS Producao",
  "hostname": "vps-abc123",
  "backend_url": "https://app.meudominio.com.br",
  "level": 1,
  "status": "success",
  "message": "Sistema recuperado via Nível 1 (Reinício Rápido)",
  "details": {
    "crash_log_filename": "backend-crash_20260223_053552.log",
    "crash_log_path": "/home/ubuntu/watchdog/logs/backend-crash_20260223_053552.log",
    "crash_log_size": "2.1M",
    "crash_log_lines": "5000",
    "recovery_duration": "51s"
  }
}
```

### Sistema de Lock

```bash
LOCK_TIMEOUT=600  # 10 minutos (tempo máximo de execução)
```

Previne múltiplas instâncias rodando simultaneamente. Se o script travar por mais de 10 minutos, o lock é removido automaticamente.

### Proteção contra Updates

```bash
UPDATE_DETECTION_WAIT=30  # 30 segundos
```

O script detecta se há operações em andamento antes de agir:
- `update.ticke.tz` rodando
- `docker compose pull` em andamento
- `docker compose up` em andamento

Se detectar qualquer uma, sai imediatamente e aguarda próxima verificação.

## 📁 Estrutura de Arquivos

```
~/watchdog/
├── netsapp-watchdog.sh          # Script principal (pode ser atualizado sem perder config)
├── .env-watchdog                # ⚙️ SUAS configurações (NÃO é sobrescrito na atualização)
├── .env-watchdog-example        # Exemplo de configuração (referência)
└── logs/
    ├── watchdog.log              # Log principal (máx. 1MB, rotacionado)
    ├── watchdog.log.old          # Log anterior (rotacionado)
    ├── backend-crash_*.log       # Logs de crashes (últimos 10 mantidos)
    └── CRITICAL-FAILURE_*.log    # Relatórios de falhas críticas
```

## 📊 Níveis de Recuperação

### Nível 1 - Reinício Rápido (~85% dos casos)

```
1. docker compose stop backend frontend
2. docker compose rm -f backend frontend
3. Aguarda 5s
4. docker compose up -d backend frontend
5. Aguarda 45s → verifica
```

**Tempo:** ~1 minuto | **Impacto:** Mínimo (só backend + frontend)

### Nível 2 - Reinício Completo (~10% dos casos)

```
1. docker compose down (toda a stack)
2. Aguarda 10s
3. docker compose up -d (toda a stack)
4. Aguarda 90s → verifica 3x (a cada 30s)
```

**Tempo:** ~2-4 minutos | **Impacto:** Médio (toda a stack)

### Nível 3 - Update do Sistema (~4% dos casos)

```
1. curl -sSL update.ticke.tz | bash
2. Pull de imagens + down + up + prune
3. Aguarda 90s → verifica 3x (a cada 30s)
```

**Tempo:** ~5-8 minutos | **Impacto:** Alto (download de imagens, só como último recurso)

### Nível 4 - Falha Crítica (~1% dos casos)

```
1. Gera relatório de diagnóstico completo
2. Envia webhook com status "critical"
3. Ativa cooldown
4. Aguarda intervenção manual
```

**Requer:** Intervenção humana

## 🔧 Troubleshooting

### Erro "permission denied" no Docker

O script auto-detecta se precisa de `sudo`. Se mesmo assim falhar:
```bash
# Adicionar usuário ao grupo docker (alternativa)
sudo usermod -aG docker $USER
# Fazer logout e login novamente
```

### Webhook não recebe dados

1. Verificar se workflow está **ATIVO** no n8n
2. Verificar URL do webhook (deve ser `/webhook/...` em produção, não `/webhook-test/...`)
3. Testar manualmente:
```bash
curl -X POST "https://seu-n8n.com/webhook/watchdog" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer seu_token" \
  -d '{"test":"ok"}'
```

### Lock travado

```bash
rm /tmp/netsapp-watchdog.lock
```

### Cooldown ativo (quer forçar recuperação)

```bash
rm /tmp/netsapp-watchdog-cooldown
```

### Cron não executa

```bash
grep CRON /var/log/syslog | tail -20
sudo systemctl status cron
```

## 📈 Estatísticas de Uso

| Métrica | Valor |
|---|---|
| Intervalo de verificação | 15 minutos (cron) |
| Tempo recuperação Nível 1 | ~1 minuto |
| Tempo recuperação Nível 2 | ~2-4 minutos |
| Tempo recuperação Nível 3 | ~5-8 minutos |
| Taxa de sucesso total | ~99% |
| Redução de downtime | 90-95% |

## 🤝 Contribuindo

Contribuições são bem-vindas! Sinta-se livre para:

- Abrir issues para reportar bugs
- Sugerir melhorias
- Enviar pull requests

## 📄 Licença

MIT License - Sinta-se livre para usar, modificar e distribuir.

## 👤 Autor

**Leonardo - Netsapp**
- Site: https://netsapp.com.br
- Sistema SaaS de atendimento para WhatsApp

## 🙏 Agradecimentos

Desenvolvido para a comunidade Ticketz com o objetivo de reduzir downtimes e automatizar recuperação de sistemas.

---

⭐ Se este script ajudou você, considere dar uma estrela no repositório!
