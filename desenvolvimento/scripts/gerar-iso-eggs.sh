#!/usr/bin/env bash
# penguins-eggs + Calamares para Arch Linux
# Execução normal: ./gerar-iso-eggs.sh
# Remasterização:  ./gerar-iso-eggs.sh --produce
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly EGGS_PACKAGE="penguins-eggs"
readonly OLD_PACKAGES=(penguins-eggs-legacy oa-tools)
readonly EGGS_CONFIG_DIR="/etc/penguins-eggs.d"
readonly EGGS_CUSTOM="${EGGS_CONFIG_DIR}/custom.yaml"
readonly EGGS_EXCLUDE="${EGGS_CONFIG_DIR}/custom.exclude.list"
readonly EGGS_REPO_NAME="penguins-eggs"
readonly EGGS_REPO_URL="https://penguins-eggs.net/basket/repository/arch"
readonly EGGS_KEY_URL="https://penguins-eggs.net/basket/repository/KEY.asc"
readonly EGGS_PACMAN_DROPIN="/etc/pacman.d/penguins-eggs.conf"
readonly EGGS_PACMAN_INCLUDE="Include = ${EGGS_PACMAN_DROPIN}"
readonly EGGS_RELEASE="v26.9.24"
readonly EGGS_RELEASE_ZIP="penguins-eggs-arch.zip"
readonly EGGS_RELEASE_URL="https://github.com/pieroproietti/penguins-eggs/releases/download/${EGGS_RELEASE}/${EGGS_RELEASE_ZIP}"
readonly EGGS_RELEASE_SHA256="0f1389c920ae1b3709e7c52d745c3f9eb0840d7d7a48ee8e3be218a43150c512"
readonly CALAMARES_VERSION="v3.3.14"
readonly CALAMARES_SOURCE_URL="https://github.com/calamares/calamares.git"
readonly TEMP_DIR="$(mktemp -d -p "${TMPDIR:-/tmp}" penguins-eggs-setup.XXXXXX)"

UPDATE=0
INSTALL_CALAMARES=1
PRODUCE=0
COMPRESSION="zstd"
COMPRESSION_LEVEL="3"
LIVE_USER="live"
LIVE_PASSWORD=""
EXCLUDE_FILE=""
ISO_PREFIX=""
SYSTEM_NAME=""
ROOT_PASSWORD=""
ROOT_SHADOW_BACKUP_ACTIVE=0
CALAMARES_SUDO_RULE_ACTIVE=0
readonly CALAMARES_SUDO_RULE="/etc/sudoers.d/99-calamares-live"

restore_root_shadow() {
  if (( ROOT_SHADOW_BACKUP_ACTIVE )); then
    if sudo install -m 600 "$TEMP_DIR/shadow.host.backup" /etc/shadow; then
      ROOT_SHADOW_BACKUP_ACTIVE=0
      ok "Senha root original do sistema hospedeiro restaurada."
    else
      warn "Não foi possível restaurar /etc/shadow automaticamente; restaure-o a partir de $TEMP_DIR/shadow.host.backup."
    fi
  fi
}
remove_calamares_sudo_rule() {
  if (( CALAMARES_SUDO_RULE_ACTIVE )); then
    sudo rm -f -- "$CALAMARES_SUDO_RULE"
    CALAMARES_SUDO_RULE_ACTIVE=0
  fi
}
cleanup() { remove_calamares_sudo_rule; restore_root_shadow; rm -rf -- "${TEMP_DIR}"; }
trap cleanup EXIT
on_error() { local rc=$?; printf '[ERRO] Falha na linha %s (código %s).\n' "${BASH_LINENO[0]:-?}" "$rc" >&2; exit "$rc"; }
trap on_error ERR

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[AVISO] %s\n' "$*" >&2; }
die() { printf '[ERRO] %s\n' "$*" >&2; exit 1; }

ensure_eggs_repository() {
  if [[ ! -f "$EGGS_PACMAN_DROPIN" ]] || ! grep -Fqx "$EGGS_PACMAN_INCLUDE" /etc/pacman.conf; then
    info "${EGGS_PACKAGE} não está configurado; adicionando o repositório oficial via HTTPS..."
    command -v curl >/dev/null 2>&1 || sudo pacman -S --needed --noconfirm curl
    command -v gpg >/dev/null 2>&1 || sudo pacman -S --needed --noconfirm gnupg

    local key_file fingerprint
    key_file="${TEMP_DIR}/penguins-eggs-key.asc"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
      --retry 3 --retry-delay 2 -o "$key_file" "$EGGS_KEY_URL"
    [[ -s "$key_file" ]] || die "A chave GPG do repositório oficial foi baixada vazia."
    fingerprint="$(gpg --batch --show-keys --with-colons "$key_file" | awk -F: '$1 == "fpr" {print $10; exit}')"
    [[ "$fingerprint" =~ ^[[:xdigit:]]{40}$ ]] || die "Não foi possível validar a impressão digital da chave GPG oficial."

    sudo pacman-key --add "$key_file" >/dev/null
    sudo pacman-key --lsign-key "$fingerprint" >/dev/null
    sudo install -d -m 755 /etc/pacman.d
    printf '[%s]\nSigLevel = PackageOptional DatabaseRequired\nServer = %s\n' "$EGGS_REPO_NAME" "$EGGS_REPO_URL" |
      sudo tee "$EGGS_PACMAN_DROPIN" >/dev/null
    if ! grep -Fqx "$EGGS_PACMAN_INCLUDE" /etc/pacman.conf; then
      printf '\n# Repositório oficial do penguins-eggs\n%s\n' "$EGGS_PACMAN_INCLUDE" |
        sudo tee -a /etc/pacman.conf >/dev/null
    fi
  fi

  # O repositório assina o banco, mas atualmente não publica .sig para alguns
  # pacotes (como calamares e ckbcomp). Exigimos o banco assinado sem TrustAll.
  sudo sed -i 's/^SigLevel[[:space:]]*=.*/SigLevel = PackageOptional DatabaseRequired/' "$EGGS_PACMAN_DROPIN"

  # -Syy evita que o pacman use um banco antigo que aponte para um pacote removido.
  sudo pacman -Syy --noconfirm
  pacman -Si "$EGGS_PACKAGE" >/dev/null 2>&1 || die "O repositório oficial foi configurado, mas não publicou ${EGGS_PACKAGE} para esta arquitetura."
  ok "Repositório oficial do eggs configurado com banco assinado."
}

install_eggs_from_official_release() {
  info "Usando o pacote Arch oficial da release ${EGGS_RELEASE} no GitHub..."
  command -v curl >/dev/null 2>&1 || sudo pacman -S --needed --noconfirm curl
  command -v unzip >/dev/null 2>&1 || sudo pacman -S --needed --noconfirm unzip
  local zip_file package_file actual_sha256
  zip_file="${TEMP_DIR}/${EGGS_RELEASE_ZIP}"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --retry 3 --retry-delay 2 -o "$zip_file" "$EGGS_RELEASE_URL"
  actual_sha256="$(sha256sum "$zip_file" | awk '{print $1}')"
  [[ "$actual_sha256" == "$EGGS_RELEASE_SHA256" ]] || die "SHA-256 do asset oficial não confere; download rejeitado."
  unzip -q -j "$zip_file" -d "$TEMP_DIR"
  package_file="$(find "$TEMP_DIR" -maxdepth 1 -type f -name 'penguins-eggs-*.pkg.tar.zst' -print -quit)"
  [[ -n "$package_file" ]] || die "O asset oficial não contém um pacote Arch .pkg.tar.zst."
  sudo pacman -U --needed --noconfirm "$package_file" || die "Falha ao instalar o pacote Arch oficial validado."
  ok "${EGGS_PACKAGE} ${EGGS_RELEASE} instalado a partir do asset oficial verificado."
}

install_system_branding() {
  local branding_dir="${EGGS_CONFIG_DIR}/branding/calamares/branding"
  sudo install -d -m 755 "$branding_dir"
  cat > "$TEMP_DIR/branding.desc.tmpl" <<EOF
---
componentName: eggs
images:
  productIcon: "logo.png"
  productLogo: "logo.png"
  productWelcome: "welcome.png"
slideshow: "show.qml"
slideshowAPI: 1
strings:
  productName: "$SYSTEM_NAME"
  shortProductName: "$SYSTEM_NAME"
  version: "{{ .Version }}"
  shortVersion: "{{ .Version }}"
  versionedName: "$SYSTEM_NAME {{ .Version }}"
  shortVersionedName: "$SYSTEM_NAME {{ .Version }}"
  bootloaderEntryName: "$SYSTEM_NAME"
  productUrl: "{{ .ProductUrl }}"
  supportUrl: "{{ .SupportUrl }}"
  knownIssuesUrl: "{{ .KnownIssuesUrl }}"
  releaseNotesUrl: "{{ .ReleaseNotesUrl }}"
welcomeStyleCalamares: true
EOF
  sudo install -m 644 "$TEMP_DIR/branding.desc.tmpl" "$branding_dir/branding.desc.tmpl"
  ok "Nome do sistema aplicado ao branding do Calamares: $SYSTEM_NAME."
}

prepare_root_password_for_remaster() {
  sudo cp -a -- /etc/shadow "$TEMP_DIR/shadow.host.backup"
  ROOT_SHADOW_BACKUP_ACTIVE=1
  printf 'root:%s\n' "$ROOT_PASSWORD" | sudo chpasswd
  ok "Senha root preparada para ser capturada na ISO; a senha original será restaurada ao terminar."
}

install_calamares_from_source() {
  info "Instalando dependências de compilação do Calamares..."
  sudo pacman -S --needed --noconfirm \
    base-devel git cmake extra-cmake-modules \
    qt6-base qt6-declarative qt6-tools qt6-svg \
    yaml-cpp kconfig kcoreaddons kcrash ki18n kiconthemes \
    kwidgetsaddons kpmcore solid polkit-qt6 hwinfo smartmontools \
    ckbcomp erofs-utils archiso mkinitcpio-archiso

  if pacman -Q calamares >/dev/null 2>&1; then
    info "Removendo o Calamares pré-compilado incompatível com yaml-cpp do Arch..."
    sudo pacman -R --noconfirm calamares
  fi

  local source_dir build_dir
  source_dir="${TEMP_DIR}/calamares-src"
  build_dir="${TEMP_DIR}/calamares-build"
  git clone --depth 1 --branch "$CALAMARES_VERSION" "$CALAMARES_SOURCE_URL" "$source_dir"
  cmake -S "$source_dir" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DWITH_QT6=ON \
    -DBUILD_TESTING=OFF \
    -DWITH_PYTHONQT=OFF
  cmake --build "$build_dir" --parallel "$(nproc)"
  sudo cmake --install "$build_dir"
  sudo ldconfig

  command -v calamares >/dev/null 2>&1 || die "Calamares não foi encontrado após a compilação."
  if ldd "$(command -v calamares)" | grep -q 'not found'; then
    ldd "$(command -v calamares)" >&2
    die "O Calamares compilado ainda possui bibliotecas ausentes."
  fi
  [[ -d /usr/lib/calamares/modules ]] || die "Diretório de módulos do Calamares não existe."
  ok "Calamares ${CALAMARES_VERSION} compilado contra as bibliotecas atuais do Arch."
}

install_calamares_passwordless_policy() {
  local policy_dir="/etc/polkit-1/actions"
  sudo install -d -m 755 "$policy_dir"
  cat > "$TEMP_DIR/calamares-no-password.policy" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC
 "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <vendor>Calamares Live ISO</vendor>
  <vendor_url>https://calamares.io/</vendor_url>
  <action id="com.github.calamares.calamares.pkexec.run">
    <description>Executar o instalador Calamares</description>
    <message>O instalador Calamares está autorizado nesta sessão live</message>
    <icon_name>drive-harddisk</icon_name>
    <defaults>
      <allow_any>no</allow_any>
      <allow_inactive>no</allow_inactive>
      <allow_active>yes</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/bin/calamares</annotate>
    <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
  </action>
</policyconfig>
EOF
  sudo install -m 644 "$TEMP_DIR/calamares-no-password.policy" \
    "$policy_dir/com.github.calamares.calamares.policy"
  ok "Calamares configurado para iniciar na sessão live sem pedir senha."
}

install_calamares_passwordless_sudo() {
  sudo install -d -m 755 /etc/sudoers.d
  printf '%s ALL=(root) NOPASSWD: /usr/bin/calamares\n' "$LIVE_USER" |
    sudo tee "$CALAMARES_SUDO_RULE" >/dev/null
  sudo chmod 440 "$CALAMARES_SUDO_RULE"
  sudo visudo -cf "$CALAMARES_SUDO_RULE" >/dev/null || die "Regra sudo do Calamares inválida."
  CALAMARES_SUDO_RULE_ACTIVE=1
  ok "A ISO permitirá executar calamares sem senha para o usuário ${LIVE_USER}."
}

usage() {
  cat <<EOF
Uso: $SCRIPT_NAME [opções]

Instala/reinstala penguins-eggs, instala o Calamares pelo instalador oficial
integrado do eggs e grava as configurações do remaster.

Opções:
  --update                    Atualiza o Arch com pacman -Syu antes da instalação.
                              Desativado por padrão para evitar atualização parcial.
  --no-calamares              Não instalar o Calamares.
  --user NOME                 Nome do usuário da sessão live (padrão: live).
  --password SENHA            Senha da sessão live (não use em histórico compartilhado).
  --compression ALGORITMO     zstd, xz, lz4 ou gzip (padrão: zstd).
  --level N                   Nível do zstd, de 1 a 19 (padrão: 3).
  --exclude-file ARQUIVO      Substitui a lista de exclusões do eggs por ARQUIVO.
  --produce                   Pergunta modo, prefixo, nome, usuário e senhas;
                              limpa o host e inicia a remasterização. Não atualiza.
  -h, --help                  Mostra esta ajuda.

Exemplos:
  $SCRIPT_NAME
  $SCRIPT_NAME --update --compression zstd --level 6
  $SCRIPT_NAME --produce
EOF
}

while (($#)); do
  case "$1" in
    --update) UPDATE=1 ;;
    --no-calamares) INSTALL_CALAMARES=0 ;;
    --produce) PRODUCE=1 ;;
    --user) (($# >= 2)) || die "--user exige um valor"; LIVE_USER="$2"; shift ;;
    --password) (($# >= 2)) || die "--password exige um valor"; LIVE_PASSWORD="$2"; shift ;;
    --compression) (($# >= 2)) || die "--compression exige um valor"; COMPRESSION="$2"; shift ;;
    --level) (($# >= 2)) || die "--level exige um valor"; COMPRESSION_LEVEL="$2"; shift ;;
    --exclude-file) (($# >= 2)) || die "--exclude-file exige um arquivo"; EXCLUDE_FILE="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opção desconhecida: $1 (use --help)" ;;
  esac
  shift
done

[[ $EUID -ne 0 ]] || die "Execute como usuário normal; o script usa sudo apenas nos comandos administrativos."
command -v sudo >/dev/null || die "sudo não encontrado."
command -v pacman >/dev/null || die "pacman não encontrado: este script é apenas para Arch Linux."
[[ -r /etc/os-release ]] || die "Não foi possível ler /etc/os-release."
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == arch || " ${ID_LIKE:-} " == *" arch "* ]] || die "Sistema não baseado em Arch: ${PRETTY_NAME:-desconhecido}"
[[ "$(uname -m)" == x86_64 ]] || die "Apenas x86_64 é suportado pelo fluxo atual."
[[ "$LIVE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Nome de usuário live inválido: $LIVE_USER"

case "$COMPRESSION" in zstd|xz|lz4|gzip) ;; *) die "Compressão inválida: $COMPRESSION" ;; esac
[[ "$COMPRESSION_LEVEL" =~ ^[0-9]+$ ]] || die "--level deve ser um inteiro."
if [[ "$COMPRESSION" == zstd ]] && (( COMPRESSION_LEVEL < 1 || COMPRESSION_LEVEL > 19 )); then die "Nível zstd deve estar entre 1 e 19."; fi
[[ -z "$EXCLUDE_FILE" || -f "$EXCLUDE_FILE" ]] || die "Arquivo de exclusões não encontrado: $EXCLUDE_FILE"
[[ "$LIVE_PASSWORD" != *$'\n'* && "$LIVE_PASSWORD" != *$'\r'* ]] || die "A senha não pode conter quebras de linha."
yaml_password="${LIVE_PASSWORD:-evolution}"
yaml_password=${yaml_password//\\/\\\\}
yaml_password=${yaml_password//\"/\\\"}

if (( PRODUCE )); then
  echo
  echo "=== Configuração da remasterização ==="
  printf 'Modo da ISO [1=distro limpa, 2=clone/backup] (1): '
  read -r mode_choice
  mode_choice="${mode_choice:-1}"
  case "$mode_choice" in
    1) REMASTER_MODE="distro" ;;
    2) REMASTER_MODE="clone" ;;
    *) die "Modo inválido." ;;
  esac
  read -r -p "Prefixo da ISO: " ISO_PREFIX
  [[ "$ISO_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "Prefixo inválido; use apenas letras, números, ponto, sublinhado ou hífen."
  read -r -p "Nome do Sistema: " SYSTEM_NAME
  system_name_re='^[A-Za-z0-9][A-Za-z0-9 ._-]{0,79}$'
  [[ "$SYSTEM_NAME" =~ $system_name_re ]] || die "Nome do Sistema inválido; use até 80 caracteres sem aspas ou quebras de linha."
  read -r -p "Usuário [${LIVE_USER}]: " input_user
  LIVE_USER="${input_user:-$LIVE_USER}"
  [[ "$LIVE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Nome de usuário live inválido: $LIVE_USER"
  read -r -s -p "Senha do usuário ${LIVE_USER}: " LIVE_PASSWORD
  echo
  [[ -n "$LIVE_PASSWORD" && "$LIVE_PASSWORD" != *$'\n'* && "$LIVE_PASSWORD" != *$'\r'* ]] || die "A senha do usuário não pode ser vazia ou conter quebras de linha."
  read -r -s -p "Senha root da ISO: " ROOT_PASSWORD
  echo
  [[ -n "$ROOT_PASSWORD" && "$ROOT_PASSWORD" != *$'\n'* && "$ROOT_PASSWORD" != *$'\r'* ]] || die "A senha root não pode ser vazia ou conter quebras de linha."
  info "O usuário ${LIVE_USER} será criado com o grupo wheel (sudo) na ISO."
  warn "A senha root do host será alterada somente durante a remasterização e restaurada automaticamente ao terminar."
  read -r -p "Confirma a configuração e a remasterização? [S/n] " confirmation
  [[ "${confirmation:-S}" =~ ^[Ss]$ ]] || { info "Operação cancelada."; exit 0; }
  yaml_password="$LIVE_PASSWORD"
  yaml_password=${yaml_password//\\/\\\\}
  yaml_password=${yaml_password//\"/\\\"}
fi

sudo -v

if (( UPDATE )); then
  info "Atualizando o Arch (opção explicitamente solicitada)..."
  sudo pacman -Syu --noconfirm
  ok "Arch atualizado."
else
  warn "Atualização do sistema não foi executada; use --update somente após snapshot/backup."
fi

info "Removendo pacotes antigos conhecidos do eggs..."
remove=()
for pkg in "$EGGS_PACKAGE" "${OLD_PACKAGES[@]}"; do
  if pacman -Q "$pkg" >/dev/null 2>&1; then remove+=("$pkg"); fi
done
if ((${#remove[@]})); then sudo pacman -R --noconfirm "${remove[@]}"; ok "Pacotes antigos removidos."; else ok "Nenhum pacote antigo instalado."; fi

# Backup antes de remover a configuração antiga; depois o script cria configuração limpa.
backup="/var/backups/penguins-eggs-$(date +%Y%m%d-%H%M%S)"
if [[ -e /etc/penguins-eggs || -e /etc/penguins-eggs.d || -e /etc/penguins-eggs.conf ]]; then
  sudo install -d -m 700 "$backup"
  for path in /etc/penguins-eggs /etc/penguins-eggs.d /etc/penguins-eggs.conf; do
    [[ -e "$path" || -L "$path" ]] && sudo cp -a -- "$path" "$backup/"
  done
  ok "Configuração anterior preservada em $backup."
  sudo rm -rf -- /etc/penguins-eggs /etc/penguins-eggs.d /etc/penguins-eggs.conf
fi

# Não usa HTTP, TrustAll, pacote CachyOS fixo ou hash congelado. O pacote deve
# vir de um repositório Arch configurado/sinado pelo usuário ou pela instalação oficial.
info "Instalando a versão atual assinada disponível nos repositórios Arch configurados..."
ensure_eggs_repository
if ! sudo pacman -S --needed --noconfirm "$EGGS_PACKAGE"; then
  warn "O repositório oficial anunciou o pacote, mas não entregou o arquivo; usando o asset oficial da release verificada."
  install_eggs_from_official_release
fi
command -v eggs >/dev/null 2>&1 || die "O pacote foi instalado, mas o executável eggs não está no PATH."
ok "$(eggs version 2>/dev/null || pacman -Q "$EGGS_PACKAGE")"

sudo install -d -m 755 "$EGGS_CONFIG_DIR"
cat > "$TEMP_DIR/custom.yaml" <<EOF
# Gerado por $SCRIPT_NAME em $(date -Is)
# Consulte: eggs config / eggs --help
remaster:
  user: "$LIVE_USER"
  password: "$yaml_password"
  iso_prefix: "$ISO_PREFIX"
  compression:
    algorithm: "$COMPRESSION"
    level: $COMPRESSION_LEVEL
EOF
sudo install -m 600 "$TEMP_DIR/custom.yaml" "$EGGS_CUSTOM"

if [[ -n "$EXCLUDE_FILE" ]]; then
  sudo install -m 644 "$EXCLUDE_FILE" "$EGGS_EXCLUDE"
elif [[ ! -e "$EGGS_EXCLUDE" ]]; then
  sudo install -m 644 /dev/null "$EGGS_EXCLUDE"
fi
ok "Configuração gravada em $EGGS_CUSTOM."

if (( INSTALL_CALAMARES )); then
  install_calamares_from_source
  install_calamares_passwordless_policy
  module_count="$(find /usr/lib/calamares/modules -type f \( -name '*.so' -o -name '*.qml' \) 2>/dev/null | wc -l)"
  (( module_count > 0 )) || die "Nenhum módulo do Calamares foi detectado."
  ok "Calamares instalado com $module_count arquivos de módulo e sem autenticação Polkit na sessão live."
fi

if (( PRODUCE )); then
  info "Executando limpeza oficial do eggs antes da remasterização..."
  sudo eggs tools clean -v
  ok "Sistema limpo pelo eggs."
  install_system_branding
  warn "A pasta /home/eggs será removida para eliminar artefatos antigos e recriada vazia pelo eggs."
  sudo rm -rf -- /home/eggs
  sudo install -d -m 755 /home/eggs
  ok "/home/eggs recriada vazia."
  prepare_root_password_for_remaster
  install_calamares_passwordless_sudo
  if [[ "$REMASTER_MODE" == clone ]]; then
    info "Iniciando remasterização em modo clone, preservando home e usuários."
    sudo eggs remaster --clone
  else
    info "Iniciando remasterização em modo distribuição limpa."
    sudo eggs remaster
  fi
else
  cat <<EOF

Instalação concluída.

Para revisar/alterar as configurações:
  sudo eggs config

Para limpar e criar uma ISO com confirmação interativa:
  ./$SCRIPT_NAME --produce

A limpeza é feita imediatamente antes da remasterização. A atualização do Arch
fica desativada por padrão para evitar o risco de um upgrade rolling release
interrompido no meio do processo.
EOF
fi
