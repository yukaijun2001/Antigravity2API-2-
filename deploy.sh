#!/usr/bin/env bash
# Linux 服务器一键部署；重复执行会拉取最新源码并保留 data/。
set -Eeuo pipefail
umask 077

REPO_URL="${REPO_URL:-https://github.com/yukaijun2001/Antigravity2API-2-.git}"
BRANCH="${BRANCH:-main}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/antigravity2api}"
HOST_PORT=10005
CONTAINER_NAME=antigravity2api
PROJECT_NAME=antigravity2api
SERVICE_NAME=antigravity2api
OWNER_LABEL=io.antigravity2api.deploy
WORK_DIR=
PREVIOUS_ID=
PREVIOUS_KIND=none
PREVIOUS_RUNNING=false
ROLLBACK_IMAGE=
KEEP_ROLLBACK_IMAGE=false
REPLACING=false
CONFIG_CHANGED=false
COMPOSE_CHANGED=false
SUCCEEDED=false

log() { printf '\n[deploy] %s\n' "$*"; }
die() { printf '\n[deploy] 错误：%s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法：sudo bash deploy.sh

自动安装 Git、Docker、Compose 和构建组件，拉取 main 最新源码，编排部署到 10005 端口。
首次自动配置管理登录并生成 API Key；重复执行保留账户、密钥、管理密码与运行数据。
自动迁移旧版 deploy.sh 创建的容器，编排文件保存到安装目录的 compose.yaml。

可选环境变量（无需设置）：
  DEPLOY_DIR  安装目录，默认 /opt/antigravity2api
  REPO_URL    Git 仓库地址，默认当前项目的 GitHub 仓库
  BRANCH      部署分支，默认 main
EOF
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die '请使用 root 运行，或安装 sudo 后执行 sudo bash deploy.sh。'
    exec sudo -- env REPO_URL="$REPO_URL" BRANCH="$BRANCH" DEPLOY_DIR="$DEPLOY_DIR" \
      bash "${BASH_SOURCE[0]}" "$@"
  fi
}

compose_file() {
  local file=$1
  shift
  docker compose --ansi never --env-file /dev/null --project-name "$PROJECT_NAME" \
    --project-directory "$DEPLOY_DIR" --file "$file" "$@"
}

compose() { compose_file "$COMPOSE_FILE" "$@"; }

install_dependencies() {
  local dependency missing=false
  for dependency in git curl python3 flock; do
    if ! command -v "$dependency" >/dev/null 2>&1; then missing=true; fi
  done
  if [[ ! -s /etc/ssl/certs/ca-certificates.crt && ! -s /etc/pki/tls/certs/ca-bundle.crt ]]; then
    missing=true
  fi
  if [[ $missing == false ]]; then return; fi

  log '安装系统依赖'
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl git python3 util-linux
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl git python3 util-linux
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl git python3 util-linux
  else
    die '自动安装支持 Debian、Ubuntu 及使用 dnf/yum 的 Linux；当前系统缺少必要组件。'
  fi
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log '通过 Docker 官方安装脚本安装 Docker'
    curl --fail --show-error --silent --location --retry 3 \
      https://get.docker.com --output "$WORK_DIR/get-docker.sh"
    sh "$WORK_DIR/get-docker.sh"
  fi

  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl enable --now docker
  elif ! docker info >/dev/null 2>&1; then
    if command -v service >/dev/null 2>&1; then
      service docker start
    else
      die '当前系统没有可用的 Docker 服务管理器，无法自动启动 Docker。'
    fi
  fi

  local attempt
  for ((attempt = 0; attempt < 30; attempt++)); do
    if docker info >/dev/null 2>&1; then break; fi
    sleep 1
  done
  docker info >/dev/null 2>&1 || die 'Docker 服务未就绪。'

  if ! docker buildx version >/dev/null 2>&1; then
    log '安装 Docker Buildx 构建组件'
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y docker-buildx-plugin || \
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker-buildx
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y docker-buildx-plugin || dnf install -y docker-buildx
    elif command -v yum >/dev/null 2>&1; then
      yum install -y docker-buildx-plugin || yum install -y docker-buildx
    fi
    docker buildx version >/dev/null 2>&1 || die '无法安装 Docker Buildx，未改动现有容器。'
  fi

  if ! docker compose version >/dev/null 2>&1; then
    log '安装 Docker Compose 编排组件'
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin || \
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y docker-compose-plugin || dnf install -y docker-compose
    elif command -v yum >/dev/null 2>&1; then
      yum install -y docker-compose-plugin || yum install -y docker-compose
    fi
    docker compose version >/dev/null 2>&1 || die '无法安装 Docker Compose，未改动现有容器。'
  fi
  local compose_help
  compose_help=$(docker compose up --help)
  [[ $compose_help == *--wait-timeout* ]] || die 'Docker Compose 版本过旧，需要支持 up --wait-timeout 的版本。'
}

update_source() {
  log "获取仓库最新代码：$BRANCH"
  if [[ -d $SOURCE_DIR/.git ]]; then
    [[ $(git -C "$SOURCE_DIR" remote get-url origin) == "$REPO_URL" ]] || \
      die "源码目录的 origin 与 REPO_URL 不一致：$SOURCE_DIR"
    [[ $(git -C "$SOURCE_DIR" branch --show-current) == "$BRANCH" ]] || \
      die "源码目录不在 $BRANCH 分支：$SOURCE_DIR"
    [[ -z $(git -C "$SOURCE_DIR" status --porcelain) ]] || \
      die "源码目录有本地改动，请先保存或提交后重试：$SOURCE_DIR"
    git -C "$SOURCE_DIR" fetch --prune origin "$BRANCH"
    git -C "$SOURCE_DIR" merge --ff-only FETCH_HEAD
    [[ $(git -C "$SOURCE_DIR" rev-parse HEAD) == "$(git -C "$SOURCE_DIR" rev-parse FETCH_HEAD)" ]] || \
      die "源码目录包含远端以外的本地提交，未覆盖它们：$SOURCE_DIR"
  else
    git clone --single-branch --branch "$BRANCH" "$REPO_URL" "$SOURCE_DIR"
  fi
  [[ -f $SOURCE_DIR/Dockerfile && -f $SOURCE_DIR/.env.example && -f $SOURCE_DIR/compose.yaml ]] || \
    die '仓库缺少 Dockerfile、.env.example 或 compose.yaml。'
  COMMIT=$(git -C "$SOURCE_DIR" rev-parse HEAD)
  IMAGE="antigravity2api:deploy-${COMMIT:0:12}"
}

check_existing_container() {
  if PREVIOUS_ID=$(docker container inspect --format '{{.Id}}' "$CONTAINER_NAME" 2>/dev/null); then
    local owner project service
    owner=$(docker container inspect --format "{{index .Config.Labels \"$OWNER_LABEL\"}}" "$CONTAINER_NAME")
    [[ $owner == "$DEPLOY_DIR" ]] || \
      die "已有同名容器 $CONTAINER_NAME 不属于此部署目录，未改动它。"
    PREVIOUS_RUNNING=$(docker container inspect --format '{{.State.Running}}' "$PREVIOUS_ID")
    project=$(docker container inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$PREVIOUS_ID")
    if [[ -z $project || $project == '<no value>' ]]; then
      PREVIOUS_KIND=legacy
    else
      service=$(docker container inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$PREVIOUS_ID")
      [[ $project == "$PROJECT_NAME" && $service == "$SERVICE_NAME" ]] || \
        die '同名容器属于其他 Compose 项目或服务，未改动它。'
      [[ -f $COMPOSE_FILE ]] || die "已有 Compose 容器但缺少原编排文件：$COMPOSE_FILE"
      PREVIOUS_KIND=compose
    fi
  else
    PREVIOUS_ID=
  fi
}

prepare_compose() {
  if [[ -f $COMPOSE_FILE ]]; then cp -p "$COMPOSE_FILE" "$WORK_DIR/previous-compose.yaml"; fi

  # 在修改运行中的服务之前验证模板，并将绝对路径与镜像版本固化到部署目录。
  ANTIGRAVITY_SOURCE_DIR="$SOURCE_DIR" ANTIGRAVITY_DATA_DIR="$DATA_DIR" \
    ANTIGRAVITY_DEPLOY_DIR="$DEPLOY_DIR" ANTIGRAVITY_IMAGE="$IMAGE" \
    compose_file "$SOURCE_DIR/compose.yaml" config >"$WORK_DIR/next-compose.yaml"

  if [[ $PREVIOUS_KIND == compose ]]; then
    local previous_image
    previous_image=$(docker container inspect --format '{{.Image}}' "$PREVIOUS_ID")
    ROLLBACK_IMAGE="antigravity2api:rollback-$(date +%s)-$$"
    docker image tag "$previous_image" "$ROLLBACK_IMAGE"
    python3 - "$ROLLBACK_IMAGE" "$WORK_DIR/rollback-image.json" <<'PY'
import json
from pathlib import Path
import sys

Path(sys.argv[2]).write_text(json.dumps({"services": {"antigravity2api": {"image": sys.argv[1]}}}))
PY
    # 固定实际运行的旧镜像，同一提交重新构建时也能恢复。
    compose --file "$WORK_DIR/rollback-image.json" config >"$WORK_DIR/rollback-compose.yaml"
  fi
}

check_port() {
  # 旧容器占用的端口会在切换时释放，其余占用在构建前报错。
  if [[ -n $PREVIOUS_ID && $PREVIOUS_RUNNING == true ]]; then return; fi
  python3 - "$HOST_PORT" <<'PY'
import socket
import sys

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
    try:
        listener.bind(("0.0.0.0", int(sys.argv[1])))
    except OSError as error:
        sys.exit(f"[deploy] 端口 {sys.argv[1]} 不可用：{error}")
PY
}

configure_app() {
  if [[ -f $ENV_FILE ]]; then cp -p "$ENV_FILE" "$WORK_DIR/previous.env"; fi
  python3 - "$ENV_FILE" "$SOURCE_DIR/.env.example" "$WORK_DIR/next.env" <<'PY'
import json
import os
from pathlib import Path
import posixpath
import re
import secrets
import sys

target, example, output = map(Path, sys.argv[1:])
text = target.read_text() if target.exists() else example.read_text()
values = {}
for line in text.splitlines():
    match = re.match(r"^\s*([A-Z][A-Z0-9_]*)\s*=(.*)$", line)
    if match:
        values[match[1]] = match[2].strip()

def value(key):
    raw = values.get(key, "")
    if raw.startswith('"'):
        return json.loads(raw)
    if raw.startswith("'") and raw.endswith("'"):
        return raw[1:-1]
    return raw.split(" #", 1)[0].strip()

updates = {
    "LISTEN": "0.0.0.0:8017",
    "AUTH_DIR": posixpath.normpath(posixpath.join("/data", value("AUTH_DIR") or "auth")),
    "RUNTIME_DIR": posixpath.normpath(posixpath.join("/data", value("RUNTIME_DIR") or "runtime")),
    "ADMIN_AUTH_ENABLED": "true",
    "ADMIN_USERNAME": value("ADMIN_USERNAME") if target.exists() else "sys_wutong",
    "ADMIN_PASSWORD": value("ADMIN_PASSWORD") or "f3RggbXHH6d5T8UKKakg",
}
updates["ADMIN_USERNAME"] = updates["ADMIN_USERNAME"] or "sys_wutong"
if not any(key.strip() for key in value("API_KEYS").split(",")):
    updates["API_KEYS"] = "sk-" + secrets.token_hex(24)

# 只修改部署必需项，保留管理端设置、注释、模板及多把 API Key。
lines = []
for line in text.splitlines():
    match = re.match(r"^\s*([A-Z][A-Z0-9_]*)\s*=", line)
    if not match or match[1] not in updates:
        lines.append(line)
lines.extend(f"{key}={json.dumps(val, ensure_ascii=False)}" for key, val in updates.items())
output.write_text("\n".join(lines) + "\n")
os.chmod(output, 0o600)
PY
  CONFIG_CHANGED=true
  # 同一文件系统上的原子替换，容器中的管理端仍可自行保存 .env。
  mv "$WORK_DIR/next.env" "$ENV_FILE"
}

wait_ready() {
  local attempt
  for ((attempt = 0; attempt < 60; attempt++)); do
    if [[ $(docker container inspect --format '{{.State.Running}}' "$CONTAINER_NAME") != true ]]; then
      return 1
    fi
    if curl --noproxy '*' --fail --silent --show-error --connect-timeout 1 --max-time 2 \
      "http://127.0.0.1:$HOST_PORT/api/session" 2>/dev/null | \
      python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("enabled") is True else 1)' \
      2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

configure_firewall() {
  if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status | grep -q '^Status: active'; then
    ufw allow "$HOST_PORT/tcp"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$HOST_PORT/tcp"
    firewall-cmd --add-port="$HOST_PORT/tcp"
  fi
}

cleanup() {
  local status=$? current_id=
  trap - ERR INT TERM
  set +e
  if [[ $SUCCEEDED != true && $REPLACING == true ]]; then
    log '部署未完成，恢复原有配置与容器'
    if [[ $COMPOSE_CHANGED == true ]]; then
      compose down --timeout 20 || log '新编排清理失败，请检查 Docker 状态。'
    fi
    if [[ $CONFIG_CHANGED == true ]]; then
      if [[ -f $WORK_DIR/previous.env ]]; then
        cp -p "$WORK_DIR/previous.env" "$ENV_FILE"
      else
        rm -f "$ENV_FILE"
      fi
    fi
    if [[ $COMPOSE_CHANGED == true ]]; then
      if [[ $PREVIOUS_KIND == compose ]]; then
        cp -p "$WORK_DIR/rollback-compose.yaml" "$COMPOSE_FILE"
        KEEP_ROLLBACK_IMAGE=true
      elif [[ -f $WORK_DIR/previous-compose.yaml ]]; then
        cp -p "$WORK_DIR/previous-compose.yaml" "$COMPOSE_FILE"
      else
        rm -f "$COMPOSE_FILE"
      fi
    fi
    if [[ $PREVIOUS_KIND == legacy ]]; then
      current_id=$(docker container inspect --format '{{.Id}}' "$CONTAINER_NAME" 2>/dev/null)
      if [[ $current_id != "$PREVIOUS_ID" ]]; then
        docker rename "$PREVIOUS_ID" "$CONTAINER_NAME"
      fi
      if [[ $PREVIOUS_RUNNING == true ]]; then docker start "$PREVIOUS_ID" >/dev/null; fi
    elif [[ $PREVIOUS_KIND == compose ]]; then
      if [[ $COMPOSE_CHANGED != true ]]; then
        if [[ $PREVIOUS_RUNNING == true ]]; then docker start "$PREVIOUS_ID" >/dev/null; fi
      elif [[ $PREVIOUS_RUNNING == true ]]; then
        compose up --detach --no-build --pull never --wait --wait-timeout 90 "$SERVICE_NAME" || \
          log '旧编排恢复启动失败，请检查日志；原数据与恢复镜像已保留。'
      else
        compose create --no-build --pull never "$SERVICE_NAME" || log '旧编排恢复失败，请检查 Docker 状态。'
      fi
    fi
  fi
  if [[ -n $ROLLBACK_IMAGE && $KEEP_ROLLBACK_IMAGE != true ]]; then
    docker image rm "$ROLLBACK_IMAGE" >/dev/null 2>&1 || true
  fi
  if [[ -n $WORK_DIR ]]; then rm -rf -- "$WORK_DIR"; fi
  exit "$status"
}

show_result() {
  local address
  address=$(curl --noproxy '*' -4 --fail --silent --connect-timeout 2 --max-time 5 \
    https://api.ipify.org 2>/dev/null || true)
  if ! python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$address" 2>/dev/null; then
    address=$(hostname -I 2>/dev/null | awk '{print $1}') || address=
  fi
  address=${address:-服务器IP}
  log '部署成功'
  printf '管理端：http://%s:%s\nAPI 地址：http://%s:%s/v1\n' "$address" "$HOST_PORT" "$address" "$HOST_PORT"
  printf '代码版本：%s\n配置文件：%s\n数据目录：%s\n' "$COMMIT" "$ENV_FILE" "$DATA_DIR"
  printf '编排文件：%s\n' "$COMPOSE_FILE"
  printf '管理员：首次使用 sys_wutong 和指定密码，后续保留管理端修改。\n'
  printf 'API Key：已自动生成并保存，可在管理端「客户端接入」中查看。\n'
  printf '查看状态：sudo docker compose -f %q ps\n' "$COMPOSE_FILE"
  printf '查看日志：sudo docker compose -f %q logs -f --tail 100\n' "$COMPOSE_FILE"
  printf '更新服务：再次执行 sudo bash deploy.sh\n'
  printf '首次使用请在管理端添加 Google 账户；云服务器安全组需允许 TCP %s。\n' "$HOST_PORT"
}

main() {
  if [[ $# -gt 0 ]]; then
    case "$1" in -h|--help) usage; return ;; *) die '不支持此参数，使用 --help 查看用法。' ;; esac
  fi
  [[ $(uname -s) == Linux ]] || die '此脚本用于 Linux 服务器。'
  case "$(uname -m)" in x86_64|aarch64|arm64) ;; *) die '仅支持 amd64 或 arm64 服务器。' ;; esac
  [[ $DEPLOY_DIR == /* && $DEPLOY_DIR != / && $DEPLOY_DIR != *,* ]] || die 'DEPLOY_DIR 需要是非根目录、无逗号的绝对路径。'
  require_root "$@"
  install_dependencies
  mkdir -p "$DEPLOY_DIR"
  DEPLOY_DIR=$(cd "$DEPLOY_DIR" && pwd -P)
  [[ $DEPLOY_DIR != / && $DEPLOY_DIR != *,* && $DEPLOY_DIR != *:* ]] || \
    die 'DEPLOY_DIR 解析后不能是根目录或包含逗号、冒号。'
  SOURCE_DIR="$DEPLOY_DIR/source"
  DATA_DIR="$DEPLOY_DIR/data"
  ENV_FILE="$DATA_DIR/.env"
  COMPOSE_FILE="$DEPLOY_DIR/compose.yaml"
  exec 9>"$DEPLOY_DIR/.deploy.lock"
  flock --nonblock 9 || die '已有部署正在运行，请等待它完成。'
  WORK_DIR=$(mktemp -d "$DEPLOY_DIR/.deploy-XXXXXX")
  trap cleanup EXIT
  trap 'printf "\n[deploy] 第 %s 行执行失败（退出码 %s）。\n" "$LINENO" "$?" >&2' ERR
  trap 'exit 130' INT
  trap 'exit 143' TERM

  ensure_docker
  check_existing_container
  check_port
  update_source
  prepare_compose
  log "构建 Docker 镜像：${COMMIT:0:12}（首次可能需要数分钟）"
  compose_file "$WORK_DIR/next-compose.yaml" build --pull "$SERVICE_NAME"
  configure_firewall

  # 构建期间保留旧服务，只有构建成功后才切换。
  mkdir -p "$DATA_DIR/auth" "$DATA_DIR/runtime"
  chmod 700 "$DATA_DIR" "$DATA_DIR/auth" "$DATA_DIR/runtime"
  REPLACING=true
  if [[ $PREVIOUS_KIND == legacy ]]; then
    log '迁移旧版容器到 Docker Compose'
    docker stop --time 20 "$PREVIOUS_ID" >/dev/null
    docker rename "$PREVIOUS_ID" "$CONTAINER_NAME-previous-$$"
  elif [[ $PREVIOUS_KIND == compose ]]; then
    compose stop --timeout 20 "$SERVICE_NAME"
  fi
  configure_app
  COMPOSE_CHANGED=true
  mv "$WORK_DIR/next-compose.yaml" "$COMPOSE_FILE"
  log "使用 Docker Compose 启动服务：$HOST_PORT -> 8017"
  if ! compose up --detach --no-build --pull never --force-recreate --wait --wait-timeout 90 "$SERVICE_NAME"; then
    compose logs --no-color --tail 80 "$SERVICE_NAME" >&2 || true
    die 'Compose 启动或健康检查失败，尝试恢复原有部署。'
  fi
  if ! wait_ready; then
    compose logs --no-color --tail 80 "$SERVICE_NAME" >&2 || true
    die '新容器未通过启动检查，尝试恢复旧容器；持久化数据会保留。'
  fi
  SUCCEEDED=true
  if [[ $PREVIOUS_KIND == legacy ]]; then
    docker rm "$PREVIOUS_ID" >/dev/null || log '旧容器清理失败，新服务已启动，可稍后手动清理旧容器。'
  fi
  show_result
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
