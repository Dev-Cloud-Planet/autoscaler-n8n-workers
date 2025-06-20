#!/bin/bash

# ==============================================================================
#   Script de Instalación del Servicio de Auto-Escalado para n8n (Ejecutar en Sitio)
#
# ASUME QUE SE EJECUTA DESDE EL DIRECTORIO RAÍZ DEL PROYECTO N8N
# (donde se encuentra el 'docker-compose.yml' principal).
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
    # Lee explícitamente del terminal del usuario (/dev/tty) para compatibilidad con 'curl | bash'
    read -p "$prompt (def: $default): " reply < /dev/tty
    echo "${reply:-$default}"
}

# --- Verificación de Dependencias y Entorno ---
check_deps() {
    echo "🔎 Verificando dependencias y entorno..."
    local missing_deps=0
    for cmd in docker docker-compose; do
        if ! command -v $cmd &> /dev/null; then
            echo "❌ Error: El comando '$cmd' no se encuentra. Por favor, instálalo."
            missing_deps=1
        fi
    done
    [[ $missing_deps -eq 1 ]] && exit 1

    if ! command -v yq &> /dev/null; then
        echo "⚠️ 'yq' no encontrado. Es necesario para modificar archivos YAML de forma segura."
        read -p "¿Deseas instalar 'yq' (v4) ahora? (y/N): " confirm_yq < /dev/tty
        if [[ "$confirm_yq" =~ ^[yY](es)?$ ]]; then
            echo "📥 Instalando yq..."
            sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq && sudo chmod +x /usr/bin/yq
            if ! command -v yq &> /dev/null; then echo "❌ Falló la instalación de yq." && exit 1; fi
            echo "✅ 'yq' instalado correctamente."
        else
            echo "Instalación cancelada. 'yq' es requerido." && exit 1
        fi
    fi
    echo "✅ Dependencias verificadas."
}


# --- INICIO DEL SCRIPT ---
clear
check_deps

print_header "Instalador del Servicio de Auto-Escalado para n8n"

# --- DETECCIÓN DE CONTEXTO ---
print_header "1. Detectando Entorno del Proyecto"
N8N_COMPOSE_PATH="$(pwd)/docker-compose.yml"
if [ ! -f "$N8N_COMPOSE_PATH" ]; then
    echo "❌ Error: No se encontró 'docker-compose.yml' en el directorio actual."
    echo "   Por favor, ejecuta este script desde la carpeta raíz de tu proyecto n8n."
    exit 1
fi
N8N_PROJECT_NAME=$(basename "$(pwd)")
echo "✅ Proyecto n8n detectado: '$N8N_PROJECT_NAME'"
echo "✅ Archivo a modificar: '$N8N_COMPOSE_PATH'"


# --- RECOPILACIÓN DE DATOS (REDUCIDA) ---
print_header "2. Configuración de Conexión a Redis"
REDIS_HOST=$(ask "Introduce el Host/IP de tu servidor Redis" "redis")
REDIS_PORT=$(ask "Introduce el Puerto de tu servidor Redis" "6379")
REDIS_PASSWORD=$(ask "Introduce la Contraseña de Redis (opcional)" "")

print_header "3. Nombres de los Servicios de n8n"
N8N_MAIN_SERVICE_NAME=$(ask "Introduce el nombre de tu servicio principal de n8n en el YAML" "n8n")
N8N_WORKER_SERVICE_NAME="n8n-worker" # Usamos un nombre estándar para consistencia


# --- MODIFICACIÓN DEL DOCKER-COMPOSE DE N8N ---
print_header "4. Preparando el Stack de n8n para Escalado"
echo "Analizando '$N8N_COMPOSE_PATH'..."

if yq e ".services | has(\"$N8N_WORKER_SERVICE_NAME\")" "$N8N_COMPOSE_PATH" &>/dev/null; then
    echo "✅ El servicio de worker '$N8N_WORKER_SERVICE_NAME' ya existe. Omitiendo modificación."
else
    echo "⚠️ El servicio de worker '$N8N_WORKER_SERVICE_NAME' no existe. Se procederá a modificar el archivo."
    read -p "¿Estás de acuerdo en modificar tu 'docker-compose.yml'? (Se creará una copia de seguridad) (y/N): " confirm_modify < /dev/tty
    if [[ ! "$confirm_modify" =~ ^[yY](es)?$ ]]; then
        echo "Instalación cancelada."
        exit 1
    fi

    BACKUP_FILE="${N8N_COMPOSE_PATH}.backup.$(date +%F_%T)"
    echo "🛡️ Creando copia de seguridad en '$BACKUP_FILE'..."
    cp "$N8N_COMPOSE_PATH" "$BACKUP_FILE"

    echo "🔧 Modificando el servicio principal '$N8N_MAIN_SERVICE_NAME'..."
    yq e -i ".services.$N8N_MAIN_SERVICE_NAME.environment += {\"EXECUTIONS_MODE\": \"queue\"}" "$N8N_COMPOSE_PATH"
    yq e -i ".services.$N8N_MAIN_SERVICE_NAME.environment += {\"EXECUTIONS_PROCESS\": \"main\"}" "$N8N_COMPOSE_PATH"
    yq e -i ".services.$N8N_MAIN_SERVICE_NAME.environment += {\"QUEUE_BULL_REDIS_HOST\": \"$REDIS_HOST\"}" "$N8N_COMPOSE_PATH"
    yq e -i ".services.$N8N_MAIN_SERVICE_NAME.environment += {\"QUEUE_BULL_REDIS_PORT\": \"$REDIS_PORT\"}" "$N8N_COMPOSE_PATH"
    [ -n "$REDIS_PASSWORD" ] && yq e -i ".services.$N8N_MAIN_SERVICE_NAME.environment += {\"QUEUE_BULL_REDIS_PASSWORD\": \"$REDIS_PASSWORD\"}" "$N8N_COMPOSE_PATH"

    echo "➕ Creando el nuevo servicio de worker '$N8N_WORKER_SERVICE_NAME'..."
    yq e ".services.$N8N_WORKER_SERVICE_NAME = .services.$N8N_MAIN_SERVICE_NAME" -i "$N8N_COMPOSE_PATH"
    yq e -i ".services.$N8N_WORKER_SERVICE_NAME.environment.EXECUTIONS_PROCESS = \"worker\"" "$N8N_COMPOSE_PATH"
    yq e -i "del(.services.$N8N_WORKER_SERVICE_NAME.ports)" "$N8N_COMPOSE_PATH"
    yq e -i ".services.$N8N_WORKER_SERVICE_NAME.restart = \"unless-stopped\"" "$N8N_COMPOSE_PATH"

    echo "✅ Archivo 'docker-compose.yml' modificado con éxito."
    echo "🔄 Aplicando la nueva configuración al stack de n8n..."
    docker-compose up -d --remove-orphans
    echo "✅ Stack de n8n actualizado."
fi

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

# --- Generación de Archivos para el Autoscaler ---
# El resto del script es idéntico, ya que ahora estamos en el directorio correcto
# para crear los archivos del autoscaler.
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
        full_command = f"docker-compose -p {N8N_PROJECT_NAME} {command}"
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

echo "🚀 Desplegando el servicio de auto-escalado..."
docker-compose up -d --build

if [ $? -eq 0 ]; then
    print_header "¡Instalación Completada!"
    echo "Tu stack de n8n ha sido configurado para escalado y el servicio de"
    echo "auto-escalado está en funcionamiento."
    echo ""
    echo "Comandos útiles:"
    echo "  - Ver logs del autoscaler: docker logs -f ${N8N_PROJECT_NAME}_autoscaler"
    echo "  - Detener el autoscaler:   cd ${AUTOSCALER_PROJECT_DIR} && docker-compose down"
    # Volver al directorio original
    cd ..
else
    echo -e "\n❌ Hubo un error durante el despliegue del autoscaler."
    echo "   Revisa los mensajes de error de Docker Compose más arriba."
fi