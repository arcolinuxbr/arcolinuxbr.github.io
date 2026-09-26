#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# PENGUINS-EGGS - INSTALADOR UNIVERSAL PARA ARCH LINUX
# =============================================================================
#
# EXECUÇÃO:
#     chmod +x instalador-eggs.sh
#     ./instalador-eggs.sh          <-- SEM sudo!
#
# NÃO executar:
#     sudo ./instalador-eggs.sh
#     sudo bash instalador-eggs.sh
#     su -c ./instalador-eggs.sh
#
# O instalador permanece SEMPRE como usuário normal.
# Para operações administrativas utiliza pkexec, que solicita autenticação
# somente quando necessária e executa apenas o comando solicitado.
#
# =============================================================================

PACKAGE="penguins-eggs"
LEGACY_PACKAGE="penguins-eggs-legacy"
OLD_PACKAGE="oa-tools"

REPO_NAME="penguins-eggs"
REPO_URL="http://www.penguins-eggs.net/repos/arch"

TEMP_DIR="/tmp/penguins-eggs-installer-$$"
TEMP_PACMAN_CONF="${TEMP_DIR}/pacman.conf"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
NC='\033[0m'

# =============================================================================
# FUNÇÕES DE MENSAGEM
# =============================================================================
info()  { printf '%b\n' " ${BLUE}[INFO]${NC}  $*"; }
ok()    { printf '%b\n' " ${GREEN}[OK]${NC}  $*"; }
warn()  { printf '%b\n' " ${YELLOW}[AVISO]${NC}  $*"; }
error() { printf '%b\n' " ${RED}[ERRO]${NC}  $*" >&2; }
die()   { error "$*"; exit 1; }

# =============================================================================
# GUARDA: NÃO PERMITIR ROOT
# =============================================================================
if [[ "${EUID}" -eq 0 ]]; then
    error "Este instalador NÃO deve ser executado como root."
    error "Execute como usuário normal:"
    error "    ./instalador-eggs.sh"
    error "O script solicitará autenticação via pkexec quando necessário."
    exit 1
fi

# =============================================================================
# EXECUTAR COM PRIVILÉGIO
# =============================================================================
admin() {
    if ! command -v pkexec >/dev/null 2>&1; then
        die "pkexec não está instalado. Instale polkit antes de continuar:
    sudo pacman -S polkit
Depois execute novamente o instalador (SEM sudo)."
    fi
    pkexec "$@"
}

# =============================================================================
# LIMPEZA
# =============================================================================
cleanup() {
    rm -rf "${TEMP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

# =============================================================================
# TRATAMENTO DE ERRO
# =============================================================================
on_error() {
    local code=$?
    error "Falha na linha ${BASH_LINENO[0]} (código ${code})."
    exit "${code}"
}
trap on_error ERR

# =============================================================================
# DETECÇÃO DO SISTEMA
# =============================================================================
echo
echo "======================================================================"
echo "                  VERIFICANDO SISTEMA"
echo "======================================================================"
echo

if [[ ! -r /etc/os-release ]]; then
    die "Não foi possível ler /etc/os-release."
fi

# shellcheck disable=SC1091
. /etc/os-release

if [[ "${ID:-}" != "arch" ]]; then
    die "Este instalador é destinado ao Arch Linux.
Sistema detectado: ${PRETTY_NAME:-desconhecido}"
fi
ok "Arch Linux confirmado."

ARCH="$(uname -m)"
if [[ "${ARCH}" != "x86_64" ]]; then
    die "Arquitetura não suportada: ${ARCH}"
fi
ok "Arquitetura: x86_64"

if ! command -v pacman >/dev/null 2>&1; then
    die "pacman não encontrado."
fi
ok "pacman encontrado."

if ! command -v pkexec >/dev/null 2>&1; then
    die "pkexec não encontrado. Instale polkit:
    sudo pacman -S polkit"
fi
ok "pkexec encontrado."

# =============================================================================
# DIRETÓRIO TEMPORÁRIO
# =============================================================================
mkdir -p "${TEMP_DIR}"
chmod 700 "${TEMP_DIR}"

# =============================================================================
# ATUALIZAÇÃO DO ARCH
# =============================================================================
echo
echo "======================================================================"
echo "                        ATUALIZANDO O ARCH"
echo "======================================================================"
echo

info "Será solicitada autenticação administrativa."
admin pacman -Syu --noconfirm
ok "Arch Linux atualizado."

# =============================================================================
# DETECTAR INSTALAÇÕES ANTIGAS
# =============================================================================
echo
echo "======================================================================"
echo "                  PROCURANDO INSTALAÇÕES ANTIGAS"
echo "======================================================================"
echo

REMOVE_LIST=()
for pkg in "${PACKAGE}" "${LEGACY_PACKAGE}" "${OLD_PACKAGE}"; do
    if pacman -Q "${pkg}" >/dev/null 2>&1; then
        REMOVE_LIST+=("${pkg}")
    fi
done

if (( ${#REMOVE_LIST[@]} == 0 )); then
    ok "Nenhuma instalação anterior encontrada."
else
    info "Pacotes encontrados:"
    for pkg in "${REMOVE_LIST[@]}"; do
        pacman -Q "${pkg}"
    done
    echo
    info "Removendo instalações anteriores..."
    admin pacman -Rns --noconfirm "${REMOVE_LIST[@]}"
    ok "Instalações anteriores removidas."
fi

# =============================================================================
# LIMPEZA DE RESÍDUOS
# =============================================================================
echo
echo "======================================================================"
echo "                     LIMPEZA DE RESÍDUOS"
echo "======================================================================"
echo

OLD_PATHS=(
    "/etc/penguins-eggs"
    "/etc/penguins-eggs.d"
    "/var/lib/penguins-eggs"
    "/var/cache/penguins-eggs"
    "/var/log/penguins-eggs"
    "/etc/penguins-eggs.conf"
    "/etc/oa-tools.conf"
)

for path in "${OLD_PATHS[@]}"; do
    if [[ -e "${path}" || -L "${path}" ]]; then
        info "Removendo: ${path}"
        admin rm -rf -- "${path}"
    fi
done
ok "Resíduos conhecidos processados."

# =============================================================================
# EXECUTÁVEIS RESIDUAIS
# =============================================================================
OLD_BINARIES=(
    "/usr/local/bin/eggs"
    "/usr/local/bin/oa"
    "/usr/local/bin/coa"
)

for binary in "${OLD_BINARIES[@]}"; do
    if [[ -e "${binary}" || -L "${binary}" ]]; then
        OWNER="$(pacman -Qo "${binary}" 2>/dev/null || true)"
        if [[ -z "${OWNER}" ]]; then
            info "Removendo executável residual: ${binary}"
            admin rm -f -- "${binary}"
        else
            warn "Não removendo arquivo pertencente a pacote:"
            echo "    ${binary}"
            echo "    ${OWNER}"
        fi
    fi
done
ok "Executáveis residuais verificados."

# =============================================================================
# LIMPAR CACHE ANTIGO
# =============================================================================
info "Limpando pacotes antigos do cache..."
admin find /var/cache/pacman/pkg \
    -maxdepth 1 \
    -type f \
    \( \
        -name 'penguins-eggs-*.pkg.tar.*' \
        -o -name 'penguins-eggs-legacy-*.pkg.tar.*' \
        -o -name 'oa-tools-*.pkg.tar.*' \
    \) \
    -delete
ok "Cache antigo processado."

# =============================================================================
# CRIAR PACMAN.CONF TEMPORÁRIO
# =============================================================================
echo
echo "======================================================================"
echo "                REPOSITÓRIO OFICIAL PENGUINS-EGGS"
echo "======================================================================"
echo

info "Criando configuração temporária do pacman..."
cp /etc/pacman.conf "${TEMP_PACMAN_CONF}"
printf '\n%s\n' \
    "[${REPO_NAME}]" \
    "SigLevel = Optional TrustAll" \
    "Server = ${REPO_URL}" \
    >> "${TEMP_PACMAN_CONF}"
ok "Configuração temporária criada."

# =============================================================================
# SINCRONIZAR REPOSITÓRIO
# =============================================================================
info "Sincronizando repositório oficial..."
admin pacman --config "${TEMP_PACMAN_CONF}" -Sy
ok "Repositório sincronizado."

# =============================================================================
# CONSULTAR VERSÃO
# =============================================================================
echo
echo "======================================================================"
echo "                  LOCALIZANDO VERSÃO MAIS RECENTE"
echo "======================================================================"
echo

# LC_ALL=C padroniza as chaves da saída em inglês
PACKAGE_INFO="$(
    LC_ALL=C pacman --config "${TEMP_PACMAN_CONF}" -Si "${PACKAGE}"
)"

if [[ -z "${PACKAGE_INFO}" ]]; then
    die "O repositório não retornou informações sobre ${PACKAGE}."
fi

printf '%s\n' "${PACKAGE_INFO}"

AVAILABLE_VERSION="$(
    printf '%s\n' "${PACKAGE_INFO}" |
    awk -F': ' '/^Version/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}'
)"

if [[ -z "${AVAILABLE_VERSION}" ]]; then
    die "Não foi possível determinar a versão disponível."
fi
echo
ok "Versão encontrada: ${AVAILABLE_VERSION}"

# =============================================================================
# VERIFICAR DEPENDÊNCIAS OBRIGATÓRIAS PROIBIDAS
# =============================================================================
# Extrai estritamente a linha "Depends On" / "Depende de" para não checar "Optional Deps"
REQUIRED_DEPS="$(
    printf '%s\n' "${PACKAGE_INFO}" |
    grep -E '^(Depends On|Depende de)' || true
)"

if printf '%s\n' "${REQUIRED_DEPS}" | grep -qi 'manjaro-tools'; then
    die "ATENÇÃO: o pacote encontrado possui dependência obrigatória de manjaro-tools.
A instalação foi cancelada para impedir a mistura de pacotes Manjaro com Arch Linux."
fi
ok "Nenhuma dependência obrigatória incompatível encontrada."

# =============================================================================
# INSTALAR
# =============================================================================
echo
echo "======================================================================"
echo "                  INSTALANDO PENGUINS-EGGS"
echo "======================================================================"
echo

info "Solicitando autenticação administrativa..."
admin pacman --config "${TEMP_PACMAN_CONF}" -S --needed --noconfirm "${PACKAGE}"
ok "Penguins-Eggs instalado."

# =============================================================================
# REMOVER CONFIGURAÇÃO TEMPORÁRIA
# =============================================================================
rm -f "${TEMP_PACMAN_CONF}"
ok "Configuração temporária removida."

# =============================================================================
# VERIFICAÇÃO FINAL
# =============================================================================
echo
echo "======================================================================"
echo "                      VERIFICAÇÃO FINAL"
echo "======================================================================"
echo

if ! pacman -Q "${PACKAGE}" >/dev/null 2>&1; then
    die "O pacote ${PACKAGE} não está instalado."
fi

INSTALLED_VERSION="$(
    pacman -Q "${PACKAGE}" | awk '{print $2}'
)"
ok "Pacote instalado:"
echo
echo "    ${PACKAGE} ${INSTALLED_VERSION}"
echo

if pacman -Q "${LEGACY_PACKAGE}" >/dev/null 2>&1; then
    die "ERRO: ${LEGACY_PACKAGE} ainda está instalado."
fi
ok "${LEGACY_PACKAGE} não está instalado."

if pacman -Q "${OLD_PACKAGE}" >/dev/null 2>&1; then
    die "ERRO: ${OLD_PACKAGE} ainda está instalado."
fi
ok "${OLD_PACKAGE} não está instalado."

# =============================================================================
# VERIFICAR EXECUTÁVEL
# =============================================================================
hash -r 2>/dev/null || true

EGGS_BIN="$(command -v eggs || true)"
if [[ -z "${EGGS_BIN}" ]]; then
    warn "O binário 'eggs' não foi encontrado no PATH."
else
    ok "Executável encontrado: ${EGGS_BIN}"
fi

echo
echo "======================================================================"
echo "                     INSTALAÇÃO CONCLUÍDA"
echo "======================================================================"
echo
echo "Versão instalada:"
echo "    ${PACKAGE} ${INSTALLED_VERSION}"
echo
echo "Legacy:"
echo "    NÃO instalado"
echo
echo "oa-tools:"
echo "    NÃO instalado"
echo
echo "Execução:"
echo "    Usuário normal"
echo
echo "Privilégios:"
echo "    pkexec somente quando necessário"
echo
echo "======================================================================"
