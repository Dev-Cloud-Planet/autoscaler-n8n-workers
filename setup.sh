#!/bin/bash

# ==============================================================================
#   Script de Instalación del Autoscaler Independiente para n8n
#
# Versión 15.0 - Verificación y Configuración Activa
#
# - [NUEVO] Verifica y configura el stack principal para modo 'queue'.
# - [NUEVO] Añade automáticamente variables al .env si faltan.
# - [NUEVO] Valida el docker-compose.yml principal antes de continuar.
# - El worker hereda la configuración directamente del .env principal.
# - El autoscaler ahora conoce la ruta absoluta a su propio docker-compose.
# ==============================================================================

# --- Funciones Auxiliares ---
print_header() { echo -e "\n\033[1;34m=================================================\033[0m\n\033[1;34m  $1\033[0m\n\033[1;34m=================================================\033[0m\n"; }
ask() { read -p "$1 (def: $2): " reply < /dev/tty; default_val="$2"; echo "${reply:-$default_val}"; }

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

# --- NUEVA FUNCIÓN: Verificar y configurar el Stack Principal ---
verify_and_configure_main_stack() {
    print_header "Verificando Stack Principal de n8n"
    local main_env_file="${MAIN_PROJECT_PATH}/.env"
    local main_compose_file="${MAIN_PROJECT_PATH}/docker-compose.yml"
    local modified_files=false

    if [ ! -f "$main_env_file" ] || [ ! -f "$main_compose_file" ]; then
        echo "❌ Error: No se encontraron los archivos '.env' y/o 'docker-compose.yml' en el directorio actual ('$MAIN_PROJECT_PATH')."
        echo "Asegúrate de ejecutar este script desde la carpeta de tu proyecto n8n principal."
        exit 1
    fi

    # 1. Verificar y corregir .env
    echo "-> Revisando '${main_env_file}'..."
    if ! grep -q "^EXECUTIONS_MODE=queue" "$main_env_file"; then
        echo "   - No se encontró 'EXECUTIONS_MODE=queue'. Añadiéndola..."
        echo -e "\n# --- Añadido por el script del Autoscaler ---\nEXECUTIONS_MODE=queue" >> "$main_env_file"
        modified_files=true
    fi
    if ! grep -q "^QUEUE_BULL_REDIS_HOST=" "$main_env_file"; then
        echo "   - No se encontró 'QUEUE_BULL_REDIS_HOST'. Añadiéndola..."
        echo "QUEUE_BULL_REDIS_HOST=redis" >> "$main_env_file"
        modified_files=true
    fi

    # 2. Validar docker-compose.yml (no modificar, solo avisar)
    echo "-> Validando '${main_compose_file}'..."
    if ! grep -q "redis:" "$main_compose_file"; then
        echo -e "\n❌ Error Crítico: Tu archivo '$main_compose_file' no parece tener un servicio 'redis'."
        echo "El modo 'queue' requiere Redis. Por favor, añade un servicio Redis a tu compose y vuelve a intentarlo."
        exit 1
    fi
    if ! grep -q "EXECUTIONS_PROCESS=main" "$main_compose_file"; then
        echo -e "\n❌ Error Crítico: A tu servicio principal de 'n8n' le falta la variable de entorno 'EXECUTIONS_PROCESS=main'."
        echo "Es VITAL para que el contenedor principal gestione la cola y no actúe como un worker."
        echo "Por favor, añade lo siguiente bajo 'environment:' en tu servicio 'n8n':"
        echo -e "\n      - EXECUTIONS_PROCESS=main\n"
        exit 1
    fi
    
    echo "✅ Tu stack principal parece estar correctamente configurado para el modo 'queue'."

    # 3. Si se modificó algo, forzar reinicio
    if [ "$modified_files" = true ]; then
        echo -e "\n\033[1;33m⚠️ ¡ACCIÓN REQUERIDA!\033[0m"
        echo "Hemos añadido configuraciones a tu archivo '.env' para habilitar el modo 'queue'."
        echo "Debes reiniciar tu stack de n8n para que los cambios surtan efecto."
        echo -e "Ejecuta el siguiente comando en otra terminal:\n"
        echo -e "  \033[1;32mcd ${MAIN_PROJECT_PATH} && ${COMPOSE_CMD_HOST} down && ${COMPOSE_CMD_HOST} up -d\033[0m\n"
        read -p "Una vez que tu stack principal se haya reiniciado, presiona [Enter] para continuar con la instalación del autoscaler..."
    fi
}


# --- INICIO DEL SCRIPT ---
clear; check_deps
print_header "Instalador del Autoscaler Independiente para n8n"

# --- FASE 1: VERIFICACIÓN Y RECOPILACIÓN DE DATOS ---
MAIN_PROJECT_PATH=$(pwd)
N8N_PROJECT_NAME=$(basename "$MAIN_PROJECT_PATH")

# Llamada a la nueva función de verificación
verify_and_configure_main_stack

print_header "1. Configuración del Entorno de Escalado"
NETWORK_KEY="n8n-network" # Nombre de la red en el compose principal
SHARED_NETWORK_NAME="${N8N_PROJECT_NAME}_${NETWORK_KEY}"
echo "ℹ️  Proyecto Principal: '$N8N_PROJECT_NAME' en '$MAIN_PROJECT_PATH'"
echo "ℹ️  Se conectará a la red compartida: '$SHARED_NETWORK_NAME'"

REDIS_HOST=$(ask "Hostname de tu servicio Redis (debe coincidir con el compose principal)" "redis")
AUTOSCALER_PROJECT_DIR="n8n-autoscaler"

print_header "2. Configuración de los Parámetros de Escalado"
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

# .env para el autoscaler
cat > .env << EOL
# --- Configuración Específica del Autoscaler ---
REDIS_HOST=${REDIS_HOST}
QUEUE_THRESHOLD=${QUEUE_THRESHOLD}
MAX_WORKERS=${MAX_WORKERS}
MIN_WORKERS=${MIN_WORKERS}
IDLE_TIME_BEFORE_SCALE_DOWN=${IDLE_TIME_BEFORE_SCALE_DOWN}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
AUTOSCALER_COMPOSE_FILE=/app/docker-compose.yml
# Pasamos el nombre del proyecto principal para que el autoscaler sepa cómo nombrarse
N8N_PROJECT_NAME=${N8N_PROJECT_NAME}
EOL

# docker-compose.yml para el autoscaler
cat > docker-compose.yml << EOL
version: '3.8'

services:
  autoscaler:
    build: .
    container_name: ${N8N_PROJECT_NAME}_autoscaler_brain
    restart: always
    env_file: .env
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./docker-compose.yml:/app/docker-compose.yml:ro
    networks:
      - n8n_shared_network

  n8n-worker:
    image: n8nio/n8n
    restart: unless-stopped
    env_file:
      - ${MAIN_PROJECT_PATH}/.env
    environment:
      - EXECUTIONS_MODE=queue
      - EXECUTIONS_PROCESS=worker
      - QUEUE_BULL_REDIS_HOST=${REDIS_HOST}
    networks:
      - n8n_shared_network

networks:
  n8n_shared_network:
    name: ${SHARED_NETWORK_NAME}
    external: true
EOL

# Dockerfile
cat > Dockerfile << 'EOL'
FROM python:3.9-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates gnupg && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh
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
# --- Configuración ---
REDIS_HOST = os.getenv('REDIS_HOST')
MAIN_N8N_PROJECT_NAME = os.getenv('N8N_PROJECT_NAME', 'n8n')
AUTOSCALER_PROJECT_NAME = f"{MAIN_N8N_PROJECT_NAME}-autoscaler"
WORKER_SERVICE_NAME = "n8n-worker" 
COMPOSE_FILE_PATH = os.getenv('AUTOSCALER_COMPOSE_FILE', '/app/docker-compose.yml')
QUEUE_KEY = "bull:default:wait"; QUEUE_THRESHOLD = int(os.getenv('QUEUE_THRESHOLD', 20)); MAX_WORKERS = int(os.getenv('MAX_WORKERS', 5))
MIN_WORKERS = int(os.getenv('MIN_WORKERS', 0)); IDLE_TIME_BEFORE_SCALE_DOWN = int(os.getenv('IDLE_TIME_BEFORE_SCALE_DOWN', 60))
POLL_INTERVAL = 10; TELEGRAM_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN'); TELEGRAM_CHAT_ID = os.getenv('TELEGRAM_CHAT_ID')
COMPOSE_CMD = "/usr/local/bin/docker-compose"
# --- Cliente Redis ---
try:
    redis_client = redis.Redis(host=REDIS_HOST, decode_responses=True, socket_connect_timeout=10); redis_client.ping(); print(f"✅ Conexión con Redis ('{REDIS_HOST}') establecida con éxito.")
except redis.exceptions.RedisError as e: print(f"❌ Error fatal al conectar con Redis: {e}"); exit(1)
# --- Funciones Auxiliares ---
def send_telegram_notification(message):
    if not TELEGRAM_TOKEN or not TELEGRAM_CHAT_ID: return
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"; payload = {'chat_id': TELEGRAM_CHAT_ID, 'text': message, 'parse_mode': 'Markdown'}
    try: requests.post(url, json=payload, timeout=10).raise_for_status()
    except requests.exceptions.RequestException: pass
def run_docker_command(command):
    try:
        full_command = f"{COMPOSE_CMD} -p {AUTOSCALER_PROJECT_NAME} -f {COMPOSE_FILE_PATH} {command}";
        result = subprocess.run(full_command, shell=True, check=True, capture_output=True, text=True)
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
# --- Bucle Principal ---
if __name__ == "__main__":
    send_telegram_notification(f"🤖 El servicio de auto-escalado para *{MAIN_N8N_PROJECT_NAME}* ha sido iniciado.")
    idle_since = None
    time.sleep(5) # Dar un pequeño margen al inicio
    scale_workers(MIN_WORKERS)
    while True:
        try:
            queue_size = redis_client.llen(QUEUE_KEY); running_workers = get_running_workers()
            if running_workers == -1: time.sleep(POLL_INTERVAL * 2); continue
            print(f"Estado: Cola={queue_size}, Workers={running_workers}, Umbral={QUEUE_THRESHOLD}, Mínimo={MIN_WORKERS}")
            if queue_size > QUEUE_THRESHOLD and running_workers < MAX_WORKERS:
                scale_workers(min(running_workers + 1, MAX_WORKERS)); idle_since = None
            elif queue_size <= 0 and running_workers > MIN_WORKERS:
                if idle_since is None: idle_since = time.time()
                if time.time() - idle_since >= IDLE_TIME_BEFORE_SCALE_DOWN:
                    scale_workers(max(running_workers - 1, MIN_WORKERS)); idle_since = None
            elif queue_size > 0: idle_since = None
            time.sleep(POLL_INTERVAL)
        except redis.exceptions.RedisError as e: print(f"⚠️ Error de Redis: {e}. Reintentando..."); time.sleep(POLL_INTERVAL * 2)
        except KeyboardInterrupt: send_telegram_notification(f"🤖 Servicio de auto-escalado detenido."); break
        except Exception as e: print(f"🔥 Error inesperado: {e}"); send_telegram_notification(f"🔥 *Error en Autoscaler*\n_{str(e)}_"); time.sleep(POLL_INTERVAL * 3)
EOL

# --- LIMPIEZA Y DESPLIEGUE FINAL ---
echo "🧹 Limpiando cualquier instancia anterior del autoscaler..."; docker rm -f "${N8N_PROJECT_NAME}_autoscaler_brain" > /dev/null 2>&1
echo "🚀 Desplegando el stack del autoscaler..."; $COMPOSE_CMD_HOST -p "${N8N_PROJECT_NAME}-autoscaler" up -d --build

if [ $? -eq 0 ]; then
    print_header "¡Instalación Completada!"; cd ..
    echo "El servicio de auto-escalado independiente está en funcionamiento."; echo ""
    echo "Pasos siguientes:"; echo "  1. Verifica que tu stack principal sigue corriendo con '${COMPOSE_CMD_HOST} ps'."; echo "  2. Verifica los logs del autoscaler con: docker logs -f ${N8N_PROJECT_NAME}_autoscaler_brain"
else
    echo -e "\n❌ Hubo un error durante el despliegue del autoscaler."; cd ..
fi