#!/usr/bin/env bash
#
# Arco Linux BR - pós-instalação segura para Arch Linux
# Versão 4.0.0
#
# Executar como usuário normal:
#   chmod +x arco-linux-postinstall-corrigido.sh
#   ./arco-linux-postinstall-corrigido.sh
#
# O script é idempotente: pode ser executado novamente sem apagar perfis Wi-Fi,
# contas, dados pessoais ou configurações que não foram criadas por ele.
#
# Opções:
#   --minimal             somente base, GNOME, rede, áudio e atualizações
#   --with-aur            habilita pacotes AUR opcionais (requer interação mínima)
#   --skip-flatpak        não instala Flatpak/Flathub
#   --skip-virtualization não instala QEMU/libvirt
#   --skip-firewall       não instala nem configura firewalld
#   --no-upgrade          não executa pacman -Syu
#   --help                mostra esta ajuda

set -Eeuo pipefail
IFS=$'\n\t'

VERSION='4.0.0'
SCRIPT_NAME="$(basename "$0")"
REAL_USER="${SUDO_USER:-${USER:-}}"
REAL_HOME=''
STATE_DIR='/var/lib/arco-linux'
LOG_DIR='/var/log/arco-linux'
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$STATE_DIR/backups/$TIMESTAMP"
LOG_FILE="$LOG_DIR/postinstall-$TIMESTAMP.log"

MINIMAL=0
WITH_AUR=0
SKIP_FLATPAK=0
SKIP_VIRT=0
SKIP_FIREWALL=0
NO_UPGRADE=0

OK=0
WARN=0
FAIL=0

usage() {
  cat <<EOF
Uso: $SCRIPT_NAME [opções]

  --minimal             instala apenas a base essencial
  --with-aur            instala complementos AUR opcionais
  --skip-flatpak        não instala/configura Flatpak
  --skip-virtualization não instala QEMU/libvirt
  --skip-firewall       não instala/configura firewalld
  --no-upgrade          não atualiza o sistema com pacman -Syu
  -h, --help            mostra esta ajuda

O script preserva perfis de rede, arquivos pessoais e configurações externas.
Backups ficam em /var/lib/arco-linux/backups.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --minimal) MINIMAL=1 ;;
    --with-aur) WITH_AUR=1 ;;
    --skip-flatpak) SKIP_FLATPAK=1 ;;
    --skip-virtualization) SKIP_VIRT=1 ;;
    --skip-firewall) SKIP_FIREWALL=1 ;;
    --no-upgrade) NO_UPGRADE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf '[ERRO] Opção desconhecida: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done

info() { printf '[INFO] %s\n' "$*"; }
warn() { WARN=$((WARN + 1)); printf '[WARN] %s\n' "$*" >&2; }
ok() { OK=$((OK + 1)); printf '[ OK ] %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '[ERRO] %s\n' "$*" >&2; }
die() { fail "$*"; printf 'Log: %s\n' "$LOG_FILE" >&2; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

on_error() {
  local code=$?
  set +e
  fail "Falha na linha ${BASH_LINENO[0]:-desconhecida}: ${BASH_COMMAND:-comando desconhecido} (código $code)"
  printf 'Log: %s\n' "$LOG_FILE" >&2
  exit "$code"
}
trap on_error ERR

require_arch_and_sudo() {
  [[ -f /etc/arch-release ]] || die 'Este script é exclusivo para Arch Linux.'
  [[ "$(id -u)" -ne 0 ]] || die 'Execute como usuário normal; o script chama sudo quando necessário.'
  command_exists sudo || die 'sudo não está instalado.'
  sudo -v || die 'Não foi possível autenticar o sudo.'
  REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
  [[ -n "$REAL_HOME" && -d "$REAL_HOME" ]] || die "Não foi possível localizar o home de $REAL_USER."
  [[ "$(id -u "$REAL_USER")" -ge 1000 ]] || die 'A conta precisa ser uma conta humana (UID >= 1000).'
}

setup_logging() {
  sudo install -d -m 0755 "$STATE_DIR" "$STATE_DIR/backups" "$LOG_DIR" "$BACKUP_DIR"
  sudo touch "$LOG_FILE"
  sudo chown "$REAL_USER:$(id -gn "$REAL_USER")" "$LOG_FILE"
  sudo chmod 0640 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  printf '\n=== Arco Linux BR pós-instalação %s — %s ===\n' "$VERSION" "$(date --iso-8601=seconds)"
}

backup_path() {
  local src="$1" dst="$BACKUP_DIR${1}"
  if [[ -e "$src" || -L "$src" ]]; then
    sudo install -d -m 0755 "$(dirname "$dst")"
    sudo cp -a --no-dereference "$src" "$dst"
  fi
}

write_root_file() {
  local dest="$1" mode="$2" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  sudo install -D -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
}

install_packages() {
  # Não usar pacman -Si aqui: gnome e gnome-extra são grupos válidos do Arch,
  # mas não aparecem como pacotes individuais em pacman -Si.
  (($# > 0)) || return 0
  sudo pacman -S --needed --noconfirm "$@"
}

pkg_available() { pacman -Si "$1" >/dev/null 2>&1; }

prepare_system() {
  info 'Instalando ferramentas essenciais.'
  install_packages sudo pacman-contrib base-devel git curl wget rsync unzip zip 7zip \
    bash-completion man-db man-pages texinfo reflector
  if (( NO_UPGRADE == 0 )); then
    info 'Atualizando o sistema com pacman -Syu.'
    sudo pacman -Syu --noconfirm
  fi
  sudo systemctl enable --now fstrim.timer 2>/dev/null || true
  sudo mandb -q 2>/dev/null || true
  ok 'Base do sistema pronta.'
}

configure_network() {
  info 'Instalando e ativando NetworkManager sem apagar perfis existentes.'
  install_packages networkmanager network-manager-applet nm-connection-editor wireless-regdb wpa_supplicant \
    iputils curl bind python
  backup_path /etc/NetworkManager/NetworkManager.conf
  sudo install -d -m 0755 /etc/NetworkManager/conf.d
  write_root_file /etc/NetworkManager/conf.d/90-arco-defaults.conf 0644 <<'CONF'
# Gerado pelo Arco Linux BR. Perfis em system-connections não são removidos.
[main]
dns=systemd-resolved

[device]
wifi.scan-rand-mac-address=yes
CONF
  for service in systemd-networkd.service dhcpcd.service connman.service netctl.service; do
    sudo systemctl disable --now "$service" 2>/dev/null || true
  done
  sudo systemctl unmask NetworkManager.service
  sudo systemctl enable --now NetworkManager.service

  if systemctl cat systemd-resolved.service >/dev/null 2>&1; then
    backup_path /etc/systemd/resolved.conf
    write_root_file /etc/systemd/resolved.conf 0644 <<'CONF'
# Gerado pelo Arco Linux BR.
[Resolve]
FallbackDNS=1.1.1.1 9.9.9.9
DNSSEC=allow-downgrade
DNSOverTLS=no
MulticastDNS=no
LLMNR=no
Cache=yes
DNSStubListener=yes
CONF
    sudo systemctl enable --now systemd-resolved.service
    if [[ -e /etc/resolv.conf || -L /etc/resolv.conf ]]; then backup_path /etc/resolv.conf; fi
    sudo ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  fi
  sudo nmcli connection reload 2>/dev/null || true
  if ! sudo nmcli general status >/dev/null 2>&1; then
    warn 'NetworkManager não respondeu após a configuração; restaurando o serviço e reaplicando a configuração gerenciada.'
    backup_path /etc/NetworkManager/conf.d/90-arco-defaults.conf
    sudo systemctl restart NetworkManager.service
    sleep 3
    sudo nmcli connection reload 2>/dev/null || true
  fi
  sudo nmcli general status >/dev/null 2>&1 || die 'NetworkManager continua sem responder após a correção.'
  ok 'Rede configurada; perfis Wi-Fi existentes foram preservados.'
}

install_gnome() {
  info 'Instalando GNOME, login gráfico e integração de aplicativos.'
  install_packages gnome gnome-extra gdm \
    gnome-software appstream archlinux-appstream-data packagekit \
    gvfs gvfs-mtp gvfs-smb gvfs-dnssd gvfs-wsdd \
    xdg-user-dirs xdg-utils polkit gnome-keyring libsecret seahorse \
    firefox firefox-i18n-pt-br gnome-tweaks gnome-shell-extensions \
    gnome-shell-extension-appindicator file-roller loupe baobab evince \
    gnome-disk-utility gnome-system-monitor gnome-text-editor
  sudo systemctl enable gdm.service
  sudo systemctl enable --now NetworkManager.service
  sudo -u "$REAL_USER" xdg-user-dirs-update 2>/dev/null || true
  sudo -u "$REAL_USER" gsettings set org.gnome.desktop.interface clock-show-weekday true 2>/dev/null || true
  ok 'GNOME e integração desktop instalados.'
}

install_desktop_apps() {
  (( MINIMAL == 1 )) && { info 'Aplicativos extras ignorados (--minimal).'; return; }
  info 'Instalando aplicativos, multimídia, documentos e periféricos.'
  install_packages libreoffice-fresh libreoffice-fresh-pt-br thunderbird \
    vlc rhythmbox gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav \
    pipewire pipewire-alsa pipewire-pulse wireplumber pavucontrol \
    cups cups-pdf cups-pk-helper system-config-printer sane sane-airscan ipp-usb \
    avahi nss-mdns bluez bluez-utils samba smbclient cifs-utils acl \
    gparted remmina deja-dup wine winetricks htop btop fastfetch \
    noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu ttf-liberation ttf-croscore ttf-carlito ttf-caladea \
    papirus-icon-theme
  sudo systemctl enable --now pipewire.socket pipewire-pulse.socket wireplumber.service 2>/dev/null || true
  sudo systemctl enable --now bluetooth.service 2>/dev/null || true
  sudo systemctl enable --now cups.service avahi-daemon.service 2>/dev/null || true
  sudo fc-cache -f 2>/dev/null || true
  ok 'Aplicativos, áudio, Bluetooth, impressão, scanners e fontes preparados.'
}

configure_flatpak() {
  (( MINIMAL == 1 || SKIP_FLATPAK == 1 )) && { info 'Flatpak ignorado.'; return; }
  if ! pkg_available flatpak; then warn 'Flatpak não está disponível no repositório; etapa ignorada.'; return; fi
  sudo pacman -S --needed --noconfirm flatpak
  sudo -u "$REAL_USER" flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || warn 'Não foi possível adicionar Flathub.'
  ok 'Flatpak e Flathub configurados.'
}

configure_firewall() {
  (( MINIMAL == 1 || SKIP_FIREWALL == 1 )) && { info 'Firewall ignorado.'; return; }
  if ! pkg_available firewalld; then warn 'firewalld não está disponível no repositório; etapa ignorada.'; return; fi
  sudo pacman -S --needed --noconfirm firewalld
  sudo systemctl enable --now firewalld.service
  sudo firewall-cmd --set-default-zone=public >/dev/null 2>&1 || true
  sudo firewall-cmd --permanent --zone=public --add-service=samba >/dev/null 2>&1 || warn 'Não foi possível liberar Samba no firewall.'
  sudo firewall-cmd --permanent --zone=public --add-service=ipp >/dev/null 2>&1 || warn 'Não foi possível liberar IPP no firewall.'
  sudo firewall-cmd --reload >/dev/null 2>&1 || true
  ok 'firewalld ativado; Samba e IPP liberados para a rede local.'
}

configure_virtualization() {
  (( MINIMAL == 1 || SKIP_VIRT == 1 )) && { info 'Virtualização ignorada.'; return; }
  info 'Instalando virtualização opcional.'
  install_packages qemu-desktop qemu-img libvirt virt-manager virt-viewer virt-install \
    gnome-boxes edk2-ovmf swtpm spice-gtk spice-protocol spice-vdagent virtiofsd
  sudo systemctl enable --now libvirtd.service 2>/dev/null || warn 'libvirtd não pôde ser ativado.'
  sudo usermod -aG libvirt,kvm "$REAL_USER" 2>/dev/null || true
  ok 'Virtualização instalada; um novo login pode ser necessário para os grupos.'
}

configure_samba() {
  (( MINIMAL == 1 )) && { info 'Samba ignorado.'; return; }
  info 'Instalando Samba sem compartilhar pastas pessoais automaticamente.'
  if ! command_exists smbpasswd; then install_packages samba smbclient cifs-utils; fi
  backup_path /etc/samba/smb.conf
  write_root_file /etc/samba/smb.conf 0644 <<'CONF'
# Gerado pelo Arco Linux BR. A pasta Pública e as impressoras são compartilhadas
# intencionalmente na rede local; outros arquivos pessoais não são compartilhados.
[global]
    workgroup = WORKGROUP
    server string = Arco Linux BR
    security = user
    map to guest = Bad User
    server min protocol = SMB2_02
    server max protocol = SMB3
    smb ports = 445
    load printers = yes
    printing = cups
    printcap name = cups
    cups options = raw
    disable netbios = yes

[printers]
    comment = Impressoras
    path = /var/spool/samba
    browseable = yes
    printable = yes
    read only = yes
    guest ok = yes
    guest only = yes
    use client driver = yes
CONF
  sudo install -d -m 1777 /var/spool/samba
  testparm -s >/dev/null
  sudo systemctl enable --now smb.service
  ok 'Samba configurado; somente impressoras e a futura pasta Pública serão compartilhadas.'
}

configure_printers() {
  (( MINIMAL == 1 )) && { info 'Compartilhamento de impressoras ignorado.'; return; }
  info 'Ativando compartilhamento simples de impressoras na rede local.'
  install_packages cups cups-pk-helper system-config-printer avahi nss-mdns
  sudo systemctl enable --now cups.service avahi-daemon.service
  if command_exists cupsctl; then
    sudo cupsctl --share-printers || warn 'CUPS não aceitou o compartilhamento; Samba continuará disponível.'
  fi
  sudo systemctl reload smb.service 2>/dev/null || true
  ok 'Impressoras CUPS publicadas pelo Samba para clientes da rede local.'
}

configure_public_share() {
  (( MINIMAL == 1 )) && { info 'Pasta Pública ignorada no modo minimal.'; return; }
  info 'Criando a pasta Pública para compartilhamento consciente na rede local.'
  install_packages samba smbclient acl
  local public_dir="${REAL_HOME}/Público"
  sudo install -d -m 0777 -o "$REAL_USER" -g "$(id -gn "$REAL_USER")" "$public_dir"
  # Permite que o usuário guest atravesse somente o home e acesse a pasta Pública.
  # O conteúdo da pasta é deliberadamente leitura/escrita para os clientes LAN.
  if command_exists setfacl; then
    sudo setfacl -m u:nobody:--x "$REAL_HOME"
    sudo setfacl -m u:nobody:rwx "$public_dir"
    sudo setfacl -d -m u::rwx,u:nobody:rwx,g::rwx,o::rwx,m::rwx "$public_dir"
  else
    warn 'setfacl indisponível; o compartilhamento poderá exigir permissões manuais no home.'
  fi
  backup_path /etc/samba/arco-public-share.conf
  write_root_file /etc/samba/arco-public-share.conf 0644 <<CONF
# Gerado pelo Arco Linux BR. Esta pasta foi criada para compartilhamento intencional.
[Publico-$REAL_USER]
    comment = Pasta Pública de $REAL_USER - leitura e escrita na LAN
    path = $public_dir
    browseable = yes
    guest ok = yes
    guest only = yes
    read only = no
    writable = yes
    force user = $REAL_USER
    create mask = 0666
    force create mode = 0666
    directory mask = 0777
    force directory mode = 0777
    inherit permissions = yes
CONF
  if ! grep -qF 'include = /etc/samba/arco-public-share.conf' /etc/samba/smb.conf; then
    printf '\ninclude = /etc/samba/arco-public-share.conf\n' | sudo tee -a /etc/samba/smb.conf >/dev/null
  fi
  testparm -s >/dev/null
  sudo systemctl reload smb.service 2>/dev/null || sudo systemctl restart smb.service
  ok "Pasta Pública criada: $public_dir (guest LAN com leitura e escrita)."
}

install_aur_optional() {
  if (( WITH_AUR != 1 || MINIMAL == 1 )); then return 0; fi
  command_exists makepkg || { warn 'makepkg não disponível; AUR ignorado.'; return; }
  info 'AUR opcional: instalando somente Extension Manager e fontes Microsoft.'
  local work="$STATE_DIR/build/aur"
  sudo install -d -m 0755 -o "$REAL_USER" -g "$(id -gn "$REAL_USER")" "$work"
  local pkg dir
  for pkg in ttf-ms-fonts; do
    dir="$work/$pkg"
    sudo -u "$REAL_USER" rm -rf "$dir"
    if sudo -u "$REAL_USER" git clone --depth=1 "https://aur.archlinux.org/$pkg.git" "$dir" >/dev/null 2>&1 \
      && (cd "$dir" && sudo -u "$REAL_USER" makepkg -si --needed --noconfirm); then
      ok "AUR instalado: $pkg"
    else
      warn "Falha no AUR para $pkg; o restante continuará." 
    fi
  done
  sudo rm -rf "$work"
}

validate() {
  info 'Executando validações finais.'
  local failed=0
  command_exists nmcli && nmcli general status >/dev/null 2>&1 || { warn 'NetworkManager não respondeu.'; failed=1; }
  systemctl is-enabled gdm.service >/dev/null 2>&1 || warn 'GDM não está habilitado.'
  systemctl is-active --quiet pipewire.service 2>/dev/null || warn 'PipeWire não está ativo nesta sessão; isso é normal antes do login.'
  command_exists testparm && testparm -s >/dev/null 2>&1 || { warn 'Validação do Samba falhou.'; failed=1; }
  command_exists curl && curl -fsS --connect-timeout 5 https://archlinux.org/ >/dev/null || { warn 'Teste HTTP para archlinux.org falhou.'; failed=1; }
  if (( failed == 0 )); then ok 'Validações críticas concluídas.'; else warn 'Há avisos; o sistema não foi alterado de forma destrutiva.'; fi
}

main() {
  require_arch_and_sudo
  setup_logging
  printf 'Usuário: %s\nHome: %s\nBackup: %s\n' "$REAL_USER" "$REAL_HOME" "$BACKUP_DIR"
  prepare_system
  configure_network
  install_gnome
  install_desktop_apps
  configure_flatpak
  configure_firewall
  configure_virtualization
  configure_samba
  configure_public_share
  configure_printers
  install_aur_optional
  validate
  printf '\n=== Concluído ===\n'
  printf 'OK: %d | Avisos: %d | Falhas: %d\n' "$OK" "$WARN" "$FAIL"
  printf 'Log: %s\nBackups: %s\n' "$LOG_FILE" "$BACKUP_DIR"
  printf 'Recomendação: reinicie o sistema para aplicar GDM, grupos e extensões.\n'
}

main "$@"
