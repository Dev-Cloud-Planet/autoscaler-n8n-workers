#!/bin/bash

# ==============================================================================
#   Script de Instalación y Configuración del Auto-Escalado para n8n
#
#   Versión: 5.0 (Lógica y sintaxis corregidas)
# ==============================================================================

# --- Funciones Auxiliares ---
print_header() {
    echo -e "\n\033[1;34m=================================================\033[0m"
    echo -e "\033[1;34m  $1\033[0m"
    echo -e "\033[1;34m=================================================\033[0m\n"
}

ask() {
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
    rm -f yq
    exit 1
}

# --- Verificación de Dependencias ---
check_deps() {
    echo "🔎 Verificando dependencias..."
    for cmd in docker curl wget sed grep cut xargs; do
        if ! command -v $cmd &> /dev/null; then echo "❌ Error: El comando '$cmd' es esencial." && exit 1; fi
    done
    if docker compose version &>/dev/null; then COMPOSE_CMD_HOST="docker compose"; elif docker-compose version &>/dev/null; then COMPOSE_CMD_HOST="docker-compose"; else echo "❌ Error: No se encontró 'docker-compose' o el plugin 'docker compose'." && exit 1; fi
    echo "✅ Se usará '$COMPOSE_CMD_HOST' para las operaciones del host."
    if [ ! -f ./yq ]; then
        echo "📥 Descargando la herramienta 'yq'..."; YQ_VERSION="v4.30.8"; YQ_BINARY="yq_linux_amd64"; wget -q "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}" -O ./yq && chmod +x ./yq || { echo "❌ Falló la descarga de yq." && exit 1; }; fi
    YQ_CMD="./yq"; echo "✅ Dependencias listas."
}

# --- INICIO DEL SCRIPT ---
clear
print_header "Instalador del Servicio de Auto-Escalado para n8n v5.0"
check_deps

# --- FASE 1: ANÁLISIS DEL ENTORNO ---
print_header "1. Analizando tu Entorno n8n"
N8N_COMPOSE_PATH="$(pwd)/docker-compose.yml"
if [ ! -f "$N8N_COMPOSE_PATH" ]; then echo "❌ Error: No se encontró 'docker-compose.yml' en el directorio actual." && rm -f yq && exit 1; fi
N8N_ENV_PATH="$(pwd)/.env"
if [ -f "$N8N_ENV_PATH" ]; then
    echo "✅ Archivo de entorno '.env' detectado."
    DEFAULT_REDIS_HOST=$(grep -E "^REDIS_HOST=" "$N8N_ENV_PATH" | cut -d '=' -f2 | tr -d '"' | tr -d "'")
    DEFAULT_PROJECT_NAME=$(grep -E "^COMPOSE_PROJECT_NAME=" "$N8N_ENV_PATH" | cut -d '=' -f2 | tr -d '"' | tr -d "'")
fi
RAW_PROJECT_NAME=${DEFAULT_PROJECT_NAME:-$(basename "$(pwd)")}
N8N_PROJECT_NAME=$(echo "$RAW_PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_-]//g')
N8N_PROJECT_NAME=$(ask "Nombre del proyecto Docker" "${N8N_PROJECT_NAME:-n8n-project}")
DETECTED_N8N_SERVICE=$($YQ_CMD eval 'keys | .[]' "$N8N_COMPOSE_PATH" | grep -m1 "n8n")
N8N_MAIN_SERVICE_NAME=$(ask "Nombre de tu servicio principal de n8n" "${DETECTED_N8N_SERVICE:-n8n}")
DETECTED_REDIS_SERVICE=$($YQ_CMD eval '(.services[] | select(.image | test("redis")) | key)' "$N8N_COMPOSE_PATH" | head -n 1 | xargs)
REDIS_HOST=$(ask "Hostname de tu servicio Redis" "${DEFAULT_REDIS_HOST:-${DETECTED_REDIS_SERVICE:-redis}}")
DETECTED_NETWORK=$($YQ_CMD eval ".services.\"$N8N_MAIN_SERVICE_NAME\".networks[0]" "$N8N_COMPOSE_PATH")
if [ -z "$DETECTED_NETWORK" ]; then echo "❌ Error: No se pudo detectar la red de '$N8N_MAIN_SERVICE_NAME'." && restore_and_exit; fi
echo "✅ Red de Docker detectada: '$DETECTED_NETWORK'"


# --- FASE 2: CONFIGURACIÓN DEL MODO 'QUEUE' ---
print_header "2. Verificando y Configurando el Modo de Escalado"
N8N_WORKER_SERVICE_NAME="${N8N_MAIN_SERVICE_NAME}-worker"
IS_QUEUE_MODE=$($YQ_CMD eval ".services.\"$N8N_MAIN_SERVICE_NAME\".environment[] | select(. == \"EXECUTIONS_MODE=queue\")" "$N8N_COMPOSE_PATH" 2>/dev/null)

if [ -z "$IS_QUEUE_MODE" ]; then
    echo "🔧 El modo 'queue' no está configurado. Se procederá a modificar 'docker-compose.yml'."
    read -p "Desea continuar? Se creara un backup [y/N]: " confirm_modify < /dev/tty
    if [[ ! "$confirm_modify" =~ ^[yY](es)?$ ]]; then
        echo "Instalación cancelada."
        rm -f yq
        exit 1
    fi

    BACKUP_FILE="${N8N_COMPOSE_PATH}.backup.$(date +%F_%H-%M-%S)"
    echo "🛡️  Creando copia de seguridad en '$BACKUP_FILE'..."
    cp "$N8N_COMPOSE_PATH" "$BACKUP_FILE"

    echo "⚙️  Aplicando configuración de modo 'queue' y añadiendo servicio de worker..."
    
    $YQ_CMD eval "
        .services.\"$REDIS_HOST\".healthcheck.test = [\"CMD\", \"redis-cli\", \"ping\"] |
        .services.\"$REDIS_HOST\".healthcheck.interval = \"10s\" |
        .services.\"$REDIS_HOST\".healthcheck.timeout = \"5s\" |
        .services.\"$REDIS_HOST\".healthcheck.retries = 5 |
        .services.\"$N8N_MAIN_SERVICE_NAME\".environment += [\"EXECUTIONS_MODE=queue\", \"EXECUTIONS_PROCESS=main\", \"QUEUE_BULL_REDIS_HOST=$REDIS_HOST\", \"OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true\"] |
        .services.\"$N8N_MAIN_SERVICE_NAME\".depends_on.\"$REDIS_HOST\".condition = \"service_healthy\" |
        .services.\"$N8N_WORKER_SERVICE_NAME\" = .services.\"$N8N_MAIN_SERVICE_NAME\" |
        .services.\"$N8N_WORKER_SERVICE_NAME\".environment |= . - [\"EXECUTIONS_PROCESS=main\"] |
        .services.\"$N8N_WORKER_SERVICE_NAME\".environment += [\"EXECUTIONS_PROCESS=worker\"] |
        del(.services.\"$N8N_WORKER_SERVICE_NAME\".ports) |
        del(.services.\"$N8N_WORKER_SERVICE_NAME\".container_name) |
        del(.services.\"$N8N_WORKER_SERVICE_NAME\".labels)
    " -i "$N8N_COMPOSE_PATH"
    
    if [ $? -ne 0 ]; then
        echo "❌ Error al modificar 'docker-compose.yml' con yq."
        restore_and_exit
    fi

    print_header "3. Reiniciando Stack de n8n para Aplicar Cambios"
    echo "🔄 Deteniendo y levantando los servicios con la nueva configuración..."
    $COMPOSE_CMD_HOST -p "$N8N_PROJECT_NAME" up -d --force-recreate --remove-orphans || restore_and_exit
    echo "✅ Tu stack de n8n ha sido actualizado y reiniciado con éxito."
else
    echo "✅ El modo 'queue' ya está configurado. No se realizarán cambios en 'docker-compose.yml'."
fi

# --- FASE 4: DESPLIEGUE DEL AUTOSCALER ---
print_header "4. Desplegando el Servicio de Auto-Escalado"
AUTOSCALER_DIR="n8n-autoscaler"; mkdir -p "$AUTOSCALER_DIR"; if [ -f "$N8N_ENV_PATH" ]; then echo "📋 Copiando '$N8N_ENV_PATH' a '$AUTOSCALER_DIR/.env'..."; cp "$N8N_ENV_PATH" "$AUTOSCALER_DIR/.env"; else touch "$AUTOSCALER_DIR/.env"; fi
cd "$AUTOSCALER_DIR" || exit; echo -e "\nAhora, configuremos el comportamiento del auto-escalado:"; QUEUE_THRESHOLD=$(ask "Nº de tareas en cola para crear un nuevo worker" "15"); MAX_WORKERS=$(ask "Nº máximo de workers permitidos" "5"); MIN_WORKERS=$(ask "Nº mínimo de workers activos" "0"); IDLE_TIME_BEFORE_SCALE_DOWN=$(ask "Segundos de inactividad para destruir un worker" "90"); POLL_INTERVAL=$(ask "Segundos entre cada verificación" "10"); TELEGRAM_BOT_TOKEN=$(ask "Token de Bot de Telegram (opcional)" ""); TELEGRAM_CHAT_ID=$(ask "Chat ID de Telegram (opcional)" "")
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
echo "📄 Generando archivos para el autoscaler..."
cat > docker-compose.yml << EOL
services:
  autoscaler: {image: n8n-autoscaler-service:latest, build: '.', container_name: ${N8N_PROJECT_NAME}_autoscaler, restart: always, env_file: .env, volumes: ['/var/run/docker.sock:/var/run/docker.sock', '${N8N_COMPOSE_PATH}:/app/docker-compose.yml'], working_dir: /app, networks: [n8n_network]}
networks:
  n8n_network: {name: ${N8N_PROJECT_NAME}_${DETECTED_NETWORK}, external: true}
EOL
cat > Dockerfile << 'EOL'
FROM python:3.9-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates gnupg apt-transport-https redis-tools && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && apt-get update && apt-get install -y docker-ce-cli && rm -rf /var/lib/apt/lists/*
RUN curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose && chmod +x /usr/local/bin/docker-compose
WORKDIR /app; COPY requirements.txt .; RUN pip install --no-cache-dir -r requirements.txt; COPY autoscaler.py .; CMD ["python", "-u", "autoscaler.py"]
EOL
cat > requirements.txt << 'EOL'
redis
requests
python-dotenv
EOL
cat > autoscaler.py << 'EOL'
import os,time,subprocess,redis,requests
from dotenv import load_dotenv
def log(m):print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {m}",flush=True)
def notify(m):
    if not T_TOKEN or not T_CHAT_ID:return
    try:requests.post(f"https://api.telegram.org/bot{T_TOKEN}/sendMessage",json={'chat_id':T_CHAT_ID,'text':m,'parse_mode':'Markdown'},timeout=10).raise_for_status()
    except:log("⚠️ Error enviando notificación a Telegram")
def docker_cmd(cmd):
    try:
        f_cmd=f"docker-compose -p {N8N_PROJ_NAME} -f /app/docker-compose.yml {cmd}";log(f"🚀 Ejecutando: {f_cmd}")
        return subprocess.run(f_cmd,shell=True,check=True,capture_output=True,text=True).stdout.strip()
    except subprocess.CalledProcessError as e:
        err=f"❌ Docker Error: {e.stderr.strip()}";log(err);notify(f"‼️ *Error Crítico de Docker*\n_{e.stderr.strip()}_");return None
def get_workers():
    out=docker_cmd(f"ps -q {N8N_WORKER_NAME}");return-1 if out is None else len(out.splitlines())if out else 0
def scale(count):
    curr=get_workers()
    if curr==-1 or curr==count:return
    log(f"⚖️ Escalando de {curr} a {count} workers...");cmd=f"up -d --scale {N8N_WORKER_NAME}={count} --no-recreate --remove-orphans"
    if docker_cmd(cmd) is not None:log(f"✅ Escalado completo: {count} workers");notify(f"✅ *{N8N_PROJ_NAME}* | Workers: *{count}*")
    else:log(f"❌ Error al escalar a {count}");notify(f"❌ Error al escalar a {count}")
def loop():
    idle=None
    while True:
        try:
            q=r.llen(Q_KEY);w=get_workers()
            if w==-1:time.sleep(POLL*2);continue
            log(f"Estado: Cola={q}, Workers={w}, Umbral={Q_THR}")
            if q>Q_THR and w<MAX_W:scale(min(w+1,MAX_W));idle=None
            elif q==0 and w>MIN_W:
                if idle is None:idle=time.time();log(f"Cola vacía. Temporizador de {IDLE_S}s iniciado.")
                if time.time()-idle>=IDLE_S:scale(max(w-1,MIN_W));idle=None
            elif q>0:
                if idle is not None:log("La cola ya no está vacía. Cancelando scale-down.");idle=None
            time.sleep(POLL)
        except redis.exceptions.RedisError as e:log(f"⚠️ Redis Error: {e}. Reintentando...");time.sleep(POLL*2)
        except KeyboardInterrupt:log("🛑 Script detenido.");notify(f"🤖 Autoscaler para *{N8N_PROJ_NAME}* detenido.");break
        except Exception as e:log(f"🔥 Error inesperado: {e}");notify(f"🔥 *Error en Autoscaler*\n_{str(e)}_");time.sleep(POLL*3)
if __name__=="__main__":
    load_dotenv();N8N_PROJ_NAME=os.getenv('N8N_DOCKER_PROJECT_NAME');N8N_WORKER_NAME=os.getenv('N8N_WORKER_SERVICE_NAME')
    REDIS_HOST=os.getenv('REDIS_HOST','redis');Q_KEY="bull:n8n-executions:wait";Q_THR=int(os.getenv('QUEUE_THRESHOLD',15));MAX_W=int(os.getenv('MAX_WORKERS',5));MIN_W=int(os.getenv('MIN_WORKERS',0))
    IDLE_S=int(os.getenv('IDLE_TIME_BEFORE_SCALE_DOWN',90));POLL=int(os.getenv('POLL_INTERVAL',10));T_TOKEN=os.getenv('TELEGRAM_BOT_TOKEN');T_CHAT_ID=os.getenv('TELEGRAM_CHAT_ID')
    if not all([N8N_PROJ_NAME,N8N_WORKER_NAME]):log("❌ Faltan variables de entorno críticas.");exit(1)
    try:r=redis.Redis(host=REDIS_HOST,port=6379,decode_responses=True,socket_connect_timeout=5);r.ping();log("✅ Conexión con Redis establecida.")
    except redis.exceptions.RedisError as e:log(f"❌ Error fatal al conectar con Redis en {REDIS_HOST}: {e}");exit(1)
    log(f"🚀 Iniciando autoscaler para '{N8N_PROJ_NAME}'");notify(f"🤖 Autoscaler para *{N8N_PROJ_NAME}* (re)iniciado.");loop()
EOL
# --- Despliegue Final ---
echo "🧹 Limpiando instancias anteriores del autoscaler..."; docker rm -f "${N8N_PROJECT_NAME}_autoscaler" > /dev/null 2>&1
echo "🏗️  Construyendo y desplegando el servicio de auto-escalado..."; $COMPOSE_CMD_HOST up -d --build
if [ $? -eq 0 ]; then
    print_header "🎉 ¡Instalación Completada con Éxito! 🎉"
    cd ..; echo -e "Tu stack de n8n ha sido configurado y el autoscaler está funcionando.\n\nPasos siguientes:\n  1. Revisa los logs: \033[0;32mdocker logs -f ${N8N_PROJECT_NAME}_autoscaler\033[0m\n  2. Configuración en: \033[0;32m./n8n-autoscaler/\033[0m"
else
    echo -e "\n❌ Hubo un error durante el despliegue del autoscaler."; cd ..
fi
rm -f ./yq; echo -e "\nScript finalizado.\n"