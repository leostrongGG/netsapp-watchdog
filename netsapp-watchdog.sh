#!/bin/bash

# ===== CONFIGURAÇÕES PRINCIPAIS =====
COMPOSE_DIR="/home/ubuntu/ticketz-docker-acme"
LOG_DIR="/home/ubuntu/watchdog/logs"
BACKEND_CONTAINER="ticketz-docker-acme-backend-1"
BACKEND_URL="http://ticketz-docker-acme-backend-1:3000/"
RETRIES=3
RETRY_DELAY=10  # segundos entre tentativas

# ===== CONFIGURAÇÕES DE BACKUP DE LOGS =====
# Controla se e como os logs do backend serão salvos antes da recuperação
SAVE_BACKEND_LOGS=true           # true = salva logs | false = não salva

# Tipo de backup (usado apenas se SAVE_BACKEND_LOGS=true)
BACKUP_TYPE="FULL"               # FULL = log completo | TAIL = últimas N linhas

# Quantidade de linhas (usado apenas se BACKUP_TYPE="TAIL")
BACKUP_TAIL_LINES=5000           # Número de linhas finais a salvar (ex: 5000, 10000)

# ===== CONFIGURAÇÕES DE NOTIFICAÇÃO VIA WEBHOOK =====
WEBHOOK_URL="https://seu-n8n.com/webhook/watchdog"
                # ← URL do webhook (n8n, Make, Zapier, etc)
                # Deixe vazio para desabilitar notificações

WEBHOOK_AUTH_HEADER="Bearer SEU_TOKEN_AQUI"
                # ← Token de autenticação do webhook
                # Formato: Bearer seu_token_aqui
                # Deixe vazio ("") se não usar autenticação

# ===== SISTEMA DE LOCK =====
LOCK_FILE="/tmp/netsapp-watchdog.lock"
LOCK_TIMEOUT=1200                # 20 minutos (tempo máximo que o script pode rodar)

# ===== PROTEÇÃO CONTRA CONFLITOS DE UPDATE =====
UPDATE_DETECTION_WAIT=30         # Segundos para aguardar e confirmar se é update ou crash

# ===== NÃO ALTERAR DAQUI PARA BAIXO =====

# Criar diretório de logs se não existir
mkdir -p "$LOG_DIR"

WATCHDOG_LOG="$LOG_DIR/watchdog.log"

# Variável global para armazenar path do crash log
CRASH_LOG_PATH=""

# Função para log com timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$WATCHDOG_LOG"
}

# Função para adquirir lock (evitar múltiplas execuções)
acquire_lock() {
    # Verificar se já existe um lock
    if [ -f "$LOCK_FILE" ]; then
        local lock_age=$(($(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0)))
        
        # Se lock tem mais de LOCK_TIMEOUT, é stale (travou), remover
        if [ $lock_age -gt $LOCK_TIMEOUT ]; then
            log_message "⚠️ Lock antigo detectado (${lock_age}s > ${LOCK_TIMEOUT}s), removendo..."
            rm -f "$LOCK_FILE"
        else
            log_message "⏸️ Outra instância do watchdog está rodando (lock age: ${lock_age}s), pulando execução"
            exit 0
        fi
    fi
    
    # Criar lock com PID atual
    echo $$ > "$LOCK_FILE"
    log_message "🔒 Lock adquirido (PID: $$, timeout: ${LOCK_TIMEOUT}s)"
}

# Função para liberar lock
release_lock() {
    if [ -f "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE"
        log_message "🔓 Lock liberado"
    fi
}

# Garantir que lock seja liberado mesmo se script for interrompido
trap release_lock EXIT

# Função para detectar se há update em andamento
detect_update_in_progress() {
    # Verificar se script update.ticke.tz está rodando
    if pgrep -f "update.ticke.tz" > /dev/null; then
        log_message "⏸️ Update manual (update.ticke.tz) em andamento, aguardando próxima verificação..."
        return 0  # 0 = true (update detectado)
    fi
    
    # Verificar se há processo docker compose pull rodando (indica update)
    if pgrep -f "docker.*compose.*pull" > /dev/null; then
        log_message "⏸️ Docker compose pull em andamento, aguardando próxima verificação..."
        return 0
    fi
    
    # Verificar se Watchtower está rodando E backend está ausente
    if pgrep -f "watchtower" > /dev/null; then
        if ! sudo docker ps --format '{{.Names}}' | grep -q "ticketz-docker-acme-backend-1"; then
            log_message "⏸️ Watchtower detectado e backend ausente (provável update), aguardando..."
            return 0
        fi
    fi
    
    return 1  # 1 = false (nenhum update detectado)
}

# Função para verificar se backend está ausente (pode ser update ou crash)
check_backend_exists() {
    if ! sudo docker ps --format '{{.Names}}' | grep -q "ticketz-docker-acme-backend-1"; then
        log_message "⚠️ Backend não encontrado na lista de containers rodando"
        log_message "🕐 Aguardando ${UPDATE_DETECTION_WAIT}s para confirmar se é update ou crash real..."
        sleep $UPDATE_DETECTION_WAIT
        
        # Verificar novamente após aguardar
        if ! sudo docker ps --format '{{.Names}}' | grep -q "ticketz-docker-acme-backend-1"; then
            log_message "🚨 Backend continua ausente após ${UPDATE_DETECTION_WAIT}s - confirmado como crash"
            return 1  # Backend realmente ausente (crash)
        else
            log_message "✅ Backend voltou durante espera - era processo de atualização"
            return 0  # Backend voltou (era update)
        fi
    fi
    
    return 0  # Backend existe
}

# Função para verificar saúde do backend
check_backend() {
    local attempt=1

    while [ $attempt -le $RETRIES ]; do
        # Executa curl DENTRO da rede Docker via container frontend
        HTTP_CODE=$(sudo docker exec ticketz-docker-acme-frontend-1 curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BACKEND_URL" 2>/dev/null)

        if [ "$HTTP_CODE" = "200" ]; then
            log_message "✅ Backend OK (HTTP $HTTP_CODE) - tentativa $attempt"
            return 0
        fi

        log_message "⚠️ Backend falhou (HTTP $HTTP_CODE) - tentativa $attempt/$RETRIES"
        attempt=$((attempt + 1))

        if [ $attempt -le $RETRIES ]; then
            sleep $RETRY_DELAY
        fi
    done

    return 1  # Falhou após todas as tentativas
}

# Função para salvar log do backend (com opções configuráveis)
save_backend_logs() {
    # Verificar se backup está habilitado
    if [ "$SAVE_BACKEND_LOGS" != "true" ]; then
        log_message "⏭️ Backup de logs desabilitado (SAVE_BACKEND_LOGS=false), pulando..."
        CRASH_LOG_PATH="(não salvo)"
        return 0
    fi
    
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    CRASH_LOG_PATH="$LOG_DIR/backend-crash_${timestamp}.log"

    cd "$COMPOSE_DIR"

    if [ "$BACKUP_TYPE" = "FULL" ]; then
        log_message "📝 Salvando LOG COMPLETO do backend (pode demorar ~10-30s)..."
        log_message "📂 Arquivo: $CRASH_LOG_PATH"
        
        # Salvar LOG COMPLETO (sem --tail)
        sudo docker compose logs -t backend > "$CRASH_LOG_PATH" 2>&1
        
    elif [ "$BACKUP_TYPE" = "TAIL" ]; then
        log_message "📝 Salvando ÚLTIMAS ${BACKUP_TAIL_LINES} LINHAS do backend (~2-5s)..."
        log_message "📂 Arquivo: $CRASH_LOG_PATH"
        
        # Salvar apenas últimas N linhas
        sudo docker compose logs -t --tail ${BACKUP_TAIL_LINES} backend > "$CRASH_LOG_PATH" 2>&1
    else
        log_message "⚠️ BACKUP_TYPE inválido ('$BACKUP_TYPE'), usando TAIL com 5000 linhas..."
        BACKUP_TAIL_LINES=5000
        sudo docker compose logs -t --tail ${BACKUP_TAIL_LINES} backend > "$CRASH_LOG_PATH" 2>&1
    fi

    if [ -f "$CRASH_LOG_PATH" ]; then
        local filesize=$(du -h "$CRASH_LOG_PATH" | cut -f1)
        local linecount=$(wc -l < "$CRASH_LOG_PATH")
        log_message "✅ Log salvo com sucesso: $filesize, ${linecount} linhas"
    else
        log_message "❌ ERRO ao salvar log!"
        CRASH_LOG_PATH="(erro ao salvar)"
    fi
}

# Função para enviar notificação via Webhook
send_webhook_notification() {
    local level="$1"
    local status="$2"
    local message="$3"
    local recovery_duration="${4:-}"
    
    # Verificar se webhook está configurado
    if [ -z "$WEBHOOK_URL" ]; then
        log_message "⏭️ Webhook não configurado, pulando notificação..."
        return 0
    fi
    
    log_message "📡 Enviando notificação via webhook..."
    
    # Preparar dados
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local hostname=$(hostname)
    local crash_log_filename="${CRASH_LOG_PATH##*/}"
    local crash_log_size=""
    local crash_log_lines=""
    
    # Obter tamanho e linhas do log (se existir)
    if [ -f "$CRASH_LOG_PATH" ] && [ "$CRASH_LOG_PATH" != "(não salvo)" ] && [ "$CRASH_LOG_PATH" != "(erro ao salvar)" ]; then
        crash_log_size=$(du -h "$CRASH_LOG_PATH" 2>/dev/null | cut -f1)
        crash_log_lines=$(wc -l < "$CRASH_LOG_PATH" 2>/dev/null)
    else
        crash_log_size="N/A"
        crash_log_lines="N/A"
    fi
    
    # Construir payload JSON
    local payload=$(cat <<EOF
{
  "event": "watchdog_alert",
  "timestamp": "$timestamp",
  "hostname": "$hostname",
  "level": $level,
  "status": "$status",
  "message": "$message",
  "details": {
    "crash_log_filename": "$crash_log_filename",
    "crash_log_path": "$CRASH_LOG_PATH",
    "crash_log_size": "$crash_log_size",
    "crash_log_lines": "$crash_log_lines",
    "recovery_duration": "$recovery_duration"
  }
}
EOF
)
    
    # Enviar webhook
    if [ -z "$WEBHOOK_AUTH_HEADER" ]; then
        # Sem autenticação
        local response=$(curl -s -w "\n%{http_code}" -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>&1)
    else
        # Com autenticação
        local response=$(curl -s -w "\n%{http_code}" -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -H "Authorization: $WEBHOOK_AUTH_HEADER" \
            -d "$payload" 2>&1)
    fi
    
    local http_code=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | head -n -1)
    
    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ] || [ "$http_code" = "204" ]; then
        log_message "✅ Webhook enviado com sucesso (HTTP $http_code)"
        log_message "📡 Resposta: $response_body"
        return 0
    else
        log_message "❌ Erro ao enviar webhook (HTTP $http_code)"
        log_message "📡 Resposta: $response_body"
        return 1
    fi
}

# NÍVEL 1: Reinício rápido (down + up)
level1_quick_restart() {
    log_message "🔧 NÍVEL 1: Tentando reinício rápido (down + up)"

    local start_time=$(date +%s)

    cd "$COMPOSE_DIR"

    # Derrubar containers completamente
    log_message "🔽 Derrubando frontend..."
    sudo docker compose down frontend

    log_message "🔽 Derrubando backend..."
    sudo docker compose down backend

    log_message "⏳ Aguardando 10 segundos..."
    sleep 10

    # Recriar containers do zero com -d (detached mode)
    log_message "🔼 Recriando backend e frontend..."
    sudo docker compose up -d backend frontend

    # Aguardar containers iniciarem (up -d demora ~10-20s) + margem
    log_message "⏳ Aguardando 40 segundos para estabilização completa..."
    sleep 40

    # Verificar se recuperou (3 tentativas com 10s cada)
    log_message "🔍 Verificando recuperação..."
    if check_backend; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        log_message "✅ NÍVEL 1: RECUPERAÇÃO BEM-SUCEDIDA!"
        
        # Enviar notificação de recuperação
        send_webhook_notification 1 "success" "Sistema recuperado automaticamente via Nível 1 (Reinício Rápido)" "${duration}s"
        
        return 0
    else
        log_message "❌ NÍVEL 1: FALHOU - Escalando para Nível 2"
        return 1
    fi
}

# NÍVEL 2: Atualização completa do sistema
level2_full_update() {
    log_message "🔧 NÍVEL 2: Executando atualização completa do sistema"
    log_message "⚠️ ATENÇÃO: Este processo pode demorar 2-5 minutos (pull de imagens)"

    # Executar script de atualização oficial
    log_message "📥 Baixando e executando update.ticke.tz..."
    
    local update_start=$(date +%s)
    
    # O script faz: pull (1-5min) + down (~10s) + up (~10-20s) + prune
    if curl -sSL update.ticke.tz | sudo bash >> "$WATCHDOG_LOG" 2>&1; then
        local update_duration=$(($(date +%s) - update_start))
        log_message "✅ Script de atualização executado com sucesso (${update_duration}s)"
    else
        local exit_code=$?
        log_message "❌ ERRO ao executar script de atualização (exit code: $exit_code)"
        return 1
    fi

    # Após update, containers já estão UP mas podem estar inicializando
    log_message "⏳ Aguardando 120 segundos para sistema completo inicializar..."
    sleep 120

    # Verificar se recuperou com tentativas progressivas
    log_message "🔍 Verificando recuperação pós-update (5 tentativas)..."
    
    local max_attempts=5
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        log_message "🔍 Tentativa $attempt/$max_attempts..."
        
        if check_backend; then
            local total_duration=$(($(date +%s) - update_start))
            
            log_message "✅ NÍVEL 2: ATUALIZAÇÃO E RECUPERAÇÃO BEM-SUCEDIDA!"
            
            # Enviar notificação de recuperação
            send_webhook_notification 2 "success" "Sistema recuperado após atualização completa (Update Completo)" "${total_duration}s"
            
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            log_message "⏳ Backend ainda não respondeu, aguardando mais 30s..."
            sleep 30
        fi
        
        attempt=$((attempt + 1))
    done
    
    log_message "❌ NÍVEL 2: FALHOU - Sistema não recuperou após update"
    return 1
}

# NÍVEL 3: Falha crítica - registrar e alertar
level3_critical_failure() {
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local critical_log="$LOG_DIR/CRITICAL-FAILURE_${timestamp}.log"

    log_message "🚨🚨🚨 NÍVEL 3: FALHA CRÍTICA - INTERVENÇÃO MANUAL NECESSÁRIA"

    # Coletar informações de diagnóstico
    {
        echo "========================================="
        echo "FALHA CRÍTICA DO SISTEMA NETSAPP"
        echo "Data/Hora: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Log completo do crash salvo em: $CRASH_LOG_PATH"
        echo "========================================="
        echo ""
        echo "--- STATUS DOS CONTAINERS ---"
        sudo docker ps -a
        echo ""
        echo "--- LOGS DO BACKEND (últimas 100 linhas) ---"
        cd "$COMPOSE_DIR"
        sudo docker compose logs --tail 100 backend 2>&1
        echo ""
        echo "--- LOGS DO FRONTEND (últimas 50 linhas) ---"
        sudo docker compose logs --tail 50 frontend 2>&1
        echo ""
        echo "--- USO DE RECURSOS ---"
        df -h
        echo ""
        free -h
        echo ""
        echo "--- PROCESSOS DOCKER ---"
        sudo docker stats --no-stream
    } > "$critical_log" 2>&1

    log_message "📝 Relatório de falha crítica salvo em: $critical_log"
    log_message "📝 Log completo do backend em: $CRASH_LOG_PATH"

    # Enviar notificação URGENTE via Webhook
    local critical_message="FALHA CRÍTICA! Todos os níveis de recuperação falharam (Nível 1: Reinício Rápido, Nível 2: Update Completo). Intervenção manual necessária. Diagnóstico completo salvo em: ${critical_log##*/}"
    
    send_webhook_notification 3 "critical" "$critical_message" "N/A"

    return 1
}

# ===== EXECUÇÃO PRINCIPAL COM ESCALONAMENTO =====

# Adquirir lock antes de tudo (impede execuções simultâneas)
acquire_lock

log_message "🔍 Iniciando verificação do Netsapp"

# PROTEÇÃO: Detectar se há update em andamento
if detect_update_in_progress; then
    exit 0  # Sai sem fazer nada, aguarda próxima verificação
fi

# PROTEÇÃO: Verificar se backend existe (pode estar sendo atualizado)
if ! check_backend_exists; then
    log_message "🚨 Backend ausente confirmado como crash (não é update)"
    # Continua para recuperação
else
    log_message "✅ Backend existe, prosseguindo com verificação de saúde"
fi

if check_backend; then
    log_message "✅ Sistema operacional - nenhuma ação necessária"
    exit 0
else
    log_message "🚨 Sistema com problemas detectado!"

    # ===== SALVAR LOG DO BACKEND (SE HABILITADO) =====
    save_backend_logs
    # ================================================

    log_message "🔄 Iniciando procedimento de recuperação escalonada..."

    # Tentar Nível 1: Reinício rápido
    if level1_quick_restart; then
        exit 0
    fi

    log_message "⚠️ Nível 1 falhou - aguardando 20s antes do Nível 2..."
    sleep 20

    # Tentar Nível 2: Atualização completa
    if level2_full_update; then
        exit 0
    fi

    log_message "⚠️ Nível 2 falhou - registrando falha crítica..."

    # Nível 3: Falha crítica
    level3_critical_failure
    exit 1
fi
