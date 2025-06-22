#!/bin/bash

# ==============================================================================
#   Script de Instalación del Servicio de Auto-Escalado para n8n (Ejecutar en Sitio)
#
# Versión 8.1 
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
# --- Verificación de Dependencias y Entorno del Host ---
check_deps() {
    echo "🔎 Verificando que tu sistema tenga todo lo necesario..."
    for cmd in docker curl wget; do
        if ! command -v $cmd &>/dev/null; then
            echo "❌ Error: El comando '$cmd' es esencial y no se encuentra. Por favor, instálalo." && exit 1;
        fi
    done
    
    # Determinar qué comando de 'compose' usar (prefiere la versión nueva)
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        COMPOSE_CMD_HOST="docker compose"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD_HOST="docker-compose"
    else
        echo "❌ Error: No se encontró 'docker-compose' o el plugin 'docker compose' en tu sistema." && exit 1
    fi
    echo "✅ Usaremos '$COMPOSE_CMD_HOST' para gestionar los contenedores."

    # Descargar 'yq' localmente para evitar conflictos de versiones
    if [ ! -f ./yq ]; then
        YQ_URL="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
        echo "📥 'yq' (una herramienta para YAML) no encontrado. Descargando la versión correcta..."
        if ! wget -q "$YQ_URL" -O ./yq || ! chmod +x ./yq; then
            echo "❌ Falló la descarga de yq. Revisa tu conexión a internet y los permisos." && exit 1;
        fi
    fi
    YQ_CMD="./yq"
    echo "✅ Todas las dependencias del host están listas."
}

# --- INICIO DEL SCRIPT ---
clear
check_deps
print_header "Instalador del Servicio de Auto-Escalado para n8n"

# --- FASE 1: DETECCIÓN Y RECOPILACIÓN DE DATOS ---
print_header "1. Detectando y Configurando tu Stack"
N8N_COMPOSE_PATH="$(pwd)/docker-compose.yml"
if [ ! -f "$N8N_COMPOSE_PATH" ]; then
    echo "❌ Error: No se encontró 'docker-compose.yml' en este directorio."
    echo "   Por favor, ejecuta este script desde la misma carpeta donde está tu archivo principal." && exit 1
fi

# Limpiar el nombre de la carpeta para usarlo como nombre de proyecto
RAW_PROJECT_NAME=$(basename "$(pwd)")
N8N_PROJECT_NAME=$(echo "$RAW_PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-]//g')
if [ -z "$N8N_PROJECT_NAME" ]; then N8N_PROJECT_NAME="n8n-project"; fi
echo "✅ Proyecto n8n detectado como: '$N8N_PROJECT_NAME'"

N8N_MAIN_SERVICE_NAME=$($YQ_CMD eval '(.services[] | select(.image == "n8nio/n8n*") | key)' "$N8N_COMPOSE_PATH" | head -n 1)
N8N_MAIN_SERVICE_NAME=$(ask "Nombre de tu servicio principal de n8n" "${N8N_MAIN_SERVICE_NAME:-n8n}")
N8N_WORKER_SERVICE_NAME="n8n-worker"
N8N_NETWORK_NAME=$($YQ_CMD eval ".services.$N8N_MAIN_SERVICE_NAME.networks[0]" "$N8N_COMPOSE_PATH")
if [ -z "$N8N_NETWORK_NAME" ] || [ "$N8N_NETWORK_NAME" == "null" ]; then
    echo "❌ Error: No se pudo detectar la red para el servicio '$N8N_MAIN_SERVICE_NAME'." && exit 1
fi
echo "✅ Red de Docker detectada: '$N8N_NETWORK_NAME'"

REDIS_SERVICE_NAME=$($YQ_CMD eval '(.services[] | select(.image == "redis*") | key)' "$N8N_COMPOSE_PATH" | head -n 1)
REDIS_HOST=$(ask "Hostname de tu servicio Redis" "${REDIS_SERVICE_NAME:-redis}")

# --- FASE 2: MODIFICACIÓN SEGURA DEL DOCKER-COMPOSE ---
print_header "2. Preparando tu Stack de n8n para Escalado"

if $YQ_CMD eval ".services | has(\"$N8N_WORKER_SERVICE_NAME\")" "$N8N_COMPOSE_PATH" &>/dev/null; then
    echo "✅ ¡Excelente! Tu 'docker-compose.yml' ya parece estar configurado con un worker. Omitiendo la modificación."
else
    read -p "¿Estás de acuerdo en modificar 'docker-compose.yml' para añadir workers? (Se creará una copia de seguridad) (y/N): " confirm_modify < /dev/tty
    if [[ ! "$confirm_modify" =~ ^[yY](es)?$ ]]; then echo "Instalación cancelada." && exit 1; fi

    BACKUP_FILE="${N8N_COMPOSE_PATH}.backup.$(date +%F_%T)"
    echo "🛡️  Creando una copia de seguridad segura en '$BACKUP_FILE'..."
    cp "$N8N_COMPOSE_PATH" "$BACKUP_FILE"

    echo "🔧 Generando la nueva configuración para tu stack..."

    ORIGINAL_ENV=$($YQ_CMD eval ".services.${N8N_MAIN_SERVICE_NAME}.environment" "$N8N_COMPOSE_PATH")

    NEW_N8N_MAIN_ENV=$(
        echo "$ORIGINAL_ENV" | $YQ_CMD eval '. += [
            "N8N_TRUST_PROXY=true",
            "N8N_RUNNERS_ENABLED=true",
            "EXECUTIONS_MODE=queue",
            "EXECUTIONS_PROCESS=main",
            "QUEUE_BULL_REDIS_HOST='"$REDIS_HOST"'"
        ]'
    )

    NEW_N8N_WORKER_ENV=$(
        echo "$ORIGINAL_ENV" | $YQ_CMD eval '. += [
            "N8N_TRUST_PROXY=true",
            "N8N_RUNNERS_ENABLED=true",
            "EXECUTIONS_MODE=queue",
            "EXECUTIONS_PROCESS=worker",
            "QUEUE_BULL_REDIS_HOST='"$REDIS_HOST"'"
        ]'
    )

    WORKER_SERVICE_BLOCK=$(
        $YQ_CMD eval ".services.${N8N_MAIN_SERVICE_NAME}" "$N8N_COMPOSE_PATH" | \
        $YQ_CMD eval '.restart = "unless-stopped"' | \
        $YQ_CMD eval 'del(.ports)' | \
        $YQ_CMD eval 'del(.labels)' | \
        $YQ_CMD eval --argjson env "$($YQ_CMD eval -o=j <<< "$NEW_N8N_WORKER_ENV")" '.environment = $env'
    )
    TEMP_COMPOSE_FILE=$(mktemp)
    $YQ_CMD eval --argjson new_env "$($YQ_CMD eval -o=j <<< "$NEW_N8N_MAIN_ENV")" \
        '(.services.'$N8N_MAIN_SERVICE_NAME'.environment) = $new_env' \
        "$N8N_COMPOSE_PATH" > "$TEMP_COMPOSE_FILE"

    $YQ_CMD eval --argjson worker_block "$($YQ_CMD eval -o=j <<< "$WORKER_SERVICE_BLOCK")" \
        '(.services.'$N8N_WORKER_SERVICE_NAME') = $worker_block' \
        "$TEMP_COMPOSE_FILE" > "$N8N_COMPOSE_PATH"
    
    rm "$TEMP_COMPOSE_FILE"

    # Verificación final post-modificación
    if $YQ_CMD eval ".services | has(\"$N8N_WORKER_SERVICE_NAME\")" "$N8N_COMPOSE_PATH" &>/dev/null && \
       $YQ_CMD eval ".services.${N8N_MAIN_SERVICE_NAME}.environment[] | select(. == \"EXECUTIONS_MODE=queue\")" "$N8N_COMPOSE_PATH" | grep -q "queue"; then
        echo "✅ ¡Éxito! La nueva configuración ha sido generada y verificada."
        echo "🔄 Aplicando los cambios al stack de n8n..."
        $COMPOSE_CMD_HOST up -d --force-recreate --remove-orphans
        echo "✅ Tu stack de n8n ha sido actualizado y ahora está listo para escalar."
    else
        echo "❌ ERROR FATAL: La verificación final del archivo modificado falló."
        echo "   La modificación no se aplicó correctamente. Se restaurará la copia de seguridad."
        mv "$BACKUP_FILE" "$N8N_COMPOSE_PATH"
        exit 1
    fi
fi

# --- FASE 3: DESPLIEGUE DEL AUTOSCALER ---
print_header "3. Desplegando el Servicio de Auto-Escalado"
AUTOSCALER_PROJECT_DIR="n8n-autoscaler"
QUEUE_THRESHOLD=$(ask "Nº de tareas en cola para crear un worker" "20")
MAX_WORKERS=$(ask "Nº máximo de workers permitidos" "5")
MIN_WORKERS=$(ask "Nº mínimo de workers que deben mantenerse activos" "0")
IDLE_TIME_BEFORE_SCALE_DOWN=$(ask "Segundos de inactividad para destruir un worker" "60")
TELEGRAM_BOT_TOKEN=$(ask "Token de Bot de Telegram (opcional)" "")
TELEGRAM_CHAT_ID=$(ask "Chat ID de Telegram (opcional)" "")

mkdir -p "$AUTOSCALER_PROJECT_DIR" && cd "$AUTOSCALER_PROJECT_DIR" || exit

echo "-> Generando archivos para el servicio autoscaler..."

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
    name: ${N8N_PROJECT_NAME}_${N8N_NETWORK_NAME}
    external: true
EOL

cat > Dockerfile << EOL
FROM python:3.9-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates gnupg && rm -rf /var/lib/apt/lists/*
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

cat > requirements.txt << 'EOL'
redis
requests
python-dotenv
EOL

cat > autoscaler.py << 'EOL'
import os, time, subprocess, redis, requests
from dotenv import load_dotenv
load_dotenv()
REDIS_HOST = os.getenv('REDIS_HOST')
N8N_PROJECT_NAME = os.getenv('N8N_DOCKER_PROJECT_NAME')
N8N_WORKER_SERVICE_NAME = os.getenv('N8N_WORKER_SERVICE_NAME')
QUEUE_NAME = "default"; QUEUE_KEY = f"bull:{QUEUE_NAME}:wait"
QUEUE_THRESHOLD = int(os.getenv('QUEUE_THRESHOLD', 20))
MAX_WORKERS = int(os.getenv('MAX_WORKERS', 5))
MIN_WORKERS = int(os.getenv('MIN_WORKERS', 0))
IDLE_TIME_BEFORE_SCALE_DOWN = int(os.getenv('IDLE_TIME_BEFORE_SCALE_DOWN', 60))
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
        # Usamos docker-compose, que está en la ruta fija dentro del contenedor
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

echo "🧹 Limpiando cualquier instancia anterior del autoscaler..."
$COMPOSE_CMD_HOST down --remove-orphans > /dev/null 2>&1

echo "🚀 Desplegando el servicio de auto-escalado (la primera vez puede tardar en construir la imagen)..."
$COMPOSE_CMD_HOST up -d --build

if [ $? -eq 0 ]; then
    print_header "¡Instalación Completada!"
    echo "Tu stack ha sido configurado y el servicio de auto-escalado está en funcionamiento."
    echo ""
    echo "Pasos siguientes:"
    echo "  1. Verifica los logs del autoscaler: docker logs -f ${N8N_PROJECT_NAME}_autoscaler"
    echo "  2. Verifica los logs de n8n: docker logs ${N8N_MAIN_SERVICE_NAME}"
    echo "     (No deberías ver 'n8n Task Broker ready...')"
    echo "  3. Para detener solo el autoscaler: (cd ${AUTOSCALER_PROJECT_DIR} && $COMPOSE_CMD_HOST down)"
    cd ..
else
    echo -e "\n❌ Hubo un error durante el despliegue del autoscaler."
fi

# Limpieza final del script
rm -f ./yq