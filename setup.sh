#!/bin/bash

# ==============================================================================
#   Script de Instalación del Servicio de Auto-Escalado para n8n (Ejecutar en Sitio)
#
# Versión 5.1
# ==============================================================================

# --- Funciones Auxiliares ---
print_header() {
    echo -e "\n\033[1;34m=================================================\033[0m"
    echo -e "\033[1;34m  $1\033[0m"
    echo -e "\033[1;34m=================================================\033[0m\n"
}

ask() {
    local prompt default reply
    prompt="$1"
    default="$2"
    read -p "$prompt (def: $default): " reply < /dev/tty
    echo "${reply:-$default}"
}

# --- Verificación de Dependencias y Entorno ---
check_deps() {
    echo "🔎 Verificando dependencias y entorno del host..."
    for cmd in docker curl wget; do
        if ! command -v $cmd &> /dev/null; then echo "❌ Error: El comando '$cmd' es requerido." && exit 1; fi
    done
    
    if ! docker compose version &>/dev/null && ! docker-compose version &>/dev/null; then
        echo "❌ Error: No se encontró 'docker-compose' o el plugin 'docker compose' en el host." && exit 1
    fi

    if [ ! -f ./yq ]; then
        echo "📥 Descargando la versión correcta de 'yq' localmente..."
        YQ_URL="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
        if ! wget -q "$YQ_URL" -O ./yq || ! chmod +x ./yq; then echo "❌ Falló la descarga de yq." && exit 1; fi
    fi
    YQ_CMD="./yq"
    echo "✅ Dependencias del host listas."
}

# --- INICIO DEL SCRIPT ---
clear
check_deps

print_header "Instalador del Servicio de Auto-Escalado para n8n"

# --- DETECCIÓN DE CONTEXTO ---
print_header "1. Detectando Entorno del Proyecto"
N8N_COMPOSE_PATH="$(pwd)/docker-compose.yml"
if [ ! -f "$N8N_COMPOSE_PATH" ]; then
    echo "❌ Error: No se encontró 'docker-compose.yml' en el directorio actual." && exit 1
fi
RAW_PROJECT_NAME=$(basename "$(pwd)")
N8N_PROJECT_NAME=$(echo "$RAW_PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-]//g')
if [ -z "$N8N_PROJECT_NAME" ]; then N8N_PROJECT_NAME="n8n-project"; fi
echo "✅ Proyecto n8n detectado como: '$N8N_PROJECT_NAME'"

# --- RECOPILACIÓN DE DATOS ---
print_header "2. Configuración del Stack"
N8N_MAIN_SERVICE_NAME=$($YQ_CMD eval '(.services[] | select(.image == "n8nio/n8n*") | key)' "$N8N_COMPOSE_PATH" | head -n 1)
N8N_MAIN_SERVICE_NAME=$(ask "Introduce el nombre de tu servicio principal de n8n en el YAML" "${N8N_MAIN_SERVICE_NAME:-n8n}")
N8N_WORKER_SERVICE_NAME="n8n-worker"

N8N_NETWORK_NAME=$($YQ_CMD eval ".services.$N8N_MAIN_SERVICE_NAME.networks[0]" "$N8N_COMPOSE_PATH")
if [ -z "$N8N_NETWORK_NAME" ] || [ "$N8N_NETWORK_NAME" == "null" ]; then
    echo "❌ Error: No se pudo detectar la red para el servicio '$N8N_MAIN_SERVICE_NAME'." && exit 1
fi
echo "✅ Red detectada para n8n: '$N8N_NETWORK_NAME'"

REDIS_SERVICE_NAME=$($YQ_CMD eval '(.services[] | select(.image == "redis*") | key)' "$N8N_COMPOSE_PATH" | head -n 1)
REDIS_HOST=$(ask "Introduce el Hostname de tu servicio Redis" "${REDIS_SERVICE_NAME:-redis}")

# --- MODIFICACIÓN DEL DOCKER-COMPOSE DE N8N ---
print_header "3. Preparando el Stack de n8n para Escalado"
if $YQ_CMD eval ".services | has(\"$N8N_WORKER_SERVICE_NAME\")" "$N8N_COMPOSE_PATH" &>/dev/null; then
    echo "✅ El servicio de worker '$N8N_WORKER_SERVICE_NAME' ya existe. Omitiendo modificación."
else
    read -p "¿Estás de acuerdo en modificar tu 'docker-compose.yml'? (Se creará una copia de seguridad) (y/N): " confirm_modify < /dev/tty
    if [[ ! "$confirm_modify" =~ ^[yY](es)?$ ]]; then echo "Instalación cancelada." && exit 1; fi

    BACKUP_FILE="${N8N_COMPOSE_PATH}.backup.$(date +%F_%T)"
    echo "🛡️  Creando copia de seguridad en '$BACKUP_FILE'..."
    cp "$N8N_COMPOSE_PATH" "$BACKUP_FILE"

    echo "🔧 Modificando el stack de n8n paso a paso..."
    
    # --- BLOQUE DE MODIFICACIÓN GRANULAR Y CON VERIFICACIÓN ---
    $YQ_CMD eval -i ".services.${N8N_MAIN_SERVICE_NAME}.environment.EXECUTIONS_MODE = \"queue\"" "$N8N_COMPOSE_PATH" || { echo "❌ ERROR FATAL: Falla al añadir EXECUTIONS_MODE."; exit 1; }
    $YQ_CMD eval -i ".services.${N8N_MAIN_SERVICE_NAME}.environment.EXECUTIONS_PROCESS = \"main\"" "$N8N_COMPOSE_PATH" || { echo "❌ ERROR FATAL: Falla al añadir EXECUTIONS_PROCESS."; exit 1; }
    $YQ_CMD eval -i ".services.${N8N_MAIN_SERVICE_NAME}.environment.QUEUE_BULL_REDIS_HOST = \"$REDIS_HOST\"" "$N8N_COMPOSE_PATH" || { echo "❌ ERROR FATAL: Falla al añadir QUEUE_BULL_REDIS_HOST."; exit 1; }
    
    echo "➕ Creando el nuevo servicio de worker '$N8N_WORKER_SERVICE_NAME'..."
    $YQ_CMD eval -i ".services.${N8N_WORKER_SERVICE_NAME} = .services.${N8N_MAIN_SERVICE_NAME}" "$N8N_COMPOSE_PATH" || { echo "❌ ERROR FATAL: Falla al clonar el servicio n8n."; exit 1; }
    $YQ_CMD eval -i ".services.${N8N_WORKER_SERVICE_NAME}.environment.EXECUTIONS_PROCESS = \"worker\"" "$N8N_COMPOSE_PATH" || { echo "❌ ERROR FATAL: Falla al configurar el worker como 'worker'."; exit 1; }
    $YQ_CMD eval -i "del(.services.${N8N_WORKER_SERVICE_NAME}.ports)" "$N8N_COMPOSE_PATH"
    $YQ_CMD eval -i "del(.services.${N8N_WORKER_SERVICE_NAME}.labels)" "$N8N_COMPOSE_PATH"
    $YQ_CMD eval -i ".services.${N8N_WORKER_SERVICE_NAME}.restart = \"unless-stopped\"" "$N8N_COMPOSE_PATH" || { echo "❌ ERROR FATAL: Falla al configurar restart en worker."; exit 1; }
    # --- FIN DEL BLOQUE DE MODIFICACIÓN ---

    echo "✅ Archivo 'docker-compose.yml' modificado con éxito."
    echo "🔄 Aplicando la nueva configuración al stack de n8n..."
    if command -v docker &> /dev/null && docker compose version &> /dev/null; then
        docker compose up -d --remove-orphans
    else
        docker-compose up -d --remove-orphans
    fi
    echo "✅ Stack de n8n actualizado."
fi

# --- DESPLIEGUE DEL AUTOSCALER ---
print_header "4. Desplegando el Servicio de Auto-Escalado"
AUTOSCALER_PROJECT_DIR="n8n-autoscaler"
QUEUE_THRESHOLD=$(ask "Nº de tareas en cola para crear un worker" "20")
MAX_WORKERS=$(ask "Nº máximo de workers permitidos" "5")
MIN_WORKERS=$(ask "Nº mínimo de workers que deben mantenerse activos" "0")
IDLE_TIME_BEFORE_SCALE_DOWN=$(ask "Segundos de inactividad para destruir un worker" "60")
TELEGRAM_BOT_TOKEN=$(ask "Introduce tu Token de Bot de Telegram (opcional)" "")
TELEGRAM_CHAT_ID=$(ask "Introduce tu Chat ID de Telegram (opcional)" "")
mkdir -p "$AUTOSCALER_PROJECT_DIR" && cd "$AUTOSCALER_PROJECT_DIR" || exit
echo "-> Generando archivo .env..."; cat > .env << EOL
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
echo "-> Generando archivo docker-compose.yml..."; cat > docker-compose.yml << EOL
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
    name: ${N8N_PROJECT_NAME}_${N8N_NETWORK_NAME}
    external: true
EOL
echo "-> Generando archivo Dockerfile..."; cat > Dockerfile << EOL
FROM python:3.9-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    echo "deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \
    \$(. /etc/os-release && echo "\$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && apt-get install -y docker-ce-cli
RUN curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)" -o /usr/local/bin/docker-compose && \
    chmod +x /usr/local/bin/docker-compose
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY autoscaler.py .
CMD ["python", "-u", "autoscaler.py"]
EOL
echo "-> Generando archivo requirements.txt..."; cat > requirements.txt << 'EOL'
redis
requests
python-dotenv
EOL
echo "-> Generando archivo autoscaler.py..."; cat > autoscaler.py << 'EOL'
import os, time, subprocess, redis, requests
from dotenv import load_dotenv
load_dotenv()
REDIS_HOST = os.getenv('REDIS_HOST')
N8N_PROJECT_NAME = os.getenv('N8N_DOCKER_PROJECT_NAME')
N8N_WORKER_SERVICE_NAME = os.getenv('N8N_WORKER_SERVICE_NAME')
QUEUE_NAME = "default"; QUEUE_KEY = f"bull:{QUEUE_NAME}:wait"
QUEUE_THRESHOLD = int(os.getenv('QUEUE_THRESHOLD')); MAX_WORKERS = int(os.getenv('MAX_WORKERS'))
MIN_WORKERS = int(os.getenv('MIN_WORKERS')); IDLE_TIME_BEFORE_SCALE_DOWN = int(os.getenv('IDLE_TIME_BEFORE_SCALE_DOWN'))
POLL_INTERVAL = 10; TELEGRAM_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN'); TELEGRAM_CHAT_ID = os.getenv('TELEGRAM_CHAT_ID')
COMPOSE_CMD = "/usr/local/bin/docker-compose"
try:
    redis_client = redis.Redis(host=REDIS_HOST, decode_responses=True, socket_connect_timeout=5)
    redis_client.ping(); print("✅ Conexión con Redis establecida con éxito.")
except redis.exceptions.RedisError as e: print(f"❌ Error fatal al conectar con Redis: {e}"); exit(1)
def send_telegram_notification(message):
    if not TELEGRAM_TOKEN or not TELEGRAM_CHAT_ID: return
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"; payload = {'chat_id': TELEGRAM_CHAT_ID, 'text': message, 'parse_mode': 'Markdown'}
    try: requests.post(url, json=payload, timeout=10).raise_for_status()
    except requests.exceptions.RequestException: pass
def run_docker_command(command):
    try:
        full_command = f"{COMPOSE_CMD} -p {N8N_PROJECT_NAME} {command}"
        result = subprocess.run(full_command, shell=True, check=True, capture_output=True, text=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"❌ Error ejecutando: {full_command}\n   Error: {e.stderr.strip()}"); send_telegram_notification(f"‼️ *Error Crítico de Docker*\n_{e.stderr.strip()}_"); return None
def get_running_workers():
    output = run_docker_command(f"ps -q {N8N_WORKER_SERVICE_NAME}"); return -1 if output is None else len(output.splitlines()) if output else 0
def scale_workers(desired_count):
    current_workers = get_running_workers()
    if current_workers == -1 or current_workers == desired_count: return
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
            elif queue_size == 0 and running_workers > MIN_WORKERS:
                if idle_since is None: idle_since = time.time()
                if time.time() - idle_since >= IDLE_TIME_BEFORE_SCALE_DOWN: scale_workers(max(running_workers - 1, MIN_WORKERS)); idle_since = None
            elif queue_size > 0: idle_since = None
            time.sleep(POLL_INTERVAL)
        except redis.exceptions.RedisError as e: print(f"⚠️ Error de Redis: {e}. Reintentando..."); time.sleep(POLL_INTERVAL * 2)
        except KeyboardInterrupt: send_telegram_notification(f"🤖 Servicio para *{N8N_PROJECT_NAME}* detenido."); break
        except Exception as e: print(f"🔥 Error inesperado: {e}"); send_telegram_notification(f"🔥 *Error en Autoscaler {N8N_PROJECT_NAME}*\n_{str(e)}_"); time.sleep(POLL_INTERVAL * 3)
EOL
if command -v docker &> /dev/null && docker compose version &> /dev/null; then
    COMPOSE_CMD_HOST="docker compose"
else
    COMPOSE_CMD_HOST="docker-compose"
fi
echo "🧹 Limpiando cualquier instancia anterior del autoscaler..."; $COMPOSE_CMD_HOST down --remove-orphans > /dev/null 2>&1
echo "🚀 Desplegando el servicio de auto-escalado..."; $COMPOSE_CMD_HOST up -d --build
if [ $? -eq 0 ]; then
    print_header "¡Instalación Completada!"
    echo "Comandos útiles:"
    echo "  - Ver logs del autoscaler: docker logs -f ${N8N_PROJECT_NAME}_autoscaler"
    echo "  - Detener el autoscaler:   (cd ${AUTOSCALER_PROJECT_DIR} && docker compose down)"
    cd ..
else
    echo -e "\n❌ Hubo un error durante el despliegue del autoscaler."
fi
rm -f ./yq