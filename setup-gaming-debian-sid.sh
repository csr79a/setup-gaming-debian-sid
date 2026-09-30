#!/usr/bin/env bash
#
# setup-gaming-debian-sid.sh
#
# Instala y optimiza Debian Sid (Unstable) / KDE Plasma para jugar: Steam,
# ProtonPlus (gestor de builds de Proton-GE), Heroic Games Launcher (con
# auto-actualización), GameMode, MangoHud (compilado desde fuente con
# soporte NVML para GPUs NVIDIA) + MangoJuice como GUI de configuración
# (Flatpak, opcional: se pregunta), Winetricks y Protontricks (paquetes nativos de Debian) para
# aplicar workarounds de Wine a juegos vía Proton, configuración automática
# de pci_dev en MangoHud.conf para GPUs híbridas, herramientas de
# diagnóstico (mesa-utils) y algunos ajustes del sistema recomendados para
# juegos modernos. Además, ntsync se carga automáticamente en cada arranque,
# y Lutris y Gamescope se ofrecen como pasos opcionales.
#
# Equivalente al proyecto setup-gaming-fedora, adaptado a las herramientas
# reales disponibles en Debian: donde el paquete de Debian está muy
# desactualizado, no existe, o (como con MangoHud) carece de capacidades
# necesarias, se usa Flatpak o compilación desde fuente; donde sí hay una
# vía nativa y actualizada y suficiente (Steam, GameMode, Heroic), se usa
# esa.
#
# Nota sobre MangoHud: el paquete `mangohud` de los repos de Debian es la
# build DFSG (Debian Free Software Guidelines), compilada SIN soporte NVML
# (la librería propietaria de NVIDIA necesaria para leer % de uso, VRAM y
# temperatura de GPUs NVIDIA). Si tienes una GPU NVIDIA, ese paquete jamás
# va a mostrar esos datos, aunque el resto del overlay funcione. Por eso
# este script compila MangoHud desde fuente con -Dwith_nvml=enabled.
#
# Uso:
#   chmod +x setup-gaming-debian-sid.sh
#   ./setup-gaming-debian-sid.sh
#
# Es complementario a setup-debian-sid.sh. Repite ejecución: el script es
# idempotente.

set -uo pipefail

# ---------------------------------------------------------------------------
# Utilidades de salida
# ---------------------------------------------------------------------------
COLOR_RESET="\e[0m"
COLOR_GREEN="\e[32m"
COLOR_YELLOW="\e[33m"
COLOR_RED="\e[31m"
COLOR_BLUE="\e[34m"

log_info()  { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"; }
log_ok()    { echo -e "${COLOR_GREEN}[ OK ]${COLOR_RESET} $*"; }
log_warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"; }
log_err()   { echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} $*"; }
log_step()  { echo -e "\n${COLOR_BLUE}==>${COLOR_RESET} \e[1m$*${COLOR_RESET}"; }

# ---------------------------------------------------------------------------
# Limpieza centralizada de temporales (.deb descargados, build_dir de
# MangoHud) -- registrados aquí para que se borren pase lo que pase:
# terminación normal, error, o Ctrl+C a mitad de la compilación. Antes,
# la limpieza dependía de un 'rm -f/-rf' puntual en cada 'return' de cada
# función: si el usuario interrumpía el script con Ctrl+C durante 'ninja
# install' o durante una descarga, ese rm nunca se ejecutaba y quedaban
# directorios temporales (potencialmente varios cientos de MB, en el caso
# del build_dir de MangoHud) sin borrar en /tmp.
TMP_PATHS=()

# Estado de la oferta opcional de MangoJuice, para las verificaciones finales:
# no_ofrecido | sin_flatpak | instalado | rechazado | fallo_consulta | fallo_instalacion
MANGOJUICE_STATE="no_ofrecido"
register_tmp_path() { TMP_PATHS+=("$1"); }
_cleanup_tmp_paths() {
    local p
    for p in ${TMP_PATHS[@]+"${TMP_PATHS[@]}"}; do
        [[ -n "$p" ]] && rm -rf "$p"
    done
}

require_root_privileges() {
    if [[ "${EUID}" -eq 0 ]]; then
        log_err "No corras este script directamente como root. Ejecútalo como tu usuario normal; se te pedirá la contraseña de sudo cuando haga falta."
        exit 1
    fi
    if ! command -v sudo &>/dev/null; then
        log_err "No se encontró 'sudo'. Instálalo o ejecuta este script con un método equivalente."
        exit 1
    fi
    if ! sudo -v; then
        log_err "No se pudieron obtener privilegios sudo."
        exit 1
    fi

    # Refresca el timestamp de sudo cada 60s mientras dure el script. Sin
    # esto, la compilación de MangoHud (que puede tardar varios minutos)
    # puede hacer que el timestamp de sudo expire a mitad de camino, y el
    # próximo 'sudo ninja install' se quede esperando una contraseña que
    # el usuario ya no está mirando la terminal para escribir.
    ( while true; do sudo -n true 2>/dev/null; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
    SUDO_KEEPALIVE_PID=$!

    # EXIT e INT/TERM tienen semántica distinta: un trap en EXIT se dispara
    # solo al terminar el script (con o sin exit explícito) y no necesita
    # más que eso. Un trap en INT/TERM, en cambio, SOLO ejecuta el bloque
    # que se le da -- si ese bloque no llama a 'exit', la señal queda
    # "absorbida" y el script sigue corriendo en el punto donde estaba,
    # como si Ctrl+C nunca hubiera pasado. Con un único trap combinado
    # 'EXIT INT TERM' sin exit explícito (como estaba antes), Ctrl+C
    # limpiaba los temporales pero el script continuaba de largo hacia el
    # siguiente paso -- exactamente lo opuesto a lo que se buscaba.
    # _on_exit puede correr dos veces si se llega vía _on_interrupt (una
    # vez ahí, otra automática al salir); es inofensivo porque 'rm -rf'
    # sobre algo ya borrado y 'kill' sobre un proceso ya muerto no hacen
    # nada.
    _on_exit() {
        _cleanup_tmp_paths
        [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
        true
    }
    _on_interrupt() {
        _on_exit
        echo
        log_err "Interrumpido por el usuario."
        exit 130
    }
    trap _on_exit EXIT
    trap _on_interrupt INT TERM
}

# Las comprobaciones de este script no usan "cmd | grep -q": con
# 'set -o pipefail', si grep -q sale en cuanto encuentra la coincidencia, el
# comando de la izquierda puede morir por SIGPIPE y toda la tubería se da por
# fallida aunque la coincidencia exista (falso negativo, probado con lsmod).
# En su lugar se captura primero la salida completa y se busca sobre ella.
pkg_installed() {
    [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null)" == "ii "* ]]
}

flatpak_installed() {
    local apps
    apps="$(flatpak list --app --columns=application 2>/dev/null)"
    grep -qFx -- "$1" <<<"$apps"
}

# ---------------------------------------------------------------------------
# 0. Comprobación de prerrequisitos del sistema
# ---------------------------------------------------------------------------
# La mayoría de los pasos de este script son autosuficientes (llaman a apt
# directamente, que resuelve dependencias solo). La excepción es la
# compilación de MangoHud (paso 5), que necesita deb-src habilitado sobre
# un /etc/apt/sources.list.d/debian.sources en formato deb822 apuntando a
# unstable -- lo que deja listo setup-debian-sid.sh.
#
# Igual que en setup-debian-sid.sh (1.2.0), este script SOLO trabaja con
# Sid: se comprueban debian.sources, /etc/apt/sources.list y el resto de
# ficheros *.sources y *.list de /etc/apt/sources.list.d que apunten a
# Debian. Solo se aceptan las suites "unstable" y "sid"; cualquier otra
# (forky, trixie, trixie-security, bookworm, testing, stable...) detiene el
# script sin preguntar. No se convierte ninguna suite automáticamente.
SOURCES_DIR="/etc/apt/sources.list.d"
SOURCES_FILE="${SOURCES_DIR}/debian.sources"
LEGACY_SOURCES="/etc/apt/sources.list"

# Suites de un .sources (debian.sources) que no son unstable ni sid.
_sources_file_bad_suites() {
    awk '/^Suites:/ { for (i = 2; i <= NF; i++) if ($i != "unstable" && $i != "sid") print $i }' "$1" | sort -u
}

# Líneas activas de /etc/apt/sources.list que apuntan a un repositorio de
# Debian con una suite distinta de unstable/sid (cdrom: se ignora).
_legacy_bad_lines() {
    awk '
      /^[[:space:]]*deb(-src)?[[:space:]]/ {
        line = $0
        sub(/^[[:space:]]*deb(-src)?[[:space:]]+/, "", line)
        if (line ~ /^\[/) sub(/^\[[^]]*\][[:space:]]*/, "", line)
        split(line, f, /[[:space:]]+/)
        if (f[1] ~ /^cdrom:/) next
        if (tolower(f[1]) !~ /debian/) next
        if (f[2] != "unstable" && f[2] != "sid") print $0
      }' "$LEGACY_SOURCES"
}

# Entradas de OTROS ficheros de sources.list.d que apuntan al archivo de
# Debian con una suite distinta de unstable/sid. Una entrada cuenta como "de
# Debian" si su URI es de debian.org o si usa debian-archive-keyring; así no
# se marcan repositorios de terceros (Docker, Brave...). Se ignoran las
# entradas con "Enabled: no". Limitación: un mirror con dominio propio y sin
# debian-archive-keyring no se reconoce como Debian.
_other_sources_bad_entries() {
    local f
    for f in "$SOURCES_DIR"/*.sources "$SOURCES_DIR"/*.list; do
        [[ -f "$f" && "$f" != "$SOURCES_FILE" ]] || continue
        case "$f" in
            *.sources)
                awk -v file="$f" '
                  function flush(   j) {
                    if (n > 0 && enabled && isdeb)
                      for (j = 1; j <= n; j++)
                        if (suites[j] != "unstable" && suites[j] != "sid") print file ": Suites: " suites[j]
                    n = 0; enabled = 1; isdeb = 0
                  }
                  BEGIN { enabled = 1 }
                  /^[[:space:]]*$/ { flush(); next }
                  /^#/ { next }
                  /^URIs:/ { if (tolower($0) ~ /[\/.]debian\.org(\/|[[:space:]]|$)/) isdeb = 1 }
                  /^Signed-By:/ { if ($0 ~ /debian-archive-keyring/) isdeb = 1 }
                  /^Enabled:/ { if (tolower($2) == "no" || tolower($2) == "false") enabled = 0 }
                  /^Suites:/ { for (k = 2; k <= NF; k++) suites[++n] = $k }
                  END { flush() }
                ' "$f"
                ;;
            *.list)
                awk -v file="$f" '
                  /^[[:space:]]*deb(-src)?[[:space:]]/ {
                    line = $0; opts = ""
                    sub(/^[[:space:]]*deb(-src)?[[:space:]]+/, "", line)
                    if (line ~ /^\[/) { opts = line; sub(/\].*$/, "]", opts); sub(/^\[[^]]*\][[:space:]]*/, "", line) }
                    split(line, f2, /[[:space:]]+/)
                    if (f2[1] ~ /^cdrom:/) next
                    isdeb = (tolower(f2[1]) ~ /[\/.]debian\.org(\/|$)/) || (opts ~ /debian-archive-keyring/)
                    if (isdeb && f2[2] != "unstable" && f2[2] != "sid") print file ": " $0
                  }
                ' "$f"
                ;;
        esac
    done
}

# Muestra las entradas no-Sid encontradas y detiene el script (siempre, sin
# preguntar).
_abort_non_sid() {
    local title="$1" entries="$2"
    log_warn "$title"
    sed 's/^/      · /' <<<"$entries"
    log_err "Este script solo trabaja con Debian Sid (unstable) y no convierte otras suites automáticamente. Corrige o desactiva esas entradas a mano (setup-debian-sid.sh repara 'unstable-updates' en debian.sources) y vuelve a ejecutar el script."
    exit 1
}

check_system_prerequisites() {
    log_step "0/14 · Comprobando prerrequisitos del sistema"

    local bad

    if [[ -f "$SOURCES_FILE" ]]; then
        if [[ -z "$(awk '/^Suites:/ { print $2 }' "$SOURCES_FILE")" ]]; then
            log_err "No se encontró ninguna línea 'Suites:' en ${SOURCES_FILE}, así que no se puede comprobar que los repositorios apunten a unstable/sid. Revisa el fichero y vuelve a ejecutar el script."
            exit 1
        fi
        bad="$(_sources_file_bad_suites "$SOURCES_FILE")"
        [[ -n "$bad" ]] && _abort_non_sid "${SOURCES_FILE} contiene suites que no son unstable/sid:" "$bad"
    fi

    if [[ -f "$LEGACY_SOURCES" ]]; then
        bad="$(_legacy_bad_lines)"
        [[ -n "$bad" ]] && _abort_non_sid "${LEGACY_SOURCES} contiene repositorios activos de Debian que no apuntan a unstable/sid:" "$bad"
    fi

    bad="$(_other_sources_bad_entries)"
    [[ -n "$bad" ]] && _abort_non_sid "Hay otros ficheros en ${SOURCES_DIR} con repositorios de Debian que no apuntan a unstable/sid:" "$bad"

    if [[ ! -f "$SOURCES_FILE" ]]; then
        log_warn "No se encontró ${SOURCES_FILE} (formato deb822), así que no se puede verificar la suite. Este script no requiere haber corrido setup-debian-sid.sh para la mayoría de los pasos (apt resuelve dependencias solo), pero SIN este archivo la compilación de MangoHud con soporte NVML (paso 5) puede fallar por falta de deb-src."
        _confirm_or_exit
    else
        log_ok "Repositorios en formato deb822 apuntando solo a unstable/sid"
    fi
}

# Solo se usa cuando no se puede verificar la suite (falta debian.sources):
# se pide confirmación explícita antes de continuar.
_confirm_or_exit() {
    if [[ ! -t 0 ]]; then
        log_err "No hay una terminal interactiva para confirmar (stdin no es un tty), así que no se puede preguntar. Se cancela por seguridad en vez de asumir una respuesta. Ejecuta el script en una terminal interactiva."
        exit 1
    fi
    read -rp "¿Continuar de todos modos? [s/N]: " respuesta
    if [[ ! "$respuesta" =~ ^[sS]$ ]]; then
        log_err "Cancelado por el usuario."
        exit 1
    fi
}

# Pregunta [s/N] para pasos opcionales. Devuelve 0 solo si se responde s/S;
# sin terminal interactiva devuelve 1 (el paso opcional se omite).
ask_optional() {
    local prompt="$1" respuesta
    if [[ ! -t 0 ]]; then
        log_info "Sin terminal interactiva: se omite el paso opcional (${prompt})"
        return 1
    fi
    read -rp "${prompt} [s/N]: " respuesta
    [[ "$respuesta" =~ ^[sS]$ ]]
}

# ---------------------------------------------------------------------------
# 1. Steam (steam-installer, repositorio oficial de Debian)
# ---------------------------------------------------------------------------
step_steam() {
    log_step "1/14 · Instalando Steam (steam-installer, repositorio oficial de Debian)"

    # No se mezclan los dos empaquetados: si ya está el paquete de Valve
    # (steam-launcher), se respeta tal cual.
    if pkg_installed steam-launcher; then
        log_ok "Steam ya está instalado con el paquete de Valve (steam-launcher); no se mezcla con steam-installer de Debian"
        return
    fi

    local foreign_archs
    foreign_archs="$(dpkg --print-foreign-architectures 2>/dev/null)"
    if ! grep -qx 'i386' <<<"$foreign_archs"; then
        if ! sudo dpkg --add-architecture i386; then
            log_err "No se pudo habilitar la arquitectura i386. Se omite Steam."
            return 1
        fi
        if ! sudo apt update; then
            log_err "Falló 'apt update' después de habilitar la arquitectura i386. Se omite Steam."
            return 1
        fi
    fi

    # steam-installer vive en el componente 'contrib'. Se comprueba antes de
    # instalar para que, si falta, el motivo quede claro.
    if ! apt-cache show steam-installer &>/dev/null; then
        log_err "steam-installer no está disponible en tus repositorios. Vive en el componente 'contrib': comprueba que esté en 'Components:' de ${SOURCES_FILE} y ejecuta 'sudo apt update'. Se omite este paso."
        return 1
    fi

    if pkg_installed steam-installer; then
        log_info "steam-installer ya estaba instalado; se comprueba si hay una versión nueva"
    else
        log_info "Steam mostrará su acuerdo de licencia durante la instalación (pantalla azul en la terminal): léelo y acéptalo para continuar."
    fi

    if ! sudo apt install -y steam-installer; then
        log_err "Falló la instalación de steam-installer. Se omite; el resto del script continúa."
        return 1
    fi

    log_ok "Steam instalado/actualizado (steam-installer). En el primer arranque descargará el cliente de Steam."
}

# ---------------------------------------------------------------------------
# 2. Flatpak + Flathub (por si el proyecto base todavía no lo dejó listo)
# ---------------------------------------------------------------------------
step_ensure_flatpak() {
    log_step "2/14 · Instalando/actualizando Flatpak y Flathub"

    # Sin pre-chequeo 'pkg_installed': 'apt install' sobre un paquete ya
    # instalado es idempotente (no hace nada si ya está en la última
    # versión) y además lo actualiza si hay una versión nueva en el repo
    # -- es la forma correcta de que este paso también sirva como
    # actualización en corridas futuras del script, no solo como
    # instalación inicial.
    if ! sudo apt install -y flatpak; then
        log_err "No se pudo instalar/actualizar flatpak. Los pasos que dependen de él (ProtonPlus, MangoJuice) van a fallar."
        return 1
    fi
    log_ok "flatpak instalado/actualizado"

    if ! flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo; then
        log_err "No se pudo agregar el remoto Flathub. Los pasos que dependen de Flatpak van a fallar."
        return 1
    fi
    log_ok "Flathub configurado"
}

# ---------------------------------------------------------------------------
# 3. ProtonPlus (Flatpak — es el método principal recomendado por el propio proyecto)
# ---------------------------------------------------------------------------
step_protonplus() {
    log_step "3/14 · Instalando/actualizando ProtonPlus (Flatpak)"

    if flatpak_installed com.vysp3r.ProtonPlus; then
        # Ya instalado: 'flatpak update' es el comando correcto para
        # comprobar/aplicar una versión más nueva -- 'flatpak install' no
        # está pensado para eso y en apps ya instaladas no siempre
        # actualiza. Si no hay nada nuevo, flatpak lo dice solo
        # ("Nothing to do") y no hace falta lógica propia para eso.
        if ! flatpak update -y com.vysp3r.ProtonPlus; then
            log_err "Falló la actualización de ProtonPlus. Se omite; el resto del script continúa."
            return 1
        fi
        log_ok "ProtonPlus comprobado/actualizado"
    else
        if ! flatpak install -y flathub com.vysp3r.ProtonPlus; then
            log_err "Falló la instalación de ProtonPlus. Se omite; el resto del script continúa."
            return 1
        fi
        log_ok "ProtonPlus instalado"
    fi
}

# ---------------------------------------------------------------------------
# 4. Heroic Games Launcher (.deb oficial, auto-actualizado desde GitHub)
# ---------------------------------------------------------------------------
step_heroic_launcher() {
    log_step "4/14 · Descargando e instalando/actualizando Heroic Games Launcher"

    if ! command -v curl &>/dev/null; then
        log_info "curl no está instalado; se instala para descargar Heroic desde GitHub"
        if ! sudo apt install -y curl; then
            log_err "No se pudo instalar curl. Se omite este paso."
            return 1
        fi
    fi

    local api_url="https://api.github.com/repos/Heroic-Games-Launcher/HeroicGamesLauncher/releases/latest"
    local deb_url
    deb_url="$(curl -fsSL "$api_url" | grep -oP '"browser_download_url":\s*"\K[^"]*amd64\.deb(?=")' | head -n1)"

    if [[ -z "$deb_url" ]]; then
        log_err "No se pudo obtener la URL del último .deb de Heroic desde GitHub. Se omite este paso."
        return
    fi

    local latest_version
    latest_version="$(echo "$deb_url" | grep -oP 'Heroic-\K[0-9.]+(?=-linux)')"

    if pkg_installed heroic && [[ -n "$latest_version" ]]; then
        local installed_version
        installed_version="$(dpkg-query -W -f='${Version}' heroic 2>/dev/null)"
        # 'dpkg --compare-versions ... ge ...' en vez de comparar strings con
        # '==': la versión instalada (formato completo de dpkg, puede traer
        # sufijos de empaquetado) y la parseada del nombre del .deb de GitHub
        # rara vez son el mismo string aunque sean la misma versión -- con
        # '==' esto forzaba una reinstalación innecesaria en cada corrida.
        # 'ge' en vez de 'eq' además evita "downgradear" si por lo que sea el
        # instalado ya es más nuevo que lo que se ve en el último release.
        if [[ -n "$installed_version" ]] && dpkg --compare-versions "$installed_version" ge "$latest_version"; then
            log_ok "Heroic Games Launcher ya está en la última versión (${installed_version})"
            return
        fi
    fi

    local tmp_deb
    tmp_deb="$(mktemp --suffix=.deb)"
    register_tmp_path "$tmp_deb"
    log_info "Descargando: ${deb_url}"
    if ! curl -fsSL "$deb_url" -o "$tmp_deb"; then
        log_err "No se pudo descargar el .deb de Heroic (revisa conectividad). Se omite este paso."
        rm -f "$tmp_deb"
        return 1
    fi

    if ! sudo apt install -y "$tmp_deb"; then
        log_err "Falló la instalación del .deb de Heroic. Se omite; el resto del script continúa."
        rm -f "$tmp_deb"
        return 1
    fi

    rm -f "$tmp_deb"
    log_ok "Heroic Games Launcher instalado/actualizado (versión ${latest_version:-desconocida})"
}

# ---------------------------------------------------------------------------
# 5. GameMode + MangoHud (compilado desde fuente con NVML) + MangoJuice (Flatpak, opcional)
# ---------------------------------------------------------------------------

# Devuelve 0 (éxito) si el MangoHud instalado en el sistema tiene soporte
# NVML compilado (necesario para leer % de uso / VRAM / temperatura de
# GPUs NVIDIA). El paquete `mangohud` de los repos de Debian NO lo trae.
mangohud_has_nvml() {
    local lib="/usr/lib/x86_64-linux-gnu/mangohud/libMangoHud.so"
    [[ -f "$lib" ]] || return 1

    # Comprobamos varios símbolos característicos de NVML en vez de uno
    # solo. Buscar únicamente "nvmlDeviceGetUtilizationRates" puede dar
    # FALSOS NEGATIVOS: el compilador puede inlinear/reordenar esa
    # referencia puntual según la build, aunque el soporte NVML esté
    # completo (visto en la práctica: build con -Dwith_nvml=enabled sin
    # ese símbolo suelto, pero con el resto de símbolos NVML presentes).
    # "get_instant_metrics_nvml" es una función INTERNA de MangoHud (no
    # solo el nombre de una API de NVIDIA), así que es una señal más
    # confiable de que el backend NVML fue compilado. Con que aparezca
    # cualquiera de estos símbolos alcanza.
    local symbols=(
        "get_instant_metrics_nvml"
        "nvmlDeviceGetUtilizationRates"
        "nvmlInit_v2"
        "nvmlDeviceGetHandleByPciBusId_v2"
    )
    # La salida de 'strings' se captura UNA vez (es enorme): con
    # 'strings | grep -q' y pipefail, grep sale al primer acierto, strings
    # muere por SIGPIPE y la comprobación daba falsos negativos.
    local sym strings_out
    strings_out="$(strings "$lib" 2>/dev/null)"
    for sym in "${symbols[@]}"; do
        if grep -qi -- "$sym" <<<"$strings_out"; then
            return 0
        fi
    done
    return 1
}

# 'mangohud --version' sigue el formato de 'git describe' (vX.Y.Z-N-gHASH,
# y a veces con sufijo -dirty). Esto extrae solo la parte X.Y.Z, para que
# comparar contra un tag limpio (vX.Y.Z) no falle por un sufijo que no
# indica ningún problema real -- evita recompilar en cada ejecución por
# una comparación de string demasiado estricta.
_mangohud_version_base() {
    grep -oP '^v?\K[0-9]+\.[0-9]+\.[0-9]+' <<<"$1" | head -n1
}

# Último tag estable de MangoHud (vX.Y.Z). Vacío si no hay conectividad
# con GitHub. Extractor de valor: nada consulta su código de salida en un
# 'if', así que la tubería con 'head -n1' no tiene el problema de
# SIGPIPE+pipefail que se evita en otras comprobaciones de este script.
_mangohud_latest_tag() {
    git ls-remote --tags --refs --sort=-v:refname \
        https://github.com/flightlessmango/MangoHud.git 'v*' 2>/dev/null \
        | awk '{sub("refs/tags/", "", $2); print $2}' \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
        | head -n1
}

# Compara la versión instalada y la presencia de NVML contra el último tag
# estable. Si no coinciden, recompila MangoHud desde upstream fijando
# exactamente ese tag (nunca el HEAD de la rama de desarrollo, que
# upstream ha roto varias veces con dependencias nuevas sin avisar).
_mangohud_check_and_maybe_recompile() {
    local mangohud_tag="" installed="" installed_base tag_base

    mangohud_tag="$(_mangohud_latest_tag)"
    if command -v mangohud &>/dev/null; then
        installed="$(mangohud --version 2>/dev/null | head -n1)"
    fi

    if [[ -z "$mangohud_tag" ]]; then
        if command -v mangohud &>/dev/null && mangohud_has_nvml; then
            log_warn "No se pudo consultar el último tag estable de MangoHud (¿sin conectividad?). Se deja la versión instalada: ${installed:-desconocida} (con NVML)."
            return 0
        fi
        if ! command -v mangohud &>/dev/null; then
            log_err "No se pudo consultar el último tag estable de MangoHud y no está instalado. Se omite este paso; el resto del script continúa."
        else
            log_err "No se pudo consultar el último tag estable de MangoHud y la build instalada no tiene NVML. Se omite este paso; el resto del script continúa."
        fi
        return 1
    fi

    installed_base="$(_mangohud_version_base "$installed")"
    tag_base="$(_mangohud_version_base "$mangohud_tag")"

    if command -v mangohud &>/dev/null && mangohud_has_nvml \
        && [[ -n "$installed_base" && "$installed_base" == "$tag_base" ]]; then
        log_ok "MangoHud ${mangohud_tag} ya está instalado con NVML"
        return 0
    fi

    log_info "MangoHud requiere instalación/recompilación (objetivo: ${mangohud_tag}, instalado: ${installed:-ninguno})."
    if ! mangohud_has_nvml; then
        log_info "Motivo: falta soporte NVML."
    elif [[ "$installed_base" != "$tag_base" ]]; then
        log_info "Motivo: no coincide con el último tag estable."
    fi

    # Variable global intencionada: step_mangohud_compile_nvml() la usa
    # para clonar exactamente este tag. Es la única función que la llama
    # (comprobado: no aparece en ningún otro sitio del script), así que
    # basta con fijarla justo antes de usarla.
    MANGOHUD_TAG="$mangohud_tag"
    step_mangohud_compile_nvml
}

step_mangohud_compile_nvml() {
    log_info "Compilando MangoHud desde fuente con soporte NVML"

    # Si en algún momento el paquete `mangohud` de apt quedó instalado
    # (por ejemplo de una ejecución vieja del script), lo sacamos primero
    # para que la instalación manual (ninja install) no choque con dpkg.
    if pkg_installed mangohud; then
        log_warn "Se eliminará el paquete Debian de MangoHud (build sin NVML) antes de instalar la versión compilada desde upstream."
        log_warn "Si la compilación falla, MangoHud quedará temporalmente sin instalar."
        if ! sudo apt remove -y mangohud; then
            log_err "No se pudo eliminar el paquete Debian de MangoHud; se omite la compilación para no chocar con dpkg."
            return 1
        fi
    fi

    # Repos de código fuente (formato deb822). A diferencia de un chequeo
    # con un único grep sobre todo el archivo (que se salta el sed entero
    # si CUALQUIER stanza ya tiene "deb deb-src", dejando otras stanzas
    # sin tocar), el sed se aplica siempre: por su propio patrón exacto
    # ('^Types: deb$'), es idempotente -- solo convierte las líneas que
    # todavía dicen solo "Types: deb", nunca toca las que ya tienen
    # "deb deb-src". Así cada stanza se corrige de forma independiente.
    local sources_file="/etc/apt/sources.list.d/debian.sources"
    if [[ -f "$sources_file" ]]; then
        if sudo grep -q '^Types: deb$' "$sources_file"; then
            sudo sed -i '/^Types: deb$/s/^Types: deb$/Types: deb deb-src/' "$sources_file"
            if ! sudo apt update; then
                log_warn "'apt update' falló después de activar deb-src; 'apt build-dep mangohud' puede fallar por índices desactualizados."
            fi
        fi
    else
        log_warn "No se encontró ${sources_file} (formato deb822). No se pudo activar deb-src automáticamente; 'apt build-dep mangohud' puede fallar por falta de fuentes. Revisa que tus repos estén en ese formato (los deja listos setup-debian-sid.sh)."
    fi

    if ! sudo apt build-dep -y mangohud; then
        log_err "'apt build-dep mangohud' falló (probablemente por falta de deb-src o de conectividad). Se aborta la compilación de MangoHud; el resto del script continúa."
        return 1
    fi
    # libcap-dev se instala explícitamente además de build-dep: en la
    # práctica se vio a meson fallar con "Dependency libcap not found"
    # (tried pkg-config and cmake) incluso con libcap-dev instalado y
    # pkg-config encontrándolo bien a mano. No se pudo confirmar la causa
    # exacta (posible PKG_CONFIG_PATH/PKG_CONFIG_LIBDIR contaminado en el
    # entorno), así que además de reinstalar el paquete, la llamada a
    # meson de abajo fuerza un PKG_CONFIG_PATH estándar de Debian.
    #
    # wayland-protocols / libgbm-dev: se instalan explícitamente porque las
    # dependencias de build-dep corresponden al paquete Debian disponible y
    # pueden no cubrir todos los requisitos del tag de MangoHud que se compila.
    # El repositorio se clona fijando MANGOHUD_TAG, por lo que el conjunto de
    # dependencias esperado queda asociado a una versión concreta.
    if ! sudo apt install -y libcap-dev libyaml-cpp-dev libwayland-egl-backend-dev wayland-protocols libgbm-dev; then
        log_err "No se pudieron instalar las dependencias de compilación (libcap-dev/libyaml-cpp-dev/libwayland-egl-backend-dev/wayland-protocols/libgbm-dev). Se aborta la compilación de MangoHud; el resto del script continúa."
        return 1
    fi

    local build_dir
    build_dir="$(mktemp -d)"
    register_tmp_path "$build_dir"
    if ! git clone --recursive --branch "$MANGOHUD_TAG" https://github.com/flightlessmango/MangoHud.git "${build_dir}/MangoHud"; then
        log_err "No se pudo clonar el repositorio de MangoHud (revisa conectividad). Se aborta la compilación; el resto del script continúa."
        rm -rf "$build_dir"
        return 1
    fi
    log_ok "MangoHud ${MANGOHUD_TAG} descargado"

    # Entorno de pkg-config estándar de Debian (multiarch), por si el
    # entorno heredado trae un PKG_CONFIG_PATH/PKG_CONFIG_LIBDIR que
    # confunde la detección de meson (p. ej. apuntando a rutas tipo
    # /usr/lib64, ajenas a Debian).
    local pkgconfig_dirs="/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
    local meson_log="${build_dir}/MangoHud/build/meson-logs/meson-log.txt"

    _mangohud_meson_build() {
        local extra_meson_args=("$@")
        cd "${build_dir}/MangoHud" &&
        PKG_CONFIG_PATH="$pkgconfig_dirs" PKG_CONFIG_LIBDIR="$pkgconfig_dirs" \
            meson setup build --prefix=/usr -Dwith_nvml=enabled -Dwith_x11=enabled -Dwith_wayland=enabled "${extra_meson_args[@]}" &&
        ninja -C build &&
        sudo ninja -C build install
    }

    # Resuelve automáticamente dependencias de meson que falten, del tipo
    # 'Dependency "X" not found'. Aunque MANGOHUD_TAG fija una versión,
    # el conjunto de dependencias de compilación puede diferir del paquete
    # Debian disponible. En vez de mantener una lista fija de paquetes,
    # esta función usa apt-file para localizar el paquete Debian que provee
    # el archivo <dependencia>.pc y lo instala.
    local apt_file_updated=0
    local tried_pkgs=""
    _mangohud_resolve_missing_meson_deps() {
        [[ -f "$meson_log" ]] || return 1

        if ! command -v apt-file &>/dev/null; then
            log_info "Instalando apt-file para poder resolver dependencias de meson automáticamente"
            sudo apt install -y apt-file || return 1
        fi
        if [[ "$apt_file_updated" -ne 1 ]]; then
            log_info "Actualizando índice de apt-file (una sola vez por corrida; puede tardar un rato)"
            sudo apt-file update || log_warn "'apt-file update' falló; la búsqueda puede no encontrar resultados si el índice quedó vacío/desactualizado"
            apt_file_updated=1
        fi

        local missing
        missing="$(grep -oP 'Dependency "\K[a-zA-Z0-9_.+-]+(?=" not found)' "$meson_log" | sort -u)"
        [[ -z "$missing" ]] && return 1

        local dep pkg resolved_any=0
        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            log_info "meson pide la dependencia '${dep}' -- buscando en apt-file qué paquete Debian provee '${dep}.pc'"
            # Restringido a ubicaciones ESTÁNDAR de pkg-config del sistema.
            # Sin este filtro, apt-file puede devolver paquetes que traen
            # su propio '<dep>.pc' privado dentro de un sysroot ajeno
            # (visto en la práctica: 'emscripten' trae un egl.pc propio
            # para compilar a WebAssembly, que nada tiene que ver con el
            # sistema real -- instalarlo no resuelve nada porque meson
            # nunca busca en esa ruta).
            pkg="$(apt-file search -x "/${dep}\.pc\$" 2>/dev/null \
                | grep -E ':[[:space:]]*/?usr/(lib/[^/]+/pkgconfig|lib/pkgconfig|share/pkgconfig)/' \
                | sort -u | head -n1 | cut -d: -f1)"
            if [[ -z "$pkg" ]]; then
                log_warn "No se encontró ningún paquete que provea '${dep}.pc' en una ruta estándar de pkg-config vía apt-file. Esta dependencia hay que resolverla a mano (busca en https://packages.debian.org/search?searchon=contents&keywords=${dep}.pc)."
                continue
            fi
            if [[ " $tried_pkgs " == *" $pkg "* ]]; then
                log_warn "El paquete '${pkg}' ya se había instalado en un intento anterior y meson sigue sin encontrar '${dep}'. No lo vuelvo a instalar -- hace falta revisar esto a mano."
                continue
            fi
            tried_pkgs="$tried_pkgs $pkg"
            log_info "Instalando ${pkg} (provee ${dep}.pc)"
            sudo apt install -y "$pkg" && resolved_any=1
        done <<< "$missing"

        [[ "$resolved_any" -eq 1 ]]
    }

    local attempt=1
    local max_attempts=6
    local build_ok=0
    local build_args=()
    while (( attempt <= max_attempts )); do
        if ( _mangohud_meson_build "${build_args[@]}" ); then
            build_ok=1
            break
        fi

        if (( attempt == 1 )); then
            log_warn "Primer intento de compilación/instalación de MangoHud falló. Volcando diagnóstico de libcap..."
            log_info "pkg-config --modversion libcap: $(pkg-config --modversion libcap 2>&1)"
            log_info "pkg-config --cflags --libs libcap: $(pkg-config --cflags --libs libcap 2>&1)"
            log_info "PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-<vacío>}"
        fi
        build_args=(--wipe)

        log_warn "Intento ${attempt}/${max_attempts} de compilación de MangoHud falló. Buscando dependencias de meson faltantes en el log..."
        if ! _mangohud_resolve_missing_meson_deps; then
            log_err "La compilación/instalación de MangoHud falló (meson/ninja) y no se detectaron (o no se pudieron resolver) más dependencias faltantes en ${meson_log}. Revisa el log para más detalle. Se aborta este paso; el resto del script continúa."
            break
        fi
        ((attempt++))
    done

    unset -f _mangohud_meson_build _mangohud_resolve_missing_meson_deps

    if [[ "$build_ok" -ne 1 ]]; then
        rm -rf "$build_dir"
        return 1
    fi

    rm -rf "$build_dir"

    if mangohud_has_nvml; then
        local installed_now installed_now_base tag_base_final
        installed_now="$(mangohud --version 2>/dev/null | head -n1)"
        installed_now_base="$(_mangohud_version_base "$installed_now")"
        tag_base_final="$(_mangohud_version_base "${MANGOHUD_TAG:-}")"
        if [[ -n "$tag_base_final" && "$installed_now_base" != "$tag_base_final" ]]; then
            log_warn "MangoHud compilado con NVML, pero 'mangohud --version' reporta '${installed_now}' en vez de '${MANGOHUD_TAG}'. La comparación de versiones podría no coincidir con el formato reportado por esa versión de MangoHud; revisa el formato de 'mangohud --version' si vuelve a compilarse en cada ejecución."
        else
            log_ok "MangoHud compilado e instalado con soporte NVML (${installed_now:-$MANGOHUD_TAG})"
        fi
    else
        log_warn "MangoHud se instaló pero no se detectó soporte NVML. Revisa el log de meson si tienes GPU NVIDIA."
    fi
}

# MangoJuice: interfaz gráfica (Flatpak) para configurar MangoHud. Es solo una
# alternativa: se pregunta si se quiere instalar y cada uno decide. Si ya
# está instalado, se actualiza sin preguntar. MangoHud se puede configurar
# igualmente editando ~/.config/MangoHud/MangoHud.conf.
_offer_mangojuice() {
    local app_id="io.github.radiolamp.mangojuice"

    if ! command -v flatpak &>/dev/null; then
        MANGOJUICE_STATE="sin_flatpak"
        log_info "Flatpak no está disponible: se omite la oferta de MangoJuice"
        return 0
    fi

    if flatpak_installed "$app_id"; then
        MANGOJUICE_STATE="instalado"
        if flatpak update -y "$app_id"; then
            log_ok "MangoJuice comprobado/actualizado"
        else
            log_err "Falló la actualización de MangoJuice. Se continúa con la versión ya instalada."
        fi
        return 0
    fi

    if ! flatpak remote-info flathub "$app_id" &>/dev/null; then
        MANGOJUICE_STATE="fallo_consulta"
        log_warn "No se pudo consultar MangoJuice en Flathub (¿sin conexión?). Se omite."
        return 1
    fi

    if ! ask_optional "¿Desea instalar MangoJuice (Flatpak) como interfaz gráfica opcional para MangoHud?"; then
        MANGOJUICE_STATE="rechazado"
        log_info "Se omite MangoJuice"
        return 0
    fi

    if flatpak install -y flathub "$app_id"; then
        MANGOJUICE_STATE="instalado"
        log_ok "MangoJuice instalado (vía Flatpak)"
        log_info "Si no llega a leer/escribir ~/.config/MangoHud por el sandbox, prueba: flatpak override --user --filesystem=xdg-config/MangoHud ${app_id}"
    else
        MANGOJUICE_STATE="fallo_instalacion"
        log_err "Falló la instalación de MangoJuice. Puedes configurar MangoHud.conf a mano."
        return 1
    fi
}

step_gamemode_mangohud() {
    log_step "5/14 · Instalando GameMode y MangoHud (compilado con NVML)"

    if sudo apt install -y gamemode; then
        log_ok "GameMode instalado/actualizado (vía apt)"
    else
        log_err "Falló la instalación/actualización de GameMode. Se continúa sin él (gamemoderun no va a estar disponible)."
    fi

    _mangohud_check_and_maybe_recompile

    _offer_mangojuice

    log_info "Para usarlos, en las opciones de lanzamiento de un juego en Steam pon:"
    log_info "  gamemoderun mangohud %command%"
    log_info "Puedes configurar el overlay de MangoHud editando ~/.config/MangoHud/MangoHud.conf (o con MangoJuice, si lo instalas)."
}

# ---------------------------------------------------------------------------
# 6. Winetricks + Protontricks (paquetes nativos de Debian)
# ---------------------------------------------------------------------------
#
# Ambos están empaquetados de forma nativa en Debian, sin necesidad de
# Flatpak ni compilar nada: winetricks y protontricks viven en el componente
# 'contrib' (protontricks depende de winetricks + python3-pil + python3-vdf,
# que apt resuelve solo). El componente 'contrib' no siempre
# está habilitado en sources.list -- si falta, 'apt install protontricks'
# falla con un genérico "Unable to locate package" que no deja claro que
# la causa es el componente, así que se avisa antes de intentar.
# Debian (wine 10.0~repack-12 y posteriores) ya no instala un lanzador
# /usr/bin/wineserver: el binario real vive dentro de los paquetes de Wine y
# winetricks falla con "wineserver not found!". Si Wine está instalado y
# 'wineserver' no está en el PATH, se crea un enlace en /usr/local/bin hacia
# el binario real y se comprueba que responde. El binario real se busca con
# dpkg (no con una ruta fija, que puede cambiar entre versiones de Debian).
# No se toca nada si ya funciona ni ficheros ajenos.
_ensure_wineserver_in_path() {
    local link="/usr/local/bin/wineserver" real="" candidate dpkg_list version

    if command -v wineserver &>/dev/null && wineserver --version &>/dev/null; then
        log_ok "wineserver ya funciona ($(command -v wineserver))"
        return 0
    fi

    dpkg_list="$(dpkg -L libwine wine64 2>/dev/null)"
    while IFS= read -r candidate; do
        if [[ "${candidate##*/}" == "wineserver" && -f "$candidate" && -x "$candidate" ]]; then
            real="$candidate"
            break
        fi
    done <<<"$dpkg_list"

    if [[ -z "$real" ]]; then
        log_info "No se encontró el binario de wineserver en los paquetes de Wine (¿Wine no está instalado?). Se omite el enlace."
        return 0
    fi

    if [[ -e "$link" && ! -L "$link" ]]; then
        log_warn "${link} existe y no es un enlace: no se toca. Winetricks puede fallar con 'wineserver not found!'."
        return 1
    fi

    log_info "wineserver no está en el PATH; se crea un enlace: ${link} -> ${real}"
    if ! sudo ln -sfn "$real" "$link"; then
        log_err "No se pudo crear el enlace ${link}"
        return 1
    fi
    hash -r

    if version="$(wineserver --version 2>/dev/null)" && [[ -n "$version" ]]; then
        log_ok "wineserver disponible (${version})"
    else
        log_err "El enlace ${link} se creó pero 'wineserver --version' no responde. Comprueba que /usr/local/bin está en tu PATH."
        return 1
    fi
}

# Wine 10 de Debian ejecuta aplicaciones de 32 bits de forma nativa en amd64
# (WoW64), así que wine32:i386 NO es imprescindible. Se intenta instalar, pero
# antes se simula: solo se instala si la simulación no da errores ni elimina
# paquetes. Si en Sid hay un conflicto temporal de dependencias (por ejemplo
# con libsnappy1v5) se informa y se continúa, sin downgrades ni mezclar
# paquetes de otras versiones.

step_winetricks_protontricks() {
    log_step "6/14 · Instalando Winetricks y Protontricks"

    local sources_file="/etc/apt/sources.list.d/debian.sources"
    if [[ -f "$sources_file" ]] && ! grep -qE '^Components:.*\bcontrib\b' "$sources_file"; then
        log_err "No se detectó el componente 'contrib' habilitado en $sources_file. Winetricks y Protontricks viven en 'contrib'. Habilita 'contrib', ejecuta 'sudo apt update' y vuelve a ejecutar este script."
        return 1
    fi

    if sudo apt install -y winetricks protontricks; then
        log_ok "Winetricks y Protontricks instalados/actualizados"
        _ensure_wineserver_in_path
    else
        log_err "Falló la instalación de Winetricks/Protontricks. Se omite; el resto del script continúa."
    fi
}

# ---------------------------------------------------------------------------
# 7. Valores por defecto de ~/.config/gamemode.ini (solo si no existe)
# ---------------------------------------------------------------------------
#
# IMPORTANTE -- por qué "solo si no existe" y no "siempre pisar con estos
# valores": este archivo es una preferencia personal, no algo con un valor
# correcto universal (ver el aviso largo en step_install_game_performance
# sobre por qué "más forzado" no siempre es mejor -- se midió un caso real
# donde SÍ lo era y otro donde NO). Si el script lo pisara en cada corrida,
# cualquier ajuste que hagas a mano después de medir con MangoHud se
# perdería la próxima vez que corras el script -- rompería exactamente el
# tipo de idempotencia que le sirve al usuario (no reinstala lo que ya
# está en su última versión), reemplazándola por una que le sirve al
# script (siempre el mismo resultado, ignorando tus cambios).
#
# Por qué se detecta el gobernador en vez de hardcodear "schedutil":
# probado en la práctica el 17/09/2026 en un Ryzen 7 6800HS con driver
# amd_pstate-epp (modo activo, el default en kernels modernos para CPUs
# AMD recientes) -- ese driver expone ÚNICAMENTE "performance" y
# "powersave" como gobernadores válidos; "schedutil" no existe ahí, y
# gamemoded -t fallaba con "Governor was not set to schedutil (was
# actually powersave)!". No es un error real: bajo amd_pstate en modo
# activo, "powersave" ya es dinámico (el kernel lo traduce a un hint EPP
# y escala en base a carga real, funcionalmente equivalente a schedutil
# en un driver cpufreq clásico) -- pero pedirle al daemon un gobernador
# que no existe en la lista disponible sigue siendo un error evitable.
# Por eso, en vez de asumir "schedutil" siempre, se lee
# scaling_available_governors y se elige: schedutil si está en la lista
# (drivers cpufreq clásicos, ej. acpi-cpufreq, amd_pstate en modo
# passive/guided), si no, powersave (amd_pstate/intel_pstate en modo
# activo, donde powersave YA es la opción dinámica).
#
# Por qué NO se incluye desiredprof: es un bug conocido y abierto en
# GameMode mismo (no del paquete de Debian, no de este equipo) -- se
# ignora silenciosamente incluso usando el gamemode.ini de ejemplo
# oficial del proyecto (FeralInteractive/gamemode issue #539, reproducido
# en GameMode 1.8.2). Incluirlo no rompe nada, pero tampoco hace nada más
# que ensuciar el log con "Config: Value ignored" -- se omite hasta que
# se resuelva río arriba.
_gamemode_pick_governor() {
    local available="" gov_file
    gov_file="/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors"

    if [[ -r "$gov_file" ]]; then
        available="$(cat "$gov_file" 2>/dev/null)"
    fi

    if grep -qw 'schedutil' <<<"$available"; then
        echo "schedutil"
    elif grep -qw 'powersave' <<<"$available"; then
        echo "powersave"
    else
        # No se pudo leer la lista (poco común) -- powersave existe en
        # prácticamente cualquier driver cpufreq de Linux, es la opción
        # más segura como último recurso.
        echo "powersave"
    fi
}

step_gamemode_ini_defaults() {
    log_step "7/14 · Configurando valores por defecto de ~/.config/gamemode.ini"

    local gamemode_ini="${HOME}/.config/gamemode.ini"
    local marker="# gamemode.ini -- configurado por setup-gaming-debian-sid.sh"

    if [[ -f "$gamemode_ini" ]] && grep -qF "$marker" "$gamemode_ini" 2>/dev/null; then
        log_ok "${gamemode_ini} ya estaba configurado por este script, no se toca"
        return
    fi

    if [[ -f "$gamemode_ini" ]]; then
        log_warn "${gamemode_ini} ya existe pero no lo generó este script (no tiene el marcador esperado). Se deja intacto para no pisar tu configuración; revísalo a mano si quieres aplicar un gobernador dinámico tú mismo."
        return
    fi

    local governor
    governor="$(_gamemode_pick_governor)"

    mkdir -p "${HOME}/.config"
    cat > "$gamemode_ini" <<GAMEMODE_INI_EOF
${marker}
[general]
; El kernel decide la frecuencia de CPU según la carga real, en vez de
; que GameMode fuerce un estado fijo mientras el juego está abierto.
; Gobernador elegido automáticamente según lo que ofrece TU driver
; cpufreq (ver scaling_available_governors) -- no es una regla
; universal, mide con MangoHud si te conviene en tu equipo; si ya lo
; tenías puesto en otro valor por algo, no lo pisamos.
desiredgov=${governor}
GAMEMODE_INI_EOF

    log_ok "${gamemode_ini} creado con valores por defecto (desiredgov=${governor}, detectado según tu driver cpufreq)"
}


# En portátiles con GPU híbrida, MangoHud (incluso con NVML) puede fallar
# al leer el % de uso de GPU si no sabe a qué GPU consultar vía NVML.
# Fijar `pci_dev` en MangoHud.conf con el bus-id exacto de la NVIDIA lo
# arregla. Si MangoJuice u otra herramienta añade `gpu_list=` (que
# selecciona por índice DRM, no por PCI), puede pisar el filtrado y
# volver a leer la GPU equivocada.
step_mangohud_pci_dev() {
    log_step "8/14 · Configurando pci_dev de la GPU NVIDIA en MangoHud.conf"

    if ! command -v nvidia-smi &>/dev/null; then
        log_info "No se detectó 'nvidia-smi'; se omite (no hay GPU NVIDIA o falta el driver)"
        return
    fi

    local bus_id
    bus_id="$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null | head -n1)"
    if [[ -z "$bus_id" ]]; then
        log_warn "No se pudo obtener el pci.bus_id vía nvidia-smi. Configura pci_dev manualmente en MangoHud.conf."
        return
    fi

    # nvidia-smi devuelve el bus-id con dominio de 8 dígitos, ej:
    # 00000000:01:00.0 — MangoHud espera el dominio en 4 dígitos, ej:
    # 0000:01:00.0
    local pci_dev
    pci_dev="$(echo "$bus_id" | sed -E 's/^0000([0-9A-Fa-f]{4}:.*)$/\1/')"

    local config_dir="${HOME}/.config/MangoHud"
    local config_file="${config_dir}/MangoHud.conf"
    mkdir -p "$config_dir"
    touch "$config_file"

    if grep -q '^pci_dev=' "$config_file"; then
        sed -i "s/^pci_dev=.*/pci_dev=${pci_dev}/" "$config_file"
        log_ok "pci_dev actualizado a ${pci_dev} en ${config_file}"
    else
        echo "pci_dev=${pci_dev}" >> "$config_file"
        log_ok "pci_dev=${pci_dev} agregado a ${config_file}"
    fi

    if grep -q '^gpu_list=' "$config_file"; then
        log_warn "Se detectó 'gpu_list=' en ${config_file}: en equipos con GPU híbrida puede entrar en conflicto con 'pci_dev' y hacer que MangoHud lea la GPU equivocada. Si el % de GPU sale mal, comenta o borra esa línea."
    fi
}

# ---------------------------------------------------------------------------
# 9. Herramientas de diagnóstico (mesa-utils: glxgears, glxinfo...)
# ---------------------------------------------------------------------------

# No forman parte del setup de gaming en sí; sirven para probar drivers,
# MangoHud, etc. sin depender de abrir un juego completo.
step_diagnostic_tools() {
    log_step "9/14 · Instalando/actualizando herramientas de diagnóstico (mesa-utils)"

    if sudo apt install -y mesa-utils; then
        log_ok "mesa-utils instalado/actualizado (glxgears, glxinfo — útiles para probar drivers/MangoHud rápido)"
    else
        log_err "Falló la instalación/actualización de mesa-utils. No es crítico; el resto del script continúa."
    fi
}

# ---------------------------------------------------------------------------
# 10. vm.max_map_count elevado (recomendado por varios juegos/motores modernos)
# ---------------------------------------------------------------------------
step_max_map_count() {
    log_step "10/14 · Ajustando vm.max_map_count"

    local sysctl_file="/etc/sysctl.d/80-gamecompatibility.conf"
    local sysctl_marker="# vm.max_map_count -- configurado por setup-gaming-debian-sid.sh"

    if [[ -f "$sysctl_file" ]]; then
        if grep -qF "$sysctl_marker" "$sysctl_file" && grep -qE '^vm\.max_map_count=2147483642$' "$sysctl_file"; then
            log_ok "vm.max_map_count ya estaba configurado"
        elif grep -qF "$sysctl_marker" "$sysctl_file"; then
            log_warn "$sysctl_file lleva la marca del script pero no contiene el valor esperado; no se sobrescribe."
            return 0
        else
            log_warn "$sysctl_file ya existe y no lleva la marca del script; no se sobrescribe para evitar modificar configuración ajena."
            return 0
        fi
    else
        {
            echo "$sysctl_marker"
            echo "vm.max_map_count=2147483642"
        } | sudo tee "$sysctl_file" >/dev/null
    fi

    sudo sysctl --system >/dev/null
    log_ok "vm.max_map_count=2147483642 aplicado ($sysctl_file)"
}

# ---------------------------------------------------------------------------
# 11. Verificar/activar ntsync
# ---------------------------------------------------------------------------
# Carga el módulo ntsync con modprobe directamente (sin depender de modinfo,
# que vive en /usr/sbin y no está en el PATH de un usuario normal) y espera
# unos segundos a que udev cree /dev/ntsync.
_ntsync_load_module() {
    log_info "Cargando el módulo ntsync (modprobe)"
    sudo modprobe ntsync || return 1
    local _
    for _ in 1 2 3 4 5 6; do
        [[ -e /dev/ntsync ]] && return 0
        sleep 0.5
    done
    return 0
}

# Explica la causa real cuando ntsync no se puede activar.
_ntsync_explain_failure() {
    local kernel cfg cfgval=""
    kernel="$(uname -r)"
    cfg="/boot/config-${kernel}"
    [[ -r "$cfg" ]] && cfgval="$(grep -m1 '^CONFIG_NTSYNC=' "$cfg" | cut -d= -f2)"

    if [[ ! -d "/lib/modules/${kernel}" ]]; then
        log_warn "No existen los módulos del kernel en ejecución (/lib/modules/${kernel}); suele pasar tras actualizar el kernel sin reiniciar. Reinicia y vuelve a ejecutar el script."
    elif [[ -r "$cfg" && -z "$cfgval" ]]; then
        log_warn "Tu kernel (${kernel}) no incluye ntsync (CONFIG_NTSYNC no está definido). Se incorporó en el kernel 6.14; necesitas un kernel más reciente."
    elif [[ "$cfgval" == "m" || "$cfgval" == "y" ]]; then
        log_warn "El kernel declara CONFIG_NTSYNC=${cfgval}, pero ntsync no se ha podido activar. Mira el motivo con: dmesg | tail"
    else
        log_warn "No se pudo cargar ntsync y no se pudo leer la configuración del kernel (${cfg}). Prueba a mano: sudo modprobe ntsync"
    fi
}

step_ntsync() {
    log_step "11/14 · Activando ntsync"

    local modules_file="/etc/modules-load.d/ntsync.conf"

    # ntsync puede estar compilado como módulo cargable (CONFIG_NTSYNC=m) o
    # integrado en el kernel (CONFIG_NTSYNC=y). En ambos casos, la señal de
    # que funciona es que exista /dev/ntsync. Si no existe, se intenta
    # cargar el módulo directamente.
    if [[ ! -e /dev/ntsync ]]; then
        if ! _ntsync_load_module; then
            _ntsync_explain_failure
            return 1
        fi
    fi

    if [[ ! -e /dev/ntsync ]]; then
        log_err "El módulo ntsync se cargó, pero /dev/ntsync no ha aparecido."
        _ntsync_explain_failure
        return 1
    fi
    log_ok "ntsync está activo (/dev/ntsync existe)"

    # Persistencia: solo hace falta si es un módulo cargable (aparece en
    # lsmod). Si está integrado en el kernel, no hay nada que cargar.
    local loaded_modules
    loaded_modules="$(lsmod 2>/dev/null)"
    if grep -q '^ntsync' <<<"$loaded_modules"; then
        if [[ -f "$modules_file" ]] && grep -qx 'ntsync' "$modules_file"; then
            log_ok "ntsync ya estaba configurado para cargarse en cada arranque (${modules_file})"
        elif echo "ntsync" | sudo tee "$modules_file" >/dev/null; then
            log_ok "ntsync configurado para cargarse automáticamente en cada arranque (${modules_file})"
        else
            log_err "No se pudo escribir ${modules_file}; ntsync no se cargará solo tras reiniciar."
            return 1
        fi
    else
        log_info "ntsync está integrado en el kernel: no hace falta configurar su carga"
    fi
}

# ---------------------------------------------------------------------------
# 12. Wrapper game-performance (mismo patrón que usa CachyOS)
# ---------------------------------------------------------------------------
# Sustituye a un enfoque de alias de bash (gaming-on/gaming-off), que NO
# funciona dentro de las opciones de lanzamiento de Steam: un alias solo
# existe en una sesión de terminal interactiva con ~/.bashrc cargado, y
# Steam ejecuta el comando directamente, sin pasar por bash interactivo.
#
# game-performance es un script wrapper real (ejecutable en el PATH):
# cambia el perfil de energía a "performance" al arrancar el proceso que
# le pasás (si ese perfil existe en el equipo), inhibe el salvapantallas
# mientras corre, y restaura el perfil que estaba activo ANTES (no un
# valor fijo) en cuanto el proceso termina -- funcione bien, falle, o se
# interrumpa.
#
# Confirmado en la práctica en este equipo (ASUS ROG, Ryzen 7 6800HS,
# asusctl) el 14/09/2026: power-profiles-daemon sincroniza a la vez el
# gobernador de CPU, el EPP, y platform_profile (curva de ventiladores de
# asusctl) con un solo cambio de perfil -- por eso alcanza con este wrapper,
# sin necesitar tocar asusctl por separado.
#
# GameMode (gamemoderun, ya usado en este script) sigue siendo complementario,
# no redundante: aporta prioridad de proceso, posible ajuste de GPU, y el
# indicador que MangoHud muestra en el overlay -- cosas que game-performance
# no cubre.
#
# IMPORTANTE -- esto NO es "usalo siempre" ni "no lo uses nunca": es
# específico de cada equipo, no hay una regla universal correcta. En un
# ASUS ROG (Ryzen 7 6800HS + RTX 3050 laptop) se midió, con MangoHud, que
# para un juego dado forzar 'performance' con game-performance daba la
# MISMA cantidad de FPS que dejarlo en 'balanced', pero con la CPU 27°C
# más caliente (84°C vs 57°C) -- ahí forzar 'performance' no aportaba
# nada y solo generaba más calor y ruido de ventilador. En otro equipo
# (desktop con disipación de CPU y GPU separada, u otro laptop con mejor
# cooling) el resultado bien podría ser el opuesto, o no notarse
# diferencia alguna. No asumas ninguno de los dos casos: mídelo tú con
# el overlay de MangoHud, juego por juego, ver el resumen final para el
# método.
step_install_game_performance() {
    log_step "12/14 · Instalando wrapper game-performance"

    if ! pkg_installed power-profiles-daemon; then
        if ! sudo apt install -y power-profiles-daemon; then
            log_err "No se pudo instalar power-profiles-daemon. Se continúa: el wrapper game-performance funciona igualmente, pero sin cambiar el perfil de energía."
        elif sudo systemctl enable --now power-profiles-daemon; then
            log_ok "power-profiles-daemon instalado y activado"
        else
            log_warn "power-profiles-daemon se instaló, pero no se pudo activar el servicio. Prueba: sudo systemctl enable --now power-profiles-daemon"
        fi
    else
        log_ok "power-profiles-daemon ya estaba instalado"
    fi

    local wrapper="/usr/local/bin/game-performance"
    local marker="# game-performance v2 -- instalado por setup-gaming-debian-sid.sh"

    if [[ -f "$wrapper" ]] && grep -qF "$marker" "$wrapper" 2>/dev/null; then
        log_ok "game-performance ya estaba instalado (${wrapper})"
        return
    fi

    sudo tee "$wrapper" >/dev/null <<'WRAPPER_EOF'
#!/usr/bin/env bash
# game-performance v2 -- instalado por setup-gaming-debian-sid.sh
#
# Wrapper para lanzar cualquier proceso (normalmente un juego) con el
# perfil de energía en "performance" mientras corre, e inhibe el
# salvapantallas/suspensión mientras dura. Requiere power-profiles-daemon.
#
# Uso en Steam (Opciones de lanzamiento):
#   game-performance gamemoderun mangohud %command%
#
# Uso manual en terminal:
#   game-performance <comando> [argumentos...]
#
# Qué hace:
#   1. Guarda el perfil de energía activo ANTES de arrancar (no asume
#      "balanced" fijo -- respeta lo que tenías puesto, sea el que sea).
#   2. Si el perfil "performance" existe en este equipo, lo activa. Si no
#      existe (algunos equipos solo tienen balanced/power-saver), avisa y
#      sigue sin tocar el perfil de energía.
#   3. Inhibe el salvapantallas/suspensión mientras el proceso corre, vía
#      systemd-inhibit (si está disponible).
#   4. Ejecuta el comando que le pasaste y espera a que termine.
#   5. Restaura el perfil que estaba activo antes, tanto si el comando
#      termina bien como si falla o se interrumpe (trap EXIT). Solo
#      restaura si de verdad lo había cambiado en el paso 2.
set -u

if [[ $# -eq 0 ]]; then
    echo "Uso: game-performance <comando> [argumentos...]" >&2
    exit 1
fi

if ! command -v powerprofilesctl &>/dev/null; then
    echo "[game-performance] 'powerprofilesctl' no encontrado (power-profiles-daemon no instalado). Ejecutando sin cambiar el perfil de energía." >&2
    exec "$@"
fi

PREVIOUS_PROFILE="$(powerprofilesctl get 2>/dev/null || echo "balanced")"
PROFILE_CHANGED=0

if powerprofilesctl list 2>/dev/null | grep -q 'performance:'; then
    if powerprofilesctl set performance &>/dev/null; then
        PROFILE_CHANGED=1
    fi
else
    echo "[game-performance] El perfil 'performance' no está disponible en este equipo. Se ejecuta sin cambiar el perfil de energía." >&2
fi

restore_profile() {
    [[ "$PROFILE_CHANGED" -eq 1 ]] && powerprofilesctl set "$PREVIOUS_PROFILE" &>/dev/null
}
trap restore_profile EXIT

if command -v systemd-inhibit &>/dev/null; then
    systemd-inhibit --what=idle:sleep --why="game-performance: proceso en curso" -- "$@"
else
    "$@"
fi
exit "$?"
WRAPPER_EOF

    sudo chmod +x "$wrapper"
    log_ok "game-performance instalado en ${wrapper}"
}

# ---------------------------------------------------------------------------
# 13. Lutris (opcional, paquete de apt)
# ---------------------------------------------------------------------------
#
# Lutris está en el componente 'contrib' de Debian Sid, en una versión
# reciente, así que no hace falta Flatpak. Si ya está instalado se actualiza
# sin preguntar; si no, se ofrece con una pregunta [s/N].
step_lutris() {
    log_step "13/14 · Lutris (opcional)"

    if ! pkg_installed lutris; then
        if ! apt-cache show lutris &>/dev/null; then
            log_warn "Lutris no está disponible en tus repositorios (vive en 'contrib'). Se omite este paso."
            return 1
        fi
        if ! ask_optional "¿Instalar Lutris (repositorio oficial de Debian, contrib)?"; then
            log_info "Se omite Lutris"
            return 0
        fi
    fi

    if sudo apt install -y lutris; then
        log_ok "Lutris instalado/actualizado (vía apt)"
    else
        log_err "Falló la instalación de Lutris. Se omite; el resto del script continúa."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 14. Gamescope (opcional, paquete de apt)
# ---------------------------------------------------------------------------
#
# Micro-compositor de Valve para escalado y pantalla completa. Está en el
# componente 'contrib' de Debian Sid. Es situacional, así que solo se
# instala si se responde que sí; con GPU híbrida NVIDIA puede requerir
# pruebas según el juego.
step_gamescope() {
    log_step "14/14 · Gamescope (opcional)"

    if ! pkg_installed gamescope; then
        if ! apt-cache show gamescope &>/dev/null; then
            log_warn "Gamescope no está disponible en tus repositorios (vive en 'contrib'). Se omite este paso."
            return 1
        fi
        if ! ask_optional "¿Instalar Gamescope (repositorio oficial de Debian, contrib)?"; then
            log_info "Se omite Gamescope"
            return 0
        fi
    fi

    if sudo apt install -y gamescope; then
        log_ok "Gamescope instalado/actualizado (vía apt)"
        log_info "Uso en Steam (opciones de lanzamiento): gamescope -f -- %command%"
    else
        log_err "Falló la instalación de Gamescope. Se omite; el resto del script continúa."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Verificaciones finales (solo comprueban; no lanzan Steam ni juegos)
# ---------------------------------------------------------------------------
#
# Steam: si sus carpetas aún no existen, es normal en una instalación limpia
# (Steam las crea la primera vez que se abre). El script NO lo lanza: se deja
# como paso manual pendiente. Si Steam ya existe y Protontricks no lo
# encuentra, se crea el enlace ~/.local/share/Steam como último recurso, sin
# tocar nada si ya existe.
# Estado de componentes con tres categorías:
#   OK             -> instalado/preparado
#   ADVERTENCIA    -> requiere una acción manual (o no es lo ideal, pero no rompe nada)
#   NO DISPONIBLE  -> no se pudo instalar o no responde
# Nada de esto es fatal: el script no cambia su código de salida por lo que
# salga aquí (lo opcional o lo que depende de una acción del usuario no son
# errores).
CHK_OK=0
CHK_WARN=0
CHK_NA=0
MANUAL_STEPS=()

_chk() {
    case "$1" in
        OK)   CHK_OK=$((CHK_OK + 1));     echo -e "  ${COLOR_GREEN}[ OK ]${COLOR_RESET}           $2" ;;
        WARN) CHK_WARN=$((CHK_WARN + 1)); echo -e "  ${COLOR_YELLOW}[ADVERTENCIA]${COLOR_RESET}     $2" ;;
        NA)   CHK_NA=$((CHK_NA + 1));     echo -e "  ${COLOR_RED}[NO DISPONIBLE]${COLOR_RESET}   $2" ;;
    esac
}

step_final_checks() {
    log_step "Verificaciones finales"

    CHK_OK=0; CHK_WARN=0; CHK_NA=0; MANUAL_STEPS=()
    local version

    # --- Wine / wineserver / Winetricks / Protontricks ---
    if command -v wine &>/dev/null && version="$(wine --version 2>/dev/null)" && [[ -n "$version" ]]; then
        _chk OK "Wine: ${version}"
    else
        _chk NA "Wine: no responde ('wine --version'); Winetricks debería haberlo instalado"
    fi

    wineserver_link="/usr/local/bin/wineserver"

    if [[ -L "$wineserver_link" && -x "$wineserver_link" ]]; then
        version="$("$wineserver_link" --version 2>/dev/null || true)"
        if [[ -n "$version" ]]; then
            _chk OK "wineserver: ${version} (${wineserver_link})"
        else
            _chk WARN "wineserver: el enlace ${wineserver_link} existe pero no responde."
        fi
    elif command -v wineserver &>/dev/null && version="$(wineserver --version 2>/dev/null)" && [[ -n "$version" ]]; then
        _chk OK "wineserver: ${version} ($(command -v wineserver))"
    else
        _chk NA "wineserver: no está en el PATH; Winetricks fallaría con 'wineserver not found!'"
    fi

    if command -v winetricks &>/dev/null; then
        _chk OK "Winetricks: instalado ($(command -v winetricks))"
    else
        _chk NA "Winetricks: no está instalado"
    fi

    local protontricks_ok=0
    if command -v protontricks &>/dev/null && version="$(protontricks --version 2>/dev/null)" && [[ -n "$version" ]]; then
        protontricks_ok=1
        _chk OK "Protontricks: ${version}"
    else
        _chk NA "Protontricks: no responde ('protontricks --version')"
    fi

    # --- Steam ---
    # El script NO lanza Steam. Si sus carpetas aún no existen (normal en una
    # instalación limpia), se deja como paso manual. Si existen y Protontricks
    # no encuentra Steam, se crea ~/.local/share/Steam como último recurso, sin
    # tocar nada si ya existe.
    if pkg_installed steam-installer || pkg_installed steam-launcher; then
        local steam_data_found=0 d
        for d in "$HOME/.steam/debian-installation" "$HOME/.local/share/Steam" "$HOME/.steam/steam"; do
            [[ -e "$d" ]] && steam_data_found=1
        done

        if [[ "$steam_data_found" -eq 0 ]]; then
            _chk WARN "Steam: instalado, pero aún sin inicializar"
            MANUAL_STEPS+=("Abre Steam una vez y deja que termine de descargarse (el script no lo lanza).")
        elif [[ "$protontricks_ok" -eq 1 ]]; then
            local pt_out
            pt_out="$(protontricks -vv -l 2>&1)"
            if ! grep -q 'Found Steam directory' <<<"$pt_out" \
               && [[ -d "$HOME/.steam/debian-installation" && ! -e "$HOME/.local/share/Steam" && ! -L "$HOME/.local/share/Steam" ]]; then
                log_info "Protontricks no encuentra Steam; se crea el enlace de compatibilidad ~/.local/share/Steam"
                mkdir -p "$HOME/.local/share"
                ln -sT "$HOME/.steam/debian-installation" "$HOME/.local/share/Steam"
                pt_out="$(protontricks -vv -l 2>&1)"
            fi

            if grep -q 'Found Steam directory' <<<"$pt_out"; then
                _chk OK "Steam: instalado y detectado por Protontricks"
            else
                _chk WARN "Steam: instalado, pero Protontricks no lo encuentra"
                MANUAL_STEPS+=("Ejecuta 'protontricks -vv -l' para ver por qué no encuentra Steam.")
            fi

            if grep -q 'Found no games' <<<"$pt_out"; then
                _chk WARN "Protontricks: aún no lista juegos (normal hasta que lances uno con Proton)"
                MANUAL_STEPS+=("Lanza un juego de Windows con Proton una vez para que Protontricks lo liste.")
            fi
        else
            _chk WARN "Steam: instalado, pero Protontricks no está disponible para comprobarlo"
        fi
    else
        _chk NA "Steam: no está instalado (steam-installer)"
    fi

    # --- MangoHud / MangoJuice ---
    if command -v mangohud &>/dev/null; then
        version="$(mangohud --version 2>/dev/null)"
        version="${version%%$'\n'*}"
        if mangohud_has_nvml; then
            _chk OK "MangoHud: ${version:-instalado} (con soporte NVML)"
        else
            _chk WARN "MangoHud: ${version:-instalado}, pero no se detecta soporte NVML (faltarían métricas de GPU NVIDIA)"
            MANUAL_STEPS+=("Vuelve a ejecutar este script para recompilar MangoHud con NVML (paso 5).")
        fi
    else
        _chk NA "MangoHud: no está instalado (paso 5)"
    fi

    case "$MANGOJUICE_STATE" in
        instalado)         _chk OK "MangoJuice: instalado (Flatpak, opcional)" ;;
        rechazado)         _chk OK "MangoJuice: no instalado (opcional; MangoHud funciona igual)" ;;
        fallo_instalacion) _chk NA "MangoJuice: no se pudo instalar (opcional; MangoHud funciona igual)" ;;
        fallo_consulta)    _chk NA "MangoJuice: no se pudo consultar en Flathub (opcional)" ;;
        sin_flatpak)       _chk NA "MangoJuice: Flatpak no está disponible (opcional)" ;;
        *)                 _chk OK "MangoJuice: no se ofreció en esta ejecución (opcional)" ;;
    esac

    # --- GameMode / perfiles de energía ---
    if pkg_installed gamemode && command -v gamemoderun &>/dev/null; then
        _chk OK "GameMode: instalado (gamemoderun)"
    else
        _chk NA "GameMode: no está instalado (paso 5)"
    fi

    local gm_ini="$HOME/.config/gamemode.ini"
    if [[ -f "$gm_ini" ]]; then
        if grep -qF "# gamemode.ini -- configurado por setup-gaming-debian-sid.sh" "$gm_ini"; then
            _chk OK "gamemode.ini: creado por el script (${gm_ini})"
        else
            _chk OK "gamemode.ini: ya existía y no lleva la marca del script; se respeta tal cual"
        fi
    else
        _chk WARN "gamemode.ini: no existe (${gm_ini}); vuelve a ejecutar el script para crearlo"
    fi

    if pkg_installed power-profiles-daemon; then
        if systemctl is-active --quiet power-profiles-daemon; then
            local ppd_profiles
            ppd_profiles="$(powerprofilesctl list 2>/dev/null)"
            if grep -q 'performance:' <<<"$ppd_profiles"; then
                _chk OK "power-profiles-daemon: activo, con el perfil 'performance' disponible"
            else
                _chk WARN "power-profiles-daemon: activo, pero no ofrece el perfil 'performance' (depende del hardware); game-performance funcionará sin cambiarlo"
            fi
        else
            _chk WARN "power-profiles-daemon: instalado pero no activo (sudo systemctl enable --now power-profiles-daemon)"
        fi
    else
        _chk NA "power-profiles-daemon: no está instalado (opcional; game-performance funciona sin él)"
    fi

    if command -v game-performance &>/dev/null; then
        _chk OK "game-performance: wrapper instalado ($(command -v game-performance))"
    else
        _chk NA "game-performance: wrapper no instalado (paso 12)"
    fi

    # --- ntsync ---
    if [[ -e /dev/ntsync ]]; then
        local loaded_mods
        loaded_mods="$(lsmod 2>/dev/null)"
        if grep -q '^ntsync' <<<"$loaded_mods"; then
            if [[ -f /etc/modules-load.d/ntsync.conf ]] && grep -qx 'ntsync' /etc/modules-load.d/ntsync.conf; then
                _chk OK "ntsync: activo y configurado para cargarse en cada arranque"
            else
                _chk WARN "ntsync: cargado, pero sin persistencia (no se cargaría solo tras reiniciar); vuelve a ejecutar el script"
            fi
        else
            _chk OK "ntsync: activo (integrado en el kernel)"
        fi
    else
        _chk NA "ntsync: /dev/ntsync no existe (¿el kernel no incluye el módulo?)"
    fi

    echo
    if [[ "$CHK_WARN" -eq 0 && "$CHK_NA" -eq 0 ]]; then
        log_ok "Componentes: ${CHK_OK} OK, sin advertencias"
    else
        log_warn "Componentes: ${CHK_OK} OK, ${CHK_WARN} advertencia(s) (acción manual) y ${CHK_NA} no disponible(s)"
    fi

    if [[ ${#MANUAL_STEPS[@]} -gt 0 ]]; then
        echo
        log_info "Pasos manuales pendientes:"
        local step
        for step in "${MANUAL_STEPS[@]}"; do
            echo "      · ${step}"
        done
    fi
}

# ---------------------------------------------------------------------------
# Resumen final
# ---------------------------------------------------------------------------
step_summary() {
    log_step "Resumen"
    echo "Instalación/configuración de gaming completa."
    echo "Recomendaciones:"
    echo "  - Steam se instaló con 'steam-installer' del repositorio oficial de Debian"
    echo "    (contrib): se actualiza con 'sudo apt upgrade'. El cliente de Steam y los"
    echo "    juegos se actualizan solos desde Valve, como con cualquier otra vía."
    echo "  - Heroic Games Launcher se descarga e instala/actualiza automáticamente"
    echo "    desde el último .deb publicado en GitHub cada vez que ejecutas este script."
    echo "  - ProtonPlus quedó instalado vía Flatpak: se actualiza con 'flatpak update'"
    echo "    (o desde tu centro de software)."
    if flatpak_installed io.github.radiolamp.mangojuice; then
        echo "  - MangoJuice está instalado (Flatpak) para configurar MangoHud gráficamente."
    fi
    echo "  - MangoHud se compiló desde fuente con soporte NVML (necesario para ver"
    echo "    % de uso, VRAM y temperatura de GPUs NVIDIA); el paquete de apt no lo trae."
    echo "    Si 'apt upgrade' (o instalar algún paquete que dependa de 'mangohud')"
    echo "    llegara a reinstalar el paquete de apt y pisar el binario compilado,"
    echo "    vuelve a ejecutar este script para recompilarlo."
    echo "  - Winetricks y Protontricks quedaron instalados como paquetes nativos de"
    echo "    Debian (se actualizan solos con 'apt upgrade'). Úsalos así:"
    echo "      protontricks -s <nombre del juego>   # buscar el AppID"
    echo "      protontricks <AppID> <acción>         # ej.: vcrun2019, corefonts"
    echo "  - En Steam: Configuración → Compatibilidad → activa 'Habilitar Steam Play"
    echo "    para todos los demás títulos' y elige la versión de Proton (o una de"
    echo "    ProtonPlus) que quieras usar por defecto."
    echo "  - Empieza cada juego SIN game-performance, solo con:"
    echo "      gamemoderun mangohud %command%"
    echo "    y mira el overlay de MangoHud (% de uso y temperatura de CPU/GPU)."
    echo "    Si los FPS te alcanzan y no ves stuttering, déjalo así -- forzar más"
    echo "    no te da nada a cambio, solo calor y ruido de ventilador de más."
    echo "    Si notas FPS bajos o caídas puntuales, suma game-performance:"
    echo "      game-performance gamemoderun mangohud %command%"
    echo "    game-performance cambia el perfil de energía a 'performance' mientras"
    echo "    el juego corre (en este equipo eso sincroniza a la vez gobernador de"
    echo "    CPU, EPP, y la curva de ventiladores de asusctl -- confirmado en la"
    echo "    práctica) y restaura el perfil anterior al cerrar el juego."
    echo "    Esto es por-juego, no una regla fija: en este mismo equipo se midió"
    echo "    un caso con los mismos FPS pero 27°C más de CPU al forzarlo, así que"
    echo "    no asumas que 'más forzado' es siempre mejor -- mide con MangoHud."
    echo "    Fuera de Steam (terminal, Heroic, Lutris) puedes usar game-performance"
    echo "    igual: 'game-performance <comando>'."
    echo "  - Si tienes GPU NVIDIA dedicada, el script ya configuró 'pci_dev' en"
    echo "    ~/.config/MangoHud/MangoHud.conf con el bus-id detectado vía nvidia-smi."
    echo "    En equipos con GPU híbrida, si MangoJuice agrega 'gpu_list=' puede pisar"
    echo "    ese filtrado y volver a mostrar el % de GPU equivocado: comenta o borra"
    echo "    esa línea si eso pasa."
    echo "  - ~/.config/gamemode.ini quedó creado (solo si no existía ya) con"
    echo "    desiredgov detectado automáticamente según tu driver cpufreq (schedutil"
    echo "    si está disponible, powersave si no -- en amd_pstate/intel_pstate en"
    echo "    modo activo, powersave YA es dinámico, no es el modo fijo-bajo de antes)."
    echo "    Así el CPU sube/baja de frecuencia según la carga real, en vez de"
    echo "    quedarse arriba fijo todo el tiempo que el juego está abierto. Si ya lo"
    echo "    tenías configurado a tu manera, el script no lo tocó. Ejecuta"
    echo "    'gamemoded -t' para confirmar qué gobernador detectó y aplicó."
    echo "  - mesa-utils quedó instalado (glxgears, glxinfo) solo como herramienta de"
    echo "    diagnóstico rápido, para probar drivers/MangoHud sin abrir un juego."
    if pkg_installed lutris; then
        echo "  - Lutris está instalado (paquete de apt, se actualiza con 'sudo apt upgrade')."
    fi
    if pkg_installed gamescope; then
        echo "  - Gamescope está instalado. Uso en Steam (opciones de lanzamiento):"
        echo "      gamescope -f -- %command%"
    fi
    echo "  - ntsync: el script lo carga y lo deja configurado para cada arranque"
    echo "    (/etc/modules-load.d/ntsync.conf). Tras reiniciar, comprueba que sigue activo:"
    echo "      ls -l /dev/ntsync"
    echo "    Solo lo aprovechan versiones de Wine/Proton con soporte ntsync; con un"
    echo "    juego abierto, 'sudo lsof /dev/ntsync' muestra si lo está usando."
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    require_root_privileges
    check_system_prerequisites

    log_info "Actualizando índices de apt (necesario para que los pasos siguientes detecten actualizaciones reales, no solo instalaciones nuevas)"
    if ! sudo apt update; then
        log_warn "'apt update' terminó con errores (puede ser un repositorio concreto o la red). Seguir con índices posiblemente desactualizados no es lo ideal."
        _confirm_or_exit
    fi

    step_steam
    step_ensure_flatpak
    step_protonplus
    step_heroic_launcher
    step_gamemode_mangohud
    step_winetricks_protontricks
    step_gamemode_ini_defaults
    step_mangohud_pci_dev
    step_diagnostic_tools
    step_max_map_count
    step_ntsync
    step_install_game_performance
    step_lutris
    step_gamescope
    step_final_checks
    step_summary
}

main "$@"
