#!/bin/bash

# ==============================================================================
#   Script de Instalación del Autoscaler Independiente para n8n
#
# Versión 13.0
#==================================

# --- Funciones Auxiliares ---
print_header() { echo -e "\n\033[1;34m=================================================\033[0m\n\033[1;34m  $1\033[0m\n\033[1;34m=================================================\033[0m\n"; }
ask() { read -p "$1 (def: $2): " reply < /dev/tty; echo "${reply:-$default}"; }

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
}

# --- INICIO DEL SCRIPT ---
clear; check_deps
print_header "Instalador del Autoscaler Independiente para n8n"
echo "Asegúrate de haber configurado tu n8n principal para el modo 'queue'."

# --- FASE 1: RECOPILACIÓN DE DATOS ---
print_header "1. Configuración del Entorno Compartido"
echo "Por favor, introduce los valores EXACTOS de tu stack de n8n principal."

# Datos del proyecto y red
N8N_PROJECT_NAME=$(ask "Nombre de tu proyecto principal de n8n" "$(basename "$(pwd)")")
NETWORK_KEY=$(ask "Nombre de la red en tu docker-compose principal" "n8n-network")
SHARED_NETWORK_NAME="${N8N_PROJECT_NAME}_${NETWORK_KEY}"
echo "ℹ️  Se asumirá que la red compartida se llama: $SHARED_NETWORK_NAME"

# Datos de la Base de Datos
POSTGRES_HOST=$(ask "Hostname de tu servicio Postgres" "postgres")
POSTGRES_DB=$(ask "Nombre de la base de datos de n8n (POSTGRES_DB)" "n8n")
POSTGRES_USER=$(ask "Usuario de Postgres (POSTGRES_USER)" "n8n")
read -sp "Contraseña de Postgres (POSTGRES_PASSWORD): " POSTGRES_PASSWORD; echo

# Datos de n8n
N8N_ENCRYPTION_KEY=$(ask "Clave de encriptación de n8n (N8N_ENCRYPTION_KEY)" "mi_clave_de_encriptacion_muy_larga_y_unica")
TZ=$(ask "Tu zona horaria (TZ)" "America/Caracas")
REDIS_HOST=$(ask "Hostname de tu servicio Redis" "redis")

# Datos del autoscaler
AUTOSCALER_PROJECT_DIR="n8n-autoscaler"
print_header "2. Configuración del Escalado"
QUEUE_THRESHOLD=$(ask "Nº de tareas en cola para crear un worker" "20")
MAX_WORKERS=$(ask "Nº máximo de workers permitidos" "5")
MIN_WORKERS=$(ask "Nº mínimo de workers que deben mantenerse activos" "0")
IDLE_TIME_BEFORE_SCALE_DOWN=$(ask "Segundos de inactividad para destruir un worker" "60")
TELEGRAM_BOT_TOKEN=$(ask "Token de Bot de Telegram (opcional)" "")
TELEGRAM_CHAT_ID=$(ask "Chat ID de Telegram (opcional)" "")

# --- FASE 2: GENERACIÓN DE ARCHIVOS DEL AUTOSCALER ---
print_header "3. Generando Stack del Autoscaler"
mkdir -p "$AUTOSCALER_PROJECT_DIR" && cd "$AUTOSCALER_PROJECT_DIR" || exit
echo "-> Generando archivos en la carpeta '$AUTOSCALER_PROJECT_DIR'..."

cat > .env << EOL
# --- Configuración Compartida ---
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=${POSTGRES_HOST}
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=${POSTGRES_DB}
DB_POSTGRESDB_USER=${POSTGRES_USER}
DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
TZ=${TZ}
N8N_TRUST_PROXY=true
N8N_RUNNERS_ENABLED=true
QUEUE_BULL_REDIS_HOST=${REDIS_HOST}
# --- Configuración del Autoscaler ---
REDIS_HOST=${REDIS_HOST}
QUEUE_THRESHOLD=${QUEUE_THRESHOLD}
MAX_WORKERS=${MAX_WORKERS}
MIN_WORKERS=${MIN_WORKERS}
IDLE_TIME_BEFORE_SCALE_DOWN=${IDLE_TIME_BEFORE_SCALE_DOWN}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
EOL

# docker-compose.yml (define autoscaler Y worker)
cat > docker-compose.yml << EOL
services:
  autoscaler:
    build: .
    container_name: ${N8N_PROJECT_NAME}_autoscaler_brain
    restart: always
    env_file: .env
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - n8n-network

  n8n-worker:
    image: n8nio/n8n
    restart: unless-stopped
    env_file: .env
    environment:
      - EXECUTIONS_MODE=queue
      - EXECUTIONS_PROCESS=worker
    depends_on:
      autoscaler:
        condition: service_started
    networks:
      - n8n-network

networks:
  n8n-network:
    name: ${SHARED_NETWORK_NAME}
    external: true
EOL
cat > Dockerfile << 'EOL'
FROM python:3.9-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates gnupg && rm -rf /var/lib/apt/lists/*
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
REDIS_HOST = os.getenv('REDIS_HOST');
# El autoscaler ahora gestiona su PROPIO proyecto de compose
AUTOSCALER_PROJECT_NAME = "n8n-autoscaler" 
WORKER_SERVICE_NAME = "n8n-worker" 
QUEUE_KEY = f"bull:default:wait"; QUEUE_THRESHOLD = int(os.getenv('QUEUE_THRESHOLD', 20)); MAX_WORKERS = int(os.getenv('MAX_WORKers', 5))
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
        full_command = f"{COMPOSE_CMD} -p {AUTOSCALER_PROJECT_NAME} {command}"; result = subprocess.run(full_command, shell=True, check=True, capture_output=True, text=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"❌ Error ejecutando: {full_command}\n   Error: {e.stderr.strip()}"); send_telegram_notification(f"‼️ *Error Crítico de Docker*\n_{e.stderr.strip()}_"); return None
def get_running_workers():
    output = run_docker_command(f"ps -q {WORKER_SERVICE_NAME}"); return -1 if output is None else len(output.splitlines()) if output else 0
def scale_workers(desired_count):
    current_workers = get_running_workers()
    if current_workers == -1 or current_workers == desired_count: return
    print(f"⚖️  Escalando workers de {current_workers} a {desired_count}...")
    command = f"up -d --scale {WORKER_SERVICE_NAME}={desired_count} --no-recreate --remove-orphans"
    if run_docker_command(command) is not None: send_telegram_notification(f"✅ Auto-escalado. *Workers activos: {desired_count}*")
    else: send_telegram_notification(f"❌ *Error al escalar workers a {desired_count}*")
if __name__ == "__main__":
    send_telegram_notification(f"🤖 El servicio de auto-escalado independiente ha sido iniciado.")
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
        except KeyboardInterrupt: send_telegram_notification(f"🤖 Servicio de auto-escalado detenido."); break
        except Exception as e: print(f"🔥 Error inesperado: {e}"); send_telegram_notification(f"🔥 *Error en Autoscaler*\n_{str(e)}_"); time.sleep(POLL_INTERVAL * 3)
EOL

# --- LIMPIEZA Y DESPLIEGUE FINAL ---
echo "🧹 Limpiando cualquier instancia anterior del autoscaler..."; docker rm -f "${N8N_PROJECT_NAME}_autoscaler_brain" > /dev/null 2>&1
echo "🚀 Desplegando el stack del autoscaler..."; $COMPOSE_CMD_HOST up -d --build

if [ $? -eq 0 ]; then
    print_header "¡Instalación Completada!"; cd ..
    echo "El servicio de auto-escalado independiente está en funcionamiento."; echo ""
    echo "Pasos siguientes:"; echo "  1. Verifica los logs con: docker logs -f ${N8N_PROJECT_NAME}_autoscaler_brain"
else
    echo -e "\n❌ Hubo un error durante el despliegue del autoscaler."; cd ..
fi