````markdown
# ðŸ›¡ï¸ Netsapp Watchdog - Monitoramento e RecuperaÃ§Ã£o AutomÃ¡tica

Script shell profissional para monitoramento e recuperaÃ§Ã£o automÃ¡tica de sistemas Ticketz rodando em Docker.

## ðŸŽ¯ O que faz?

Monitora o backend a cada 1 minuto e, em caso de falha, executa recuperaÃ§Ã£o automÃ¡tica em 3 nÃ­veis:

- **NÃ­vel 1** (ReinÃ­cio RÃ¡pido): `docker compose down/up` â†’ ~2 minutos
- **NÃ­vel 2** (Update Completo): Executa `curl update.ticke.tz` â†’ ~5-8 minutos  
- **NÃ­vel 3** (Falha CrÃ­tica): Gera diagnÃ³stico completo e alerta

**Taxa de sucesso:** ~99% (90% NÃ­vel 1, 9% NÃ­vel 2, 1% requer intervenÃ§Ã£o)

## âœ¨ Funcionalidades

âœ… Monitoramento automÃ¡tico via cron (1 em 1 minuto)  
âœ… Sistema de lock (previne execuÃ§Ãµes simultÃ¢neas)  
âœ… ProteÃ§Ã£o contra falsos positivos (detecta updates em andamento)  
âœ… Backup automÃ¡tico de logs (FULL ou TAIL configurÃ¡vel)  
âœ… NotificaÃ§Ã£o via webhook (n8n, Make, Zapier, etc)  
âœ… Payload JSON estruturado  
âœ… 3 nÃ­veis de recuperaÃ§Ã£o escalonada  
âœ… Logging detalhado  

## ðŸ“Š Antes vs Depois

| SituaÃ§Ã£o | Sem Watchdog | Com Watchdog |
|---|---|---|
| **DetecÃ§Ã£o** | Manual (horas) | AutomÃ¡tica (1 min) |
| **RecuperaÃ§Ã£o** | Manual (minutos) | AutomÃ¡tica (2-8 min) |
| **Downtime** | 30min - 2h | 3-10 min |
| **NotificaÃ§Ã£o** | Clientes reclamam | Webhook automÃ¡tico |

## ðŸš€ InstalaÃ§Ã£o RÃ¡pida

### PrÃ©-requisitos

- Ubuntu/Debian com Docker
- Sistema Ticketz rodando em Docker Compose
- (Opcional) n8n, Make ou Zapier para notificaÃ§Ãµes

### Passo 1: Criar estrutura

```bash
# Criar diretÃ³rio
mkdir -p /home/ubuntu/watchdog/logs
cd /home/ubuntu/watchdog

# Baixar script
wget https://raw.githubusercontent.com/leostrongGG/netsapp-watchdog/main/netsapp-watchdog.sh

# Dar permissÃ£o
chmod +x netsapp-watchdog.sh
```

### Passo 2: Configurar variÃ¡veis

```bash
nano netsapp-watchdog.sh
```

**Editar no topo do arquivo:**

```bash
# ===== CONFIGURAÃ‡Ã•ES PRINCIPAIS =====
COMPOSE_DIR="/home/ubuntu/ticketz-docker-acme"  # â† SEU diretÃ³rio Docker
LOG_DIR="/home/ubuntu/watchdog/logs"
BACKEND_CONTAINER="ticketz-docker-acme-backend-1"
BACKEND_URL="http://ticketz-docker-acme-backend-1:3000/"

# ===== BACKUP DE LOGS =====
SAVE_BACKEND_LOGS=true        # true = salva | false = nÃ£o salva
BACKUP_TYPE="FULL"            # FULL = completo | TAIL = Ãºltimas N linhas
BACKUP_TAIL_LINES=50000       # Quantidade de linhas (se TAIL)

# ===== WEBHOOK (NOTIFICAÃ‡Ã•ES) =====
WEBHOOK_URL="https://seu-n8n.com/webhook/watchdog"  # â† SUA URL
WEBHOOK_AUTH_HEADER="Bearer seu_token_aqui"                 # â† SEU TOKEN
# Deixe vazio ("") para desabilitar notificaÃ§Ãµes
```

### Passo 3: Testar

```bash
# Verificar sintaxe
bash -n netsapp-watchdog.sh

# Executar teste
./netsapp-watchdog.sh
```

**SaÃ­da esperada:**
```
[2026-01-07 05:40:00] ðŸ”’ Lock adquirido (PID: 123456, timeout: 1200s)
[2026-01-07 05:40:00] ðŸ” Iniciando verificaÃ§Ã£o do Netsapp
[2026-01-07 05:40:00] âœ… Backend OK (HTTP 200) - tentativa 1
[2026-01-07 05:40:00] âœ… Sistema operacional - nenhuma aÃ§Ã£o necessÃ¡ria
[2026-01-07 05:40:00] ðŸ”“ Lock liberado
```

### Passo 4: Configurar cron

```bash
crontab -e
```

**Adicionar:**
```bash
# Watchdog Netsapp - VerificaÃ§Ã£o a cada 1 minuto
* * * * * /home/ubuntu/watchdog/netsapp-watchdog.sh
```

**Salvar e fechar** (CTRL+O, ENTER, CTRL+X)

### Passo 5: Verificar funcionamento

```bash
# Ver logs em tempo real
tail -f /home/ubuntu/watchdog/logs/watchdog.log

# Simular crash para testar
cd /home/ubuntu/ticketz-docker-acme
sudo docker compose stop backend
# Aguardar 1-2 minutos e verificar recuperaÃ§Ã£o automÃ¡tica
```

## âš™ï¸ ConfiguraÃ§Ãµes DisponÃ­veis

### Backup de Logs

```bash
# Backup COMPLETO (todas as linhas - pode ser grande e demorado)
SAVE_BACKEND_LOGS=true
BACKUP_TYPE="FULL"

# Backup PARCIAL (mais rÃ¡pido - recomendado)
SAVE_BACKEND_LOGS=true
BACKUP_TYPE="TAIL"
BACKUP_TAIL_LINES=50000  # Ãšltimas 50 mil linhas (~5-10s)

# SEM backup (mais rÃ¡pido - nÃ£o recomendado)
SAVE_BACKEND_LOGS=false
```

### NotificaÃ§Ãµes via Webhook

O script envia dados em JSON para qualquer webhook (n8n, Make, Zapier, etc):

```json
{
  "event": "watchdog_alert",
  "timestamp": "2026-01-07 05:36:43",
  "hostname": "ticketz",
  "level": 1,
  "status": "success",
  "message": "Sistema recuperado automaticamente via NÃ­vel 1 (ReinÃ­cio RÃ¡pido)",
  "details": {
    "crash_log_filename": "backend-crash_20260107_053552.log",
    "crash_log_path": "/home/ubuntu/watchdog/logs/backend-crash_20260107_053552.log",
    "crash_log_size": "9.1M",
    "crash_log_lines": "109280",
    "recovery_duration": "51s"
  }
}
```

**No n8n, vocÃª pode:**
- Enviar WhatsApp (via Evolution API, Baileys, Netsapp API)
- Enviar Telegram
- Enviar Email
- Enviar SMS
- Qualquer integraÃ§Ã£o disponÃ­vel

### Sistema de Lock

```bash
LOCK_TIMEOUT=1200  # 20 minutos (tempo mÃ¡ximo de execuÃ§Ã£o)
```

Previne mÃºltiplas instÃ¢ncias rodando simultaneamente. Se o script travar por mais de 20 minutos, o lock Ã© removido automaticamente.

### ProteÃ§Ã£o contra Updates

```bash
UPDATE_DETECTION_WAIT=30  # 30 segundos
```

Quando o backend nÃ£o Ã© encontrado, aguarda 30s para confirmar se Ã©:
- **Update em andamento** â†’ NÃ£o faz nada, aguarda prÃ³xima verificaÃ§Ã£o
- **Crash real** â†’ Prossegue com recuperaÃ§Ã£o

## ðŸ“ Estrutura de Arquivos

```
/home/ubuntu/watchdog/
â”œâ”€â”€ netsapp-watchdog.sh          # Script principal
â””â”€â”€ logs/
    â”œâ”€â”€ watchdog.log              # Log principal do watchdog
    â”œâ”€â”€ backend-crash_*.log       # Logs de crashes do backend
    â””â”€â”€ CRITICAL-FAILURE_*.log    # RelatÃ³rios de falhas crÃ­ticas
```

## ðŸ§ª Testando RecuperaÃ§Ã£o

### Simular crash:

```bash
cd /home/ubuntu/ticketz-docker-acme
sudo docker compose stop backend
```

### Acompanhar recuperaÃ§Ã£o:

```bash
tail -f /home/ubuntu/watchdog/logs/watchdog.log
```

### Verificar webhook (se configurado):

Acesse seu n8n/Make/Zapier e veja o webhook recebido com todos os dados.

## ðŸ“Š NÃ­veis de RecuperaÃ§Ã£o

### NÃ­vel 1 - ReinÃ­cio RÃ¡pido (~90% dos casos)

```bash
1. Salva log do backend
2. docker compose down backend frontend
3. docker compose up -d backend frontend
4. Aguarda 40s
5. Verifica se voltou
```

**Tempo:** ~2 minutos  
**Taxa de sucesso:** ~90%

### NÃ­vel 2 - Update Completo (~9% dos casos)

```bash
1. Executa: curl -sSL update.ticke.tz | sudo bash
2. Pull de imagens + down + up
3. Aguarda 120s
4. Verifica 5x (a cada 30s)
```

**Tempo:** ~5-8 minutos  
**Taxa de sucesso:** ~9%

### NÃ­vel 3 - Falha CrÃ­tica (~1% dos casos)

```bash
1. Gera relatÃ³rio de diagnÃ³stico completo
2. Envia webhook com status "critical"
3. Aguarda intervenÃ§Ã£o manual
```

**Requer:** IntervenÃ§Ã£o humana

## ðŸ”§ Troubleshooting

### Webhook nÃ£o recebe dados

1. Verificar se workflow estÃ¡ **ATIVO** no n8n
2. Verificar URL do webhook (deve ser `/webhook/...` em produÃ§Ã£o)
3. Testar manualmente:

```bash
curl -X POST "https://seu-n8n.com/webhook/watchdog" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer seu_token" \
  -d '{"test":"ok"}'
```

### Lock travado

Se o script nÃ£o executar e mostrar "Outra instÃ¢ncia rodando", mas nÃ£o hÃ¡ nenhuma:

```bash
# Remover lock manualmente
rm /tmp/netsapp-watchdog.lock

# Executar novamente
/home/ubuntu/watchdog/netsapp-watchdog.sh
```

### Cron nÃ£o executa

```bash
# Ver logs do cron
grep CRON /var/log/syslog | tail -20

# Verificar se cron estÃ¡ ativo
sudo systemctl status cron
```

## ðŸ“ˆ EstatÃ­sticas de Uso

Baseado em testes reais:

| MÃ©trica | Valor |
|---|---|
| Tempo de detecÃ§Ã£o | 1 minuto (cron) |
| Tempo recuperaÃ§Ã£o NÃ­vel 1 | 2 minutos |
| Tempo recuperaÃ§Ã£o NÃ­vel 2 | 5-8 minutos |
| Taxa de sucesso total | 99% |
| ReduÃ§Ã£o de downtime | 90-95% |

## ðŸ¤ Contribuindo

ContribuiÃ§Ãµes sÃ£o bem-vindas! Sinta-se livre para:

- Abrir issues para reportar bugs
- Sugerir melhorias
- Enviar pull requests

## ðŸ“„ LicenÃ§a

MIT License - Sinta-se livre para usar, modificar e distribuir.

## ðŸ‘¤ Autor

**Leonardo - Netsapp**
- Site: https://netsapp.com.br
- Sistema SaaS de atendimento para WhatsApp

## ðŸ™ Agradecimentos

Desenvolvido para a comunidade Ticketz com o objetivo de reduzir downtimes e automatizar recuperaÃ§Ã£o de sistemas.

---

â­ Se este script ajudou vocÃª, considere dar uma estrela no repositÃ³rio!
```

***
***
