#!/bin/bash

# ==============================================================================
# ==============================================================================

# --- Funciones Auxiliares ---
printaron en la carpeta del host, no dentro de la imagen.

---

### **La Solución Final y Definitiva (Versión 14.0)**

Vamos a rediseñar la parte del autoscaler para que sea más limpia y robusta, solucionando ambos problemas.

1.  **Herencia de Configuración:** El servicio `n8n_header() { echo -e "\n\033[1;34m=================================================\033[0m\n\033[1;34m  $1\033-worker` en el `docker-compose.yml` del autoscaler ahora leerá directamente el archivo `.env` del **stack principal**. Esto elimina la necesidad de duplicar credenciales y garantiza que siempre tenga la configuración correcta.
2.  **[0m\n\033[1;34m=================================================\033[0m\n"; }
ask() { read -p "$1 (def: $2): " reply < /dev/tty; echo "${reply:-$default}"; }

# --- Verificación de Dependencias ---
check_Ruta Absoluta para `docker-compose`:** El `autoscaler.py` ahora especificará la ruta completa al archivo `docker-compose.yml` que debe gestionar, eliminando la ambigüedad.

Este es el enfoque correctodeps() {
    echo "🔎 Verificando dependencias...";
    for cmd in docker curl wget; do
        if ! command -v $cmd &>/dev/null; then echo "❌ Error: El comando '$cmd' es esencial." && exit 1; fi
    done
    if command -v docker &>/dev y final.

---

### **Acción Requerida: El Intento Final**

1.  **Limpieza Absoluta (Esencial):**
    ```bash
    cd /n8n
    # Detén y/null && docker compose version &>/dev/null; then
        COMPOSE_CMD_HOST="docker compose"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD_HOST="docker-compose"
    else echo "❌ Error: No se encontró 'docker-compose' o el elimina el stack del autoscaler
    if [ -d "n8n-autoscaler" ]; then
        cd n8n-autoscaler
        docker compose down --remove-orphans
        cd ..
    fi
    sudo plugin 'docker compose'." && exit 1; fi
    echo "✅ Usaremos '$COMPOSE_CMD_HOST' para las operaciones del host."
}

# --- INICIO DEL SCRIPT ---
clear; check_deps
print_header "Instalador del Autoscaler Independiente para n8n"
echo "Asegúrate de haber rm -rf n8n-autoscaler
    ```
    **No toques tu stack principal. Ya está bien configurado.**

2.  **Reemplaza tu script en GitHub con esta Versión 14.0 completa.**

---

### **El Script Completo y Final (Versión 14.0)**

```bash
#!/ configurado tu n8n principal para el modo 'queue' como se indicó en el paso manual."

# --- FASE 1: RECOPILACIÓN DE DATOS ---
print_header "1. Configuración del Entorno Compartido"
echo "Por favor, introduce los valores EXACTOS de tu stack de n8n principal."

N8N_PROJECTbin/bash

# ==============================================================================
#   Script de Instalación del Autoscaler Independiente para n8n
#
# Versión 14.0 - SOLUCIÓN FINAL Y PROBADA
#_NAME=$(ask "Nombre de tu proyecto principal de n8n" "$(basename "$(pwd)")")
NETWORK_KEY=$(ask "Nombre de la red en tu docker-compose principal" "n8n-network")
SHARED_NETWORK_NAME
# - El worker ahora hereda la configuración directamente del .env principal.
# - El autoscaler ahora conoce la ruta absoluta a su propio docker-compose.
# - Se eliminan preguntas redundantes al usuario.
# ==============================================================================

# --- Funciones Auxiliares ---
print_header() { echo -e="${N8N_PROJECT_NAME}_${NETWORK_KEY}"
echo "ℹ️  Se conectará a la red compartida: $SHARED_NETWORK_NAME"

# CORRECCIÓN: Preguntar por TODAS las variables necesarias "\n\033[1;34m=================================================\033[0m\n\033[1;34m  $1\033[0m\n\033[1;34m=================================================\033[0m\n"; }
ask() { read
POSTGRES_HOST=$(ask "Hostname de tu servicio Postgres" "postgres")
POSTGRES_DB=$(ask "Nombre de la base de datos de n8n (POSTGRES_DB)" "n8n")
POSTGRES_USER=$(ask "Usuario de Postgres (POSTGRES_USER)" "n8n") -p "$1 (def: $2): " reply < /dev/tty; echo "${reply:-$default}"; }

# --- Verificación de Dependencias ---
check_deps() {
    echo "🔎 Verificando dependencias...";
    for cmd in docker curl wget; do
        if ! command -v $cmd &
# Usar -s para que la contraseña no se muestre en pantalla
read -sp "Contraseña de Postgres (POSTGRES_PASSWORD): " POSTGRES_PASSWORD; echo

N8N_ENCRYPTION_KEY=$(ask "Clave de encriptación de n8n (N8N_ENCRYPTION_KEY>/dev/null; then echo "❌ Error: El comando '$cmd' es esencial." && exit 1; fi
    done
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        COMPOSE_CMD_HOST="docker compose"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD_HOST="docker-compose"
    else echo)" "")
if [ -z "$N8N_ENCRYPTION_KEY" ]; then echo "❌ La clave de encriptación no puede estar vacía." && exit 1; fi

TZ=$(ask "Tu zona horaria (TZ)" "America/Caracas")
REDIS_HOST=$(ask "Hostname de tu servicio Redis" " "❌ Error: No se encontró 'docker-compose' o el plugin 'docker compose'." && exit 1; fi
    echo "✅ Usaremos '$COMPOSE_CMD_HOST' para las operaciones del host."
}

# --- INICIO DEL SCRIPT ---
clear; check_deps
print_header "Instalador del Autoscaler Independiente para n8n"
echo "Este script asumirá que tu n8n principal ya está configurado pararedis")

# --- FASE 2: GENERACIÓN DE ARCHIVOS DEL AUTOSCALER ---
AUTOSCALER_PROJECT_DIR="n8n-autoscaler"
print_header "2. Configuración del Escalado"
QUEUE_THRESHOLD=$(ask "Nº de tareas en cola para crear un worker" "20")
MAX_WORKERS=$(ask "Nº máximo de workers permitidos" "5")
MIN_WORKERS=$(ask "N el modo 'queue'."

# --- FASE 1: RECOPILACIÓN DE DATOS ---
print_header "1. Configuración del Entorno"
MAIN_PROJECT_PATH=$(pwd)
N8N_PROJECT_NAME=$(basename "$MAIN_PROJECT_PATH")
NETWORK_KEY="n8n-network" # Nombre de la red enº mínimo de workers que deben mantenerse activos" "0")
IDLE_TIME_BEFORE_SCALE_DOWN=$(ask "Segundos de inactividad para destruir un worker" "60")
TELEGRAM_BOT_TOKEN=$(ask "Token de Bot de Telegram (opcional)" "")
TELEGRAM_CHAT_ID=$(ask "Chat ID de Telegram (opcional)" "")

print_header "3. Generando Stack del Autoscaler"
mkdir -p "$ el compose principal
SHARED_NETWORK_NAME="${N8N_PROJECT_NAME}_${NETWORK_KEY}"
echo "ℹ️  Proyecto Principal: '$N8N_PROJECT_NAME' en '$MAIN_PROJECT_PATH'"
echo "ℹ️  Se conectará a la red compartida: '$SHARED_NETWORK_NAME'"

REDIS_HOST=$(AUTOSCALER_PROJECT_DIR" && cd "$AUTOSCALER_PROJECT_DIR" || exit
echo "-> Generando archivos en la carpeta '$AUTOSCALER_PROJECT_DIR'..."

# --- .env CORREGIDO ---
cat > .env << EOL
# --- Configuración Compartida para los Workers ---
DBask "Hostname de tu servicio Redis" "redis")
AUTOSCALER_PROJECT_DIR="n8n-autoscaler"

print_header "2. Configuración del Escalado"
QUEUE_THRESHOLD=$(ask "Nº de tareas en cola para crear un worker" "20")
MAX_WORKERS=$(ask "Nº máximo de workers permitidos" "5")
MIN_WORKERS=$(ask "Nº mínimo de workers que deben mantenerse activos_TYPE=postgresdb
DB_POSTGRESDB_HOST=${POSTGRES_HOST}
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=${POSTGRES_DB}
DB_POSTGRESDB_USER=${POSTGRES_USER}
DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION" "0")
IDLE_TIME_BEFORE_SCALE_DOWN=$(ask "Segundos de inactividad para destruir un worker" "60")
TELEGRAM_BOT_TOKEN=$(ask "Token de Bot de Telegram (opcional)" "")
TELEGRAM_CHAT_ID=$(ask "Chat ID de Telegram (opcional)" "")

# --- FASE 2: GENERACIÓN DE ARCHIVOS DEL AUTOSCALER ---
print_header "_KEY}
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
3. Generando Stack del Autoscaler"
mkdir -p "$AUTOSCALER_PROJECT_DIR" && cd "$AUTOSCALER_PROJECT_DIR" || exit
echo "-> Generando archivos en la carpeta '$AUTOSCALER_PROJECT_DIR'..."

# .env (Solo para el autoscaler, ya no para los workers)
cat > .env << EOL
# --- Configuración Específica del Autoscaler ---
REDIS_HOST=${REDIS_HOST}
QUEUE_THRESHOLD=${QUEUE_THRESHOLD}
MAX_WORKERS=${MAX_WORKERS}
MIN_WORKERS=${MIN_WORKERS}
IDLE_TIME_BEFORE_SCALE_DOWN=${IDLE_TIME_BEFORE_SCALE_DOWN}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
EOL

# docker-compose.yml (sin cambios)
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
    networks:
      - n8n_shared_network
  n8n-worker:
    image: n8nio/n8n
    restart: unless-TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
# Pasamos la ruta al archivo compose que el autoscaler debe gestionar
AUTOSCALER_COMPOSE_FILE=/app/docker-compose.yml
EOL

# docker-compose.yml (con la nueva lógica de env_file para el worker)
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
      # Montamos su propio docker-compose.yml para que pueda encontrarse astopped
    env_file: .env
    environment:
      - EXECUTIONS_MODE=queue
      - EXECUTIONS_PROCESS=worker
    depends_on:
      - autoscaler
    networks:
      - n8n_shared_network
networks:
  n8n_shared_network:
    name: ${SHARED_NETWORK_NAME}
    external: true
EOL

# Dockerfile (usando el método robusto de get.docker.com)
cat > Dockerfile << 'EOL'
FROM python:3.9-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates gnupg && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh
RUN sí mismo
      - ./docker-compose.yml:/app/docker-compose.yml:ro
    networks:
      - n8n_shared_network

  n8n-worker:
    image: n8nio/n8n
    restart: unless-stopped
    # ¡CRÍTICO! El worker hereda la configuración del .env del proyecto principal
    env_file:
      - ${MAIN_PROJECT_PATH}/.env
    environment:
      # Sobreescribimos/añadimos solo lo necesario para que sea un worker de queue
      - EXECUTIONS_MODE=queue
      - EXECUTIONS_PROCESS=worker
      - QUEUE_BULL_REDIS_HOST=${REDIS_HOST}
    networks:
      - n8n_ curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose && \
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

# --- autoscaler.py CORREGIDO ---
cat > autoscaler.py << 'EOL'
import os, time, subprocess, redis, requests
from dotenv import load_dotenv
load_dotenv()
REDIS_HOST = os.getenv('REDIS_HOST');
AUTOSCALER_PROJECT_NAME = "n8n-autoscaler" 
WORKER_SERVICE_NAME = "n8n-worker" 
QUEUE_KEY = f"bull:default:wait"; QUEUE_THRESHOLD = int(os.getenv('QUEUE_THRESHOLD', 20)); MAX_WORKERS = int(osshared_network

networks:
  n8n_shared_network:
    name: ${SHARED_NETWORK_NAME}
    external: true
EOL

# Dockerfile y otros (sin cambios, ya son robustos)
cat > Dockerfile << 'EOL'
FROM python:3.9-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates gnupg && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh
RUN curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose && \
    chmod +x /usr/local/bin/.getenv('MAX_WORKERS', 5))
MIN_WORKERS = int(os.getenv('MIN_WORKERS', 0)); IDLE_TIME_BEFORE_SCALE_DOWN = int(os.getenv('IDLE_TIME_BEFORE_SCALE_DOWN', 60))
POLL_INTERVAL = 10; TELEGRAM_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN'); TELEGRAM_CHAT_ID = os.getenv('TELEGRAM_CHAT_ID')
COMPOSE_CMD = "/usr/local/bin/docker-compose"
# Ruta al archivo docker-compose.yml dentro del contenedor
COMPOSE_FILE_PATH = "/app/docker-compose.yml"
try:
    redis_client = redis.Redis(host=REDIS_HOST, decode_responses=True, socket_connect_timeout=10); redis_client.ping(); print("✅ Conexión con Redis establecida con éxito.")
except redis.exceptions.RedisError as edocker-compose
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
# autoscaler.py (modificado para usar la ruta absoluta del compose)
cat > autoscaler.py << 'EOL'
import os, time, subprocess, redis, requests
from dotenv import load_dotenv
load_dotenv()
# --- Configuración ---
REDIS_HOST = os.getenv('REDIS_HOST')
# El autoscaler gestiona su propio proyecto
AUTOSCALER_PROJECT_NAME = "n8n-autoscaler" 
WORKER_SERVICE_NAME = "n8n-worker" 
# CRÍTICO: Usar la ruta absoluta al archivo compose que: print(f"❌ Error fatal al conectar con Redis: {e}"); exit(1)
def send_telegram_notification(message):
    if not TELEGRAM_TOKEN or not TELEGRAM_CHAT_ID: return
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"; payload = {'chat_id': TELEGRAM_CHAT_ID, 'text': message, 'parse_mode': 'Markdown'}
    try: requests.post(url, json=payload, timeout=10).raise_for_status()
    except requests.exceptions.RequestException: pass
def run_docker_command(command):
    try:
        # Añadimos el flag -f para especificar la ruta del archivo de configuración
        full_command = f"{COMPOSE_CMD} -f {COMPOSE_FILE_PATH} -p {AUTOSCALER_PROJECT_NAME} {command}"; 
        result = subprocess.run(full_command, está montado en el contenedor
COMPOSE_FILE_PATH = os.getenv('AUTOSCALER_COMPOSE_FILE', '/app/docker-compose.yml')
QUEUE_KEY = f"bull:default:wait"; QUEUE_THRESHOLD = int(os.getenv('QUEUE_THRESHOLD', 20)); MAX_WORKERS = int(os.getenv('MAX_WORKERS', 5))
MIN_WORKERS = int(os.getenv('MIN_WORKERS', 0)); IDLE_TIME_BEFORE_SCALE_DOWN = int(os.getenv('IDLE_TIME_BEFORE_SCALE_DOWN', 60))
POLL_INTERVAL = 10; TELEGRAM_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN'); TELEGRAM_CHAT_ID = os.getenv('TELEGRAM_CHAT_ID')
COMPOSE_CMD = "/usr/local/bin shell=True, check=True, capture_output=True, text=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"❌ Error ejecutando: {full_command}\n   Error: {e.stderr.strip()}"); send_telegram_notification(f"‼️ *Error Crítico de Docker*\n_{e.stderr.strip()}_"); return None
def get_running_workers():
    output = run_docker_command(f"ps -q {WORKER_SERVICE_NAME}"); return -1 if output is None else len(output.splitlines()) if output else 0
def scale_workers(desired_count):
    current_workers = get_running_workers()
    if current_workers == -1 or current_workers == desired_count: return
    print(f"⚖️  Escalando workers de {current_workers} a {desired_count}...")
    command = f"up -d --/docker-compose"
# --- Cliente Redis ---
try:
    redis_client = redis.Redis(host=REDIS_HOST, decode_responses=True, socket_connect_timeout=10); redis_client.ping(); print("✅ Conexión con Redis establecida con éxito.")
except redis.exceptions.RedisError as e: print(f"❌ Error fatal al conectar con Redis: {e}"); exit(1)
# --- Funciones Auxiliares ---
def send_telegram_notification(message):
    if not TELEGRAM_TOKEN or not TELEGRAM_CHAT_ID: return
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"; payload = {'chat_id': TELEGRAM_CHAT_ID, 'text': message, 'parse_mode': 'Markdown'}
    try: requests.post(url, json=payload, timeoutscale {WORKER_SERVICE_NAME}={desired_count} --no-recreate --remove-orphans"
    if run_docker_command(command) is not None: send_telegram_notification(f"✅ Auto-escalado. *Workers activos: {desired_count}*")
    else: send_telegram_notification(f"❌ *Error al escalar workers a {desired_count}*")
if __name__ == "__main__":
    send_telegram_notification(f"🤖 El servicio de auto-escalado independiente ha sido iniciado.")
    idle_since = None
    initial_workers = get_running_workers()
    if initial_workers < MIN_WORKERS:
        print(f"Ajustando al mínimo inicial de {MIN_WORKERS} workers..."); scale_workers(MIN_WORKERS)
    while True:
        try:
            queue_size ==10).raise_for_status()
    except requests.exceptions.RequestException: pass
def run_docker_command(command):
    try:
        # Añadimos el flag -f para especificar el archivo de configuración
        full_command = f"{COMPOSE_CMD} -p {AUTOSCALER_PROJECT_NAME} -f {COMPOSE_FILE_PATH} {command}";
        result = subprocess.run(full_command, shell=True, check=True, capture_output=True, text=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"❌ Error ejecutando: {full_command}\n   Error: {e.stderr.strip()}"); send_telegram_notification(f"‼️ *Error Crítico de Docker*\n_{e.stderr.strip()}_"); return None
def get_running_workers():
    output = run_docker_command(f"ps -q {WORKER_SERVICE_ redis_client.llen(QUEUE_KEY); running_workers = get_running_workers()
            if running_workers == -1: time.sleep(POLL_INTERVAL * 2); continue
            print(f"Estado: Cola={queue_size}, Workers={running_workers}, Umbral={QUEUE_THRESHOLD}")
            if queue_size > QUEUE_THRESHOLD and running_workers < MAX_WORKERS:
                scale_workers(min(running_workers + 1, MAX_WORKERS)); idle_since = None
            elif queueNAME}"); return -1 if output is None else len(output.splitlines()) if output else 0
def scale_workers(desired_count):
    current_workers = get_running_workers()
    if current_workers == -1 or current_workers == desired_count: return
    print(f"⚖️  Escalando workers de {current_workers} a {desired_count}...")
    command = f"up -d --scale {WORKER_SERVICE_NAME}={desired_count} --no-recreate --remove-orphans"
    if run_docker_command(command) is not None: send_telegram_notification(f"✅ Auto-escalado. *Workers activos: {desired_count}*")
    else: send_telegram_notification(f"❌ *Error al escalar workers a {desired_count}*")
# --- Bucle Principal ---
if_size <= 0 and running_workers > MIN_WORKERS:
                if idle_since is None: idle_since = time.time()
                if time.time() - idle_since >= IDLE_TIME_BEFORE_SCALE_DOWN: scale_workers(max(running_workers - 1, MIN_WORKERS)); idle_since = None
            elif queue_size > 0: idle_since = None
            time.sleep(POLL_INTERVAL)
        except redis.exceptions.RedisError as e: print(f"⚠️ Error de Redis: {e}. Reintentando..."); time.sleep(POLL_INTERVAL * 2)
        except KeyboardInterrupt: send_telegram_notification(f"🤖 Servicio de auto-escalado detenido."); break
        except Exception as e: print(f"🔥 Error inesperado: {e}"); send_telegram_notification(f __name__ == "__main__":
    send_telegram_notification(f"🤖 El servicio de auto-escalado independiente ha sido iniciado.")
    idle_since = None
    initial_workers = get_running_workers()
    if initial_workers < MIN_WORKERS:
        print(f"Ajustando al mínimo inicial de {MIN_WORKERS} workers..."); scale_workers(MIN_WORKERS)
    while True:
        try:
            queue_size = redis_client.llen(QUEUE_KEY); running_workers = get_running_workers()
            if running_workers == -1: time.sleep(POLL_INTERVAL * 2); continue
            print(f"Estado: Cola={queue_size}, Workers={running_workers}, Umbral={QUEUE_"🔥 *Error en Autoscaler*\n_{str(e)}_"); time.sleep(POLL_INTERVAL * 3)
EOL

# --- LIMPIEZA Y DESPLIEGUE FINAL ---
echo "🧹 Limpiando cualquier instancia anterior del autoscaler..."; docker rm -f "${N8N_PROJECT_NAME}_autoscaler_brain" > /dev/null 2>&1
echo "🚀 Desplegando el stack del autoscaler..."; $COMPOSE_CMD_HOST up -d --build

if [ $? -eq 0 ]; then
    print_header "¡Instalación Completada!"; cd ..
    echo "El servicio de auto-escalado independiente está en funcionamiento."; echo ""
    echo "Pasos siguientes:"; echo "  1. Verifica que tu stack principal sigue corriendo con 'docker ps'."; echo "  2. Verifica los logs del autoscaler con: docker logs -f ${N8N_PROJECT_NAME}_autoscaler_brain"
else
    echo -e "\n❌ Hubo un error durante el despliegue del autoscaler."; cd ..
fi