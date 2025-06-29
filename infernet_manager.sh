#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

RED='\e[0;31m'
GREEN='\e[0;32m'
YELLOW='\e[0;33m'
BLUE='\e[0;34m'
CYAN='\e[0;36m'
WHITE='\e[1;37m'
BOLD='\e[1m'
NC='\e[0m'

trap 'echo -e "${RED}❌ Error on line ${BASH_LINENO[0]}${NC}"' ERR

NODE_TAG="1.4.0"
HELLO_TAG="1.0.0"
REPO_DIR="$HOME/infernet-container-starter"
COMPOSE_BIN="/usr/local/bin/docker-compose"

ask_nonempty() {
  local __var=$1 prompt=$2 val
  while :; do
    read -e -p "$(echo -e "${BOLD}${YELLOW}${prompt}${NC}")" val
    [[ -n "${val// }" ]] && { printf -v "$__var" '%s' "$val"; break; }
    echo -e "${RED}Value cannot be empty.${NC}"
  done
}

normalize_key() {
  local pk=$1
  [[ $pk =~ ^0x?[0-9a-fA-F]{64}$ ]] || return 1
  [[ $pk =~ ^0x ]] && echo "$pk" || echo "0x$pk"
}

install_deps() {
  echo -e "${BLUE}${BOLD}\nInstalling packages...${NC}"
  sudo apt update && sudo apt upgrade -y
  sudo apt -qy install curl git jq lz4 build-essential screen docker.io

  echo -e "${BLUE}Installing docker-compose...${NC}"
  sudo curl -L "https://github.com/docker/compose/releases/download/v2.29.2/docker-compose-$(uname -s)-$(uname -m)" -o $COMPOSE_BIN
  sudo chmod +x $COMPOSE_BIN

  DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
  mkdir -p "$DOCKER_CONFIG/cli-plugins"
  curl -SL https://github.com/docker/compose/releases/download/v2.20.2/docker-compose-linux-x86_64 -o "$DOCKER_CONFIG/cli-plugins/docker-compose"
  chmod +x "$DOCKER_CONFIG/cli-plugins/docker-compose"

  docker compose version && echo -e "${GREEN}docker compose installed${NC}"

  sudo usermod -aG docker "$USER"
  echo -e "${YELLOW}Please reboot the server before continuing.${NC}"
}

install_node() {
  echo -e "${BLUE}${BOLD}\nCloning starter repository...${NC}"
  git clone https://github.com/ritual-net/infernet-container-starter "$REPO_DIR" 2>/dev/null || true
  cd "$REPO_DIR"

  echo -e "${BLUE}Starting screen session 'ritual' to deploy containers...${NC}"
  screen -S ritual -dm bash -c "docker pull ritualnetwork/hello-world-infernet:latest && project=hello-world make deploy-container && exec bash"
  sleep 5

  echo -e "${GREEN}Containers started. Current list:${NC}"
  docker container ls
}

configure_node() {
  local rpc_url pk_raw pk reg
  read -e -p "$(echo -e "${BOLD}${YELLOW}Enter RPC URL [https://mainnet.base.org/]: ${NC}")" rpc_url
  rpc_url=${rpc_url:-https://mainnet.base.org/}
  echo -e "${YELLOW}Using RPC provider: $rpc_url (Alchemy recommended)${NC}"

  while :; do
    ask_nonempty pk_raw "Enter private key (with 0x): "
    if pk=$(normalize_key "$pk_raw"); then break; fi
    echo -e "${RED}Invalid key format.${NC}"
  done

  read -e -p "$(echo -e "${BOLD}${YELLOW}Enter registry address [0x3B1554f346DFe5c482Bb4BA31b880c1C18412170]: ${NC}")" reg
  reg=${reg:-0x3B1554f346DFe5c482Bb4BA31b880c1C18412170}

  for cfg in "$REPO_DIR/deploy/config.json" "$REPO_DIR/projects/hello-world/container/config.json"; do
    [[ -f $cfg ]] || continue
    tmp=$(mktemp)
    jq --arg rpc "$rpc_url" --arg pk "$pk" --arg reg "$reg" \
       '.chain.rpc_url=$rpc | .chain.wallet.private_key=$pk | .chain.registry_address=$reg | .chain.trail_head_blocks=3 | .chain.snapshot_sync.sleep=3 | .chain.snapshot_sync.starting_sub_id=245000 | .chain.snapshot_sync.batch_size=500 | .chain.snapshot_sync.sync_period=30' "$cfg" >"$tmp"
    mv "$tmp" "$cfg"
  done

  sed -i "s|^sender := .*|sender := $pk|" "$REPO_DIR/projects/hello-world/contracts/Makefile"
  sed -i "s|^RPC_URL := .*|RPC_URL := $rpc_url|" "$REPO_DIR/projects/hello-world/contracts/Makefile"
  sed -i "s|0x[0-9a-fA-F]\{40\}|$reg|" "$REPO_DIR/projects/hello-world/contracts/script/Deploy.s.sol"
  sed -i "s|ritualnetwork/infernet-node:.*|ritualnetwork/infernet-node:${NODE_TAG}|" "$REPO_DIR/deploy/docker-compose.yaml"

  for c in infernet-anvil hello-world infernet-node infernet-fluentbit infernet-redis; do
    docker restart "$c"
    sleep 3
  done
  echo -e "${GREEN}Configuration applied and containers restarted.${NC}"
}

deploy_and_call() {
  echo -e "${BLUE}${BOLD}\nInstalling Foundry...${NC}"
  curl -L https://foundry.paradigm.xyz | bash
  source "$HOME/.bashrc"
  foundryup

  cd "$REPO_DIR/projects/hello-world/contracts"
  rm -rf lib
  forge install --no-commit foundry-rs/forge-std
  forge install --no-commit ritual-net/infernet-sdk
  foundryup

  echo -e "${BLUE}Deploying contracts...${NC}"
  cd "$REPO_DIR"
  project=hello-world make deploy-contracts

  echo -e "${BLUE}Enter deployed SaysGM address:${NC}"
  read -e says
  sed -E -i "s|(SaysGM saysGm = SaysGM\().*?\)|\1${says})|" "$REPO_DIR/projects/hello-world/contracts/script/CallContract.s.sol"
  project=hello-world make call-contract
}

check_health() {
  curl -s localhost:4000/health | jq . || echo -e "${RED}Health endpoint not ready${NC}"
}

restart_node() {
  for c in infernet-anvil hello-world infernet-node infernet-fluentbit infernet-redis; do
    docker restart "$c"
    sleep 3
  done
  echo -e "${GREEN}Containers restarted.${NC}"
}

uninstall_node() {
  docker compose -f "$REPO_DIR/deploy/docker-compose.yaml" down || true
  docker image ls -a | grep infernet | awk '{print $3}' | xargs -r docker rmi -f
  rm -rf "$REPO_DIR" "$HOME/foundry" "$HOME/.foundry"
  echo -e "${GREEN}Infernet node removed.${NC}"
}

menu() {
  printf "\n${BOLD}${WHITE}╭━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╮${NC}\n"
  printf "${BOLD}${WHITE}│       🚀 RITUAL NODE MANAGER      │${NC}\n"
  printf "${BOLD}${WHITE}╰━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╯${NC}\n\n"
  printf "${WHITE}[${CYAN}1${WHITE}] ${GREEN}➜${NC} Install dependencies\n"
  printf "${WHITE}[${CYAN}2${WHITE}] ${GREEN}➜${NC} Install node\n"
  printf "${WHITE}[${CYAN}3${WHITE}] ${GREEN}➜${NC} Configure node\n"
  printf "${WHITE}[${CYAN}4${WHITE}] ${GREEN}➜${NC} Deploy & call contract\n"
  printf "${WHITE}[${CYAN}5${WHITE}] ${GREEN}➜${NC} Check node health\n"
  printf "${WHITE}[${CYAN}6${WHITE}] ${GREEN}➜${NC} Restart node\n"
  printf "${WHITE}[${CYAN}7${WHITE}] ${GREEN}➜${NC} Uninstall node\n"
  printf "${WHITE}[${CYAN}8${WHITE}] ${GREEN}➜${NC} Exit\n"
}

while true; do
  clear
  menu
  read -p "$(echo -e "${BOLD}${BLUE}Select action [1-8]: ${NC}")" choice
  case $choice in
    1) install_deps ;;
    2) install_node ;;
    3) configure_node ;;
    4) deploy_and_call ;;
    5) check_health ;;
    6) restart_node ;;
    7) uninstall_node ;;
    8) echo -e "${GREEN}Bye!${NC}"; exit 0 ;;
    *) echo -e "${RED}Invalid choice${NC}" ;;
  esac
  echo -e "\nPress Enter to continue..."; read
done

