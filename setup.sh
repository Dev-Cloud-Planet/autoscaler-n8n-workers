#!/bin/bash

# ==============================================================================
#   Script de Instalación y Configuración del Auto-Escalado para n8n
#
#   Versión: 2.2 (Corrige error de 'ValueError' en autoscaler.py)
# ==============================================================================

# --- Funciones Auxiliares ---
print_header() {
    echo -e "\n\033[1;34m=================================================\033[0m"
    echo -e "\033[1;34m  $1\033[0m"
    echo -e "\033[1;34m=================================================\033[0m\n"
}

ask() {
    local prompt="$1"
    local default="$2"
    read -p "$prompt (def: $default): " reply < /dev/tty
    echo "${reply:-$default}"
}

restore_and_exit() {
    echo -e "\n\033[1;31m❌ Ocurrió un error crítico.\033[0m"
    echo "🛡️  Restaurando 'docker-compose.yml' desde la copia de seguridad..."
    if [ -f "$BACKUP_FILE" ]; then
        mv "$BACKUP_FILE" "$N8N_COMPOSE_PATH"
        echo "✅ Restauración completa. El script se detendrá."
    else
        echo "⚠️ No se encontró un archivo de backup para restaurar."
    fi
    rm -f yq
    exit 1
}

# --- Verificación de Dependencias ---
check_deps() {
    echo "🔎 Verificando dependencias..."
    for cmd in docker curl wget sed grep cut xargs; do
        if ! command -v $cmd &> /dev/null; then
            echo "❌ Error: El comando '$cmd' es esencial y no fue encontrado." && exit 1
        fi
    done

    if docker compose version &>/dev/null; then
        COMPOSE_CMD_HOST="docker compose"
    elif docker-compose version &>/dev/null; then
        COMPOSE_CMD_HOST="docker-compose"
    else
        echo "❌ Error: No se encontró 'docker-compose' o el plugin 'docker compose'." && exit 1
    fi
    echo "✅ Se usará '$COMPOSE_CMD_HOST' para las operaciones del host."

    if [ ! -f ./yq ]; then
        echo "📥 Descargando la herramienta 'yq' (para manejar YAML de forma segura)..."
        YQ_VERSION="v4.30.8"
        YQ_BINARY="yq_linux_amd64"
        wget -q "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}" -O ./yq && chmod +x ./yq || {
            echo "❌ Falló la descarga de yq." && exit 1
        }
    fi
    YQ_CMD="./yq"
    echo "✅ Dependencias listas."
}

# --- INICIO DEL SCRIPT ---
clear
print_header "Instalador del Servicio de Auto-Escalado para n8n v2.2"
check_deps

# --- FASE 1: ANÁLISIS DEL ENTORNO ---
print_header "1. Analizando tu Entorno n8n"

N8N_COMPOSE_PATH="$(pwd)/docker-compose.yml"
if [ ! -f "$N8N_COMPOSE_PATH" ]; then
    echo "❌ Error: No se encontró 'docker-compose.yml' en el directorio actual."
    rm -f yq
    exit 1
fi

N8N_ENV_PATH="$(pwd)/.env"
if [ -f "$N8N_ENV_PATH" ]; then
    echo "✅ Archivo de entorno '.env' detectado."
    DEFAULT_REDIS_HOST=$(grep -E "^REDIS_HOST=" "$N8N_ENV_PATH" | cut -d '=' -f2 | tr -d '"' | tr -d "'")
    DEFAULT_PROJECT_NAME=$(grep -E "^COMPOSE_PROJECT_NAME=" "$N8N_ENV_PATH" | cut -d '=' -f2 | tr -d '"' | tr -d "'")
fi

RAW_PROJECT_NAME=${DEFAULT_PROJECT_NAME:-$(basename "$(pwd)")}
N8N_PROJECT_NAME=$(echo "$RAW_PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_-]//g')
N8N_PROJECT_NAME=$(ask "Nombre del proyecto Docker" "${N8N_PROJECT_NAME:-n8n-project}")

DETECTED_N8N_SERVICE=$($YQ_CMD eval 'keys | .[]' "$N8N_COMPOSE_PATH" | grep -m1 "n8n")
N8N_MAIN_SERVICE_NAME=$(ask "Nombre de tu servicio principal de n8n" "${DETECTED_N8N_SERVICE:-n8n}")

DETECTED_NETWORK=$($YQ_CMD eval ".services.\"$N8N_MAIN_SERVICE_NAME\".networks[0]" "$N8N_COMPOSE_PATH")
if [ -z "$DETECTED_NETWORK" ] || [ "$DETECTED_NETWORK" == "null" ]; then
    echo "❌ Error: No se pudo detectar la red del servicio '$N8N_MAIN_SERVICE_NAME'." && restore_and_exit
fi
echo "✅ Red de Docker detectada: '$DETECTED_NETWORK'"

DETECTED_REDIS_SERVICE=$($YQ_CMD eval '(.services[] | select(.image | test("redis")) | key)' "$N8N_COMPOSE_PATH" | head -n 1 | xargs)
REDIS_HOST=$(ask "Hostname de tu servicio Redis" "${DEFAULT_REDIS_HOST:-${DETECTED_REDIS_SERVICE:-redis}}")

# --- FASE 2: CONFIGURACIÓN DEL MODO 'QUEUE' ---
print_header "2. Verificando y Configurando el Modo de Escalado"
N8N_WORKER_SERVICE_NAME="${N8N_MAIN_SERVICE_NAME}-worker"

IS_QUEUE_MODE=$($YQ_CMD eval ".services.\"$N8N_MAIN_SERVICE_NAME\".environment[] | select(. == \"EXECUTIONS_MODE=queue\")" "$N8N_COMPOSE_PATH" 2>/dev/null)

if [ -z "$IS_QUEUE_MODE" ]; then
    echo "🔧 El modo 'queue' no está configurado. Se procederá a modificar 'docker-compose.yml'."
    read -p "¿Estás de acuerdo? (Se creará una copia de seguridad) (y/N): " confirm_modify < /dev/tty
    if [[ ! "$confirm_modify" =~ ^[yY](es)?$ ]]; then
        echo "Instalación cancelada."
        rm -f yq
        exit 1
    fi

    BACKUP_FILE="${N8N_COMPOSE_PATH}.backup.$(date +%F_%T)"
    echo "🛡️  Creando copia de seguridad en '$BACKUP_FILE'..."
    cp "$N8N_COMPOSE_PATH" "$BACKUP_FILE"

    echo "⚙️  Aplicando configuración de modo 'queue' y añadiendo servicio de worker..."
    $YQ_CMD eval "
        .services.\"$N8N_MAIN_SERVICE_NAME\".environment += [
            \"EXECUTIONS_MODE=queue\",
            \"EXECUTIONS_PROCESS=main\",
            \"QUEUE_BULL_REDIS_HOST=$REDIS_HOST\"
        ] |
        .services.\"$N8N_WORKER_SERVICE_NAME\" = .services.\"$N8N_MAIN_SERVICE_NAME\" |
        .services.\"$N8N_WORKER_SERVICE_NAME\".environment |= map(
            if . == \"EXECUTIONS_PROCESS=main\" then \"EXECUTIONS_PROCESS=worker\" else . end
        ) |
        del(.services.\"$N8N_WORKER_SERVICE_NAME\".ports) |
        del(.services.\"$N8N_WORKER_SERVICE_NAME\".container_name) |
        del(.services.\"$N8N_WORKER_SERVICE_NAME\".labels)
    " -i "$N8N_COMPOSE_PATH"
    if [ $? -ne 0 ]; then
        echo "❌ Error al modificar 'docker-compose.yml' con yq."
        restore_and_exit
    fi

    print_header "3. Reiniciando Stack de n8n para Aplicar Cambios"
    echo "🔄 Deteniendo y levantando los servicios con la nueva configuración..."
    $COMPOSE_CMD_HOST -p "$N8N_PROJECT_NAME" up -d --force-recreate --remove-orphans || restore_and_exit
    echo "✅ Tu stack de n8n ha sido actualizado y reiniciado con éxito."
else
    echo "✅ El modo 'queue' ya está configurado. No se realizarán cambios en 'docker-compose.yml'."
fi

# --- FASE 4: DESPLIEGUE DEL AUTOSCALER ---
print_header "4. Desplegando el Servicio de Auto-Escalado"
AUTOSCALER_DIR="n8n-autoscaler"
mkdir -p "$AUTOSCALER_DIR"

if [ -f "$N8N_ENV_PATH" ]; then
    echo "📋 Copiando '$N8N_ENV_PATH' a '$AUTOSCALER_DIR/.env' para usarlo como base."
    cp "$N8N_ENV_PATH" "$AUTOSCALER_DIR/.env"
else
    touch "$AUTOSCALER_DIR/.env"
fi

cd "$AUTOSCALER_DIR" || exit

echo -e "\nAhora, configuremos el comportamiento del auto-escalado:"
QUEUE_THRESHOLD=$(ask "Nº de tareas en cola para crear un nuevo worker" "15")
MAX_WORKERS=$(ask "Nº máximo de workers permitidos" "5")
MIN_WORKERS=$(ask "Nº mínimo de workers activos (0 para apagarlos si no hay carga)" "0")
IDLE_TIME_BEFORE_SCALE_DOWN=$(ask "Segundos de inactividad para destruir un worker" "90")
POLL_INTERVAL=$(ask "Segundos entre cada verificación de la cola" "10")
TELEGRAM_BOT_TOKEN=$(ask "Token de Bot de Telegram para notificaciones (opcional)" "")
TELEGRAM_CHAT_ID=$(ask "Chat ID de Telegram para notificaciones (opcional)" "")

cat >> .env << EOL

# --- AUTOSCALER CONFIG - GENERATED BY SCRIPT ---
N8N_DOCKER_PROJECT_NAME=${N8N_PROJECT_NAME}
N8N_WORKER_SERVICE_NAME=${N8N_WORKER_SERVICE_NAME}
QUEUE_THRESHOLD=${QUEUE_THRESHOLD}
MAX_WORKERS=${MAX_WORKERS}
MIN_WORKERS=${MIN_WORKERS}
IDLE_TIME_BEFORE_SCALE_DOWN=${IDLE_TIME_BEFORE_SCALE_DOWN}
POLL_INTERVAL=${POLL_INTERVAL}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
EOL

echo "📄 Generando 'docker-compose.yml' para el autoscaler..."
cat > docker-compose.yml << EOL
# Este archivo es obsoleto en Docker Compose v2 pero se mantiene por compatibilidad.
# version: '3.8'

services:
  autoscaler:
    image: n8n-autoscaler-service:latest
    build: .
    container_name: ${N8N_PROJECT_NAME}_autoscaler
    restart: always
    env_file: .env
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${N8N_COMPOSE_PATH}:/app/docker-compose.yml
    working_dir: /app
    networks:
      - n8n_network

networks:
  n8n_network:
    name: ${N8N_PROJECT_NAME}_${DETECTED_NETWORK}
    external: true
EOL

cat > Dockerfile << 'EOL'
FROM python:3.9-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates gnupg apt-transport-https && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && apt-get install -y docker-ce-cli && \
    rm -rf /var/lib/apt/lists/*
RUN curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose && \
    chmod +x /usr/local/bin/docker-compose
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY autoscaler.py .
CMD ["python", "-u", "autoscaler.py"]
EOL

cat > requirements.txt << 'EOL'
redis
requests
python-dotenv
EOL

### CORRECCIÓN PRINCIPAL AQUÍ ###
cat > autoscaler.py << 'EOL'
import os
import time
import subprocess
import redis
import requests
from dotenv import load_dotenv

# --- Funciones Auxiliares ---
def log(message):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}", flush=True)

def send_telegram_notification(message):
    if not TELEGRAM_TOKEN or not TELEGRAM_CHAT_ID:
        return
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"
    payload = {'chat_id': TELEGRAM_CHAT_ID, 'text': message, 'parse_mode': 'Markdown'}
    try:
        requests.post(url, json=payload, timeout=10).raise_for_status()
    except requests.exceptions.RequestException as e:
        log(f"⚠️  Error al enviar notificación a Telegram: {e}")

# --- Funciones de Docker ---
def run_docker_command(command):
    try:
        # Usamos docker-compose, que está instalado en el Dockerfile
        full_command = f"docker-compose -p {N8N_PROJECT_NAME} -f /app/docker-compose.yml {command}"
        log(f"🚀 Ejecutando: {full_command}")
        result = subprocess.run(full_command, shell=True, check=True, capture_output=True, text=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        error_message = f"❌ Error ejecutando Docker: {e.stderr.strip()}"
        log(error_message)
        send_telegram_notification(f"‼️ *Error Crítico de Docker*\n_{e.stderr.strip()}_")
        return None

def get_running_workers():
    output = run_docker_command(f"ps -q {N8N_WORKER_SERVICE_NAME}")
    if output is None:
        return -1
    return len(output.splitlines()) if output else 0

def scale_workers(desired_count):
    current_workers = get_running_workers()
    if current_workers == -1 or current_workers == desired_count:
        return
    log(f"⚖️  Escalando workers de {current_workers} a {desired_count}...")
    command = f"up -d --scale {N8N_WORKER_SERVICE_NAME}={desired_count} --no-recreate --remove-orphans"
    if run_docker_command(command) is not None:
        log(f"✅ Escalado completado. Workers activos: {desired_count}")
        send_telegram_notification(f"✅ Auto-escalado de *{N8N_PROJECT_NAME}*. Workers activos: *{desired_count}*")
    else:
        log(f"❌ Error al intentar escalar a {desired_count} workers.")
        send_telegram_notification(f"❌ *Error al escalar workers a {desired_count}*")

# --- Bucle Principal ---
def main_loop():
    idle_since = None
    while True:
        try:
            queue_size = redis_client.llen(QUEUE_KEY)
            running_workers = get_running_workers()
            if running_workers == -1:
                time.sleep(POLL_INTERVAL * 2)
                continue
            log(f"Estado: Cola={queue_size}, Workers={running_workers}, Umbral={QUEUE_THRESHOLD}")
            if queue_size > QUEUE_THRESHOLD and running_workers < MAX_WORKERS:
                scale_workers(min(running_workers + 1, MAX_WORKERS))
                idle_since = None
            elif queue_size == 0 and running_workers > MIN_WORKERS:
                if idle_since is None:
                    idle_since = time.time()
                    log(f"La cola está vacía. Iniciando temporizador de {IDLE_TIME_BEFORE_SCALE_DOWN}s para scale-down.")
                if time.time() - idle_since >= IDLE_TIME_BEFORE_SCALE_DOWN:
                    scale_workers(max(running_workers - 1, MIN_WORKERS))
                    idle_since = None
            elif queue_size > 0:
                if idle_since is not None:
                    log("La cola ya no está vacía. Cancelando scale-down.")
                    idle_since = None
            time.sleep(POLL_INTERVAL)
        except redis.exceptions.RedisError as e:
            log(f"⚠️ Error de conexión con Redis: {e}. Reintentando...")
            time.sleep(POLL_INTERVAL * 2)
        except KeyboardInterrupt:
            log("🛑 Script detenido por el usuario.")
            send_telegram_notification(f"🤖 Servicio de auto-escalado para *{N8N_PROJECT_NAME}* detenido manualmente.")
            break
        except Exception as e:
            log(f"🔥 Error inesperado en el bucle principal: {e}")
            send_telegram_notification(f"🔥 *Error Inesperado en Autoscaler {N8N_PROJECT_NAME}*\n_{str(e)}_")
            time.sleep(POLL_INTERVAL * 3)

# --- Punto de Entrada del Script ---
if __name__ == "__main__":
    load_dotenv()
    
    # Lectura de variables de entorno, una por línea para evitar errores.
    REDIS_HOST = os.getenv('REDIS_HOST', 'redis')
    N8N_PROJECT_NAME = os.getenv('N8N_DOCKER_PROJECT_NAME')
    N8N_WORKER_SERVICE_NAME = os.getenv('N8N_WORKER_SERVICE_NAME')
    QUEUE_KEY = "bull:n8n-executions:wait" 
    
    QUEUE_THRESHOLD = int(os.getenv('QUEUE_THRESHOLD', 15))
    MAX_WORKERS = int(os.getenv('MAX_WORKERS', 5))
    MIN_WORKERS = int(os.getenv('MIN_WORKERS', 0))
    IDLE_TIME_BEFORE_SCALE_DOWN = int(os.getenv('IDLE_TIME_BEFORE_SCALE_DOWN', 90))
    POLL_INTERVAL = int(os.getenv('POLL_INTERVAL', 10))
    
    TELEGRAM_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN')
    TELEGRAM_CHAT_ID = os.getenv('TELEGRAM_CHAT_ID')

    if not all([N8N_PROJECT_NAME, N8N_WORKER_SERVICE_NAME]):
        log("❌ Error: Faltan variables de entorno críticas (N8N_DOCKER_PROJECT_NAME, N8N_WORKER_SERVICE_NAME).")
        exit(1)

    try:
        redis_client = redis.Redis(host=REDIS_HOST, port=6379, db=0, decode_responses=True, socket_connect_timeout=5)
        redis_client.ping()
        log("✅ Conexión con Redis establecida con éxito.")
    except redis.exceptions.RedisError as e:
        log(f"❌ Error fatal al conectar con Redis en {REDIS_HOST}: {e}")
        exit(1)

    log(f"🚀 Iniciando servicio de auto-escalado para el proyecto '{N8N_PROJECT_NAME}'")
    send_telegram_notification(f"🤖 El servicio de auto-escalado para *{N8N_PROJECT_NAME}* ha sido (re)iniciado.")
    main_loop()
EOL

### FIN DE LA CORRECCIÓN ###

echo "🧹 Limpiando cualquier instancia anterior del autoscaler..."
docker rm -f "${N8N_PROJECT_NAME}_autoscaler" > /dev/null 2>&1
echo "🏗️  Construyendo y desplegando el servicio de auto-escalado..."
$COMPOSE_CMD_HOST up -d --build
if [ $? -eq 0 ]; then
    print_header "🎉 ¡Instalación Completada con Éxito! 🎉"
    cd ..
    echo "Tu stack de n8n ha sido configurado para escalar y el servicio de auto-escalado está en funcionamiento."
    echo ""
    echo "Pasos siguientes recomendados:"; echo "  1. Revisa los logs del autoscaler para confirmar que todo funciona:"; echo -e "     \033[0;32mdocker logs -f ${N8N_PROJECT_NAME}_autoscaler\033[0m"
    echo "  2. Puedes encontrar toda la configuración del autoscaler en la carpeta:"; echo -e "     \033[0;32m./n8n-autoscaler/\033[0m"
else
    echo -e "\n❌ Hubo un error durante el despliegue del autoscaler."; cd ..
fi
rm -f ./yq
echo -e "\nScript finalizado.\n"