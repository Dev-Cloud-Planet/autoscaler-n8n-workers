#!/bin/bash

# ==============================================================================
#   Script de Instalación del Servicio de Auto-Escalado para n8n
#
# Versión 12.1 (Modificado para rutas correctas)
# ==============================================================================

# --- Funciones Auxiliares ---
print_header() {
  echo -e "\n\033[1;34m=================================================\033[0m"
  echo -e "\033[1;34m  $1\033[0m"
  echo -e "\033[1;34m=================================================\033[0m\n"
}
ask() { read -p "$1 (def: $2): " reply < /dev/tty; echo "${reply:-$2}"; }
restore_and_exit() {
  echo "🛡️  Restaurando 'docker-compose.yml' desde la copia de seguridad..."
  if [ -f "$BACKUP_FILE" ]; then mv "$BACKUP_FILE" "$N8N_COMPOSE_PATH"; echo "   Restauración completa. El script se detendrá.";
  else echo "   No se encontró un archivo de backup para restaurar."; fi
  rm -f yq
  exit 1
}

# --- Verificación de Dependencias ---
check_deps() {
  echo "🔎 Verificando dependencias..."
  for cmd in docker curl wget sed; do
    if ! command -v $cmd &>/dev/null; then echo "❌ Error: El comando '$cmd' es esencial." && exit 1; fi
  done

  if docker compose version &>/dev/null; then
    COMPOSE_CMD_HOST="docker compose"
  elif docker-compose version &>/dev/null; then
    COMPOSE_CMD_HOST="docker-compose"
  else
    echo "❌ Error: No se encontró 'docker-compose' o el plugin 'docker compose'." && exit 1
  fi

  echo "✅ Usaremos '$COMPOSE_CMD_HOST' para las operaciones del host."

  if [ ! -f ./yq ]; then
    echo "📥 Descargando la herramienta 'yq'..."
    wget -q "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" -O ./yq && chmod +x ./yq || {
      echo "❌ Falló la descarga de yq." && exit 1
    }
  fi

  YQ_CMD="./yq"
  echo "✅ Dependencias del host listas."
}

# --- INICIO DEL SCRIPT ---
clear; check_deps
print_header "Instalador del Servicio de Auto-Escalado para n8n"

# --- FASE 1: DETECCIÓN Y RECOPILACIÓN DE DATOS ---
print_header "1. Analizando tu Entorno"
N8N_COMPOSE_PATH="$(pwd)/docker-compose.yml"
[ ! -f "$N8N_COMPOSE_PATH" ] && echo "❌ Error: No se encontró 'docker-compose.yml'" && exit 1

RAW_PROJECT_NAME=$(basename "$(pwd)")
N8N_PROJECT_NAME=$(echo "$RAW_PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_-]//g')
[ -z "$N8N_PROJECT_NAME" ] && N8N_PROJECT_NAME="n8n-project"
echo "✅ Proyecto n8n detectado como: '$N8N_PROJECT_NAME'"

N8N_MAIN_SERVICE_NAME=$($YQ_CMD eval 'keys | .[]' "$N8N_COMPOSE_PATH" | grep -m1 "n8n")
N8N_MAIN_SERVICE_NAME=$(ask "Nombre de tu servicio principal de n8n" "${N8N_MAIN_SERVICE_NAME:-n8n}")
N8N_WORKER_SERVICE_NAME="${N8N_MAIN_SERVICE_NAME}-worker"

NETWORK_KEY=$($YQ_CMD eval ".services.\"$N8N_MAIN_SERVICE_NAME\".networks[0]" "$N8N_COMPOSE_PATH")
[ -z "$NETWORK_KEY" ] || [ "$NETWORK_KEY" == "null" ] && echo "❌ Error: No se pudo detectar la red." && exit 1
echo "✅ Red de Docker detectada: '$NETWORK_KEY'"

REDIS_SERVICE_NAME=$($YQ_CMD eval '(.services[] | select(.image == "redis*") | key)' "$N8N_COMPOSE_PATH" | head -n 1)
REDIS_HOST=$(ask "Hostname de tu servicio Redis" "${REDIS_SERVICE_NAME:-redis}")

# --- FASE 2: MODIFICACIÓN SEGURA DEL DOCKER-COMPOSE ---
print_header "2. Preparando tu Stack de n8n para Escalado"

worker_exists=$($YQ_CMD eval ".services | has(\"$N8N_WORKER_SERVICE_NAME\")" "$N8N_COMPOSE_PATH")
if [ "$worker_exists" == "true" ]; then
  echo "✅ Tu 'docker-compose.yml' ya tiene un worker configurado."
else
  read -p "¿Estás de acuerdo en modificar 'docker-compose.yml'? (Se creará una copia de seguridad) (y/N): " confirm_modify < /dev/tty
  [[ ! "$confirm_modify" =~ ^[yY](es)?$ ]] && echo "Instalación cancelada." && exit 1

  BACKUP_FILE="${N8N_COMPOSE_PATH}.backup.$(date +%F_%T)"
  echo "🛡️  Creando copia de seguridad en '$BACKUP_FILE'..."
  cp "$N8N_COMPOSE_PATH" "$BACKUP_FILE"

  echo "🔧 Modificando 'docker-compose.yml' con yq..."

  $YQ_CMD eval "
    .services.\"$N8N_MAIN_SERVICE_NAME\".environment += [
      \"N8N_TRUST_PROXY=true\",
      \"N8N_RUNNERS_ENABLED=true\",
      \"EXECUTIONS_MODE=queue\",
      \"EXECUTIONS_PROCESS=main\",
      \"QUEUE_BULL_REDIS_HOST=$REDIS_HOST\"
    ] |
    .services.\"$N8N_WORKER_SERVICE_NAME\" = .services.\"$N8N_MAIN_SERVICE_NAME\" |
    .services.\"$N8N_WORKER_SERVICE_NAME\".environment |=
      map(select(. != \"EXECUTIONS_PROCESS=main\")) |
    .services.\"$N8N_WORKER_SERVICE_NAME\".environment += [
      \"EXECUTIONS_MODE=queue\",
      \"EXECUTIONS_PROCESS=worker\",
      \"QUEUE_BULL_REDIS_HOST=$REDIS_HOST\"
    ] |
    del(.services.\"$N8N_WORKER_SERVICE_NAME\".ports) |
    del(.services.\"$N8N_WORKER_SERVICE_NAME\".container_name) |
    del(.services.\"$N8N_WORKER_SERVICE_NAME\".labels)
  " "$N8N_COMPOSE_PATH" -i

  echo "🔄 Reiniciando stack con nuevo worker..."
  $COMPOSE_CMD_HOST up -d --force-recreate --remove-orphans || restore_and_exit
  echo "✅ Tu stack ha sido actualizado con éxito."
fi

# --- FASE 3: DESPLIEGUE DEL AUTOSCALER ---
print_header "4. Creando y Desplegando Servicio de Auto-Escalado (Separado)"
AUTOSCALER_DIR="n8n-autoscaler"
mkdir -p "$AUTOSCALER_DIR"
cat > "$AUTOSCALER_DIR/.env" << EOL
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

cat > "$AUTOSCALER_DIR/docker-compose.yml" << EOL
services:
  autoscaler:
    build: .
    container_name: ${N8N_PROJECT_NAME}_autoscaler
    restart: always
    env_file: .env
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - \$(pwd)/$AUTOSCALER_DIR:/app
      - \$(pwd):/project-n8n
    working_dir: /app
    networks:
      - n8n-network
networks:
  n8n-network:
    external: true
    name: ${N8N_PROJECT_NAME}_${NETWORK_KEY}
EOL

cat > "$AUTOSCALER_DIR/Dockerfile" << 'EOL'
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

cat > "$AUTOSCALER_DIR/requirements.txt" << 'EOL'
redis
requests
python-dotenv
EOL

cat > "$AUTOSCALER_DIR/autoscaler.py" << 'EOL'
import os, time, subprocess, redis, requests
from dotenv import load_dotenv
load_dotenv()
REDIS_HOST = os.getenv('REDIS_HOST')
N8N_PROJECT_NAME = os.getenv('N8N_DOCKER_PROJECT_NAME')
N8N_WORKER_SERVICE_NAME = os.getenv('N8N_WORKER_SERVICE_NAME')
QUEUE_KEY = f"bull:default:wait"
QUEUE_THRESHOLD = int(os.getenv('QUEUE_THRESHOLD', 20))
MAX_WORKERS = int(os.getenv('MAX_WORKERS', 5))
MIN_WORKERS = int(os.getenv('MIN_WORKERS', 0))
IDLE_TIME_BEFORE_SCALE_DOWN = int(os.getenv('IDLE_TIME_BEFORE_SCALE_DOWN', 60))
POLL_INTERVAL = 10
TELEGRAM_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN')
TELEGRAM_CHAT_ID = os.getenv('TELEGRAM_CHAT_ID')
COMPOSE_CMD = "/usr/local/bin/docker-compose"
COMPOSE_FILE = "/project-n8n/docker-compose.yml"

try:
    redis_client = redis.Redis(host=REDIS_HOST, decode_responses=True, socket_connect_timeout=5)
    redis_client.ping()
    print("✅ Conexión con Redis establecida con éxito.")
except redis.exceptions.RedisError as e:
    print(f"❌ Error fatal al conectar con Redis: {e}")
    exit(1)

def send_telegram_notification(message):
    if not TELEGRAM_TOKEN or not TELEGRAM_CHAT_ID:
        return
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"
    payload = {'chat_id': TELEGRAM_CHAT_ID, 'text': message, 'parse_mode': 'Markdown'}
    try:
        requests.post(url, json=payload, timeout=10).raise_for_status()
    except requests.exceptions.RequestException:
        pass

def run_docker_command(command):
    try:
        full_command = f"{COMPOSE_CMD} -f {COMPOSE_FILE} -p {N8N_PROJECT_NAME} {command}"
        result = subprocess.run(full_command, shell=True, check=True, capture_output=True, text=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"❌ Error ejecutando: {full_command}\n   Error: {e.stderr.strip()}")
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
    print(f"⚖️  Escalando workers de {current_workers} a {desired_count}...")
    command = f"up -d --scale {N8N_WORKER_SERVICE_NAME}={desired_count} --no-recreate --remove-orphans"
    if run_docker_command(command) is not None:
        send_telegram_notification(f"✅ Auto-escalado. *Workers activos: {desired_count}*")
    else:
        send_telegram_notification(f"❌ *Error al escalar workers a {desired_count}*")

if __name__ == "__main__":
    send_telegram_notification(f"🤖 El servicio de auto-escalado para *{N8N_PROJECT_NAME}* ha sido iniciado.")
    idle_since = None
    while True:
        try:
            queue_size = redis_client.llen(QUEUE_KEY)
            running_workers = get_running_workers()
            if running_workers == -1:
                time.sleep(POLL_INTERVAL * 2)
                continue
            print(f"Estado: Cola={queue_size}, Workers={running_workers}, Umbral={QUEUE_THRESHOLD}")
            if queue_size > QUEUE_THRESHOLD and running_workers < MAX_WORKERS:
                scale_workers(min(running_workers + 1, MAX_WORKERS))
                idle_since = None
            elif queue_size <= MIN_WORKERS and running_workers > MIN_WORKERS:
                if idle_since is None:
                    idle_since = time.time()
                if time.time() - idle_since >= IDLE_TIME_BEFORE_SCALE_DOWN:
                    scale_workers(max(running_workers - 1, MIN_WORKERS))
                    idle_since = None
            elif queue_size > MIN_WORKERS:
                idle_since = None
            time.sleep(POLL_INTERVAL)
        except redis.exceptions.RedisError as e:
            print(f"⚠️ Error de Redis: {e}. Reintentando...")
            time.sleep(POLL_INTERVAL * 2)
        except KeyboardInterrupt:
            send_telegram_notification(f"🤖 Servicio para *{N8N_PROJECT_NAME}* detenido.")
            break
        except Exception as e:
            print(f"🔥 Error inesperado: {e}")
            send_telegram_notification(f"🔥 *Error en Autoscaler {N8N_PROJECT_NAME}*\n_{str(e)}_")
            time.sleep(POLL_INTERVAL * 3)
EOL

echo "🧹 Limpiando cualquier instancia anterior del autoscaler..."
docker rm -f "${N8N_PROJECT_NAME}_autoscaler" > /dev/null 2>&1

echo "🚀 Desplegando el servicio autoscaler en carpeta separada..."
docker compose -f "$AUTOSCALER_DIR/docker-compose.yml" up -d --build

if [ $? -eq 0 ]; then
  print_header "¡Autoscaler Desplegado Correctamente!"
  echo "Puedes ver los logs con: docker logs -f ${N8N_PROJECT_NAME}_autoscaler"
else
  echo "❌ Hubo un error al desplegar el autoscaler."
fi
rm -f ./yq
echo -e "\nGracias por usar este instalador. ¡Disfruta de tu servicio de auto-escalado para n8n! 🎉"