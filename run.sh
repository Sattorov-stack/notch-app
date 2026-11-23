#!/bin/bash
# Запуск проекта: ./run.sh [start|stop|restart|status|open|log|fg]  (или командой p <имя>)
P_DIR="$(cd "$(dirname "$0")" && pwd)"
P_NAME=notchapp; P_DESC="NotchApp (челка MacBook)"; P_APP=NotchApp; P_APP_PATH=/Applications/NotchApp.app; P_APP_BUILD="./build_app.sh"
source "$HOME/Projects/_инструменты/launcher/lib.sh"
lib_main "$@"
