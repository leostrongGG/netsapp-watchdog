#!/bin/bash

# ===== CARREGAR CONFIGURAÇÕES EXTERNAS =====
# O arquivo .env-watchdog deve estar no mesmo diretório do script.
# Copie .env-watchdog-example para .env-watchdog e edite seus valores.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env-watchdog"

if [ ! -f "$ENV_FILE" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ ERRO: Arquivo de configuração não encontrado: $ENV_FILE" >&2
    echo "  Copie o exemplo e edite:  cp $SCRIPT_DIR/.env-watchdog-example $ENV_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# Validar variáveis obrigatórias
for var in TICKETZ_DIR BACKEND_CONTAINER; do
    if [ -z "${!var}" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ ERRO: Variável obrigatória '$var' não definida em $ENV_FILE" >&2
        exit 1
    fi
done

# LOG_DIR é sempre na pasta logs/ junto ao script (não configurável)
LOG_DIR="$SCRIPT_DIR/logs"

# Defaults para variáveis opcionais (caso não definidas no .env-watchdog)
VPS_NAME="${VPS_NAME:-$(hostname)}"
BACKEND_PUBLIC_URL="${BACKEND_PUBLIC_URL:-}"
BACKEND_PORT="${BACKEND_PORT:-3000}"
BACKEND_URL="http://${BACKEND_CONTAINER}:${BACKEND_PORT}/"
FRONTEND_CONTAINER="${BACKEND_CONTAINER/backend/frontend}"
RETRIES="${RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-10}"
SAVE_BACKEND_LOGS="${SAVE_BACKEND_LOGS:-true}"
BACKUP_TYPE="${BACKUP_TYPE:-TAIL}"
BACKUP_TAIL_LINES="${BACKUP_TAIL_LINES:-10000}"
WEBHOOK_URL="${WEBHOOK_URL:-}"
WEBHOOK_AUTH_HEADER="${WEBHOOK_AUTH_HEADER:-}"
LOCK_FILE="${LOCK_FILE:-/tmp/netsapp-watchdog.lock}"
LOCK_TIMEOUT="${LOCK_TIMEOUT:-600}"
UPDATE_DETECTION_WAIT="${UPDATE_DETECTION_WAIT:-30}"
COOLDOWN_FILE="${COOLDOWN_FILE:-/tmp/netsapp-watchdog-cooldown}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-900}"

# =====

# --- Auto-detecção de sudo para Docker ---
# Se o usuário atual NÃO consegue acessar o Docker sem sudo, usa "sudo".
# Detecta automaticamente: funciona tanto como root quanto como ubuntu/outro user.
SUDO=""
if ! docker info > /dev/null 2>&1; then
    if sudo docker info > /dev/null 2>&1; then
        SUDO="sudo"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ ERRO: Sem acesso ao Docker (nem com sudo). Abortando." >&2
        exit 1
    fi
fi

# Criar diretório de logs se não existir
mkdir -p "$LOG_DIR"

WATCHDOG_LOG="$LOG_DIR/watchdog.log"

# Rotação simples do log (máximo 1MB)
if [ -f "$WATCHDOG_LOG" ]; then
    log_size=$(stat -c %s "$WATCHDOG_LOG" 2>/dev/null || echo 0)
    if [ "$log_size" -gt 1048576 ]; then
        mv "$WATCHDOG_LOG" "$WATCHDOG_LOG.old"
    fi
fi

# Variável global para armazenar path do crash log
CRASH_LOG_PATH=""

# Função para log com timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$WATCHDOG_LOG"
}

# Função para verificar cooldown
check_cooldown() {
    if [ -f "$COOLDOWN_FILE" ]; then
        local cooldown_age=$(($(date +%s) - $(stat -c %Y "$COOLDOWN_FILE" 2>/dev/null || echo 0)))
        if [ $cooldown_age -lt $COOLDOWN_SECONDS ]; then
            local remaining=$((COOLDOWN_SECONDS - cooldown_age))
            log_message "⏸️ Em cooldown (${remaining}s restantes), pulando ação de recuperação"
            return 0  # Em cooldown
        else
            rm -f "$COOLDOWN_FILE"
        fi
    fi
    return 1  # Sem cooldown
}

# Função para ativar cooldown
set_cooldown() {
    touch "$COOLDOWN_FILE"
    log_message "⏸️ Cooldown ativado por ${COOLDOWN_SECONDS}s"
}

# Função para adquirir lock (evitar múltiplas execuções)
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_age=$(($(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0)))

        if [ $lock_age -gt $LOCK_TIMEOUT ]; then
            log_message "⚠️ Lock antigo detectado (${lock_age}s > ${LOCK_TIMEOUT}s), removendo..."
            rm -f "$LOCK_FILE"
        else
            log_message "⏸️ Outra instância do watchdog está rodando (lock age: ${lock_age}s), pulando execução"
            exit 0
        fi
    fi

    echo $$ > "$LOCK_FILE"
}

# Função para liberar lock
release_lock() {
    if [ -f "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE"
    fi
}

# Garantir que lock seja liberado mesmo se script for interrompido
trap release_lock EXIT

# Função para detectar se há update em andamento
detect_update_in_progress() {
    # Verificar se script update.ticke.tz está rodando
    if pgrep -f "update.ticke.tz" > /dev/null; then
        log_message "⏸️ Update manual (update.ticke.tz) em andamento, aguardando próxima verificação..."
        return 0
    fi

    # Verificar se há processo docker compose pull rodando (indica update)
    if pgrep -f "docker.*compose.*pull" > /dev/null; then
        log_message "⏸️ Docker compose pull em andamento, aguardando próxima verificação..."
        return 0
    fi

    # Verificar se docker compose up está rodando (pode ser deploy manual)
    if pgrep -f "docker.*compose.*up" > /dev/null; then
        log_message "⏸️ Docker compose up em andamento, aguardando próxima verificação..."
        return 0
    fi

    return 1
}

# Função para verificar se backend está ausente (pode ser update ou crash)
check_backend_exists() {
    if ! $SUDO docker ps --format '{{.Names}}' | grep -q "$BACKEND_CONTAINER"; then
        log_message "⚠️ Backend não encontrado na lista de containers rodando"
        log_message "🕐 Aguardando ${UPDATE_DETECTION_WAIT}s para confirmar se é update ou crash real..."
        sleep $UPDATE_DETECTION_WAIT

        if ! $SUDO docker ps --format '{{.Names}}' | grep -q "$BACKEND_CONTAINER"; then
            log_message "🚨 Backend continua ausente após ${UPDATE_DETECTION_WAIT}s - confirmado como crash"
            return 1
        else
            log_message "✅ Backend voltou durante espera - era processo de atualização"
            return 0
        fi
    fi

    return 0
}

# Função para verificar saúde do backend
check_backend() {
    local attempt=1

    while [ $attempt -le $RETRIES ]; do
        HTTP_CODE=$($SUDO docker exec "$FRONTEND_CONTAINER" curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BACKEND_URL" 2>/dev/null)

        if [ "$HTTP_CODE" = "200" ]; then
            return 0
        fi

        log_message "⚠️ Backend falhou (HTTP $HTTP_CODE) - tentativa $attempt/$RETRIES"
        attempt=$((attempt + 1))

        if [ $attempt -le $RETRIES ]; then
            sleep $RETRY_DELAY
        fi
    done

    return 1
}

# Função para salvar log do backend (com opções configuráveis)
save_backend_logs() {
    if [ "$SAVE_BACKEND_LOGS" != "true" ]; then
        CRASH_LOG_PATH="(não salvo)"
        return 0
    fi

    local timestamp=$(date '+%Y%m%d_%H%M%S')
    CRASH_LOG_PATH="$LOG_DIR/backend-crash_${timestamp}.log"

    cd "$TICKETZ_DIR"

    if [ "$BACKUP_TYPE" = "FULL" ]; then
        log_message "📝 Salvando LOG COMPLETO do backend..."
        $SUDO docker compose logs -t backend > "$CRASH_LOG_PATH" 2>&1
    else
        log_message "📝 Salvando ÚLTIMAS ${BACKUP_TAIL_LINES} LINHAS do backend..."
        $SUDO docker compose logs -t --tail ${BACKUP_TAIL_LINES} backend > "$CRASH_LOG_PATH" 2>&1
    fi

    if [ -f "$CRASH_LOG_PATH" ]; then
        local filesize=$(du -h "$CRASH_LOG_PATH" | cut -f1)
        local linecount=$(wc -l < "$CRASH_LOG_PATH")
        log_message "✅ Log salvo: $filesize, ${linecount} linhas → $CRASH_LOG_PATH"
    else
        CRASH_LOG_PATH="(erro ao salvar)"
    fi

    # Limpar crash logs antigos (manter apenas últimos 10)
    ls -t "$LOG_DIR"/backend-crash_*.log 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null
}

# Função para enviar notificação via Webhook
send_webhook_notification() {
    local level="$1"
    local status="$2"
    local message="$3"
    local recovery_duration="${4:-}"

    if [ -z "$WEBHOOK_URL" ]; then
        return 0
    fi

    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local hostname=$(hostname)
    local crash_log_filename="${CRASH_LOG_PATH##*/}"
    local crash_log_size="N/A"
    local crash_log_lines="N/A"

    if [ -f "$CRASH_LOG_PATH" ] && [ "$CRASH_LOG_PATH" != "(não salvo)" ] && [ "$CRASH_LOG_PATH" != "(erro ao salvar)" ]; then
        crash_log_size=$(du -h "$CRASH_LOG_PATH" 2>/dev/null | cut -f1)
        crash_log_lines=$(wc -l < "$CRASH_LOG_PATH" 2>/dev/null)
    fi

    local payload=$(cat <<EOFPAYLOAD
{
  "event": "watchdog_alert",
  "timestamp": "$timestamp",
  "vps_name": "$VPS_NAME",
  "hostname": "$hostname",
  "backend_url": "$BACKEND_PUBLIC_URL",
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
EOFPAYLOAD
)

    local response
    if [ -z "$WEBHOOK_AUTH_HEADER" ]; then
        response=$(curl -s -w "\n%{http_code}" -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            --max-time 15 \
            -d "$payload" 2>&1)
    else
        response=$(curl -s -w "\n%{http_code}" -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -H "Authorization: $WEBHOOK_AUTH_HEADER" \
            --max-time 15 \
            -d "$payload" 2>&1)
    fi

    local http_code=$(echo "$response" | tail -n1)

    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ] || [ "$http_code" = "204" ]; then
        log_message "✅ Webhook enviado (HTTP $http_code)"
    else
        log_message "❌ Erro ao enviar webhook (HTTP $http_code)"
    fi
}

# NÍVEL 1: Reinício rápido (apenas backend e frontend)
level1_quick_restart() {
    log_message "🔧 NÍVEL 1: Reinício rápido do backend e frontend"

    local start_time=$(date +%s)

    cd "$TICKETZ_DIR"

    # Derrubar apenas backend e frontend
    log_message "🔽 Derrubando backend e frontend..."
    $SUDO docker compose stop backend frontend 2>&1 | tail -2 >> "$WATCHDOG_LOG"
    $SUDO docker compose rm -f backend frontend 2>&1 | tail -2 >> "$WATCHDOG_LOG"

    sleep 5

    # Recriar containers
    log_message "🔼 Recriando backend e frontend..."
    $SUDO docker compose up -d backend frontend 2>&1 | tail -5 >> "$WATCHDOG_LOG"

    # Aguardar estabilização
    log_message "⏳ Aguardando 45 segundos para estabilização..."
    sleep 45

    # Verificar recuperação
    if check_backend; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_message "✅ NÍVEL 1: RECUPERAÇÃO BEM-SUCEDIDA! (${duration}s)"
        send_webhook_notification 1 "success" "Sistema recuperado via Nível 1 (Reinício Rápido)" "${duration}s"
        set_cooldown
        return 0
    else
        log_message "❌ NÍVEL 1: FALHOU - Escalando para Nível 2"
        return 1
    fi
}

# NÍVEL 2: Reinício completo de toda a stack (sem update)
level2_full_restart() {
    log_message "🔧 NÍVEL 2: Reinício completo de toda a stack Docker"

    local start_time=$(date +%s)

    cd "$TICKETZ_DIR"

    # Derrubar TODA a stack
    log_message "🔽 Derrubando todos os containers..."
    $SUDO docker compose down 2>&1 | tail -10 >> "$WATCHDOG_LOG"

    sleep 10

    # Subir toda a stack
    log_message "🔼 Recriando toda a stack..."
    $SUDO docker compose up -d 2>&1 | tail -10 >> "$WATCHDOG_LOG"

    # Aguardar estabilização (mais tempo para toda a stack)
    log_message "⏳ Aguardando 90 segundos para estabilização completa..."
    sleep 90

    # Verificar recuperação com mais tentativas
    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if check_backend; then
            local total_duration=$(($(date +%s) - start_time))
            log_message "✅ NÍVEL 2: RECUPERAÇÃO BEM-SUCEDIDA! (${total_duration}s)"
            send_webhook_notification 2 "success" "Sistema recuperado via Nível 2 (Reinício Completo)" "${total_duration}s"
            set_cooldown
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            log_message "⏳ Backend ainda não respondeu, aguardando mais 30s (tentativa $attempt/$max_attempts)..."
            sleep 30
        fi

        attempt=$((attempt + 1))
    done

    log_message "❌ NÍVEL 2: FALHOU - Sistema não recuperou após reinício completo"
    return 1
}

# NÍVEL 3: Update do sistema (último recurso antes de falha crítica)
level3_update_restart() {
    log_message "🔧 NÍVEL 3: Atualização do sistema (último recurso)"
    log_message "📥 Baixando e executando update.ticke.tz..."

    local start_time=$(date +%s)

    cd "$TICKETZ_DIR"

    # O script update faz: pull + down + up + prune
    if curl -sSL update.ticke.tz | $SUDO bash >> "$WATCHDOG_LOG" 2>&1; then
        local update_duration=$(($(date +%s) - start_time))
        log_message "✅ Script de atualização executado com sucesso (${update_duration}s)"
    else
        local exit_code=$?
        log_message "❌ ERRO ao executar script de atualização (exit code: $exit_code)"
        return 1
    fi

    # Aguardar estabilização pós-update
    log_message "⏳ Aguardando 90 segundos para sistema inicializar..."
    sleep 90

    # Verificar recuperação
    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if check_backend; then
            local total_duration=$(($(date +%s) - start_time))
            log_message "✅ NÍVEL 3: ATUALIZAÇÃO E RECUPERAÇÃO BEM-SUCEDIDA! (${total_duration}s)"
            send_webhook_notification 3 "success" "Sistema recuperado via Nível 3 (Update do Sistema)" "${total_duration}s"
            set_cooldown
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            log_message "⏳ Backend ainda não respondeu, aguardando mais 30s (tentativa $attempt/$max_attempts)..."
            sleep 30
        fi

        attempt=$((attempt + 1))
    done

    log_message "❌ NÍVEL 3: FALHOU - Sistema não recuperou mesmo após update"
    return 1
}

# NÍVEL 4: Falha crítica - registrar e alertar
level4_critical_failure() {
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local critical_log="$LOG_DIR/CRITICAL-FAILURE_${timestamp}.log"

    log_message "🚨🚨🚨 NÍVEL 4: FALHA CRÍTICA - INTERVENÇÃO MANUAL NECESSÁRIA"

    {
        echo "========================================="
        echo "FALHA CRÍTICA DO SISTEMA NETSAPP"
        echo "Data/Hora: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "VPS: $VPS_NAME"
        echo "Log do crash: $CRASH_LOG_PATH"
        echo "========================================="
        echo ""
        echo "--- STATUS DOS CONTAINERS ---"
        $SUDO docker ps -a
        echo ""
        echo "--- LOGS DO BACKEND (últimas 100 linhas) ---"
        cd "$TICKETZ_DIR"
        $SUDO docker compose logs --tail 100 backend 2>&1
        echo ""
        echo "--- LOGS DO FRONTEND (últimas 50 linhas) ---"
        $SUDO docker compose logs --tail 50 frontend 2>&1
        echo ""
        echo "--- USO DE DISCO ---"
        df -h
        echo ""
        echo "--- USO DE MEMÓRIA ---"
        free -h
        echo ""
        echo "--- PROCESSOS DOCKER ---"
        $SUDO docker stats --no-stream 2>&1
    } > "$critical_log" 2>&1

    log_message "📝 Relatório de falha crítica: $critical_log"

    send_webhook_notification 4 "critical" \
        "FALHA CRÍTICA! Nível 1 (Reinício Rápido), Nível 2 (Reinício Completo) e Nível 3 (Update) falharam. Intervenção manual necessária. Diagnóstico: ${critical_log##*/}" \
        "N/A"

    set_cooldown

    return 1
}

# ===== EXECUÇÃO PRINCIPAL =====

acquire_lock

log_message "🔍 Verificação iniciada"

# Verificar se há update em andamento
if detect_update_in_progress; then
    exit 0
fi

# Verificar se backend existe
if ! check_backend_exists; then
    log_message "🚨 Backend ausente confirmado como crash"
fi

# Verificar saúde do backend
if check_backend; then
    log_message "✅ Sistema OK"
    exit 0
fi

# === SISTEMA COM PROBLEMAS ===
log_message "🚨 Sistema com problemas detectado!"

# Verificar cooldown antes de agir
if check_cooldown; then
    log_message "⏸️ Recuperação já foi tentada recentemente, aguardando expirar cooldown"
    exit 0
fi

# Salvar log do backend antes de qualquer ação
save_backend_logs

log_message "🔄 Iniciando recuperação escalonada..."

# Nível 1: Reinício rápido (apenas backend + frontend)
if level1_quick_restart; then
    exit 0
fi

sleep 10

# Nível 2: Reinício completo da stack
if level2_full_restart; then
    exit 0
fi

sleep 10

# Nível 3: Update do sistema (último recurso)
if level3_update_restart; then
    exit 0
fi

# Nível 4: Falha crítica
level4_critical_failure
exit 1
