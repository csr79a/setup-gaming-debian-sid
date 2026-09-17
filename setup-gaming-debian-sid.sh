#!/usr/bin/env bash
#
# setup-gaming-debian-sid.sh
#
# Instala y optimiza Debian Sid (Unstable) / KDE Plasma para jugar: Steam,
# ProtonPlus (gestor de builds de Proton-GE), Heroic Games Launcher (con
# auto-actualización), GameMode, MangoHud (compilado desde fuente con
# soporte NVML para GPUs NVIDIA) + MangoJuice como GUI de configuración,
# configuración automática de pci_dev en MangoHud.conf para GPUs híbridas,
# herramientas de diagnóstico (mesa-utils) y algunos ajustes del sistema
# recomendados para juegos modernos.
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
# temperatura de GPUs NVIDIA). Si tenés una GPU NVIDIA, ese paquete jamás
# va a mostrar esos datos, aunque el resto del overlay funcione. Por eso
# este script compila MangoHud desde fuente con -Dwith_nvml=enabled.
#
# Uso:
#   chmod +x setup-gaming-debian-sid.sh
#   ./setup-gaming-debian-sid.sh
#
# Complementario a setup-debian-sid.sh. Repite ejecución: el script es
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
# MangoHud) -- registrados acá para que se borren pase lo que pase:
# terminación normal, error, o Ctrl+C a mitad de la compilación. Antes,
# la limpieza dependía de un 'rm -f/-rf' puntual en cada 'return' de cada
# función: si el usuario interrumpía el script con Ctrl+C durante 'ninja
# install' o durante una descarga, ese rm nunca se ejecutaba y quedaban
# directorios temporales (potencialmente varios cientos de MB, en el caso
# del build_dir de MangoHud) sin borrar en /tmp.
TMP_PATHS=()
register_tmp_path() { TMP_PATHS+=("$1"); }
_cleanup_tmp_paths() {
    local p
    for p in ${TMP_PATHS[@]+"${TMP_PATHS[@]}"}; do
        [[ -n "$p" ]] && rm -rf "$p"
    done
}

require_root_privileges() {
    if [[ "${EUID}" -eq 0 ]]; then
        log_err "No corras este script directamente como root. Ejecutalo como tu usuario normal; se te pedirá la contraseña de sudo cuando haga falta."
        exit 1
    fi
    if ! command -v sudo &>/dev/null; then
        log_err "No se encontró 'sudo'. Instalalo o corré este script con un método equivalente."
        exit 1
    fi
    sudo -v

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

pkg_installed() {
    dpkg -l "$1" 2>/dev/null | grep -q '^ii'
}

flatpak_installed() {
    flatpak list --app --columns=application 2>/dev/null | grep -qFx "$1"
}

# ---------------------------------------------------------------------------
# 0. Comprobación de prerrequisitos del sistema
# ---------------------------------------------------------------------------
# La mayoría de los pasos de este script son autosuficientes (llaman a apt
# directamente, que resuelve dependencias solo). La excepción es la
# compilación de MangoHud (paso 5), que necesita deb-src habilitado sobre
# un /etc/apt/sources.list.d/debian.sources en formato deb822 apuntando a
# unstable -- lo que deja listo setup-debian-sid.sh. Si ese archivo no
# existe o no apunta a unstable, 'apt build-dep mangohud' puede fallar más
# adelante; este chequeo avisa la causa real por adelantado, en vez de
# dejar que el síntoma aparezca disfrazado como "no se detectó NVML".
check_system_prerequisites() {
    log_step "0/11 · Comprobando prerrequisitos del sistema"

    local sources_file="/etc/apt/sources.list.d/debian.sources"

    if [[ ! -f "$sources_file" ]]; then
        log_warn "No se encontró ${sources_file} (formato deb822). Este script no requiere haber corrido setup-debian-sid.sh para la mayoría de los pasos (apt resuelve dependencias solo), pero SIN este archivo la compilación de MangoHud con soporte NVML (paso 5) puede fallar por falta de deb-src."
        _confirm_or_exit_no_sid
        return
    fi

    if ! grep -qE '^Suites:.*(unstable|testing)' "$sources_file"; then
        log_warn "${sources_file} existe pero no parece apuntar a 'unstable' ni 'testing'. Este script está pensado para Debian Sid (y probablemente ande bien en testing/trixie); en Debian estable, la compilación de MangoHud (librerías más viejas) y ntsync (kernel viejo) pueden fallar."
        _confirm_or_exit_no_sid
    else
        log_ok "Repos en formato deb822 apuntando a unstable/testing detectados correctamente"
    fi
}

# Antes, este chequeo solo avisaba y el script seguía igual sin importar la
# respuesta -- un problema real en un sistema no-Sid podía aparecer recién
# varios minutos después, en medio de la compilación de MangoHud, sin que
# el mensaje de error dijera que la causa era esta. Ahora, si no se detecta
# Sid/testing, se pide confirmación explícita antes de continuar.
_confirm_or_exit_no_sid() {
    if [[ ! -t 0 ]]; then
        log_err "No hay una terminal interactiva para confirmar (stdin no es un tty), así que no se puede preguntar. Se cancela por seguridad en vez de asumir una respuesta. Corré el script en una terminal interactiva, o en un sistema que sí sea Sid/testing."
        exit 1
    fi
    read -rp "¿Continuar de todos modos? [s/N]: " respuesta
    if [[ ! "$respuesta" =~ ^[sS]$ ]]; then
        log_err "Cancelado por el usuario."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# 1. Steam (.deb oficial de Valve)
# ---------------------------------------------------------------------------
step_steam() {
    log_step "1/11 · Instalando Steam (.deb oficial de Valve)"

    if pkg_installed steam-launcher || pkg_installed steam-installer; then
        log_ok "Steam ya estaba instalado"
        return
    fi

    if ! dpkg --print-foreign-architectures | grep -q '^i386$'; then
        sudo dpkg --add-architecture i386
        sudo apt update
    fi

    local tmp_deb
    tmp_deb="$(mktemp --suffix=.deb)"
    register_tmp_path "$tmp_deb"
    log_info "Descargando el .deb oficial de Steam"
    if ! curl -fsSL "https://cdn.cloudflare.steamstatic.com/client/installer/steam.deb" -o "$tmp_deb"; then
        log_err "No se pudo descargar el .deb de Steam (revisá conectividad). Se omite este paso."
        rm -f "$tmp_deb"
        return 1
    fi

    if ! sudo apt install -y "$tmp_deb"; then
        log_err "Falló la instalación del .deb de Steam. Se omite; el resto del script continúa."
        rm -f "$tmp_deb"
        return 1
    fi

    rm -f "$tmp_deb"
    log_ok "Steam instalado"
}

# ---------------------------------------------------------------------------
# 2. Flatpak + Flathub (por si el proyecto base todavía no lo dejó listo)
# ---------------------------------------------------------------------------
step_ensure_flatpak() {
    log_step "2/11 · Instalando/actualizando Flatpak y Flathub"

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
    log_step "3/11 · Instalando/actualizando ProtonPlus (Flatpak)"

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
    log_step "4/11 · Descargando e instalando/actualizando Heroic Games Launcher"

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
        log_err "No se pudo descargar el .deb de Heroic (revisá conectividad). Se omite este paso."
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
# 5. GameMode + MangoHud (compilado desde fuente con NVML) + MangoJuice (Flatpak)
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
    local sym
    for sym in "${symbols[@]}"; do
        if strings "$lib" 2>/dev/null | grep -qi "$sym"; then
            return 0
        fi
    done
    return 1
}

# 'mangohud --version' sigue el formato de 'git describe' (vX.Y.Z-N-gHASH).
# Esto extrae el HASH corto, que identifica exactamente qué commit de
# upstream quedó compilado. Vacío si mangohud no está instalado o si por
# casualidad HEAD coincide exactamente con un tag (sin sufijo -N-gHASH).
mangohud_installed_git_hash() {
    command -v mangohud &>/dev/null || return 1
    mangohud --version 2>/dev/null | grep -oP -- '-g\K[0-9a-f]{7,40}$'
}

# Compara el commit instalado contra el HEAD actual de la rama por
# defecto de upstream. Si coinciden (o no se puede determinar, por
# ejemplo sin conectividad), no recompila -- evita gastar varios minutos
# de compilación en cada corrida del script cuando no hay nada nuevo.
# Si son distintos, recompila para traer la versión nueva.
_mangohud_check_and_maybe_recompile() {
    if ! mangohud_has_nvml; then
        log_info "MangoHud no está instalado (o le falta NVML). Compilando..."
        step_mangohud_compile_nvml
        return
    fi

    local installed_hash remote_hash
    installed_hash="$(mangohud_installed_git_hash)"
    remote_hash="$(git ls-remote https://github.com/flightlessmango/MangoHud.git HEAD 2>/dev/null | awk '{print $1}')"

    if [[ -z "$remote_hash" ]]; then
        log_warn "No se pudo consultar el último commit de MangoHud en GitHub (¿sin conectividad?). Se deja la versión ya instalada (${installed_hash:-desconocida}) sin recompilar."
        return
    fi

    if [[ -n "$installed_hash" && "$remote_hash" == "$installed_hash"* ]]; then
        log_ok "MangoHud ya está instalado con NVML y en el último commit de upstream (${installed_hash})"
        return
    fi

    log_info "Hay una versión más nueva de MangoHud en upstream (instalado: ${installed_hash:-desconocido}, remoto: ${remote_hash:0:8}). Recompilando..."
    step_mangohud_compile_nvml
}

step_mangohud_compile_nvml() {
    log_info "Compilando MangoHud desde fuente con soporte NVML"

    # Si en algún momento el paquete `mangohud` de apt quedó instalado
    # (por ejemplo de una ejecución vieja del script), lo sacamos primero
    # para que la instalación manual (ninja install) no choque con dpkg.
    if pkg_installed mangohud; then
        log_info "Desinstalando el paquete 'mangohud' de apt (build sin NVML) antes de compilar"
        sudo apt remove -y mangohud
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
            sudo apt update
        fi
    else
        log_warn "No se encontró ${sources_file} (formato deb822). No se pudo activar deb-src automáticamente; 'apt build-dep mangohud' puede fallar por falta de fuentes. Revisá que tus repos estén en ese formato (los deja listos setup-debian-sid.sh)."
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
    # wayland-protocols / libgbm-dev: tampoco están cubiertos por 'apt
    # build-dep mangohud', por el mismo motivo -- ese build-dep refleja
    # las dependencias del paquete VIEJO de Debian, mientras que 'git
    # clone' de abajo trae la rama por defecto de upstream (sin fijar
    # tag/versión). La reescritura de upstream ("MangoHud next") fue
    # agregando dependencias nuevas de a una: primero wayland-protocols
    # (backend Wayland), después gbm/libgbm-dev (backend de render). Como
    # el script no fija una versión del repo, esto puede volver a pasar
    # con otra dependencia nueva que upstream agregue en el futuro -- si
    # eso ocurre, agregar el paquete que pida meson en el error a esta
    # lista es la solución (mismo patrón cada vez).
    if ! sudo apt install -y libcap-dev libyaml-cpp-dev libwayland-egl-backend-dev wayland-protocols libgbm-dev; then
        log_err "No se pudieron instalar las dependencias de compilación (libcap-dev/libyaml-cpp-dev/libwayland-egl-backend-dev/wayland-protocols/libgbm-dev). Se aborta la compilación de MangoHud; el resto del script continúa."
        return 1
    fi

    local build_dir
    build_dir="$(mktemp -d)"
    register_tmp_path "$build_dir"
    if ! git clone --recursive https://github.com/flightlessmango/MangoHud.git "${build_dir}/MangoHud"; then
        log_err "No se pudo clonar el repositorio de MangoHud (revisá conectividad). Se aborta la compilación; el resto del script continúa."
        rm -rf "$build_dir"
        return 1
    fi

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
    # 'Dependency "X" not found'. Esto pasa seguido porque 'git clone' de
    # arriba trae la rama por defecto de upstream SIN fijar tag/versión,
    # y la reescritura de upstream ("MangoHud next") fue agregando
    # requisitos nuevos de a uno (ya se vio en la práctica con
    # wayland-protocols, gbm y egl). En vez de mantener a mano una lista
    # fija de paquetes en el script (que se desactualiza cada vez que
    # upstream suma un requisito), esta función usa apt-file para
    # averiguar qué paquete Debian provee el archivo <dependencia>.pc y
    # lo instala. apt-file update solo se corre una vez por ejecución del
    # script (variable de control en el enclosing scope), no en cada
    # reintento.
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
                log_warn "No se encontró ningún paquete que provea '${dep}.pc' en una ruta estándar de pkg-config vía apt-file. Esta dependencia hay que resolverla a mano (buscá en https://packages.debian.org/search?searchon=contents&keywords=${dep}.pc)."
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
            log_err "La compilación/instalación de MangoHud falló (meson/ninja) y no se detectaron (o no se pudieron resolver) más dependencias faltantes en ${meson_log}. Revisá el log para más detalle. Se aborta este paso; el resto del script continúa."
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
        log_ok "MangoHud compilado e instalado con soporte NVML"
    else
        log_warn "MangoHud se instaló pero no se detectó soporte NVML. Revisá el log de meson si tenés GPU NVIDIA."
    fi
}

step_gamemode_mangohud() {
    log_step "5/11 · Instalando GameMode, MangoHud (compilado con NVML) y MangoJuice (Flatpak)"

    if sudo apt install -y gamemode; then
        log_ok "GameMode instalado/actualizado (vía apt)"
    else
        log_err "Falló la instalación/actualización de GameMode. Se continúa sin él (gamemoderun no va a estar disponible)."
    fi

    _mangohud_check_and_maybe_recompile

    if flatpak_installed io.github.radiolamp.mangojuice; then
        if flatpak update -y io.github.radiolamp.mangojuice; then
            log_ok "MangoJuice comprobado/actualizado"
        else
            log_err "Falló la actualización de MangoJuice. Se continúa con la versión ya instalada."
        fi
    else
        if flatpak install -y flathub io.github.radiolamp.mangojuice; then
            log_ok "MangoJuice instalado (vía Flatpak; permisos correctos de fábrica hacia ~/.config/MangoHud, sin necesitar 'flatpak override')"
        else
            log_err "Falló la instalación de MangoJuice. Podés configurar MangoHud.conf a mano."
        fi
    fi

    log_info "Para usarlos, en las opciones de lanzamiento de un juego en Steam poné:"
    log_info "  gamemoderun mangohud %command%"
    log_info "Podés configurar el overlay de MangoHud gráficamente abriendo MangoJuice."
}

# ---------------------------------------------------------------------------
# 6. Valores por defecto de ~/.config/gamemode.ini (solo si no existe)
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
    log_step "6/11 · Configurando valores por defecto de ~/.config/gamemode.ini"

    local gamemode_ini="${HOME}/.config/gamemode.ini"
    local marker="# gamemode.ini -- configurado por setup-gaming-debian-sid.sh"

    if [[ -f "$gamemode_ini" ]] && grep -qF "$marker" "$gamemode_ini" 2>/dev/null; then
        log_ok "${gamemode_ini} ya estaba configurado por este script, no se toca"
        return
    fi

    if [[ -f "$gamemode_ini" ]]; then
        log_warn "${gamemode_ini} ya existe pero no lo generó este script (no tiene el marcador esperado). Se deja intacto para no pisar tu configuración; revisalo a mano si querés aplicar un gobernador dinámico vos mismo."
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
    log_step "7/11 · Configurando pci_dev de la GPU NVIDIA en MangoHud.conf"

    if ! command -v nvidia-smi &>/dev/null; then
        log_info "No se detectó 'nvidia-smi'; se omite (no hay GPU NVIDIA o falta el driver)"
        return
    fi

    local bus_id
    bus_id="$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null | head -n1)"
    if [[ -z "$bus_id" ]]; then
        log_warn "No se pudo obtener el pci.bus_id vía nvidia-smi. Configurá pci_dev manualmente en MangoHud.conf."
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
        log_warn "Se detectó 'gpu_list=' en ${config_file}: en equipos con GPU híbrida puede entrar en conflicto con 'pci_dev' y hacer que MangoHud lea la GPU equivocada. Si el % de GPU sale mal, comentá o borrá esa línea."
    fi
}

# ---------------------------------------------------------------------------
# 7. Herramientas de diagnóstico (mesa-utils: glxgears, glxinfo...)
# ---------------------------------------------------------------------------

# No forman parte del setup de gaming en sí; sirven para probar drivers,
# MangoHud, etc. sin depender de abrir un juego completo.
step_diagnostic_tools() {
    log_step "8/11 · Instalando/actualizando herramientas de diagnóstico (mesa-utils)"

    if sudo apt install -y mesa-utils; then
        log_ok "mesa-utils instalado/actualizado (glxgears, glxinfo — útiles para probar drivers/MangoHud rápido)"
    else
        log_err "Falló la instalación/actualización de mesa-utils. No es crítico; el resto del script continúa."
    fi
}

# ---------------------------------------------------------------------------
# 8. vm.max_map_count elevado (recomendado por varios juegos/motores modernos)
# ---------------------------------------------------------------------------
step_max_map_count() {
    log_step "9/11 · Ajustando vm.max_map_count"

    local sysctl_file="/etc/sysctl.d/80-gamecompatibility.conf"
    if [[ -f "$sysctl_file" ]] && grep -q '^vm.max_map_count=2147483642' "$sysctl_file"; then
        log_ok "vm.max_map_count ya estaba configurado"
    else
        echo "vm.max_map_count=2147483642" | sudo tee "$sysctl_file" >/dev/null
        sudo sysctl --system >/dev/null
        log_ok "vm.max_map_count=2147483642 aplicado (${sysctl_file})"
    fi
}

# ---------------------------------------------------------------------------
# 9. Verificar/activar ntsync
# ---------------------------------------------------------------------------
step_ntsync() {
    log_step "10/11 · Verificando soporte de ntsync"

    local modules_file="/etc/modules-load.d/ntsync.conf"

    # ntsync puede estar compilado como built-in (CONFIG_NTSYNC=y) o como
    # módulo cargable (CONFIG_NTSYNC=m). Si está built-in, no hay módulo
    # que lsmod/modinfo puedan detectar: la forma correcta de comprobarlo
    # en ese caso es que exista el device /dev/ntsync.
    if [[ -e /dev/ntsync ]]; then
        log_ok "ntsync está activo (/dev/ntsync existe)"
        if lsmod | grep -q '^ntsync' && [[ ! -f "$modules_file" ]]; then
            # Solo hace falta persistir la carga si es módulo, no si es built-in
            echo "ntsync" | sudo tee "$modules_file" >/dev/null
            log_ok "ntsync configurado para cargarse automáticamente en cada arranque"
        fi
        return
    fi

    if lsmod | grep -q '^ntsync'; then
        log_ok "El módulo ntsync ya está cargado"
        if [[ ! -f "$modules_file" ]]; then
            echo "ntsync" | sudo tee "$modules_file" >/dev/null
            log_ok "ntsync configurado para cargarse automáticamente en cada arranque"
        fi
        return
    fi

    if modinfo ntsync &>/dev/null; then
        sudo modprobe ntsync
        if lsmod | grep -q '^ntsync'; then
            log_ok "Módulo ntsync cargado correctamente"
            if [[ ! -f "$modules_file" ]]; then
                echo "ntsync" | sudo tee "$modules_file" >/dev/null
                log_ok "ntsync configurado para cargarse automáticamente en cada arranque"
            fi
        else
            log_warn "No se pudo cargar el módulo ntsync. Revisá que tu kernel lo soporte."
        fi
    else
        log_warn "Tu kernel no trae el módulo ntsync (se incorporó a partir del kernel 6.14)."
        log_warn "Debian Sid suele traer kernels recientes; si el tuyo es más viejo, actualizalo."
    fi
}

# ---------------------------------------------------------------------------
# 10. Wrapper game-performance (mismo patrón que usa CachyOS)
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
# diferencia alguna. No asumas ninguno de los dos casos: medilo vos con
# el overlay de MangoHud, juego por juego, ver el resumen final para el
# método.
step_install_game_performance() {
    log_step "11/11 · Instalando wrapper game-performance"

    if ! pkg_installed power-profiles-daemon; then
        sudo apt install -y power-profiles-daemon
        sudo systemctl enable --now power-profiles-daemon
        log_ok "power-profiles-daemon instalado y activado"
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
# Resumen final
# ---------------------------------------------------------------------------
step_summary() {
    log_step "Resumen"
    echo "Instalación/configuración de gaming completa."
    echo "Recomendaciones:"
    echo "  - Heroic Games Launcher se descarga e instala/actualiza automáticamente"
    echo "    desde el último .deb publicado en GitHub cada vez que corrés este script."
    echo "  - ProtonPlus y MangoJuice quedaron instalados vía Flatpak, se actualizan con"
    echo "    'flatpak update' (o desde tu centro de software)."
    echo "  - MangoHud se compiló desde fuente con soporte NVML (necesario para ver"
    echo "    % de uso, VRAM y temperatura de GPUs NVIDIA); el paquete de apt no lo trae."
    echo "    Si 'apt upgrade' llegara a reinstalar el paquete 'mangohud' y pisar el"
    echo "    binario compilado, volvé a correr este script para recompilarlo."
    echo "  - En Steam: Configuración → Compatibilidad → activá 'Habilitar Steam Play"
    echo "    para todos los demás títulos' y elegí la versión de Proton (o una de"
    echo "    ProtonPlus) que quieras usar por defecto."
    echo "  - Empezá cada juego SIN game-performance, solo con:"
    echo "      gamemoderun mangohud %command%"
    echo "    y mirá el overlay de MangoHud (% de uso y temperatura de CPU/GPU)."
    echo "    Si los FPS te alcanzan y no ves stuttering, dejalo así -- forzar más"
    echo "    no te da nada a cambio, solo calor y ruido de ventilador de más."
    echo "    Si notás FPS bajos o caídas puntuales, sumá game-performance:"
    echo "      game-performance gamemoderun mangohud %command%"
    echo "    game-performance cambia el perfil de energía a 'performance' mientras"
    echo "    el juego corre (en este equipo eso sincroniza a la vez gobernador de"
    echo "    CPU, EPP, y la curva de ventiladores de asusctl -- confirmado en la"
    echo "    práctica) y restaura el perfil anterior al cerrar el juego."
    echo "    Esto es por-juego, no una regla fija: en este mismo equipo se midió"
    echo "    un caso con los mismos FPS pero 27°C más de CPU al forzarlo, así que"
    echo "    no asumas que 'más forzado' es siempre mejor -- medí con MangoHud."
    echo "    Fuera de Steam (terminal, Heroic, Lutris) podés usar game-performance"
    echo "    igual: 'game-performance <comando>'."
    echo "  - Si tenés GPU NVIDIA dedicada, el script ya configuró 'pci_dev' en"
    echo "    ~/.config/MangoHud/MangoHud.conf con el bus-id detectado vía nvidia-smi."
    echo "    En equipos con GPU híbrida, si MangoJuice agrega 'gpu_list=' puede pisar"
    echo "    ese filtrado y volver a mostrar el % de GPU equivocado: comentá o borrá"
    echo "    esa línea si eso pasa."
    echo "  - ~/.config/gamemode.ini quedó creado (solo si no existía ya) con"
    echo "    desiredgov detectado automáticamente según tu driver cpufreq (schedutil"
    echo "    si está disponible, powersave si no -- en amd_pstate/intel_pstate en"
    echo "    modo activo, powersave YA es dinámico, no es el modo fijo-bajo de antes)."
    echo "    Así el CPU sube/baja de frecuencia según la carga real, en vez de"
    echo "    quedarse arriba fijo todo el tiempo que el juego está abierto. Si ya lo"
    echo "    tenías configurado a tu manera, el script no lo tocó. Corré"
    echo "    'gamemoded -t' para confirmar qué gobernador detectó y aplicó."
    echo "  - mesa-utils quedó instalado (glxgears, glxinfo) solo como herramienta de"
    echo "    diagnóstico rápido, para probar drivers/MangoHud sin abrir un juego."
    echo "  - Si acabás de habilitar ntsync, puede que necesites reiniciar para que"
    echo "    quede persistente en el próximo arranque."
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    require_root_privileges
    check_system_prerequisites

    log_info "Actualizando índices de apt (necesario para que los pasos siguientes detecten actualizaciones reales, no solo instalaciones nuevas)"
    sudo apt update

    step_steam
    step_ensure_flatpak
    step_protonplus
    step_heroic_launcher
    step_gamemode_mangohud
    step_gamemode_ini_defaults
    step_mangohud_pci_dev
    step_diagnostic_tools
    step_max_map_count
    step_ntsync
    step_install_game_performance
    step_summary
}

main "$@"
