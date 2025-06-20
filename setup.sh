#!/bin/bash

# ==============================================================================
#   Script de Instalación del Servicio de Auto-Escalado para n8n (Ejecutar en Sitio)
#
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
    echo "🔎 Verificando dependencias y entorno..."
    local missing_deps=0
    for cmd in docker curl wget; do
        if ! command -v $cmd &> /dev/null; then
            echo "❌ Error: El comando '$cmd' no se encuentra. Por favor, instálalo."
            missing_deps=1
        fi
    done
    [[ $missing_deps -eq 1 ]] && exit 1

    if command -v docker &> /dev/null && docker compose version &> /dev/null; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &> /dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        echo "❌ Error: No se encontró 'docker-compose' o el plugin 'docker compose'."
        exit 1
    fi
    echo "✅ Usando '$COMPOSE_CMD' para las operaciones."

    if [ ! -f ./yq ]; then
        echo "📥 Descargando la versión correcta de 'yq' localmente..."
        YQ_URL="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
        if ! wget -q "$YQ_URL" -O ./yq || ! chmod +x ./yq; then
            echo "❌ Falló la descarga de yq." && exit 1
        fi
    fi
    YQ_CMD="./yq"
    echo "✅ Dependencias listas."
}

# --- INICIO DEL SCRIPT ---
clear
check_deps


# --- DESPLIEGUE DEL AUTOSCALER ---
print_header "5. Desplegando el Servicio de Auto-Escalado"
AUTOSCALER_PROJECT_DIR="n8n-autoscaler"
QUEUE_THRESHOLD=$(ask "Nº de tareas en cola para crear un worker" "20")
MAX_WORKERS=$(ask "Nº máximo de workers permitidos" "5")
MIN_WORKERS=$(ask "Nº mínimo de workers que deben mantenerse activos" "0")
IDLE_TIME_BEFORE_SCALE_DOWN=$(ask "Segundos de inactividad para destruir un worker" "60")
TELEGRAM_BOT_TOKEN=$(ask "Introduce tu Token de Bot de Telegram (opcional)" "")
TELEGRAM_CHAT_ID=$(ask "Introduce tu Chat ID de Telegram (opcional)" "")

echo "Creando directorio del autoscaler en './${AUTOSCALER_PROJECT_DIR}'..."
mkdir -p "$AUTOSCALER_PROJECT_DIR"
cd "$AUTOSCALER_PROJECT_DIR" || exit

echo "-> Generando archivo .env..."
cat > .env << EOL
REDIS_HOST=${REDIS_HOST}
REDIS_PORT=${REDIS_PORT}
REDIS_PASSWORD=${REDIS_PASSWORD}
N8N_DOCKER_PROJECT_NAME=${N8N_PROJECT_NAME}
N8N_WORKER_SERVICE_NAME=${N8N_WORKER_SERVICE_NAME}
QUEUE_THRESHOLD=${QUEUE_THRESHOLD}
MAX_WORKERS=${MAX_WORKERS}
MIN_WORKERS=${MIN_WORKERS}
IDLE_TIME_BEFORE_SCALE_DOWN=${IDLE_TIME_BEFORE_SCALE_DOWN}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
EOL

echo "-> Generando archivo docker-compose.yml..."
cat > docker-compose.yml << EOL
version: '3.8'
services:
  autoscaler:
    build: .
    container_name: ${N8N_PROJECT_NAME}_autoscaler
    restart: always
    env_file: .env
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /usr/local/bin/docker-compose:/usr/local/bin/docker-compose:ro
      - /usr/bin/docker-compose:/usr/bin/docker-compose:ro
EOL

echo "-> Generando archivo Dockerfile..."
cat > Dockerfile << EOL
FROM python:3.9-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY autoscaler.py .
CMD ["python", "-u", "autoscaler.py"]
EOL

echo "-> Generando archivo requirements.txt..."
cat > requirements.txt << 'EOL'
redis
requests
python-dotenv
EOL

echo "-> Generando archivo autoscaler.py..."
cat > autoscaler.py << 'EOL'
import os, time, subprocess, redis, requests
from dotenv import load_dotenv
load_dotenv()
REDIS_HOST = os.getenv('REDIS_HOST')
REDIS_PORT = int(os.getenv('REDIS_PORT', 6379))
REDIS_PASSWORD = os.getenv('REDIS_PASSWORD')
N8N_PROJECT_NAME = os.getenv('N8N_DOCKER_PROJECT_NAME')
N8N_WORKER_SERVICE_NAME = os.getenv('N8N_WORKER_SERVICE_NAME')
QUEUE_NAME = "default"
QUEUE_KEY = f"bull:{QUEUE_NAME}:wait"
QUEUE_THRESHOLD = int(os.getenv('QUEUE_THRESHOLD'))
MAX_WORKERS = int(os.getenv('MAX_WORKERS'))
MIN_WORKERS = int(os.getenv('MIN_WORKERS'))
IDLE_TIME_BEFORE_SCALE_DOWN = int(os.getenv('IDLE_TIME_BEFORE_SCALE_DOWN'))
POLL_INTERVAL = 10
TELEGRAM_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN')
TELEGRAM_CHAT_ID = os.getenv('TELEGRAM_CHAT_ID')
COMPOSE_CMD = "docker compose" if shutil.which("docker-compose") is None else "docker-compose"
try:
    redis_client = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, password=REDIS_PASSWORD if REDIS_PASSWORD else None, decode_responses=True, socket_connect_timeout=5)
    redis_client.ping()
    print("✅ Conexión con Redis establecida con éxito.")
except redis.exceptions.RedisError as e:
    print(f"❌ Error fatal al conectar con Redis: {e}")
    exit(1)
def send_telegram_notification(message):
    if not TELEGRAM_TOKEN or not TELEGRAM_CHAT_ID: return
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"
    payload = {'chat_id': TELEGRAM_CHAT_ID, 'text': message, 'parse_mode': 'Markdown'}
    try:
        requests.post(url, json=payload, timeout=10).raise_for_status()
        print(f"✔️ Notificación enviada: {message}")
    except requests.exceptions.RequestException as e:
        print(f"⚠️ Error al enviar notificación a Telegram: {e}")
def run_docker_command(command):
    try:
        full_command = f"{COMPOSE_CMD} -p {N8N_PROJECT_NAME} {command}"
        result = subprocess.run(full_command, shell=True, check=True, capture_output=True, text=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"❌ Error ejecutando: {full_command}\n   Error: {e.stderr.strip()}")
        send_telegram_notification(f"‼️ *Error Crítico de Docker*\nNo se pudo ejecutar: `{command}`\n\n_{e.stderr.strip()}_")
        return None
def get_running_workers():
    output = run_docker_command(f"ps -q {N8N_WORKER_SERVICE_NAME}")
    if output is None: return -1
    return len(output.splitlines()) if output else 0
def scale_workers(desired_count):
    current_workers = get_running_workers()
    if current_workers == -1 or current_workers == desired_count: return
    print(f"⚖️ Escalando workers de {current_workers} a {desired_count}...")
    command = f"up -d --scale {N8N_WORKER_SERVICE_NAME}={desired_count} --no-recreate --remove-orphans"
    if run_docker_command(command) is not None:
        send_telegram_notification(f"✅ Auto-escalado. *Workers activos: {desired_count}*")
    else:
        send_telegram_notification(f"❌ *Error al escalar workers a {desired_count}*")
if __name__ == "__main__":
    import shutil
    send_telegram_notification(f"🤖 El servicio de auto-escalado para *{N8N_PROJECT_NAME}* ha sido iniciado.")
    idle_since = None
    while True:
        try:
            queue_size = redis_client.llen(QUEUE_KEY)
            running_workers = get_running_workers()
            if running_workers == -1: time.sleep(POLL_INTERVAL * 2); continue
            print(f"Estado: Cola={queue_size}, Workers={running_workers}, Umbral={QUEUE_THRESHOLD}")
            if queue_size > QUEUE_THRESHOLD and running_workers < MAX_WORKERS:
                scale_workers(min(running_workers + 1, MAX_WORKERS))
                idle_since = None
            elif queue_size == 0 and running_workers > MIN_WORKERS:
                if idle_since is None: idle_since = time.time()
                if time.time() - idle_since >= IDLE_TIME_BEFORE_SCALE_DOWN:
                    scale_workers(max(running_workers - 1, MIN_WORKERS))
                    idle_since = None
            elif queue_size > 0:
                idle_since = None
            time.sleep(POLL_INTERVAL)
        except redis.exceptions.RedisError as e:
            print(f"⚠️ Error de Redis: {e}. Reintentando...")
            time.sleep(POLL_INTERVAL * 2)
        except KeyboardInterrupt:
            send_telegram_notification(f"🤖 Servicio de auto-escalado para *{N8N_PROJECT_NAME}* detenido."); break
        except Exception as e:
            print(f"🔥 Error inesperado: {e}")
            send_telegram_notification(f"🔥 *Error en Autoscaler {N8N_PROJECT_NAME}*\n_{str(e)}_")
            time.sleep(POLL_INTERVAL * 3)
EOL

echo "🧹 Limpiando cualquier instancia anterior del autoscaler..."
$COMPOSE_CMD down --remove-orphans > /dev/null 2>&1

echo "🚀 Desplegando el servicio de auto-escalado..."
$COMPOSE_CMD up -d --build

if [ $? -eq 0 ]; then
    print_header "¡Instalación Completada!"
    echo "El servicio de auto-escalado está en funcionamiento."
    echo ""
    echo "Comandos útiles:"
    echo "  - Ver logs del autoscaler: docker logs -f ${N8N_PROJECT_NAME}_autoscaler"
    echo "  - Detener el autoscaler:   cd ${AUTOSCALER_PROJECT_DIR} && $COMPOSE_CMD down"
    cd ..
else
    echo -e "\n❌ Hubo un error durante el despliegue del autoscaler."
    echo "   Revisa los mensajes de error de Docker Compose más arriba."
fi

# Limpieza del binario de yq descargado
rm -f ./yq