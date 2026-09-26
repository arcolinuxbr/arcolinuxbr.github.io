#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# AUTOMATIZADOR DE GERAÇÃO DE ISO - PENGUINS-EGGS
# =============================================================================

EGGS_CONF="/etc/penguins-eggs.d/eggs.yaml"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
NC='\033[0m'

info()  { printf '%b\n' " ${BLUE}[INFO]${NC}  $*"; }
ok()    { printf '%b\n' " ${GREEN}[OK]${NC}  $*"; }
warn()  { printf '%b\n' " ${YELLOW}[AVISO]${NC}  $*"; }
error() { printf '%b\n' " ${RED}[ERRO]${NC}  $*" >&2; }
die()   { error "$*"; exit 1; }

# Verificar se o executável 'eggs' existe no sistema
if ! command -v eggs >/dev/null 2>&1; then
    die "O 'eggs' não foi encontrado. Certifique-se de que ele foi instalado corretamente."
fi

# =============================================================================
# COLETAR DADOS DO USUÁRIO
# =============================================================================
clear
echo "======================================================================"
echo "          CONFIGURADOR E GERADOR DE ISO - PENGUINS-EGGS"
echo "======================================================================"
echo

# 1. Escolha do tipo de imagem (Distro limpa vs Backup completo)
echo -e "${CYAN}Selecione o tipo de imagem que deseja criar:${NC}"
echo "  1) Imagem de Distribuição (Distribuição limpa, sem dados pessoais/home)"
echo "  2) Backup do Sistema (Inclui dados pessoais, arquivos da home e configurações)"
read -rp "Opção (1 ou 2): " TIPO_OPCAO

case "${TIPO_OPCAO}" in
    1) TIPO_MODO="distro" ;;
    2) TIPO_MODO="clone" ;;
    *) die "Opção inválida selecionada." ;;
esac

# 2. Prefixo da ISO
echo
read -rp "Prefixo/Nome da ISO (ex: arco-linux): " ISO_PREFIX
if [[ -z "${ISO_PREFIX}" ]]; then
    die "O prefixo da ISO não pode ser vazio."
fi
ISO_PREFIX="${ISO_PREFIX%.iso}"

# 3. Nome da Distribuição
echo
read -rp "Nome da Distribuição (ex: Arco Linux): " DISTRO_NAME
if [[ -z "${DISTRO_NAME}" ]]; then
    DISTRO_NAME="Arco Linux"
fi

# 4. Nome do Usuário Live
echo
read -rp "Nome do Usuário Live [Padrão: live]: " USER_NAME
USER_NAME="${USER_NAME:-live}"

# 5. Senha do Usuário Live
echo
read -rp "Senha do Usuário Live [Padrão: live]: " USER_PASS
USER_PASS="${USER_PASS:-live}"

# 6. Senha do Root
echo
read -rp "Senha do Root [Padrão: live]: " ROOT_PASS
ROOT_PASS="${ROOT_PASS:-live}"

# =============================================================================
# CONFIRMAÇÃO DOS DADOS
# =============================================================================
clear
echo "======================================================================"
echo "                      CONFIRMAÇÃO DOS DADOS"
echo "======================================================================"
echo
echo -e " Modo da ISO:            ${GREEN}${TIPO_MODO}${NC}"
echo -e " Nome/Prefixo da ISO:    ${GREEN}${ISO_PREFIX}.iso${NC}"
echo -e " Nome da Distribuição:   ${GREEN}${DISTRO_NAME}${NC}"
echo -e " Usuário Live:           ${GREEN}${USER_NAME}${NC}"
echo -e " Senha Usuário:          ${GREEN}${USER_PASS}${NC}"
echo -e " Senha Root:             ${GREEN}${ROOT_PASS}${NC}"
echo "======================================================================"
echo

read -rp "Os dados acima estão corretos? [S/n]: " CONFIRM
CONFIRM="${CONFIRM:-S}"

if [[ ! "${CONFIRM}" =~ ^[Ss]$ ]]; then
    warn "Operação cancelada pelo usuário."
    exit 0
fi

# =============================================================================
# ATUALIZAÇÃO E LIMPEZA PROFUNDA DO SISTEMA
# =============================================================================
echo
echo "======================================================================"
echo "           ATUALIZAÇÃO E LIMPEZA PROFUNDA DO SISTEMA"
echo "======================================================================"
echo

info "Iniciando atualização completa do sistema..."
sudo pacman -Syu --noconfirm
ok "Sistema atualizado."

info "Verificando e removendo pacotes órfãos (não utilizados)..."
ORPHANS="$(pacman -Qtdq 2>/dev/null || true)"
if [[ -n "${ORPHANS}" ]]; then
    sudo pacman -Rns --noconfirm ${ORPHANS}
    ok "Pacotes órfãos removidos."
else
    ok "Nenhum pacote órfão encontrado."
fi

info "Limpando cache de pacotes do pacman..."
if command -v paccache >/dev/null 2>&1; then
    sudo paccache -r -u -k 0 || true
else
    sudo pacman -Sc --noconfirm || true
fi
ok "Cache de pacotes limpo."

info "Removendo resíduos de kernels não utilizados..."
CURRENT_KERNEL="$(uname -r)"
for module_dir in /usr/lib/modules/*; do
    if [[ -d "${module_dir}" ]]; then
        dir_name="$(basename "${module_dir}")"
        if [[ "${dir_name}" != "${CURRENT_KERNEL}" ]]; then
            # Se a pasta de módulos existe mas o pacote do kernel correspondente não está no pacman, remove resíduos
            if ! pacman -Qo "${module_dir}" >/dev/null 2>&1; then
                info "Removendo módulos residuais inativos: ${dir_name}"
                sudo rm -rf "${module_dir}"
            fi
        fi
    fi
done
ok "Kernels e módulos inativos verificados."

info "Limpando logs antigos do systemd, caches e arquivos temporários..."
sudo journalctl --vacuum-time=1d >/dev/null 2>&1 || true
sudo rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
rm -rf ~/.cache/* 2>/dev/null || true
sudo find /var/log -type f -name "*.log" -exec truncate -s 0 {} + 2>/dev/null || true
sudo find /home /root /etc -type f \( -name "*.bak" -o -name "*~" -o -name "*.old" \) -delete 2>/dev/null || true
ok "Limpeza de arquivos temporários e logs concluída."

# =============================================================================
# APLICAR CONFIGURAÇÕES NO EGGS E GERAR ISO
# =============================================================================
echo
echo "======================================================================"
echo "                     GERANDO A IMAGEM ISO"
echo "======================================================================"
echo

info "Aplicando configurações no penguins-eggs..."

sudo mkdir -p "$(dirname "${EGGS_CONF}")"

sudo bash -c "cat <<EOF > '${EGGS_CONF}'
# Configuração gerada automaticamente pelo script de automação
snapshot:
  basename: '${ISO_PREFIX}'
  distro: '${DISTRO_NAME}'
  user: '${USER_NAME}'
  user_opt: '${USER_PASS}'
  root_opt: '${ROOT_PASS}'
EOF"

ok "Configurações gravadas em ${EGGS_CONF}."

echo
info "Iniciando a criação da ISO via 'eggs remaster'..."
echo "----------------------------------------------------------------------"

if [[ "${TIPO_MODO}" == "clone" ]]; then
    sudo eggs remaster --clone
else
    sudo eggs remaster
fi

echo "----------------------------------------------------------------------"
ok "Processo concluído com sucesso! A imagem ISO foi gerada."
