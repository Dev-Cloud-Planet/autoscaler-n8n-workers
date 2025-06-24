#!/bin/bash

# ==============================================================================
#   Script de Instalación y Configuración del Auto-Escalado para n8n
#
#   Versión: 2.0

# ==============================================================================

# --- Funciones Auxiliares ---
print_header() {
    echo -e "\n\033[1;34m=================================================\033[0m"
    echo -e "\033[1;34m  $1\033[0m"
    echo -e "\033[1;34m=================================================\033[0m\n"
}

ask() {
    # Usage: variable=$(ask "Prompt text" "default_value")
    local prompt="$1"
    local default="$2"
    read -p "$prompt (def: $default): " reply < /dev/tty
    echo "${reply:-$default}"
}

restore_and_exit() {
    echo -e "\n\033[1;31m❌ Ocurrió un error crítico.\033[0m"
    echo "🛡️  Restaurando 'docker-compose.yml' desde la copia de seguridad..."
    if [ -f "$BACKUP_FILE" ]; then
        mv "$BACKUP_FILE" "$N8N_COMPOSE_PATH"
        echo "✅ Restauración completa. El script se detendrá."
    else
        echo "⚠️ No se encontró un archivo de backup para restaurar."
    fi
    # Limpiar y salir
    rm -f yq
    exit 1
}

# --- Verificación de Dependencias ---
check_deps() {
    echo "🔎 Verificando dependencias..."
    for cmd in docker curl wget sed grep cut; do
        if ! command -v $cmd &> /dev/null; then
            echo "❌ Error: El comando '$cmd' es esencial y no fue encontrado." && exit 1
        fi
    done

    # Determinar el comando de compose a usar
    if docker compose version &>/dev/null; then
        COMPOSE_CMD_HOST="docker compose"
    elif docker-compose version &>/dev/null; then
        COMPOSE_CMD_HOST="docker-compose"
    else
        echo "❌ Error: No se encontró 'docker-compose' o el plugin 'docker compose'." && exit 1
    fi
    echo "✅ Se usará '$COMPOSE_CMD_HOST' para las operaciones del host."

    # Descargar yq si no existe
    if [ ! -f ./yq ]; then
        echo "📥 Descargando la herramienta 'yq' (para manejar YAML de forma segura)..."
        YQ_VERSION="v4.30.8" # Fijar una versión para consistencia
        YQ_BINARY="yq_linux_amd64"
        wget -q "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}" -O ./yq && chmod +x ./yq || {
            echo "❌ Falló la descarga de yq." && exit 1
        }
    fi
    YQ_CMD="./yq"
    echo "✅ Dependencias listas."
}

# --- INICIO DEL SCRIPT ---
clear
print_header "Instalador del Servicio de Auto-Escalado para n8n v2.0"
check_deps

# --- FASE 1: ANÁLISIS DEL ENTORNO ---
print_header "1. Analizando tu Entorno n8n"

N8N_COMPOSE_PATH="$(pwd)/docker-compose.yml"
if [ ! -f "$N8N_COMPOSE_PATH" ]; then
    echo "❌ Error: No se encontró 'docker-compose.yml' en el directorio actual."
    echo "   Por favor, ejecuta este script desde la misma carpeta donde está tu archivo."
    rm -f yq
    exit 1
fi

N8N_ENV_PATH="$(pwd)/.env"
if [ -f "$N8N_ENV_PATH" ]; then
    echo "✅ Archivo de entorno '.env' detectado. Se usarán sus valores por defecto."
    # Extraer valores del .env para usarlos como defaults
    DEFAULT_REDIS_HOST=$(grep -E "^REDIS_HOST=" "$N8N_ENV_PATH" | cut -d '=' -f2 | tr -d '"' | tr -d "'")
    DEFAULT_PROJECT_NAME=$(grep -E "^COMPOSE_PROJECT_NAME=" "$N8N_ENV_PATH" | cut -d '=' -f2 | tr -d '"' | tr -d "'")
else
    echo "⚠️  No se encontró el archivo '.env'. Se te pedirán los valores necesarios."
fi

# Detección del nombre del proyecto Docker
RAW_PROJECT_NAME=${DEFAULT_PROJECT_NAME:-$(basename "$(pwd)")}
N8N_PROJECT_NAME=$(echo "$RAW_PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_-]//g')
N8N_PROJECT_NAME=$(ask "Nombre del proyecto Docker" "${N8N_PROJECT_NAME:-n8n-project}")

# Detección del servicio principal de n8n
DETECTED_N8N_SERVICE=$($YQ_CMD eval '.services | with_entries(select(.value.image | test("n8n")))[].key' "$N8N_COMPOSE_PATH" | head -n 1)
N8N_MAIN_SERVICE_NAME=$(ask "Nombre de tu servicio principal de n8n" "${DETECTED_N8N_SERVICE:-n8n}")

# Detección de la red
DETECTED_NETWORK=$($YQ_CMD eval ".services.\"$N8N_MAIN_SERVICE_NAME\".networks[0]" "$N8N_COMPOSE_PATH")
if [ -z "$DETECTED_NETWORK" ] || [ "$DETECTED_NETWORK" == "null" ]; then
    echo "❌ Error: No se pudo detectar la red del servicio '$N8N_MAIN_SERVICE_NAME'." && restore_and_exit
fi
echo "✅ Red de Docker detectada: '$DETECTED_NETWORK'"

# Detección de Redis
DETECTED_REDIS_SERVICE=$($YQ_CMD eval '(.services[] | select(.image | test("redis")) | key)' "$N8N_COMPOSE_PATH" | head -n 1)
REDIS_HOST=$(ask "Hostname de tu servicio Redis" "${DEFAULT_REDIS_HOST:-${DETECTED_REDIS_SERVICE:-redis}}")


# --- FASE 2: CONFIGURACIÓN DEL MODO 'QUEUE' ---
print_header "2. Verificando y Configurando el Modo de Escalado"
N8N_WORKER_SERVICE_NAME="${N8N_MAIN_SERVICE_NAME}-worker"

# Comprobar si el modo 'queue' ya está activado
IS_QUEUE_MODE=$($YQ_CMD eval ".services.\"$N8N_MAIN_SERVICE_NAME\".environment[] | select(. == \"EXECUTIONS_MODE=queue\")" "$N8N_COMPOSE_PATH")

if [ -z "$IS_QUEUE_MODE" ]; then
    echo "🔧 El modo 'queue' no está configurado. Se procederá a modificar 'docker-compose.yml'."
    read -p "¿Estás de acuerdo en modificar 'docker-compose.yml' para habilitar los workers? (Se creará una copia de seguridad) (y/N): " confirm_modify < /dev/tty
    if [[ ! "$confirm_modify" =~ ^[yY](es)?$ ]]; then
        echo "Instalación cancelada."
        rm -f yq
        exit 1
    fi

    # 1. Crear backup
    BACKUP_FILE="${N8N_COMPOSE_PATH}.backup.$(date +%F_%T)"
    echo "🛡️  Creando copia de seguridad en '$BACKUP_FILE'..."
    cp "$N8N_COMPOSE_PATH" "$BACKUP_FILE"

    # 2. Modificar el docker-compose.yml
    echo "⚙️  Aplicando configuración de modo 'queue' y añadiendo servicio de worker..."
    $YQ_CMD eval "
        # Añadir variables de entorno al servicio principal para modo queue
        .services.\"$N8N_MAIN_SERVICE_NAME\".environment += [
            \"EXECUTIONS_MODE=queue\",
            \"EXECUTIONS_PROCESS=main\",
            \"QUEUE_BULL_REDIS_HOST=$REDIS_HOST\"
        ] |
        # Crear el servicio de worker duplicando el principal
        .services.\"$N8N_WORKER_SERVICE_NAME\" = .services.\"$N8N_MAIN_SERVICE_NAME\" |
        # Modificar el worker: cambiar 'main' por 'worker'
        .services.\"$N8N_WORKER_SERVICE_NAME\".environment |= map(
            if . == \"EXECUTIONS_PROCESS=main\" then \"EXECUTIONS_PROCESS=worker\" else . end
        ) |
        # Eliminar configuraciones que no aplican al worker
        del(.services.\"$N8N_WORKER_SERVICE_NAME\".ports) |
        del(.services.\"$N8N_WORKER_SERVICE_NAME\".container_name) |
        del(.services.\"$N8N_WORKER_SERVICE_NAME\".labels)
    " -i "$N8N_COMPOSE_PATH"

    # 3. Reiniciar los servicios para que tomen los cambios
    print_header "3. Reiniciando Stack de n8n para Aplicar Cambios"
    echo "🔄 Deteniendo y levantando los servicios con la nueva configuración..."
    $COMPOSE_CMD_HOST -p "$N8N_PROJECT_NAME" up -d --force-recreate --remove-orphans || restore_and_exit
    echo "✅ Tu stack de n8n ha sido actualizado y reiniciado con éxito."

else
    echo "✅ El modo 'queue' ya está configurado. No se realizarán cambios en 'docker-compose.yml'."
    # No es necesario reiniciar si no hubo cambios.
fi


# --- FASE 4: DESPLIEGUE DEL AUTOSCALER ---
print_header "4. Desplegando el Servicio de Auto-Escalado"
AUTOSCALER_DIR="n8n-autoscaler"
mkdir -p "$AUTOSCALER_DIR"

# 4. Copiar el archivo .env principal a la nueva carpeta
echo "📋 Copiando '$N8N_ENV_PATH' a '$AUTOSCALER_DIR/.env' para usarlo como base."
if [ -f "$N8N_ENV_PATH" ]; then
    cp "$N8N_ENV_PATH" "$AUTOSCALER_DIR/.env"
else
    touch "$AUTOSCALER_DIR/.env" # Crear un .env vacío si no existía el original
fi

# Entrar en el directorio del autoscaler
cd "$AUTOSCALER_DIR" || exit

# 5. Pedir datos para los workers y añadirlos al .env
echo -e "\nAhora, configuremos el comportamiento del auto-escalado:"
QUEUE_THRESHOLD=$(ask "Nº de tareas en cola para crear un nuevo worker" "15")
MAX_WORKERS=$(ask "Nº máximo de workers permitidos" "5")
MIN_WORKERS=$(ask "Nº mínimo de workers activos (0 para apagarlos todos si no hay carga)" "0")
IDLE_TIME_BEFORE_SCALE_DOWN=$(ask "Segundos de inactividad para destruir un worker" "90")
POLL_INTERVAL=$(ask "Segundos entre cada verificación de la cola" "10")
TELEGRAM_BOT_TOKEN=$(ask "Token de Bot de Telegram para notificaciones (opcional)" "")
TELEGRAM_CHAT_ID=$(ask "Chat ID de Telegram para notificaciones (opcional)" "")

# 6. Crear/Añadir las variables específicas del autoscaler al .env
# Esto sobreescribirá valores si ya existen, y los añadirá si no.
cat >> .env << EOL

# --- AUTOSCALER CONFIG - GENERATED BY SCRIPT ---
N8N_DOCKER_PROJECT_NAME=${N8N_PROJECT_NAME}
N8N_WORKER_SERVICE_NAME=${N8N_WORKER_SERVICE_NAME}
QUEUE_THRESHOLD=${QUEUE_THRESHOLD}
MAX_WORKERS=${MAX_WORKERS}
MIN_WORKERS=${MIN_WORKERS}
IDLE_TIME_BEFORE_SCALE_DOWN=${IDLE_TIME_BEFORE_SCALE_DOWN}
POLL_INTERVAL=${POLL_INTERVAL}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
EOL

# 7. Crear el docker-compose.yml del autoscaler
echo "📄 Generando 'docker-compose.yml' para el autoscaler..."
cat > docker-compose.yml << EOL
version: '3.8'

services:
  autoscaler:
    image: n8n-autoscaler-service:latest
    build: .
    container_name: ${N8N_PROJECT_NAME}_autoscaler
    restart: always
    env_file: .env
    volumes:
      # Montar el socket de Docker para que el autoscaler pueda gestionar los contenedores
      - /var/run/docker.sock:/var/run/docker.sock
      # Montar el docker-compose.yml principal para que el autoscaler pueda ejecutar comandos sobre él
      - ${N8N_COMPOSE_PATH}:/app/docker-compose.yml
    working_dir: /app
    networks:
      # Conectar el autoscaler a la misma red de n8n para que pueda ver a Redis
      - n8n_network

networks:
  n8n_network:
    name: ${N8N_PROJECT_NAME}_${DETECTED_NETWORK}
    external: true
EOL

# Crear Dockerfile para la imagen del autoscaler
cat > Dockerfile << 'EOL'
# Usar una imagen slim de Python
FROM python:3.9-slim

# Instalar dependencias del sistema: curl y docker-cli
# Es mejor instalar docker-cli desde los repositorios de Docker para asegurar compatibilidad
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates gnupg apt-transport-https && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && apt-get install -y docker-ce-cli && \
    rm -rf /var/lib/apt/lists/*

# Instalar Docker Compose V2
RUN curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose && \
    chmod +x /usr/local/bin/docker-compose

WORKDIR /app

# Instalar dependencias de Python
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copiar el script del autoscaler
COPY autoscaler.py .

# Comando por defecto al iniciar el contenedor
CMD ["python", "-u", "autoscaler.py"]
EOL

# Crear requirements.txt para las librerías de Python
cat > requirements.txt << 'EOL'
redis
requests
python-dotenv
EOL

# Crear el script de Python autoscaler.py
cat > autoscaler.py << 'EOL'
import os
import time
import subprocess
import redis
import requests
from dotenv import load_dotenv

def log(message):
    """Función de logging con timestamp."""
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}", flush=True)

def send_telegram_notification(message):
    """Envía una notificación a Telegram si está configurado."""
    if not TELEGRAM_TOKEN or not TELEGRAM_CHAT_ID:
        return
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"
    payload = {'chat_id': TELEGRAM_CHAT_ID, 'text': message, 'parse_mode': 'Markdown'}
    try:
        requests.post(url, json=payload, timeout=10).raise_for_status()
    except requests.exceptions.RequestException as e:
        log(f"⚠️  Error al enviar notificación a Telegram: {e}")

def run_docker_command(command):
    """Ejecuta un comando de Docker Compose y gestiona errores."""
    try:
        # Usamos docker-compose con el archivo y proyecto especificados
        full_command = f"docker-compose -p {N8N_PROJECT_NAME} -f /app/docker-compose.yml {command}"
        log(f"🚀 Ejecutando: {full_command}")
        result = subprocess.run(full_command, shell=True, check=True, capture_output=True, text=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        error_message = f"❌ Error ejecutando Docker: {e.stderr.strip()}"
        log(error_message)
        send_telegram_notification(f"‼️ *Error Crítico de Docker*\n_{e.stderr.strip()}_")
        return None

def get_running_workers():
    """Obtiene el número de workers actualmente en ejecución."""
    output = run_docker_command(f"ps -q {N8N_WORKER_SERVICE_NAME}")
    if output is None:
        return -1  # Indica un error
    # Cuenta las líneas de la salida para saber cuántos contenedores hay
    return len(output.splitlines()) if output else 0

def scale_workers(desired_count):
    """Escala el número de workers al valor deseado."""
    current_workers = get_running_workers()
    if current_workers == -1 or current_workers == desired_count:
        return

    log(f"⚖️  Escalando workers de {current_workers} a {desired_count}...")
    command = f"up -d --scale {N8N_WORKER_SERVICE_NAME}={desired_count} --no-recreate --remove-orphans"
    if run_docker_command(command) is not None:
        log(f"✅ Escalado completado. Workers activos: {desired_count}")
        send_telegram_notification(f"✅ Auto-escalado de *{N8N_PROJECT_NAME}*. Workers activos: *{desired_count}*")
    else:
        log(f"❌ Error al intentar escalar a {desired_count} workers.")
        send_telegram_notification(f"❌ *Error al escalar workers a {desired_count}*")

def main_loop():
    """Bucle principal del autoscaler."""
    idle_since = None
    while True:
        try:
            queue_size = redis_client.llen(QUEUE_KEY)
            running_workers = get_running_workers()

            if running_workers == -1:  # Si hubo un error en Docker, esperar y reintentar
                time.sleep(POLL_INTERVAL * 2)
                continue

            log(f"Estado: Cola={queue_size}, Workers={running_workers}, Umbral={QUEUE_THRESHOLD}")

            # Lógica de escalado hacia arriba (Scale Up)
            if queue_size > QUEUE_THRESHOLD and running_workers < MAX_WORKERS:
                new_worker_count = min(running_workers + 1, MAX_WORKERS)
                scale_workers(new_worker_count)
                idle_since = None  # Resetear el temporizador de inactividad
            # Lógica de escalado hacia abajo (Scale Down)
            elif queue_size == 0 and running_workers > MIN_WORKERS:
                if idle_since is None:
                    idle_since = time.time()
                    log(f"La cola está vacía. Iniciando temporizador de {IDLE_TIME_BEFORE_SCALE_DOWN}s para scale-down.")
                
                if time.time() - idle_since >= IDLE_TIME_BEFORE_SCALE_DOWN:
                    new_worker_count = max(running_workers - 1, MIN_WORKERS)
                    scale_workers(new_worker_count)
                    idle_since = None  # Resetear el temporizador
            # Si hay tareas en la cola pero por debajo del umbral, no hacer nada y resetear timer
            elif queue_size > 0:
                if idle_since is not None:
                    log("La cola ya no está vacía. Cancelando scale-down.")
                    idle_since = None

            time.sleep(POLL_INTERVAL)

        except redis.exceptions.RedisError as e:
            log(f"⚠️ Error de conexión con Redis: {e}. Reintentando...")
            time.sleep(POLL_INTERVAL * 2)
        except KeyboardInterrupt:
            log("🛑 Script detenido por el usuario.")
            send_telegram_notification(f"🤖 Servicio de auto-escalado para *{N8N_PROJECT_NAME}* detenido manualmente.")
            break
        except Exception as e:
            log(f"🔥 Error inesperado en el bucle principal: {e}")
            send_telegram_notification(f"🔥 *Error Inesperado en Autoscaler {N8N_PROJECT_NAME}*\n_{str(e)}_")
            time.sleep(POLL_INTERVAL * 3)

if __name__ == "__main__":
    # Cargar variables de entorno desde el archivo .env
    load_dotenv()
    
    # Asignar variables de entorno a variables globales
    REDIS_HOST = os.getenv('REDIS_HOST', 'redis')
    N8N_PROJECT_NAME = os.getenv('N8N_DOCKER_PROJECT_NAME')
    N8N_WORKER_SERVICE_NAME = os.getenv('N8N_WORKER_SERVICE_NAME')
    QUEUE_KEY = "bull:n8n-executions:wait"  # Cola por defecto de n8n
    QUEUE_THRESHOLD = int(os.getenv('QUEUE_THRESHOLD', 15))
    MAX_WORKERS = int(os.getenv('MAX_WORKERS', 5))
    MIN_WORKERS = int(os.getenv('MIN_WORKERS', 0))
    IDLE_TIME_BEFORE_SCALE_DOWN = int(os.getenv('IDLE_TIME_BEFORE_SCALE_DOWN', 90))
    POLL_INTERVAL = int(os.getenv('POLL_INTERVAL', 10))
    TELEGRAM_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN')
    TELEGRAM_CHAT_ID = os.getenv('TELEGRAM_CHAT_ID')

    if not all([N8N_PROJECT_NAME, N8N_WORKER_SERVICE_NAME]):
        log("❌ Error: Faltan variables de entorno críticas (N8N_DOCKER_PROJECT_NAME, N8N_WORKER_SERVICE_NAME).")
        exit(1)

    try:
        redis_client = redis.Redis(host=REDIS_HOST, port=6379, db=0, decode_responses=True, socket_connect_timeout=5)
        redis_client.ping()
        log("✅ Conexión con Redis establecida con éxito.")
    except redis.exceptions.RedisError as e:
        log(f"❌ Error fatal al conectar con Redis en {REDIS_HOST}: {e}")
        exit(1)

    log(f"🚀 Iniciando servicio de auto-escalado para el proyecto '{N8N_PROJECT_NAME}'")
    send_telegram_notification(f"🤖 El servicio de auto-escalado para *{N8N_PROJECT_NAME}* ha sido (re)iniciado.")
    main_loop()

EOL

# Desplegar el servicio de autoscaler
echo "🧹 Limpiando cualquier instancia anterior del autoscaler..."
docker rm -f "${N8N_PROJECT_NAME}_autoscaler" > /dev/null 2>&1
echo "🏗️  Construyendo y desplegando el servicio de auto-escalado..."
$COMPOSE_CMD_HOST up -d --build

if [ $? -eq 0 ]; then
    print_header "🎉 ¡Instalación Completada con Éxito! 🎉"
    cd ..
    echo "Tu stack de n8n ha sido configurado para escalar y el servicio"
    echo "de auto-escalado ('autoscaler') está en funcionamiento."
    echo ""
    echo "Pasos siguientes recomendados:"
    echo "  1. Revisa los logs del autoscaler para confirmar que todo funciona:"
    echo -e "     \033[0;32mdocker logs -f ${N8N_PROJECT_NAME}_autoscaler\033[0m"
    echo "  2. Puedes encontrar toda la configuración del autoscaler en la carpeta:"
    echo -e "     \033[0;32m./n8n-autoscaler/\033[0m"
else
    echo -e "\n❌ Hubo un error durante el despliegue del autoscaler."
    cd ..
fi

# Limpieza final
rm -f ./yq
echo -e "\nScript finalizado.\n"