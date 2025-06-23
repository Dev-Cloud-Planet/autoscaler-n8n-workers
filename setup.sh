#!/bin/bash

# ==============================================================================
#   Script de Instalación del Servicio de Auto-Escalado para n8n
#
# Versión 11.0 
# ==============================================================================

# --- Funciones Auxiliares ---
print_header() { echo -e "\n\033[1;34m=================================================\033[0m\n\033[1;34m  $1\033[0m\n\033[1;34m=================================================\033[0m\n"; }
ask() { read -p "$1 (def: $2): " reply < /dev/tty; echo "${reply:-$default}"; }
restore_and_exit() {
    echo "🛡️  Restaurando 'docker-compose.yml' desde la copia de seguridad...";
    if [ -f "$BACKUP_FILE" ]; then mv "$BACKUP_FILE" "$N8N_COMPOSE_PATH"; echo "   Restauración completa. El script se detendrá.";
    else echo "   No se encontró un archivo de backup para restaurar."; fi
    rm -f patch.yml new-compose.yml yq
    exit 1
}

# --- Verificación de Dependencias ---
check_deps() {
    echo "🔎 Verificando dependencias...";
    for cmd in docker curl wget; do
        if ! command -v $cmd &>/dev/null; then echo "❌ Error: El comando '$cmd' es esencial." && exit 1; fi
    done
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        COMPOSE_CMD_HOST="docker compose"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD_HOST="docker-compose"
    else echo "❌ Error: No se encontró 'docker-compose' o el plugin 'docker compose'." && exit 1; fi
    echo "✅ Usaremos '$COMPOSE_CMD_HOST' para las operaciones del host."
    if [ ! -f ./yq ]; then
        YQ_URL="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
        echo "📥 Descargando la herramienta 'yq'...";
        if ! wget -q "$YQ_URL" -O ./yq || ! chmod +x ./yq; then echo "❌ Falló la descarga de yq." && exit 1; fi
    fi; YQ_CMD="./yq"; echo "✅ Dependencias del host listas."
}

# --- INICIO DEL SCRIPT ---
clear; check_deps
print_header "Instalador del Servicio de Auto-Escalado para n8n"

# --- FASE 1: DETECCIÓN Y RECOPILACIÓN DE DATOS ---
print_header "1. Analizando tu Entorno"
N8N_COMPOSE_PATH="$(pwd)/docker-compose.yml"
if [ ! -f "$N8N_COMPOSE_PATH" ]; then echo "❌ Error: No se encontró 'docker-compose.yml' en este directorio." && exit 1; fi
RAW_PROJECT_NAME=$(basename "$(pwd)"); N8N_PROJECT_NAME=$(echo "$RAW_PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_-]//g')
if [ -z "$N8N_PROJECT_NAME" ]; then N8N_PROJECT_NAME="n8n-project"; fi
echo "✅ Proyecto n8n detectado como: '$N8N_PROJECT_NAME'"

N8N_MAIN_SERVICE_NAME=$($YQ_CMD eval '(.services[] | select(.image == "n8nio/n8n*") | key)' "$N8N_COMPOSE_PATH" | head -n 1)
N8N_MAIN_SERVICE_NAME=$(ask "Nombre de tu servicio principal de n8n" "${N8N_MAIN_SERVICE_NAME:-n8n}")
N8N_WORKER_SERVICE_NAME="${N8N_MAIN_SERVICE_NAME}-worker"

NETWORK_KEY=$($YQ_CMD eval ".services.\"$N8N_MAIN_SERVICE_NAME\".networks[0]" "$N8N_COMPOSE_PATH")
if [ -z "$NETWORK_KEY" ] || [ "$NETWORK_KEY" == "null" ]; then echo "❌ Error: No se pudo detectar la red para '$N8N_MAIN_SERVICE_NAME'." && exit 1; fi
echo "✅ Red de Docker detectada: '$NETWORK_KEY'"

REDIS_SERVICE_NAME=$($YQ_CMD eval '(.services[] | select(.image == "redis*") | key)' "$N8N_COMPOSE_PATH" | head -n 1)
REDIS_HOST=$(ask "Hostname de tu servicio Redis" "${REDIS_SERVICE_NAME:-redis}")

# --- FASE 2: MODIFICACIÓN SEGURA DEL DOCKER-COMPOSE ---
print_header "2. Preparando tu Stack de n8n para Escalado"
worker_exists=$($YQ_CMD eval ".services | has(\"$N8N_WORKER_SERVICE_NAME\")" "$N8N_COMPOSE_PATH")
if [ "$worker_exists" = "true" ]; then
    echo "✅ Tu 'docker-compose.yml' ya está configurado con un worker."
else
    read -p "¿Estás de acuerdo en modificar 'docker-compose.yml'? (Se creará una copia de seguridad) (y/N): " confirm_modify < /dev/tty
    if [[ ! "$confirm_modify" =~ ^[yY](es)?$ ]]; then echo "Instalación cancelada." && exit 1; fi
    BACKUP_FILE="${N8N_COMPOSE_PATH}.backup.$(date +%F_%T)"; echo "🛡️  Creando copia de seguridad en '$BACKUP_FILE'..."; cp "$N8N_COMPOSE_PATH" "$BACKUP_FILE"
    
    echo "🔧 Generando parche de configuración..."
    
    # Extraer la configuración base del servicio n8n principal para clonarla
    N8N_BASE_CONFIG=$($YQ_CMD eval ".services.\"$N8N_MAIN_SERVICE_NAME\"" "$N8N_COMPOSE_PATH")
    
    # Crear el archivo patch.yml con las modificaciones
    cat << EOL > patch.yml
services:
  ${N8N_MAIN_SERVICE_NAME}:
    environment:
      - N8N_TRUST_PROXY=true
      - N8N_RUNNERS_ENABLED=true
      - EXECUTIONS_MODE=queue
      - EXECUTIONS_PROCESS=main
      - QUEUE_BULL_REDIS_HOST=${REDIS_HOST}
  ${N8N_WORKER_SERVICE_NAME}:
$(echo "$N8N_BASE_CONFIG" | $YQ_CMD eval '
    .restart = "unless-stopped" |
    del(.ports) |
    del(.labels) |
    del(.container_name) |
    .environment += [
        "N8N_TRUST_PROXY=true",
        "N8N_RUNNERS_ENABLED=true",
        "EXECUTIONS_MODE=queue",
        "EXECUTIONS_PROCESS=worker",
        "QUEUE_BULL_REDIS_HOST='${REDIS_HOST}'"
    ]
' - | sed 's/^/    /')
EOL

    echo "⚙️  Aplicando parche..."
    # Usar yq para fusionar el archivo original con el parche
    $YQ_CMD eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$N8N_COMPOSE_PATH" patch.yml > new-compose.yml

    # Verificación final antes de reemplazar
    if [ -s new-compose.yml ] && $YQ_CMD eval ".services | has(\"$N8N_WORKER_SERVICE_NAME\")" new-compose.yml | grep -q "true"; then
        echo "✅ Nueva configuración generada y verificada con éxito."
        mv new-compose.yml "$N8N_COMPOSE_PATH"
        
        echo "🔄 Aplicando la nueva configuración al stack de n8n..."
        $COMPOSE_CMD_HOST up -d --force-recreate --remove-orphans
        echo "✅ Tu stack de n8n ha sido actualizado y está listo para escalar."
    else
        echo "❌ ERROR FATAL: La fusión de la configuración falló. Revirtiendo..."
        restore_and_exit
    fi
fi

# --- FASE 3: DESPLIEGUE DEL AUTOSCALER ---
# (Esta sección es estable y no requiere cambios)
print_header "3. Desplegando el Servicio de Auto-Escalado"
AUTOSCALER_PROJECT_DIR="n8n-autoscaler"
QUEUE_THRESHOLD=$(ask "Nº de tareas en cola para crear un worker" "20")
MAX_WORKERS=$(ask "Nº máximo de workers permitidos" "5")
MIN_WORKERS=$(ask "Nº mínimo de workers que deben mantenerse activos" "0")
IDLE_TIME_BEFORE_SCALE_DOWN=$(ask "Segundos de inactividad para destruir un worker" "60")
TELEGRAM_BOT_TOKEN=$(ask "Token de Bot de Telegram (opcional)" "")
TELEGRAM_CHAT_ID=$(ask "Chat ID de Telegram (opcional)" "")
mkdir -p "$AUTOSCALER_PROJECT_DIR" && cd "$AUTOSCALER_PROJECT_DIR" || exit

# --- Generación de archivos del autoscaler (sin cambios) ---
echo "-> Generando archivos para el servicio autoscaler..."
# .env
cat > .env << EOL
REDIS_HOST=${REDIS_HOST}
N8N_DOCKER_PROJECT_NAME=${N8N_PROJECT_NAME}
N8N_WORKER_SERVICE_NAME=${N8N_WORKER_SERVICE_NAME}
QUEUE_THRESHOLD=${QUEUE_THRESHOLD}
MAX_WORKERS=${MAX_WORKERS}
MIN_WORKERS=${MIN_WORKERS}
IDLE_TIME_BEFORE_SCALE_DOWN=${IDLE_TIME_BEFORE_SCALE_DOWN}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
EOL
# docker-compose.yml
cat > docker-compose.yml << EOL
services:
  autoscaler:
    build: .
    container_name: ${N8N_PROJECT_NAME}_autoscaler
    restart: always
    env_file: .env
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - n8n_shared_network
networks:
  n8n_shared_network:
    name: ${N8N_PROJECT_NAME}_${NETWORK_KEY}
    driver: bridge
EOL
# Dockerfile
cat > Dockerfile << 'EOL'
FROM python:3.9-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates gnupg && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && apt-get install -y docker-ce-cli
RUN curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose && \
    chmod +x /usr/local/bin/docker-compose
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY autoscaler.py .
CMD ["python", "-u", "autoscaler.py"]
EOL
# requirements.txt
cat > requirements.txt << 'EOL'
redis
requests
python-dotenv
EOL
# autoscaler.py
cat > autoscaler.py << 'EOL'
import os, time, subprocess, redis, requests
from dotenv import load_dotenv
load_dotenv()
REDIS_HOST = os.getenv('REDIS_HOST'); N8N_PROJECT_NAME = os.getenv('N8N_DOCKER_PROJECT_NAME'); N8N_WORKER_SERVICE_NAME = os.getenv('N8N_WORKER_SERVICE_NAME')
QUEUE_KEY = f"bull:default:wait"; QUEUE_THRESHOLD = int(os.getenv('QUEUE_THRESHOLD', 20)); MAX_WORKERS = int(os.getenv('MAX_WORKERS', 5))
MIN_WORKERS = int(os.getenv('MIN_WORKERS', 0)); IDLE_TIME_BEFORE_SCALE_DOWN = int(os.getenv('IDLE_TIME_BEFORE_SCALE_DOWN', 60))
POLL_INTERVAL = 10; TELEGRAM_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN'); TELEGRAM_CHAT_ID = os.getenv('TELEGRAM_CHAT_ID')
COMPOSE_CMD = "/usr/local/bin/docker-compose"
try:
    redis_client = redis.Redis(host=REDIS_HOST, decode_responses=True, socket_connect_timeout=5); redis_client.ping(); print("✅ Conexión con Redis establecida con éxito.")
except redis.exceptions.RedisError as e: print(f"❌ Error fatal al conectar con Redis: {e}"); exit(1)
def send_telegram_notification(message):
    if not TELEGRAM_TOKEN or not TELEGRAM_CHAT_ID: return
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"; payload = {'chat_id': TELEGRAM_CHAT_ID, 'text': message, 'parse_mode': 'Markdown'}
    try: requests.post(url, json=payload, timeout=10).raise_for_status()
    except requests.exceptions.RequestException: pass
def run_docker_command(command):
    try:
        full_command = f"{COMPOSE_CMD} -p {N8N_PROJECT_NAME} {command}"; result = subprocess.run(full_command, shell=True, check=True, capture_output=True, text=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"❌ Error ejecutando: {full_command}\n   Error: {e.stderr.strip()}"); send_telegram_notification(f"‼️ *Error Crítico de Docker*\n_{e.stderr.strip()}_"); return None
def get_running_workers():
    output = run_docker_command(f"ps -q {N8N_WORKER_SERVICE_NAME}"); return -1 if output is None else len(output.splitlines()) if output else 0
def scale_workers(desired_count):
    current_workers = get_running_workers()
    if current_workers == -1 or current_workers == desired_count: return
    print(f"⚖️  Escalando workers de {current_workers} a {desired_count}...")
    command = f"up -d --scale {N8N_WORKER_SERVICE_NAME}={desired_count} --no-recreate --remove-orphans"
    if run_docker_command(command) is not None: send_telegram_notification(f"✅ Auto-escalado. *Workers activos: {desired_count}*")
    else: send_telegram_notification(f"❌ *Error al escalar workers a {desired_count}*")
if __name__ == "__main__":
    send_telegram_notification(f"🤖 El servicio de auto-escalado para *{N8N_PROJECT_NAME}* ha sido iniciado.")
    idle_since = None
    while True:
        try:
            queue_size = redis_client.llen(QUEUE_KEY); running_workers = get_running_workers()
            if running_workers == -1: time.sleep(POLL_INTERVAL * 2); continue
            print(f"Estado: Cola={queue_size}, Workers={running_workers}, Umbral={QUEUE_THRESHOLD}")
            if queue_size > QUEUE_THRESHOLD and running_workers < MAX_WORKERS:
                scale_workers(min(running_workers + 1, MAX_WORKERS)); idle_since = None
            elif queue_size <= MIN_WORKERS and running_workers > MIN_WORKERS:
                if idle_since is None: idle_since = time.time()
                if time.time() - idle_since >= IDLE_TIME_BEFORE_SCALE_DOWN: scale_workers(max(running_workers - 1, MIN_WORKERS)); idle_since = None
            elif queue_size > MIN_WORKERS: idle_since = None
            time.sleep(POLL_INTERVAL)
        except redis.exceptions.RedisError as e: print(f"⚠️ Error de Redis: {e}. Reintentando..."); time.sleep(POLL_INTERVAL * 2)
        except KeyboardInterrupt: send_telegram_notification(f"🤖 Servicio para *{N8N_PROJECT_NAME}* detenido."); break
        except Exception as e: print(f"🔥 Error inesperado: {e}"); send_telegram_notification(f"🔥 *Error en Autoscaler {N8N_PROJECT_NAME}*\n_{str(e)}_"); time.sleep(POLL_INTERVAL * 3)
EOL

echo "🧹 Limpiando cualquier instancia anterior del autoscaler..."; docker rm -f "${N8N_PROJECT_NAME}_autoscaler" > /dev/null 2>&1
echo "🚀 Desplegando el servicio de auto-escalado..."; $COMPOSE_CMD_HOST up -d --build

if [ $? -eq 0 ]; then
    print_header "¡Instalación Completada!"; cd ..
    echo "Tu stack ha sido configurado y el servicio de auto-escalado está en funcionamiento."; echo ""
    echo "Pasos siguientes:"; echo "  1. Verifica con 'cat docker-compose.yml' que el archivo fue modificado."; echo "  2. Verifica los logs con: docker logs -f ${N8N_PROJECT_NAME}_autoscaler"
else
    echo -e "\n❌ Hubo un error durante el despliegue del autoscaler."; cd ..
fi
# Limpieza final
rm -f ./yq patch.yml