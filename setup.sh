#!/bin/bash

# ==============================================================================
#   Script de Instalación del Servicio de Auto-Escalado para n8n (Ejecutar en Sitio)
#
# Versión 7.0 
# ==============================================================================
print_header() {
    echo -e "\n\033[1;34m=================================================\033[0m"
    echo -e "\033[1;34m  $1\033[0m"
    echo -e "\033[1;34m=================================================\033[0m\n"
}
ask() {
    local prompt default reply
    prompt="$1"; default="$2"
    read -p "$prompt (def: $default): " reply < /dev/tty
    echo "${reply:-$default}"
}
check_deps() {
    echo "🔎 Verificando dependencias del host..."
    for cmd in docker curl wget; do
        if ! command -v $cmd &> /dev/null; then echo "❌ Error: El comando '$cmd' es requerido." && exit 1; fi
    done
    if command -v docker &> /dev/null && docker compose version &> /dev/null; then
        COMPOSE_CMD_HOST="docker compose"
    elif command -v docker-compose &> /dev/null; then
        COMPOSE_CMD_HOST="docker-compose"
    else
        echo "❌ Error: No se encontró 'docker-compose' o el plugin 'docker compose'." && exit 1
    fi
    echo "✅ Usando '$COMPOSE_CMD_HOST' para las operaciones del host."
    if [ ! -f ./yq ]; then
        YQ_URL="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
        echo "📥 Descargando yq desde $YQ_URL..."
        if ! wget -q "$YQ_URL" -O ./yq || ! chmod +x ./yq; then echo "❌ Falló la descarga de yq." && exit 1; fi
    fi
    YQ_CMD="./yq"
    echo "✅ Dependencias del host listas."
}

# --- INICIO DEL SCRIPT ---
clear
check_deps
print_header "Instalador del Servicio de Auto-Escalado para n8n"

# --- DETECCIÓN Y RECOPILACIÓN DE DATOS ---
print_header "1. Detectando y Configurando el Stack"
N8N_COMPOSE_PATH="$(pwd)/docker-compose.yml"
if [ ! -f "$N8N_COMPOSE_PATH" ]; then echo "❌ Error: No se encontró 'docker-compose.yml' en el directorio actual." && exit 1; fi
RAW_PROJECT_NAME=$(basename "$(pwd)")
N8N_PROJECT_NAME=$(echo "$RAW_PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-]//g')
if [ -z "$N8N_PROJECT_NAME" ]; then N8N_PROJECT_NAME="n8n-project"; fi
echo "✅ Proyecto n8n detectado como: '$N8N_PROJECT_NAME'"

N8N_MAIN_SERVICE_NAME=$($YQ_CMD eval '(.services[] | select(.image == "n8nio/n8n*") | key)' "$N8N_COMPOSE_PATH" | head -n 1)
N8N_MAIN_SERVICE_NAME=$(ask "Introduce el nombre de tu servicio principal de n8n" "${N8N_MAIN_SERVICE_NAME:-n8n}")
N8N_WORKER_SERVICE_NAME="n8n-worker"
N8N_NETWORK_NAME=$($YQ_CMD eval ".services.$N8N_MAIN_SERVICE_NAME.networks[0]" "$N8N_COMPOSE_PATH")
if [ -z "$N8N_NETWORK_NAME" ] || [ "$N8N_NETWORK_NAME" == "null" ]; then echo "❌ Error: No se pudo detectar la red para '$N8N_MAIN_SERVICE_NAME'." && exit 1; fi
echo "✅ Red detectada: '$N8N_NETWORK_NAME'"

REDIS_SERVICE_NAME=$($YQ_CMD eval '(.services[] | select(.image == "redis*") | key)' "$N8N_COMPOSE_PATH" | head -n 1)
REDIS_HOST=$(ask "Introduce el Hostname de tu servicio Redis" "${REDIS_SERVICE_NAME:-redis}")

# --- MODIFICACIÓN DEL DOCKER-COMPOSE DE N8N ---
print_header "2. Preparando el Stack de n8n para Escalado"

if $YQ_CMD eval ".services | has(\"$N8N_WORKER_SERVICE_NAME\")" "$N8N_COMPOSE_PATH" &>/dev/null; then
    echo "✅ El servicio de worker '$N8N_WORKER_SERVICE_NAME' ya existe. Omitiendo modificación."
else
    read -p "¿Estás de acuerdo en modificar 'docker-compose.yml' para añadir workers? (Se creará una copia de seguridad) (y/N): " confirm_modify < /dev/tty
    if [[ ! "$confirm_modify" =~ ^[yY](es)?$ ]]; then echo "Instalación cancelada." && exit 1; fi
    BACKUP_FILE="${N8N_COMPOSE_PATH}.backup.$(date +%F_%T)"
    echo "🛡️  Creando copia de seguridad en '$BACKUP_FILE'..."
    cp "$N8N_COMPOSE_PATH" "$BACKUP_FILE"

    echo "🔧 Generando nueva configuración del stack..."
    cat << EOF > additions.yml
services:
  ${N8N_MAIN_SERVICE_NAME}:
    environment:
      N8N_TRUST_PROXY: "true"
      N8N_RUNNERS_ENABLED: "true"
      EXECUTIONS_MODE: "queue"
      EXECUTIONS_PROCESS: "main"
      QUEUE_BULL_REDIS_HOST: "${REDIS_HOST}"
  ${N8N_WORKER_SERVICE_NAME}:
    image: \${IMAGE}
    container_name: \${CONTAINER_NAME}
    restart: "unless-stopped"
    environment: \${ENVIRONMENT}
    depends_on: \${DEPENDS_ON}
    networks: \${NETWORKS}
EOF
    $YQ_CMD eval-all '
        (
            select(fi == 0).services.n8n as $n8n_base |
            . as $additions |
            $additions.services."n8n-worker".image = $n8n_base.image |
            $additions.services."n8n-worker".container_name = $n8n_base.container_name |
            $additions.services."n8n-worker".environment = $n8n_base.environment |
            $additions.services."n8n-worker".depends_on = $n8n_base.depends_on |
            $additions.services."n8n-worker".networks = $n8n_base.networks
        ) as $worker_config |
        select(fi == 1) * $worker_config |
        (select(fi==1).services.n8n-worker.environment.EXECUTIONS_PROCESS = "worker")
    ' additions.yml "$N8N_COMPOSE_PATH" > new-compose.yml
    
    # Este es un segundo merge para asegurar que las variables del n8n-main se añaden
    $YQ_CMD eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' new-compose.yml additions.yml > final-compose.yml

    # Verificación final
    if [ -s final-compose.yml ] && $YQ_CMD eval ".services | has(\"$N8N_WORKER_SERVICE_NAME\")" final-compose.yml &>/dev/null; then
        echo "✅ Nueva configuración generada con éxito."
        mv final-compose.yml "$N8N_COMPOSE_PATH"
        rm additions.yml new-compose.yml
        
        echo "🔄 Aplicando la nueva configuración al stack de n8n..."
        $COMPOSE_CMD_HOST up -d --force-recreate --remove-orphans
        echo "✅ Stack de n8n actualizado con workers."
    else
        echo "❌ ERROR FATAL: No se pudo generar la nueva configuración. Revirtiendo..."
        mv "$BACKUP_FILE" "$N8N_COMPOSE_PATH"
        rm -f additions.yml new-compose.yml final-compose.yml
        exit 1
    fi
fi

# --- DESPLIEGUE DEL AUTOSCALER ---
print_header "3. Desplegando el Servicio de Auto-Escalado"
AUTOSCALER_PROJECT_DIR="n8n-autoscaler"
QUEUE_THRESHOLD=$(ask "Nº de tareas en cola para crear un worker" "20")
MAX_WORKERS=$(ask "Nº máximo de workers permitidos" "5")
MIN_WORKERS=$(ask "Nº mínimo de workers que deben mantenerse activos" "0")
IDLE_TIME_BEFORE_SCALE_DOWN=$(ask "Segundos de inactividad para destruir un worker" "60")
TELEGRAM_BOT_TOKEN=$(ask "Introduce tu Token de Bot de Telegram (opcional)" "")
TELEGRAM_CHAT_ID=$(ask "Introduce tu Chat ID de Telegram (opcional)" "")
mkdir -p "$AUTOSCALER_PROJECT_DIR" && cd "$AUTOSCALER_PROJECT_DIR" || exit

echo "-> Generando archivos del autoscaler...";
$COMPOSE_CMD_HOST down --remove-orphans > /dev/null 2>&1
echo "🚀 Desplegando el servicio de auto-escalado...";
$COMPOSE_CMD_HOST up -d --build
if [ $? -eq 0 ]; then
    print_header "¡Instalación Completada!"
    cd ..
else
    echo -e "\n❌ Hubo un error durante el despliegue del autoscaler."
fi
rm -f ./yq