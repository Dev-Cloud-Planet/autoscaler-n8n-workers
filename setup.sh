#!/bin/bash

# ==============================================================================
#   Script de Instalación y Configuración del Auto-Escalado para n8n
#
#   Versión: 4.1 
# ==============================================================================

# --- Funciones Auxiliares ---
print_header() {
    echo -e "\n\033[1;34m=================================================\033[0m"
    echo -e "\033[1;34m  $1\033[0m"
    echo -e "\033[1;34m=================================================\033[0m\n"
}

ask() {
    local prompt="$1"; local default="$2"; read -p "$prompt (def: $default): " reply < /dev/tty; echo "${reply:-$default}"
}

restore_and_exit() {
    local step_name="$1"; echo -e "\n\033[1;31m❌ Error: '$step_name'.\033[0m"; echo "🛡️  Restaurando 'docker-compose.yml'..."
    if [ -f "$BACKUP_FILE" ]; then mv "$BACKUP_FILE" "$N8N_COMPOSE_PATH"; echo "✅ Restauración completa."; else echo "⚠️ No se encontró backup."; fi
    rm -f yq; exit 1
}

# --- Verificación de Dependencias ---
check_deps() {
    echo "🔎 Verificando dependencias..."; for cmd in docker curl wget sed grep cut xargs; do if ! command -v $cmd &> /dev/null; then echo "❌ Error: '$cmd' es esencial." && exit 1; fi; done
    if docker compose version &>/dev/null; then COMPOSE_CMD_HOST="docker compose"; elif docker-compose version &>/dev/null; then COMPOSE_CMD_HOST="docker-compose"; else echo "❌ Error: No se encontró docker-compose." && exit 1; fi
    echo "✅ Se usará '$COMPOSE_CMD_HOST'."; if [ ! -f ./yq ]; then echo "📥 Descargando 'yq'..."; YQ_VERSION="v4.30.8"; YQ_BINARY="yq_linux_amd64"; wget -q "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}" -O ./yq && chmod +x ./yq || { echo "❌ Falló la descarga de yq." && exit 1; }; fi
    YQ_CMD="./yq"; echo "✅ Dependencias listas."
}

# --- INICIO DEL SCRIPT ---
clear; print_header "Instalador del Auto-Escalado para n8n v4.1"; check_deps

# --- FASE 1: ANÁLISIS DEL ENTORNO ---
print_header "1. Analizando tu Entorno n8n"
N8N_COMPOSE_PATH="$(pwd)/docker-compose.yml"; if [ ! -f "$N8N_COMPOSE_PATH" ]; then echo "❌ Error: No se encontró 'docker-compose.yml'." >&2; rm -f yq; exit 1; fi
N8N_ENV_PATH="$(pwd)/.env"; if [ -f "$N8N_ENV_PATH" ]; then echo "✅ Archivo '.env' detectado."; DEFAULT_REDIS_HOST=$(grep -E "^REDIS_HOST=" "$N8N_ENV_PATH" | cut -d '=' -f2 | tr -d '"' | tr -d "'"); DEFAULT_PROJECT_NAME=$(grep -E "^COMPOSE_PROJECT_NAME=" "$N8N_ENV_PATH" | cut -d '=' -f2 | tr -d '"' | tr -d "'"); fi
RAW_PROJECT_NAME=${DEFAULT_PROJECT_NAME:-$(basename "$(pwd)")}; N8N_PROJECT_NAME=$(echo "$RAW_PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_-]//g'); N8N_PROJECT_NAME=$(ask "Nombre del proyecto Docker" "${N8N_PROJECT_NAME:-n8n-project}")
DETECTED_N8N_SERVICE=$($YQ_CMD eval 'keys | .[]' "$N8N_COMPOSE_PATH" | grep -m1 "n8n"); N8N_MAIN_SERVICE_NAME=$(ask "Nombre de tu servicio principal de n8n" "${DETECTED_N8N_SERVICE:-n8n}")
DETECTED_NETWORK=$($YQ_CMD eval ".services.\"$N8N_MAIN_SERVICE_NAME\".networks[0]" "$N8N_COMPOSE_PATH"); if [ -z "$DETECTED_NETWORK" ] || [ "$DETECTED_NETWORK" == "null" ]; then echo "❌ Error: No se pudo detectar la red." >&2 && restore_and_exit "Detección de Red"; fi
echo "✅ Red de Docker detectada: '$DETECTED_NETWORK'"; DETECTED_REDIS_SERVICE=$($YQ_CMD eval '(.services[] | select(.image | test("redis")) | key)' "$N8N_COMPOSE_PATH" | head -n 1 | xargs); REDIS_HOST=$(ask "Hostname de tu servicio Redis" "${DEFAULT_REDIS_HOST:-${DETECTED_REDIS_SERVICE:-redis}}")

# --- FASE 2: CONFIGURACIÓN DEL MODO 'QUEUE' ---
print_header "2. Verificando y Configurando el Modo de Escalado"
N8N_WORKER_SERVICE_NAME="${N8N_MAIN_SERVICE_NAME}-worker"; IS_QUEUE_MODE=$($YQ_CMD eval ".services.\"$N8N_MAIN_SERVICE_NAME\".environment[] | select(. == \"EXECUTIONS_MODE=queue\")" "$N8N_COMPOSE_PATH"); WORKER_EXISTS=$($YQ_CMD eval "has(\"services.$N8N_WORKER_SERVICE_NAME\")" "$N8N_COMPOSE_PATH")
if [ -z "$IS_QUEUE_MODE" ] || [ "$WORKER_EXISTS" == "false" ]; then
    echo "🔧 La configuración de escalado no está activa o completa. Se procederá a (re)configurar."; read -p "¿Estás de acuerdo en modificar 'docker-compose.yml'? (Se creará una copia de seguridad) (y/N): " confirm_modify < /dev/tty
    if [[ ! "$confirm_modify" =~ ^[yY](es)?$ ]]; then echo "Instalación cancelada."; rm -f yq; exit 1; fi
    BACKUP_FILE="${N8N_COMPOSE_PATH}.backup.$(date +%F_%T)"; echo "🛡️  Creando copia de seguridad en '$BACKUP_FILE'..."; cp "$N8N_COMPOSE_PATH" "$BACKUP_FILE"; echo "⚙️  Aplicando configuración moderna de escalado (paso a paso)..."
    echo "   Paso 1/4: Eliminando variables obsoletas (EXECUTIONS_PROCESS)..."; $YQ_CMD eval -i 'del(.services.[].environment[] | select(. == "EXECUTIONS_PROCESS=main" or . == "EXECUTIONS_PROCESS=worker"))' "$N8N_COMPOSE_PATH" || restore_and_exit "Paso 1"
    echo "   Paso 2/4: Añadiendo variables modernas al servicio principal..."; CLEAN_REDIS_HOST=$(echo "$REDIS_HOST" | xargs); $YQ_CMD eval -i ".services.\"$N8N_MAIN_SERVICE_NAME\".environment |= (. - [\"EXECUTIONS_MODE=queue\", \"QUEUE_BULL_REDIS_HOST=*\"]) | .services.\"$N8N_MAIN_SERVICE_NAME\".environment += [\"EXECUTIONS_MODE=queue\", \"QUEUE_BULL_REDIS_HOST=$CLEAN_REDIS_HOST\", \"OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true\"]" "$N8N_COMPOSE_PATH" || restore_and_exit "Paso 2"
    echo "   Paso 3/4: Creando/Actualizando el servicio worker..."; $YQ_CMD eval -i ".services.\"$N8N_WORKER_SERVICE_NAME\" = .services.\"$N8N_MAIN_SERVICE_NAME\"" "$N8N_COMPOSE_PATH" || restore_and_exit "Paso 3"
    echo "   Paso 4/4: Limpiando claves innecesarias del worker..."; $YQ_CMD eval -i "del(.services.\"$N8N_WORKER_SERVICE_NAME\".ports) | del(.services.\"$N8N_WORKER_SERVICE_NAME\".container_name) | del(.services.\"$N8N_WORKER_SERVICE_NAME\".labels)" "$N8N_COMPOSE_PATH" || restore_and_exit "Paso 4"
    echo "✅ Modificación de 'docker-compose.yml' completada."; print_header "3. Reiniciando Stack de n8n para Aplicar Cambios"
    echo "🔄 Deteniendo y levantando los servicios..."; $COMPOSE_CMD_HOST -p "$N8N_PROJECT_NAME" up -d --force-recreate --remove-orphans || restore_and_exit "Reinicio de Docker"
    echo "✅ Tu stack de n8n ha sido actualizado y reiniciado."
else echo "✅ La configuración de escalado ya está activa."; fi

# --- FASE 4: DESPLIEGUE DEL AUTOSCALER ---
print_header "4. Desplegando el Servicio de Auto-Escalado"
AUTOSCALER_DIR="n8n-autoscaler"; mkdir -p "$AUTOSCALER_DIR"; echo "📋 Copiando '.env' a '$AUTOSCALER_DIR/.env' como base."; if [ -f "$N8N_ENV_PATH" ]; then cp "$N8N_ENV_PATH" "$AUTOSCALER_DIR/.env"; else touch "$AUTOSCALER_DIR/.env"; fi; cd "$AUTOSCALER_DIR" || exit
echo -e "\nConfigurando el comportamiento del auto-escalado:"; QUEUE_THRESHOLD=$(ask "Nº de tareas en cola para crear un worker" "15"); MAX_WORKERS=$(ask "Nº máximo de workers" "5"); MIN_WORKERS=$(ask "Nº mínimo de workers activos (Recomendado: 1)" "1")
IDLE_TIME_BEFORE_SCALE_DOWN=$(ask "Segundos de inactividad para destruir un worker" "90"); POLL_INTERVAL=$(ask "Segundos entre cada verificación" "10"); TELEGRAM_BOT_TOKEN=$(ask "Token de Bot de Telegram (opcional)" ""); TELEGRAM_CHAT_ID=$(ask "Chat ID de Telegram (opcional)" "")
(grep -v -E "^(N8N_DOCKER_PROJECT_NAME|N8N_WORKER_SERVICE_NAME|QUEUE_THRESHOLD|MAX_WORKERS|MIN_WORKERS|IDLE_TIME_BEFORE_SCALE_DOWN|POLL_INTERVAL|TELEGRAM_BOT_TOKEN|TELEGRAM_CHAT_ID)=" .env 2>/dev/null || true) > .env.tmp
cat >> .env.tmp << EOL
# --- AUTOSCALER CONFIG - GENERATED BY SCRIPT ---
N8N_DOCKER_PROJECT_NAME=${N8N_PROJECT_NAME}; N8N_WORKER_SERVICE_NAME=${N8N_WORKER_SERVICE_NAME}; QUEUE_THRESHOLD=${QUEUE_THRESHOLD}; MAX_WORKERS=${MAX_WORKERS}; MIN_WORKERS=${MIN_WORKERS}
IDLE_TIME_BEFORE_SCALE_DOWN=${IDLE_TIME_BEFORE_SCALE_DOWN}; POLL_INTERVAL=${POLL_INTERVAL}; TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}; TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
EOL
mv .env.tmp .env
echo "📄 Generando 'docker-compose.yml' para el autoscaler..."; cat > docker-compose.yml << EOL
version: '3.8'; services:
  autoscaler: {image: n8n-autoscaler-service:latest, build: ., container_name: ${N8N_PROJECT_NAME}_autoscaler, restart: always, env_file: .env, volumes: ['/var/run/docker.sock:/var/run/docker.sock', '${N8N_COMPOSE_PATH}:/app/docker-compose.yml'], working_dir: /app, networks: [n8n_network]}
networks: {n8n_network: {name: ${N8N_PROJECT_NAME}_${DETECTED_NETWORK}, external: true}}
EOL
cat > Dockerfile << 'EOL'
FROM python:3.9-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates gnupg apt-transport-https && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && apt-get install -y docker-ce-cli && rm -rf /var/lib/apt/lists/*
RUN DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep -oP '"tag_name": "\K(v[0-9]+\.[0-9]+\.[0-9]+)') && \
    curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose && \
    chmod +x /usr/local/bin/docker-compose
WORKDIR /app; COPY requirements.txt .; RUN pip install --no-cache-dir -r requirements.txt; COPY autoscaler.py .; CMD ["python", "-u", "autoscaler.py"]
EOL
cat > requirements.txt << 'EOL'
redis
requests
python-dotenv
EOL

cat > autoscaler.py << 'EOL'
import os, time, subprocess, redis, requests
from dotenv import load_dotenv
def log(message): print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}", flush=True)
def send_telegram_notification(message):
    if not TELEGRAM_TOKEN or not TELEGRAM_CHAT_ID: return
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"; payload = {'chat_id': TELEGRAM_CHAT_ID, 'text': message, 'parse_mode': 'Markdown'}
    try: requests.post(url, json=payload, timeout=10).raise_for_status()
    except requests.exceptions.RequestException as e: log(f"⚠️  Error al enviar a Telegram: {e}")
def run_docker_command(command):
    try:
        full_command = f"docker-compose -p {N8N_PROJECT_NAME} -f /app/docker-compose.yml {command}"; log(f"🚀 Ejecutando: {full_command}")
        result = subprocess.run(full_command, shell=True, check=True, capture_output=True, text=True); return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        error_message = f"❌ Error Docker: {e.stderr.strip()}"; log(error_message); send_telegram_notification(f"‼️ *Error Crítico de Docker*\n_{e.stderr.strip()}_"); return None
def get_running_workers(): output = run_docker_command(f"ps -q {N8N_WORKER_SERVICE_NAME}"); return -1 if output is None else len(output.splitlines()) if output else 0
def scale_workers(desired_count):
    current_workers = get_running_workers()
    if current_workers in (-1, desired_count): return
    log(f"⚖️  Escalando workers de {current_workers} a {desired_count}..."); command = f"up -d --scale {N8N_WORKER_SERVICE_NAME}={desired_count} --no-recreate --remove-orphans"
    if run_docker_command(command) is not None: log(f"✅ Escalado completo. Workers: {desired_count}"); send_telegram_notification(f"✅ Auto-escalado *{N8N_PROJECT_NAME}*. Workers: *{desired_count}*")
    else: log(f"❌ Error al escalar."); send_telegram_notification(f"❌ *Error al escalar workers a {desired_count}*")
def main_loop():
    idle_since = None
    while True:
        try:
            queue_size = redis_client.llen(QUEUE_KEY); running_workers = get_running_workers()
            if running_workers == -1: time.sleep(POLL_INTERVAL * 2); continue
            log(f"Estado: Cola={queue_size}, Workers={running_workers}, Min={MIN_WORKERS}, Max={MAX_WORKERS}, Umbral={QUEUE_THRESHOLD}")
            if queue_size > QUEUE_THRESHOLD and running_workers < MAX_WORKERS:
                scale_workers(min(running_workers + 1, MAX_WORKERS)); idle_since = None
            elif queue_size == 0 and running_workers > MIN_WORKERS:
                if idle_since is None: idle_since = time.time(); log(f"Cola vacía. Iniciando temporizador de {IDLE_TIME_BEFORE_SCALE_DOWN}s para scale-down.")
                if time.time() - idle_since >= IDLE_TIME_BEFORE_SCALE_DOWN: scale_workers(max(running_workers - 1, MIN_WORKERS)); idle_since = None
            elif queue_size > 0:
                if idle_since is not None: log("Cola con tareas. Cancelando scale-down."); idle_since = None
            time.sleep(POLL_INTERVAL)
        except redis.exceptions.RedisError as e: log(f"⚠️ Error Redis: {e}. Reintentando..."); time.sleep(POLL_INTERVAL * 2)
        except KeyboardInterrupt: log("🛑 Script detenido."); send_telegram_notification(f"🤖 Servicio para *{N8N_PROJECT_NAME}* detenido."); break
        except Exception as e: log(f"🔥 Error inesperado: {e}"); send_telegram_notification(f"🔥 *Error en Autoscaler {N8N_PROJECT_NAME}*\n_{str(e)}_"); time.sleep(POLL_INTERVAL * 3)
if __name__ == "__main__":
    load_dotenv(); REDIS_HOST = os.getenv('REDIS_HOST', 'redis'); N8N_PROJECT_NAME = os.getenv('N8N_DOCKER_PROJECT_NAME'); N8N_WORKER_SERVICE_NAME = os.getenv('N8N_WORKER_SERVICE_NAME')
    # ESTA ES LA LÍNEA CORREGIDA: 'default' en lugar de 'n8n-executions'
    QUEUE_KEY = "bull:default:wait"; QUEUE_THRESHOLD = int(os.getenv('QUEUE_THRESHOLD', 15)); MAX_WORKERS = int(os.getenv('MAX_WORKERS', 5))
    MIN_WORKERS = int(os.getenv('MIN_WORKERS', 1)); IDLE_TIME_BEFORE_SCALE_DOWN = int(os.getenv('IDLE_TIME_BEFORE_SCALE_DOWN', 90)); POLL_INTERVAL = int(os.getenv('POLL_INTERVAL', 10))
    TELEGRAM_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN'); TELEGRAM_CHAT_ID = os.getenv('TELEGRAM_CHAT_ID')
    if not all([N8N_PROJECT_NAME, N8N_WORKER_SERVICE_NAME]): log("❌ Error: Faltan variables de entorno críticas."); exit(1)
    try:
        redis_client = redis.Redis(host=REDIS_HOST, port=6379, db=0, decode_responses=True, socket_connect_timeout=5); redis_client.ping(); log("✅ Conexión con Redis establecida.")
    except redis.exceptions.RedisError as e: log(f"❌ Error fatal al conectar con Redis en {REDIS_HOST}: {e}"); exit(1)
    log(f"🚀 Iniciando autoscaler para '{N8N_PROJECT_NAME}'..."); send_telegram_notification(f"🤖 Autoscaler para *{N8N_PROJECT_NAME}* (re)iniciado.")
    main_loop()
EOL

echo "🧹 Limpiando instancia anterior del autoscaler..."; docker rm -f "${N8N_PROJECT_NAME}_autoscaler" > /dev/null 2>&1
echo "🏗️  Construyendo y desplegando el servicio de auto-escalado..."; $COMPOSE_CMD_HOST up -d --build
if [ $? -eq 0 ]; then
    print_header "🎉 ¡Instalación Completada con Éxito! 🎉"
    cd ..; echo "El stack de n8n está configurado y el autoscaler está funcionando con la lógica correcta."; echo ""
    echo "Pasos siguientes:"; echo "  1. Lanza algunas ejecuciones en n8n."; echo "  2. Revisa los logs: \033[0;32mdocker logs -f ${N8N_PROJECT_NAME}_autoscaler\033[0m para ver cómo reacciona."
else
    echo -e "\n❌ Hubo un error durante el despliegue del autoscaler."; cd ..
fi
rm -f ./yq; echo -e "\nScript finalizado.\n"