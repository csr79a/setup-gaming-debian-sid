# setup-gaming-debian-sid

Script para dejar **Debian Sid (Unstable) / KDE Plasma** listo para jugar: instala Steam, ProtonPlus, Heroic Games Launcher (con auto-actualización), GameMode, MangoHud (compilado desde fuente con soporte NVML) + MangoJuice como GUI opcional, Winetricks y Protontricks, herramientas de diagnóstico, y aplica ajustes del sistema recomendados para juegos modernos. Lutris y Gamescope se ofrecen como pasos opcionales.

Equivalente a [`setup-gaming-fedora`](https://github.com/csr79a/setup-gaming-fedora), adaptado a las herramientas reales disponibles en Debian — complementario a [`debian-sid-setup`](https://github.com/csr79a/debian-sid-setup).

> **Solo Debian Sid.** El script comprueba los repositorios al arrancar y se detiene si encuentra cualquier suite distinta de `unstable`/`sid` (forky, trixie, bookworm, testing, stable...). No convierte suites automáticamente.

## Estructura

```
setup-gaming-debian-sid/
├── setup-gaming-debian-sid.sh     # Script principal (instalación y configuración)
├── cleanup-gaming-debian-sid.sh   # Revierte lo que instala el script principal
├── README.md
└── MANUAL.md                      # Explicación detallada de cada paso
```

## Qué hace `setup-gaming-debian-sid.sh`

0. Comprueba que los repositorios apunten solo a `unstable`/`sid` (`debian.sources`, `sources.list` y el resto de ficheros de `sources.list.d`); si no, se detiene sin preguntar
1. Instala **Steam** con `steam-installer` del repositorio oficial de Debian (`contrib`), habilitando la arquitectura i386 si hace falta
2. Instala/actualiza **Flatpak** y configura el remoto **Flathub**
3. Instala/actualiza **ProtonPlus** vía Flatpak
4. Descarga el último `.deb` de **Heroic Games Launcher** publicado en GitHub y lo instala/actualiza (compara versión instalada vs. disponible)
5. Instala **GameMode** vía `apt`, **compila MangoHud desde el último tag estable con soporte NVML** (necesario para leer % de uso, VRAM y temperatura en GPUs NVIDIA — el paquete de Debian no lo trae) y ofrece instalar **MangoJuice** (Flatpak) como GUI de configuración
6. Instala **Winetricks** y **Protontricks** (paquetes nativos de Debian, `contrib`), deja `wineserver` accesible en el `PATH` si hace falta e intenta instalar `wine32:i386` sin forzar nada (Wine 10 ya ejecuta apps de 32 bits; si hay un conflicto temporal en Sid, informa y continúa)
7. Crea `~/.config/gamemode.ini` con un gobernador de CPU dinámico elegido según tu driver (solo si el fichero no existe)
8. En equipos con GPU NVIDIA, detecta el `pci_dev` correcto vía `nvidia-smi` y lo configura en `MangoHud.conf` (evita lecturas erróneas en gráficas híbridas)
9. Instala **mesa-utils** (`glxgears`, `glxinfo`) como herramientas rápidas de diagnóstico
10. Ajusta `vm.max_map_count` a un valor alto, recomendado por varios juegos/motores modernos
11. Verifica si el kernel soporta **ntsync**, lo activa y lo deja persistente en cada arranque (si es un módulo cargable)
12. Instala `power-profiles-daemon` si hace falta y agrega el wrapper **`game-performance`** (`/usr/local/bin/game-performance`), que activa el perfil de energía "performance" mientras corre el proceso que le pases y restaura el perfil anterior al terminar
13. **Lutris** (opcional): se pregunta antes de instalarlo; si ya está instalado, se actualiza
14. **Gamescope** (opcional): igual que Lutris

Al terminar, el script hace unas **verificaciones finales** (solo comprueban, no lanzan Steam ni juegos) y muestra un resumen con los pasos manuales pendientes, si los hay.

El script es **idempotente**: se puede correr varias veces sin romper nada, y está pensado para volver a correrse periódicamente (actualiza Heroic, ProtonPlus y MangoJuice, y recompila MangoHud cuando sale un tag estable nuevo en upstream).

## Por qué esta combinación de apt / .deb / Flatpak / compilación

No es un criterio parejo por sistema, sino "la mejor fuente real para cada herramienta" en Debian:

| Herramienta | Fuente | Por qué |
|---|---|---|
| Steam | `steam-installer` (`apt`, `contrib`) | Paquete oficial de Debian; se actualiza con `apt upgrade`. Si ya tienes `steam-launcher` de Valve instalado, el script lo respeta y no mezcla los dos |
| ProtonPlus | Flatpak | El propio proyecto indica que **Flathub es su método principal de instalación**; no existe paquete nativo para Debian |
| Heroic Games Launcher | `.deb` oficial, auto-descargado desde GitHub | Heroic publica un `.deb` oficial en cada release — mismo mecanismo de auto-actualización que en el proyecto de Fedora (ahí con `.rpm`) |
| GameMode | `apt` (repos de Sid) | Va razonablemente al día en Debian Unstable, sin necesidad de nada externo |
| MangoHud | **Compilado desde fuente** (`meson`/`ninja`, último tag estable, con `-Dwith_nvml=enabled`) | El paquete `mangohud` de Debian es la build DFSG, compilada **sin soporte NVML**: en GPUs NVIDIA no muestra % de uso, VRAM ni temperatura. El script detecta esto, desinstala el paquete de apt si estaba presente, y compila la última versión estable de upstream con NVML habilitado. Se fija un tag (nunca el `HEAD` de la rama de desarrollo) para evitar roturas por dependencias nuevas |
| MangoJuice | Flatpak (opcional) | GUI para configurar MangoHud sin editar ficheros. Se pregunta si quieres instalarla. Si el sandbox de Flatpak no le deja acceder a `~/.config/MangoHud`, el `MANUAL.md` indica el `flatpak override` necesario |
| Winetricks / Protontricks | `apt` (`contrib`) | Paquetes nativos de Debian, sin Flatpak ni compilar nada |
| Lutris / Gamescope | `apt` (`contrib`), opcionales | Versiones recientes en Sid; solo se instalan si respondes que sí |
| mesa-utils | `apt` | Herramientas de diagnóstico estándar (`glxgears`, `glxinfo`) para probar drivers/MangoHud sin abrir un juego |

## Uso rápido

```
git clone https://github.com/csr79a/setup-gaming-debian-sid.git
cd setup-gaming-debian-sid

chmod +x setup-gaming-debian-sid.sh
./setup-gaming-debian-sid.sh
```

Ejecútalo como usuario normal (no como root); se te pedirá la contraseña de `sudo` cuando haga falta.

## Revertir los cambios

`cleanup-gaming-debian-sid.sh` deshace lo que instala y configura el script principal. Cada bloque pide confirmación.

```
./cleanup-gaming-debian-sid.sh --dry-run      # solo muestra lo que haría
./cleanup-gaming-debian-sid.sh                # pregunta bloque a bloque
./cleanup-gaming-debian-sid.sh -y             # acepta las preguntas normales
./cleanup-gaming-debian-sid.sh --purge-data   # además ofrece borrar datos de usuario
```

Pregunta aparte (y `-y` nunca lo acepta) por el `autoremove`, la línea `pci_dev` de `MangoHud.conf`, el `deb-src` que activó el setup y el enlace `/usr/local/bin/wineserver`. Deja intactos a propósito `power-profiles-daemon`, Flatpak y Flathub, la arquitectura i386 y tus datos de juego (salvo que uses `--purge-data`).

Ver `MANUAL.md` para el detalle de cada paso.
