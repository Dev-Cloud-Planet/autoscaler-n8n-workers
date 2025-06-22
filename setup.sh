#!/bin/bash

# ==============================================================================
#   Script de Instalación del Servicio de Auto-Escalado para n8n (Ejecutar en Sitio)
#
# Versión 9.1 
# ==============================================================================

# --- Funciones Auxiliares ---

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

# Función de verificación mejorada.
run_and_verify() {
    local modification_cmd=$1
    local verification_cmd=$2
    local success_message=$3

    eval "$modification_cmd"
    if [ $? -ne 0 ]; then
        echo "❌ ERROR: El comando de modificación yq falló con un código de error."
        echo "   Comando ejecutado: $modification_cmd"
        restore_and_exit
    fi

    # Captura la salida de la verificación y comprueba que no esté vacía.
    local verification_output
    verification_output=$(eval "$verification_cmd")
    if [ -z "$verification_output" ]; then
        echo "❌ ERROR FATAL: La verificación falló para '$success_message'."
        echo "   El archivo docker-compose.yml no se modificó como se esperaba."
        restore_and_exit
    fi
    echo "✅ OK: $success_message"
}

restore_and_exit() {
    echo "🛡️  Restaurando 'docker-compose.yml' desde la copia de seguridad..."
    mv "$BACKUP_FILE" "$N8N_COMPOSE_PATH"
    echo "   Restauración completa. El script se detendrá."
    exit 1
}

# --- Verificación de Dependencias ---
check_deps() {
    echo "🔎 Verificando que tu sistema tenga todo lo necesario..."
    for cmd in docker curl wget; do
        if ! command -v $cmd &>/dev/null; then echo "❌ Error: El comando '$cmd' es esencial." && exit 1; fi
    done
    
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        COMPOSE_CMD_HOST="docker compose"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD_HOST="docker-compose"
    else
        echo "❌ Error: No se encontró 'docker-compose' o el plugin 'docker compose'." && exit 1
    fi
    echo "✅ Usaremos '$COMPOSE_CMD_HOST' para gestionar los contenedores."

    if [ ! -f ./yq ]; then
        YQ_URL="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
        echo "📥 Descargando la herramienta 'yq'..."
        if ! wget -q "$YQ_URL" -O ./yq || ! chmod +x ./yq; then echo "❌ Falló la descarga de yq." && exit 1; fi
    fi
    YQ_CMD="./yq"
    echo "✅ Todas las dependencias del host están listas."
}

# --- INICIO DEL SCRIPT ---
clear
check_deps
print_header "Instalador del Servicio de Auto-Escalado para n8n"

# --- FASE 1: DETECCIÓN Y RECOPILACIÓN DE DATOS ---
print_header "1. Analizando tu Entorno"
N8N_COMPOSE_PATH="$(pwd)/docker-compose.yml"
if [ ! -f "$N8N_COMPOSE_PATH" ]; then echo "❌ Error: No se encontró 'docker-compose.yml' en este directorio." && exit 1; fi

RAW_PROJECT_NAME=$(basename "$(pwd)")
N8N_PROJECT_NAME=$(echo "$RAW_PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-]//g')
if [ -z "$N8N_PROJECT_NAME" ]; then N8N_PROJECT_NAME="n8n-project"; fi
echo "✅ Proyecto n8n detectado como: '$N8N_PROJECT_NAME'"

N8N_MAIN_SERVICE_NAME=$($YQ_CMD eval '(.services[] | select(.image == "n8nio/n8n*") | key)' "$N8N_COMPOSE_PATH" | head -n 1)
N8N_MAIN_SERVICE_NAME=$(ask "Nombre de tu servicio principal de n8n" "${N8N_MAIN_SERVICE_NAME:-n8n}")
N8N_WORKER_SERVICE_NAME="n8n-worker"
N8N_NETWORK_NAME=$($YQ_CMD eval ".services.$N8N_MAIN_SERVICE_NAME.networks[0]" "$N8N_COMPOSE_PATH")
if [ -z "$N8N_NETWORK_NAME" ] || [ "$N8N_NETWORK_NAME" == "null" ]; then echo "❌ Error: No se pudo detectar la red para '$N8N_MAIN_SERVICE_NAME'." && exit 1; fi
echo "✅ Red de Docker detectada: '$N8N_NETWORK_NAME'"

REDIS_SERVICE_NAME=$($YQ_CMD eval '(.services[] | select(.image == "redis*") | key)' "$N8N_COMPOSE_PATH" | head -n 1)
REDIS_HOST=$(ask "Hostname de tu servicio Redis" "${REDIS_SERVICE_NAME:-redis}")

# --- FASE 2: MODIFICACIÓN SEGURA DEL DOCKER-COMPOSE ---
print_header "2. Preparando tu Stack de n8n para Escalado"

# --- CORRECCIÓN CRÍTICA AQUÍ ---
# Capturamos la salida de texto y la comparamos con "true".
worker_exists=$($YQ_CMD eval ".services | has(\"$N8N_WORKER_SERVICE_NAME\")" "$N8N_COMPOSE_PATH")
if [ "$worker_exists" = "true" ]; then
    echo "✅ ¡Excelente! Tu 'docker-compose.yml' ya está configurado con un worker. Omitiendo la modificación."
else
    read -p "¿Estás de acuerdo en modificar 'docker-compose.yml' para añadir workers? (Se creará una copia de seguridad) (y/N): " confirm_modify < /dev/tty
    if [[ ! "$confirm_modify" =~ ^[yY](es)?$ ]]; then echo "Instalación cancelada." && exit 1; fi

    BACKUP_FILE="${N8N_COMPOSE_PATH}.backup.$(date +%F_%T)"
    echo "🛡️  Creando una copia de seguridad segura en '$BACKUP_FILE'..."
    cp "$N8N_COMPOSE_PATH" "$BACKUP_FILE"

    echo "🔧 Modificando el stack de n8n paso a paso, con verificación en cada uno..."
    
    # --- BLOQUE DE MODIFICACIÓN ATÓMICA Y VERIFICADA ---
    
    run_and_verify \
        "$YQ_CMD eval -i '.services.\"$N8N_MAIN_SERVICE_NAME\".environment += \"N8N_TRUST_PROXY=true\"' '$N8N_COMPOSE_PATH'" \
        "$YQ_CMD eval '.services.\"$N8N_MAIN_SERVICE_NAME\".environment[] | select(. == \"N8N_TRUST_PROXY=true\")' '$N8N_COMPOSE_PATH'" \
        "Añadida variable 'N8N_TRUST_PROXY'."

    run_and_verify \
        "$YQ_CMD eval -i '.services.\"$N8N_MAIN_SERVICE_NAME\".environment += \"N8N_RUNNERS_ENABLED=true\"' '$N8N_COMPOSE_PATH'" \
        "$YQ_CMD eval '.services.\"$N8N_MAIN_SERVICE_NAME\".environment[] | select(. == \"N8N_RUNNERS_ENABLED=true\")' '$N8N_COMPOSE_PATH'" \
        "Añadida variable 'N8N_RUNNERS_ENABLED'."

    run_and_verify \
        "$YQ_CMD eval -i '.services.\"$N8N_MAIN_SERVICE_NAME\".environment += \"EXECUTIONS_MODE=queue\"' '$N8N_COMPOSE_PATH'" \
        "$YQ_CMD eval '.services.\"$N8N_MAIN_SERVICE_NAME\".environment[] | select(. == \"EXECUTIONS_MODE=queue\")' '$N8N_COMPOSE_PATH'" \
        "Habilitado el modo 'queue'."

    run_and_verify \
        "$YQ_CMD eval -i '.services.\"$N8N_MAIN_SERVICE_NAME\".environment += \"EXECUTIONS_PROCESS=main\"' '$N8N_COMPOSE_PATH'" \
        "$YQ_CMD eval '.services.\"$N8N_MAIN_SERVICE_NAME\".environment[] | select(. == \"EXECUTIONS_PROCESS=main\")' '$N8N_COMPOSE_PATH'" \
        "Configurado el servicio principal como 'main'."
        
    run_and_verify \
        "$YQ_CMD eval -i '.services.\"$N8N_MAIN_SERVICE_NAME\".environment += \"QUEUE_BULL_REDIS_HOST=$REDIS_HOST\"' '$N8N_COMPOSE_PATH'" \
        "$YQ_CMD eval '.services.\"$N8N_MAIN_SERVICE_NAME\".environment[] | select(. == \"QUEUE_BULL_REDIS_HOST=$REDIS_HOST\")' '$N8N_COMPOSE_PATH'" \
        "Configurado el host de Redis para la cola."

    WORKER_BLOCK=$($YQ_CMD eval ".services.\"$N8N_MAIN_SERVICE_NAME\"" "$N8N_COMPOSE_PATH" | \
        $YQ_CMD eval '.restart = "unless-stopped" | del(.ports) | del(.labels) | .environment.EXECUTIONS_PROCESS = "worker"' -)
    
    run_and_verify \
        "$YQ_CMD eval -i --argjson worker_block \"$($YQ_CMD eval -o=j <<< "$WORKER_BLOCK")\" '.services.\"$N8N_WORKER_SERVICE_NAME\" = \$worker_block' '$N8N_COMPOSE_PATH'" \
        "$YQ_CMD eval '.services | has(\"$N8N_WORKER_SERVICE_NAME\")' '$N8N_COMPOSE_PATH'" \
        "Añadido el nuevo servicio '$N8N_WORKER_SERVICE_NAME'."
        
    # --- FIN DEL BLOQUE DE MODIFICACIÓN ---

    echo ""
    echo "✅ ¡Éxito! Tu archivo 'docker-compose.yml' ha sido modificado y verificado."
    echo "🔄 Aplicando la nueva configuración a tu stack de n8n..."
    $COMPOSE_CMD_HOST up -d --force-recreate --remove-orphans
    echo "✅ Tu stack de n8n ha sido actualizado y ahora está listo para escalar."
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
QUEUE_THRESHOLD = int(os.getenv('QUEUE_THRESHOLD', 20)); MAX_WORKERS = int(os.getenv('MAX_WORKERS', 5))
MIN_WORKERS = int(os.getenv('MIN_WORKERS', 0)); IDLE_TIME_BEFORE_SCALE_DOWN = int(os.getenv('IDLE_TIME_BEFORE_SCALE_DOWN', 60))
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
        full_command = f"docker-compose -p {N8N_PROJECT_NAME} {command}"
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
echo "🚀 Desplegando el servicio de auto-escalado..."
$COMPOSE_CMD_HOST up -d --build

if [ $? -eq 0 ]; then
    print_header "¡Instalación Completada!"
    cd ..
    echo "Tu stack ha sido configurado y el servicio de auto-escalado está en funcionamiento."
    echo ""
    echo "Pasos siguientes:"
    echo "  1. Verifica que el archivo 'docker-compose.yml' ahora contiene el servicio 'n8n-worker'."
    echo "  2. Verifica los logs del autoscaler: docker logs -f ${N8N_PROJECT_NAME}_autoscaler"
    echo "  3. Verifica los logs de n8n: docker logs ${N8N_MAIN_SERVICE_NAME}"
else
    echo -e "\n❌ Hubo un error durante el despliegue del autoscaler."
    cd ..
fi

rm -f ./yq