#!/bin/bash
# Xcode "Run Script" build phase for the Fengshui iOS target (spec §8).
# Installs the CPython stdlib from Python.xcframework into <App>.app/python,
# turns binary extension modules into signed frameworks (BeeWare's utils.sh),
# and copies fengshui_engine + tzdata into <App>.app/app_packages.
set -euo pipefail

XCFW_REL="Python/Python.xcframework"          # relative to $PROJECT_DIR (apple/)
REPO="$PROJECT_DIR/.."
APP_PACKAGES="$CODESIGNING_FOLDER_PATH/app_packages"

if [ ! -d "$PROJECT_DIR/$XCFW_REL" ]; then
  echo "error: $XCFW_REL missing; run scripts/bootstrap.sh"
  exit 1
fi

# shellcheck disable=SC1091
source "$PROJECT_DIR/$XCFW_REL/build/utils.sh"

# The stdlib minus things the engine never uses; keeps the app small.
install_stdlib "$XCFW_REL"
PYTHON_VER=$(ls -1 "$CODESIGNING_FOLDER_PATH/python/lib" | grep -E "^python3\.[0-9]+$")
STDLIB="$CODESIGNING_FOLDER_PATH/python/lib/$PYTHON_VER"
for d in test idlelib tkinter turtledemo ensurepip lib2to3 pydoc_data unittest/test; do
  rm -rf "$STDLIB"/$d
done
find "$STDLIB" -name "__pycache__" -type d -prune -exec rm -rf {} +

process_dylibs "$XCFW_REL" "python/lib/$PYTHON_VER/lib-dynload"

# Our pure-Python packages.
mkdir -p "$APP_PACKAGES"
rsync -a --delete --exclude "__pycache__" "$REPO/engine/fengshui_engine/" "$APP_PACKAGES/fengshui_engine/"
TZDATA=$("$REPO/.venv/bin/python" -c "import tzdata, os; print(os.path.dirname(tzdata.__file__))")
rsync -a --delete --exclude "__pycache__" "$TZDATA/" "$APP_PACKAGES/tzdata/"
echo "build_python_ios: engine $(sed -n 's/^ENGINE_VERSION = "\(.*\)"/\1/p' "$REPO/engine/fengshui_engine/__init__.py") installed"
