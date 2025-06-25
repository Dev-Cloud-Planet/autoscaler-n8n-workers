#!/bin/bash
set -euo pipefail
# ==============================================================================
#   Script de Instalación y Configuración del Auto-Escalado para n8n
#
#   Versión: 7.1
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
    local reply
    read -r -p "$prompt (def: $default): " reply < /dev/tty || true
    echo "${reply:-$default}"
}

restore_and_exit() {
    echo -e "\n\033[1;31m❌ Ocurrió un error crítico.\033[0m"
    echo "🛡️  Restaurando 'docker-compose.yml' desde la copia de seguridad..."
    if [[ -f "$BACKUP_FILE" ]]; then
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
        if ! command -v "$cmd" &> /dev/null; then
            echo "❌ Error: El comando '$cmd' es esencial."
            exit 1
        fi
    done

    if docker compose version &>/dev/null; then
        COMPOSE_CMD_HOST="docker compose"
    elif docker-compose version &>/dev/null; then
        COMPOSE_CMD_HOST="docker-compose"
    else
        echo "❌ Error: No se encontró 'docker-compose' o el plugin 'docker compose'."
        exit 1
    fi
    echo "✅ Se usará '$COMPOSE_CMD_HOST' para las operaciones del host."

    if [[ ! -f ./yq ]]; then
        echo "📥 Descargando la herramienta 'yq'..."
        YQ_VERSION="v4.30.8"
        YQ_BINARY="yq_linux_amd64"
        wget -q "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}" -O ./yq && chmod +x ./yq || { echo "❌ Falló la descarga de yq." && exit 1; }
    fi
    YQ_CMD="./yq"
    echo "✅ Dependencias listas."
}

# --- INICIO DEL SCRIPT ---
clear
print_header "Instalador del Servicio de Auto-Escalado para n8n v7.1"
check_deps

# --- FASE 1: ANÁLISIS DEL ENTORNO ---
print_header "1. Analizando tu Entorno n8n"
N8N_COMPOSE_PATH="$(pwd)/docker-compose.yml"
if [[ ! -f "$N8N_COMPOSE_PATH" ]]; then
    echo "❌ Error: No se encontró 'docker-compose.yml' en el directorio actual."
    rm -f yq
    exit 1
fi

N8N_ENV_PATH="$(pwd)/.env"
if [[ -f "$N8N_ENV_PATH" ]]; then
    echo "✅ Archivo de entorno '.env' detectado."
    DEFAULT_REDIS_HOST=$($YQ_CMD eval '.services | to_entries | map(select(.value.image | test("redis"))) | .[0].key' "$N8N_COMPOSE_PATH" 2>/dev/null || echo "redis")
    DEFAULT_PROJECT_NAME=$(grep -E "^COMPOSE_PROJECT_NAME=" "$N8N_ENV_PATH" | cut -d '=' -f2 | tr -d '"' | tr -d "'" || echo "")
else
    DEFAULT_REDIS_HOST="redis"
    DEFAULT_PROJECT_NAME=""
fi

RAW_PROJECT_NAME=${DEFAULT_PROJECT_NAME:-$(basename "$(pwd)")}
N8N_PROJECT_NAME=$(echo "$RAW_PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_-]//g')
N8N_PROJECT_NAME=$(ask "Nombre del proyecto Docker" "${N8N_PROJECT_NAME:-n8n-project}")

DETECTED_N8N_SERVICE=$($YQ_CMD eval 'keys | .[]' "$N8N_COMPOSE_PATH" | grep -m1 "n8n" || echo "n8n")
N8N_MAIN_SERVICE_NAME=$(ask "Nombre de tu servicio principal de n8n" "${DETECTED_N8N_SERVICE:-n8n}")

DETECTED_REDIS_SERVICE=$($YQ_CMD eval '.services | to_entries | map(select(.value.image | test("redis"))) | .[0].key' "$N8N_COMPOSE_PATH" 2>/dev/null || echo "redis")
REDIS_HOST=$(ask "Hostname de tu servicio Redis" "${DETECTED_REDIS_SERVICE:-redis}")

DETECTED_NETWORK=$($YQ_CMD eval ".services.\"$N8N_MAIN_SERVICE_NAME\".networks[0]" "$N8N_COMPOSE_PATH" 2>/dev/null || echo "")
if [[ -z "$DETECTED_NETWORK" ]]; then
    echo "❌ Error: No se pudo detectar la red de '$N8N_MAIN_SERVICE_NAME'."
    restore_and_exit
fi
echo "✅ Red de Docker detectada: '$DETECTED_NETWORK'"

N8N_WORKER_SERVICE_NAME="${N8N_MAIN_SERVICE_NAME}-worker"

# --- Detectar env_file del servicio principal ---
ENV_FILE_PATH=$($YQ_CMD eval ".services.\"$N8N_MAIN_SERVICE_NAME\".env_file[0]" "$N8N_COMPOSE_PATH" 2>/dev/null || echo "")
if [[ -z "$ENV_FILE_PATH" ]]; then
  ENV_FILE_PATH=".env"
fi

# Verificar si DB_HOST está en el archivo env_file, si no pedir y añadir con default 'postgres'
if ! grep -qE "^DB_HOST=" "$ENV_FILE_PATH" 2>/dev/null; then
  echo "⚠️ No se encontró 'DB_HOST' en $ENV_FILE_PATH."
  input_db_host=$(ask "Por favor, ingresa el valor para DB_HOST" "postgres")
  echo "DB_HOST=$input_db_host" >> "$ENV_FILE_PATH"
  echo "✅ DB_HOST añadido a $ENV_FILE_PATH con valor '$input_db_host'."
fi

# --- FASE 2: CONFIGURACIÓN DEL MODO 'QUEUE' ---
print_header "2. Verificando y Configurando el Modo de Escalado"
IS_QUEUE_MODE=$($YQ_CMD eval ".services.\"$N8N_MAIN_SERVICE_NAME\".environment[] | select(. == \"EXECUTIONS_MODE=queue\")" "$N8N_COMPOSE_PATH" 2>/dev/null || echo "")

if [[ -z "$IS_QUEUE_MODE" ]]; then
    echo "🔧 El modo 'queue' no está configurado. Se procederá a modificar 'docker-compose.yml'."
    confirm_modify=$(ask "¿Desea continuar? Se creará un backup [y/N]" "N")
    if [[ ! "$confirm_modify" =~ ^[yY](es)?$ ]]; then
        echo "Instalación cancelada."
        rm -f yq
        exit 1
    fi

    BACKUP_FILE="${N8N_COMPOSE_PATH}.backup.$(date +%F_%H-%M-%S)"
    echo "🛡️  Creando copia de seguridad en '$BACKUP_FILE'..."
    cp "$N8N_COMPOSE_PATH" "$BACKUP_FILE"

    echo "⚙️  Aplicando configuración de modo 'queue' y añadiendo servicio de worker..."

    # --- Modificaciones con yq ---
    $YQ_CMD eval -i '.services."'$REDIS_HOST'".healthcheck.test = ["CMD", "redis-cli", "ping"]' "$N8N_COMPOSE_PATH"
    $YQ_CMD eval -i '.services."'$REDIS_HOST'".healthcheck.interval = "10s"' "$N8N_COMPOSE_PATH"
    $YQ_CMD eval -i '.services."'$REDIS_HOST'".healthcheck.timeout = "5s"' "$N8N_COMPOSE_PATH"
    $YQ_CMD eval -i '.services."'$REDIS_HOST'".healthcheck.retries = 5' "$N8N_COMPOSE_PATH"
    $YQ_CMD eval -i '.services."'$N8N_MAIN_SERVICE_NAME'".environment += ["EXECUTIONS_MODE=queue", "QUEUE_BULL_REDIS_HOST=\"'$REDIS_HOST'\"", "OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true"]' "$N8N_COMPOSE_PATH"
    $YQ_CMD eval -i '.services."'$N8N_MAIN_SERVICE_NAME'".depends_on."'$REDIS_HOST'".condition = "service_healthy"' "$N8N_COMPOSE_PATH"

    # Añadir worker con configuración copiada y ajustes
    $YQ_CMD eval -i '.services."'$N8N_WORKER_SERVICE_NAME'" = .services."'$N8N_MAIN_SERVICE_NAME'"' "$N8N_COMPOSE_PATH"
    $YQ_CMD eval -i 'del(.services."'$N8N_WORKER_SERVICE_NAME'".ports)' "$N8N_COMPOSE_PATH"
    $YQ_CMD eval -i 'del(.services."'$N8N_WORKER_SERVICE_NAME'".container_name)' "$N8N_COMPOSE_PATH"
    $YQ_CMD eval -i 'del(.services."'$N8N_WORKER_SERVICE_NAME'".labels)' "$N8N_COMPOSE_PATH"

    # Cambiado para poner env_file como lista, no string
    $YQ_CMD eval -i ".services.\"$N8N_WORKER_SERVICE_NAME\".env_file = [\"$ENV_FILE_PATH\"]" "$N8N_COMPOSE_PATH"

    if [[ $? -ne 0 ]]; then
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

if [[ -f "$N8N_ENV_PATH" ]]; then
    echo "📋 Copiando '$N8N_ENV_PATH' a '$AUTOSCALER_DIR/.env'..."
    cp "$N8N_ENV_PATH" "$AUTOSCALER_DIR/.env"
else
    echo "⚠️ No se encontró archivo .env principal, creando vacío en autoscaler..."
    touch "$AUTOSCALER_DIR/.env"
fi

cd "$AUTOSCALER_DIR" || exit

echo -e "\nAhora, configuremos el comportamiento del auto-escalado:"
QUEUE_THRESHOLD=$(ask "Nº de tareas en cola para crear un nuevo worker" "15")
MAX_WORKERS=$(ask "Nº máximo de workers permitidos" "5")
MIN_WORKERS=$(ask "Nº mínimo de workers activos" "0")
IDLE_TIME_BEFORE_SCALE_DOWN=$(ask "Segundos de inactividad para destruir un worker" "90")
POLL_INTERVAL=$(ask "Segundos entre cada verificación" "10")
TELEGRAM_BOT_TOKEN=$(ask "Token de Bot de Telegram (opcional)" "")
TELEGRAM_CHAT_ID=$(ask "Chat ID de Telegram (opcional)" "")

# Evitar duplicados, eliminamos si existen
sed -i '/^# --- AUTOSCALER CONFIG - GENERATED BY SCRIPT ---$/,/^$/d' .env

cat >> .env << EOL

# --- AUTOSCALER CONFIG - GENERATED BY SCRIPT ---
N8N_DOCKER_PROJECT_NAME=${N8N_PROJECT_NAME}
N8N_WORKER_SERVICE_NAME=${N8N_WORKER_SERVICE_NAME}
REDIS_HOST=${REDIS_HOST}
QUEUE_THRESHOLD=${QUEUE_THRESHOLD}
MAX_WORKERS=${MAX_WORKERS}
MIN_WORKERS=${MIN_WORKERS}
IDLE_TIME_BEFORE_SCALE_DOWN=${IDLE_TIME_BEFORE_SCALE_DOWN}
POLL_INTERVAL=${POLL_INTERVAL}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
EOL

echo "📄 Generando archivos para el autoscaler..."

# Docker Compose para el autoscaler
cat > docker-compose.yml << EOL
version: "3.8"
services:
  autoscaler:
    image: n8n-autoscaler-service:latest
    build: .
    container_name: ${N8N_PROJECT_NAME}_autoscaler
    restart: always
    env_file:
      - .env  # corregido: referencia local dentro del contenedor
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${N8N_COMPOSE_PATH}:/app/docker-compose.yml:ro
    working_dir: /app
    networks:
      - ${DETECTED_NETWORK}

networks:
  ${DETECTED_NETWORK}:
    external: true
EOL
cat > Dockerfile << 'EOL'
FROM python:3.9-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl ca-certificates gnupg apt-transport-https redis-tools && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y docker-ce-cli && \
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

cat > autoscaler.py << 'EOL'
import os
import time
import subprocess
import redis
import requests
from dotenv import load_dotenv

def log(message):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}", flush=True)

def notify(message):
    if not TELEGRAM_TOKEN or not TELEGRAM_CHAT_ID:
        return
    try:
        requests.post(
            f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage",
            json={'chat_id': TELEGRAM_CHAT_ID, 'text': message, 'parse_mode': 'Markdown'},
            timeout=10
        ).raise_for_status()
    except requests.exceptions.RequestException as e:
        log(f"⚠️  Error al enviar notificación a Telegram: {e}")

def docker_cmd(command):
    try:
        full_command = f"docker-compose -p {N8N_PROJECT_NAME} -f /app/docker-compose.yml {command}"
        log(f"🚀 Ejecutando: {full_command}")
        result = subprocess.run(full_command, shell=True, check=True, capture_output=True, text=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        error_message = f"❌ Docker Error: {e.stderr.strip() if e.stderr else e}"
        log(error_message)
        notify(f"‼️ *Error Crítico de Docker*\n_{error_message}_")
        return None

def get_workers():
    output = docker_cmd(f"ps -q {N8N_WORKER_NAME}")
    if output is None:
        return -1
    # Contar líneas no vacías
    return len([line for line in output.splitlines() if line.strip()])

def scale(count):
    current_workers = get_workers()
    if current_workers == -1 or current_workers == count:
        return
    log(f"⚖️ Escalando de {current_workers} a {count} workers...")
    command = f"up -d --scale {N8N_WORKER_NAME}={count} --no-recreate --remove-orphans"
    if docker_cmd(command) is not None:
        log(f"✅ Escalado completo. Workers activos: {count}")
        notify(f"✅ *{N8N_PROJECT_NAME}* | Workers: *{count}*")
    else:
        log(f"❌ Error al escalar a {count}")
        notify(f"❌ Error al escalar a {count}")

def main_loop():
    idle_since = None
    while True:
        try:
            queue_size = redis_client.llen(QUEUE_KEY)
            running_workers = get_workers()
            if running_workers == -1:
                time.sleep(POLL_INTERVAL * 2)
                continue
            log(f"Estado: Cola={queue_size}, Workers={running_workers}, Umbral={QUEUE_THRESHOLD}")

            desired_workers = min(max(queue_size, MIN_WORKERS), MAX_WORKERS)

            if desired_workers != running_workers:
                if desired_workers < running_workers:
                    if idle_since is None:
                        idle_since = time.time()
                        log(f"Cola vacía o menor. Temporizador de {IDLE_TIME_BEFORE_SCALE_DOWN}s iniciado.")
                    elif time.time() - idle_since >= IDLE_TIME_BEFORE_SCALE_DOWN:
                        scale(desired_workers)
                        idle_since = None
                else:
                    scale(desired_workers)
                    idle_since = None
            else:
                idle_since = None

            time.sleep(POLL_INTERVAL)
        except redis.exceptions.RedisError as e:
            log(f"⚠️ Redis Error: {e}. Reintentando...")
            time.sleep(POLL_INTERVAL * 2)
        except KeyboardInterrupt:
            log("🛑 Script detenido.")
            notify(f"🤖 Autoscaler para *{N8N_PROJECT_NAME}* detenido.")
            break
        except Exception as e:
            log(f"🔥 Error inesperado: {e}")
            notify(f"🔥 *Error en Autoscaler*\n_{str(e)}_")
            time.sleep(POLL_INTERVAL * 3)

if __name__ == "__main__":
    load_dotenv()
    N8N_PROJECT_NAME = os.getenv('N8N_DOCKER_PROJECT_NAME')
    N8N_WORKER_NAME = os.getenv('N8N_WORKER_SERVICE_NAME')
    REDIS_HOST = os.getenv('REDIS_HOST', 'redis')
    QUEUE_KEY = "bull:jobs:wait"
    QUEUE_THRESHOLD = int(os.getenv('QUEUE_THRESHOLD', 15))  # Jobs para crear nuevo worker
    MAX_WORKERS = int(os.getenv('MAX_WORKERS', 5))
    MIN_WORKERS = int(os.getenv('MIN_WORKERS', 0))
    IDLE_TIME_BEFORE_SCALE_DOWN = int(os.getenv('IDLE_TIME_BEFORE_SCALE_DOWN', 90))
    POLL_INTERVAL = int(os.getenv('POLL_INTERVAL', 10))
    TELEGRAM_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN')
    TELEGRAM_CHAT_ID = os.getenv('TELEGRAM_CHAT_ID')
    redis_client = redis.Redis(host=REDIS_HOST, decode_responses=True)
    main_loop()
EOL
# --- Despliegue Final ---
echo "🧹 Limpiando instancias anteriores del autoscaler..."
docker rm -f "${N8N_PROJECT_NAME}_autoscaler" > /dev/null 2>&1
echo "🏗️  Construyendo y desplegando el servicio de auto-escalado..."
$COMPOSE_CMD_HOST up -d --build
if [ $? -eq 0 ]; then
    print_header "🎉 ¡Instalación Completada con Éxito! 🎉"
    cd ..; echo -e "Tu stack de n8n ha sido configurado y el autoscaler está funcionando.\n\nPasos siguientes:\n  1. Revisa los logs: \033[0;32mdocker logs -f ${N8N_PROJECT_NAME}_autoscaler\033[0m\n  2. Configuración en: \033[0;32m./n8n-autoscaler/\033[0m"
else
    echo -e "\n❌ Hubo un error durante el despliegue del autoscaler."
    cd ..
fi
rm -f ./yq
echo -e "\nScript finalizado.\n"
